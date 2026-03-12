import Foundation

struct AppConfig {
    static var language: String {
        get { UserDefaults.standard.string(forKey: "aichat.language") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.language") }
    }

    static var backendURL: String {
        get { UserDefaults.standard.string(forKey: "aichat.backend_url") ?? "http://localhost:8000" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.backend_url") }
    }
    static var anthropicKey: String {
        get { UserDefaults.standard.string(forKey: "aichat.anthropic_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.anthropic_key") }
    }
    /// 自带 Key 时的模型提供商：claude | openai | gemini
    static var provider: String {
        get { UserDefaults.standard.string(forKey: "aichat.provider") ?? "claude" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.provider") }
    }
    static var openaiKey: String {
        get { UserDefaults.standard.string(forKey: "aichat.openai_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.openai_key") }
    }
    static var googleKey: String {
        get { UserDefaults.standard.string(forKey: "aichat.google_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.google_key") }
    }
    static var deepseekKey: String {
        get { UserDefaults.standard.string(forKey: "aichat.deepseek_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.deepseek_key") }
    }
    static var minimaxKey: String {
        get { UserDefaults.standard.string(forKey: "aichat.minimax_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.minimax_key") }
    }
    static var doubaoKey: String {
        get { UserDefaults.standard.string(forKey: "aichat.doubao_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.doubao_key") }
    }
    static var composioApiKey: String {
        get { UserDefaults.standard.string(forKey: "aichat.composio_api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.composio_api_key") }
    }
    /// 根据 provider id 取当前存储的 API Key
    static func apiKey(for providerId: String) -> String {
        switch providerId {
        case "claude": return anthropicKey
        case "openai": return openaiKey
        case "gemini": return googleKey
        case "deepseek": return deepseekKey
        case "minimax": return minimaxKey
        case "doubao": return doubaoKey
        default: return ""
        }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: "aichat.model") ?? "claude-sonnet-4-6" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.model") }
    }
    static var modelCategory: String {
        get { UserDefaults.standard.string(forKey: "aichat.model_category") ?? "sonnet" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.model_category") }
    }
    static var utilityModel: String {
        get { UserDefaults.standard.string(forKey: "aichat.utility_model") ?? "claude-haiku-4-5" }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.utility_model") }
    }
    static var enabledTools: Set<String> {
        get {
            if let arr = UserDefaults.standard.stringArray(forKey: "aichat.enabled_tools") {
                return Set(arr)
            }
            return Set(ToolInfo.catalog.map(\.id))
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: "aichat.enabled_tools") }
    }

    static var wsURL: URL {
        let base = backendURL
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
        return URL(string: "\(base)/ws/chat")!
    }

    static var httpBase: URL {
        URL(string: backendURL)!
    }

    // MARK: - 云端配置（代理到 CloudConfig，集中管理）

    static var serviceBaseURL: String {
        get { CloudConfig.serviceBaseURL }
        set { CloudConfig.serviceBaseURL = newValue }
    }
    static var authBaseURL: String {
        get { CloudConfig.authBaseURL }
        set { CloudConfig.authBaseURL = newValue }
    }
    static var paymentBackendURL: String {
        get { CloudConfig.paymentBackendURL }
        set { CloudConfig.paymentBackendURL = newValue }
    }
    static var usesPaymentBackend: Bool { CloudConfig.usesPaymentBackend }
    static var paymentSuccessURL: String { CloudConfig.paymentSuccessURL }
    static var paymentCancelURL: String { CloudConfig.paymentCancelURL }
    static var authToken: String { CloudConfig.authToken }

    /// 用户选择的服务模式：true = 自带 API Key，false = Clawbie 云端服务
    static var useOwnKey: Bool {
        get { UserDefaults.standard.bool(forKey: "aichat.use_own_key") }
        set { UserDefaults.standard.set(newValue, forKey: "aichat.use_own_key") }
    }

    static var cachedCloudModels: [BackendService.ModelOption] {
        get { CloudConfig.cachedCloudModels }
        set { CloudConfig.cachedCloudModels = newValue }
    }

    /// 是否实际在使用自有 API Key（兼容旧逻辑）
    static var usesOwnKey: Bool {
        if !useOwnKey { return false }
        return !apiKey(for: provider).isEmpty
    }

    /// 当前选中提供商的 API Key（用于校验等）
    static var currentProviderKey: String {
        apiKey(for: provider)
    }

    static func configPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "utility_model": utilityModel,
            "auth_token": authToken,
            "enabled_tools": Array(enabledTools),
            "provider": provider,
        ]
        if useOwnKey {
            payload["anthropic_api_key"] = anthropicKey
            payload["openai_api_key"] = openaiKey
            payload["google_api_key"] = googleKey
            payload["deepseek_api_key"] = deepseekKey
            payload["minimax_api_key"] = minimaxKey
            payload["doubao_api_key"] = doubaoKey
        }
        return payload
    }
}
