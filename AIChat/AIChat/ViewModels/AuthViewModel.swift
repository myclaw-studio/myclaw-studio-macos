import SwiftUI
import Combine
import AuthenticationServices

enum PaymentResult {
    case success, cancelled
}

@MainActor
class AuthViewModel: ObservableObject {
    @Published var session: UserSession?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var tokenBalance: Int = 0
    @Published var paymentResult: PaymentResult?
    @Published var currentPlan: String = "free"
    @Published var subscriptionStatus: String = "active"
    @Published var currentPeriodEnd: Date?
    @Published var trialEnd: Date?
    @Published var isTrial: Bool = false

    private var balanceTask: URLSessionWebSocketTask?
    private var balanceListenTask: Task<Void, Never>?
    private var chatCompleteObserver: Any?

    init() {
        session = AuthService.shared.loadSession()

        // 有登录态就验证 token 是否有效
        if let token = session?.accessToken {
            Task { await validateSession(token: token) }
        }
        // 聊天完成后主动刷新余额
        chatCompleteObserver = NotificationCenter.default.addObserver(
            forName: .chatDidComplete, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshBalance()
            }
        }
    }

    deinit {
        if let obs = chatCompleteObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// 启动时验证 token，过期则自动退出登录
    private func validateSession(token: String) async {
        if AppConfig.usesPaymentBackend {
            if let sub = try? await BackendService().fetchSubscription(accessToken: token) {
                tokenBalance = sub.balanceSonnet
                currentPlan = sub.plan
                subscriptionStatus = sub.status
                currentPeriodEnd = sub.currentPeriodEnd
                isTrial = sub.isTrial
                trialEnd = sub.trialEnd
                connectBalanceWS(token: token)
            } else {
                let balance = try? await BackendService().fetchBalanceFromPaymentBackend(accessToken: token)
                if let b = balance, b >= 0 {
                    tokenBalance = b
                    connectBalanceWS(token: token)
                } else if balance == -401 {
                    signOut()
                }
            }
        } else {
            let balance = try? await BackendService().fetchBalance(accessToken: token)
            if let b = balance, b >= 0 {
                tokenBalance = b
                connectBalanceWS(token: token)
            } else if balance == -401 {
                signOut()
            }
        }
    }

    /// 是否本地模式（无需云端账户）
    @Published var isLocalMode: Bool = UserDefaults.standard.bool(forKey: "aichat.local_mode")

    var isAuthenticated: Bool { session != nil || isLocalMode }

    var displayName: String {
        if isLocalMode { return L.isEN ? "Local User" : "本地用户" }
        return session?.displayName ?? session?.email ?? "User"
    }
    var avatarLetter: String { String(displayName.prefix(1)).uppercased() }

    // MARK: - 余额

    func refreshBalance(token: String? = nil) async {
        guard let accessToken = token ?? session?.accessToken else { return }
        if AppConfig.usesPaymentBackend {
            if let sub = try? await BackendService().fetchSubscription(accessToken: accessToken) {
                tokenBalance = sub.balanceSonnet
                currentPlan = sub.plan
                subscriptionStatus = sub.status
                currentPeriodEnd = sub.currentPeriodEnd
                isTrial = sub.isTrial
                trialEnd = sub.trialEnd
                return
            }
        }
        let balance: Int?
        if AppConfig.usesPaymentBackend {
            balance = try? await BackendService().fetchBalanceFromPaymentBackend(accessToken: accessToken)
        } else {
            balance = try? await BackendService().fetchBalance(accessToken: accessToken)
        }
        if let b = balance, b >= 0 {
            tokenBalance = b
        } else if balance == -401 {
            signOut()
        }
    }

    // MARK: - 余额 WebSocket

    private func connectBalanceWS(token: String) {
        disconnectBalanceWS()
        let url: URL?
        if AppConfig.usesPaymentBackend {
            url = BackendService().paymentBackendBalanceWebSocketURL(accessToken: token)
        } else {
            let wsBase = AppConfig.serviceBaseURL.replacingOccurrences(of: "https://", with: "wss://").replacingOccurrences(of: "http://", with: "ws://")
            url = URL(string: "\(wsBase)/api/v1/credits/balance/ws?token=\(token)")
        }
        guard let url else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        balanceTask = task
        balanceListenTask = Task { [weak self] in
            await self?.listenBalance(task: task, token: token)
        }
    }

    private func listenBalance(task: URLSessionWebSocketTask, token: String) async {
        while !Task.isCancelled && task.state == .running {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let balance = json["balance_sonnet"] as? Int {
                        await MainActor.run { self.tokenBalance = balance }
                    }
                default:
                    break
                }
            } catch {
                // 连接断开，等 3 秒后重连
                if !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if !Task.isCancelled {
                        await MainActor.run { self.connectBalanceWS(token: token) }
                    }
                }
                return
            }
        }
    }

    private func disconnectBalanceWS() {
        balanceListenTask?.cancel()
        balanceListenTask = nil
        balanceTask?.cancel(with: .goingAway, reason: nil)
        balanceTask = nil
    }

    // MARK: - 登录

    func signInWithGoogle() async {
        isLoading = true
        errorMessage = nil
        do {
            let s = try await AuthService.shared.signInWithGoogle()
            AuthService.shared.saveSession(s)
            session = s
            await refreshBalance(token: s.accessToken)
            connectBalanceWS(token: s.accessToken)
        } catch ASWebAuthenticationSessionError.canceledLogin {
            // 用户主动取消，不显示错误
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    #if DEBUG
    func signInWithPassword(username: String, password: String) {
        errorMessage = nil
        do {
            let s = try AuthService.shared.signInWithPassword(username: username, password: password)
            AuthService.shared.saveSession(s)
            session = s
            Task {
                await refreshBalance(token: s.accessToken)
                connectBalanceWS(token: s.accessToken)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    #endif

    func enterLocalMode() {
        UserDefaults.standard.set(true, forKey: "aichat.local_mode")
        isLocalMode = true
        AppConfig.useOwnKey = true
    }

    func exitLocalMode() {
        UserDefaults.standard.set(false, forKey: "aichat.local_mode")
        isLocalMode = false
    }

    func signOut() {
        disconnectBalanceWS()
        AuthService.shared.clearSession()
        session = nil
        tokenBalance = 0
        currentPlan = "free"
        subscriptionStatus = "active"
        currentPeriodEnd = nil
        isTrial = false
        trialEnd = nil
    }

    /// True when user is in an active trial (not expired).
    /// Backend sets is_trial=true while trial is active, or we check trial_end directly.
    var isTrialActive: Bool {
        guard let end = trialEnd else { return false }
        return end > Date() && currentPlan == "free"
    }

    /// True when trial has expired and user has no paid plan.
    /// Backend sets is_trial=false after trial ends, so we check trial_end directly.
    var isTrialExpired: Bool {
        guard let end = trialEnd else { return false }
        return end <= Date() && currentPlan == "free"
    }

    /// Days remaining in trial period. nil if not on trial.
    var trialDaysLeft: Int? {
        guard let end = trialEnd, isTrialActive else { return nil }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfEnd = calendar.startOfDay(for: end)
        return calendar.dateComponents([.day], from: startOfToday, to: startOfEnd).day
    }

    /// Days until current_period_end (nil if no period or free). Can be negative if already past.
    var daysUntilPeriodEnd: Int? {
        guard let end = currentPeriodEnd, currentPlan != "free" else { return nil }
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        let startOfEnd = calendar.startOfDay(for: end)
        return calendar.dateComponents([.day], from: startOfToday, to: startOfEnd).day
    }

    /// True when status is canceled and period end date has passed (expired).
    var isSubscriptionExpired: Bool {
        guard subscriptionStatus == "canceled", currentPlan != "free", let end = currentPeriodEnd else { return false }
        return end <= Date()
    }
}
