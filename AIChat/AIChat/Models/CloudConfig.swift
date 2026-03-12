import Foundation

// MARK: - 云端服务配置
// 从 Resources/cloud_config.json 读取云端服务地址。
// 开发者只需修改 cloud_config.json 即可切换云端服务，无需改 Swift 代码。
// 所有地址留空 → 本地模式（跳过登录，隐藏付费功能，需自备 API Key）。

struct CloudConfig {

    // MARK: - 从 JSON 加载的配置（启动时读取一次）

    private static let config: [String: Any] = {
        guard let url = Bundle.main.url(forResource: "cloud_config", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }()

    /// JSON 中的默认值（编译时固定）
    private static let jsonServiceBaseURL = config["service_base_url"] as? String ?? ""
    private static let jsonAuthBaseURL = config["auth_base_url"] as? String ?? ""
    private static let jsonPaymentBaseURL = config["payment_base_url"] as? String ?? ""

    // MARK: - 服务地址（UserDefaults 覆盖 > JSON 默认值）

    static var serviceBaseURL: String {
        get { UserDefaults.standard.string(forKey: "aichat.service_base_url") ?? jsonServiceBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.service_base_url") }
    }

    static var authBaseURL: String {
        get { UserDefaults.standard.string(forKey: "aichat.auth_base_url") ?? jsonAuthBaseURL }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.auth_base_url") }
    }

    static var paymentBackendURL: String {
        get {
            let stored = UserDefaults.standard.string(forKey: "aichat.payment_backend_url") ?? jsonPaymentBaseURL
            return stored.isEmpty ? serviceBaseURL : stored
        }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.payment_backend_url") }
    }

    // MARK: - 模式判断

    static var isCloudMode: Bool {
        !serviceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var isLocalMode: Bool { !isCloudMode }

    static var usesPaymentBackend: Bool {
        isCloudMode && !paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 云端认证

    static var authToken: String {
        if let data = UserDefaults.standard.data(forKey: "auth_session"),
           let session = try? JSONDecoder().decode(UserSession.self, from: data) {
            return session.accessToken
        }
        return ""
    }

    // MARK: - 云端模型缓存

    static var cachedCloudModels: [BackendService.ModelOption] {
        get {
            guard let data = UserDefaults.standard.data(forKey: "aichat.cloud_models"),
                  let models = try? JSONDecoder().decode([BackendService.ModelOption].self, from: data)
            else { return [] }
            return models
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: "aichat.cloud_models")
        }
    }

    // MARK: - 回调 URL

    static var paymentSuccessURL: String { "myclaw://payment/success" }
    static var paymentCancelURL: String { "myclaw://payment/cancel" }

    // MARK: - URL 工具方法

    static func apiURL(_ path: String) -> String {
        let base = serviceBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)\(path)"
    }

    static func paymentURL(_ path: String) -> String {
        var base = paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.isEmpty { base = serviceBaseURL }
        return "\(base)\(path)"
    }

    static func wsURL(_ path: String) -> String {
        let base = serviceBaseURL
            .replacingOccurrences(of: "https://", with: "wss://")
            .replacingOccurrences(of: "http://", with: "ws://")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(base)\(path)"
    }
}
