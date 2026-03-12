import Foundation
import AuthenticationServices

// MARK: - 数据模型

struct UserSession: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let tokenType: String
    var displayName: String?
    var email: String?

    enum CodingKeys: String, CodingKey {
        case accessToken  = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn    = "expires_in"
        case tokenType    = "token_type"
        case displayName  = "display_name"
        case email
    }
}

enum AuthError: LocalizedError {
    case invalidURL
    case noCallback
    case invalidCallback
    case missingTokens
    case invalidCredentials

    var errorDescription: String? {
        switch self {
        case .invalidURL:          return "无效的认证 URL"
        case .noCallback:          return "未收到登录回调"
        case .invalidCallback:     return "回调 URL 格式错误"
        case .missingTokens:       return "登录响应中缺少 token"
        case .invalidCredentials:  return "账号或密码错误"
        }
    }
}

// MARK: - AuthService

class AuthService: NSObject {
    static let shared = AuthService()

    private var supabaseURL: String { AppConfig.authBaseURL }
    private let callbackScheme = "myclaw"
    private let callbackURL    = "myclaw://login-callback"
    private let sessionKey     = "auth_session"

    // 持有引用，防止 ASWebAuthenticationSession 被提前释放
    private var currentSession: ASWebAuthenticationSession?

    // MARK: - Google 登录

    func signInWithGoogle() async throws -> UserSession {
        var components = URLComponents(string: "\(supabaseURL)/auth/v1/authorize")!
        components.queryItems = [
            URLQueryItem(name: "provider",     value: "google"),
            URLQueryItem(name: "redirect_to",  value: callbackURL),
        ]
        guard let authURL = components.url else { throw AuthError.invalidURL }

        let callbackResult: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] url, error in
                self?.currentSession = nil
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let url = url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: AuthError.noCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            currentSession = session
            session.start()
        }

        return try parseCallback(callbackResult)
    }

    // MARK: - 解析 Supabase 回调
    // Supabase 把 tokens 放在 URL fragment：myclaw://login-callback#access_token=...

    private func parseCallback(_ url: URL) throws -> UserSession {
        let raw = url.fragment ?? url.query ?? ""
        guard !raw.isEmpty else { throw AuthError.invalidCallback }

        var params: [String: String] = [:]
        raw.components(separatedBy: "&").forEach { pair in
            let parts = pair.components(separatedBy: "=")
            if parts.count == 2 {
                params[parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
            }
        }

        guard let accessToken  = params["access_token"],
              let refreshToken = params["refresh_token"] else {
            throw AuthError.missingTokens
        }

        return UserSession(
            accessToken:  accessToken,
            refreshToken: refreshToken,
            expiresIn:    Int(params["expires_in"] ?? "3600") ?? 3600,
            tokenType:    params["token_type"] ?? "bearer"
        )
    }

    // MARK: - Session 持久化（UserDefaults）

    func saveSession(_ session: UserSession) {
        if let data = try? JSONEncoder().encode(session) {
            UserDefaults.standard.set(data, forKey: sessionKey)
        }
    }

    func loadSession() -> UserSession? {
        guard let data = UserDefaults.standard.data(forKey: sessionKey) else { return nil }
        return try? JSONDecoder().decode(UserSession.self, from: data)
    }

    func clearSession() {
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    // MARK: - Local debug login (non-functional stub, DEBUG builds only)

    #if DEBUG
    /// This is a non-functional stub for local development only.
    /// It does not connect to any real authentication service.
    func signInWithPassword(username: String, password: String) throws -> UserSession {
        guard username == "dev_stub" && password == "not_a_real_password" else {
            throw AuthError.invalidCredentials
        }
        return UserSession(
            accessToken:  "local_debug_token",
            refreshToken: "local_debug_refresh",
            expiresIn:    86400 * 365,
            tokenType:    "bearer",
            displayName:  "Debug User",
            email:        "debug@example.com"
        )
    }
    #endif
}

// MARK: - macOS 窗口锚点

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if Thread.isMainThread {
            return NSApplication.shared.windows.first ?? NSWindow()
        }
        return DispatchQueue.main.sync {
            NSApplication.shared.windows.first ?? NSWindow()
        }
    }
}
