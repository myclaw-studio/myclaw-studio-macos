import XCTest
@testable import MyClaw

final class AppConfigTests: XCTestCase {

    // 测试用的 UserDefaults key，避免污染真实配置
    private let testKeys = [
        "aichat.provider", "aichat.anthropic_key", "aichat.openai_key",
        "aichat.google_key", "aichat.deepseek_key", "aichat.minimax_key",
        "aichat.doubao_key", "aichat.composio_api_key", "aichat.use_own_key",
        "aichat.model", "aichat.backend_url", "aichat.local_mode",
    ]

    override func setUp() {
        super.setUp()
        // 保存原始值
    }

    override func tearDown() {
        super.tearDown()
    }

    // MARK: - apiKey(for:)

    func testApiKeyForClaude() {
        let original = AppConfig.anthropicKey
        defer { AppConfig.anthropicKey = original }

        AppConfig.anthropicKey = "test-claude-key"
        XCTAssertEqual(AppConfig.apiKey(for: "claude"), "test-claude-key")
    }

    func testApiKeyForOpenAI() {
        let original = AppConfig.openaiKey
        defer { AppConfig.openaiKey = original }

        AppConfig.openaiKey = "test-openai-key"
        XCTAssertEqual(AppConfig.apiKey(for: "openai"), "test-openai-key")
    }

    func testApiKeyForGemini() {
        let original = AppConfig.googleKey
        defer { AppConfig.googleKey = original }

        AppConfig.googleKey = "test-google-key"
        XCTAssertEqual(AppConfig.apiKey(for: "gemini"), "test-google-key")
    }

    func testApiKeyForDeepseek() {
        let original = AppConfig.deepseekKey
        defer { AppConfig.deepseekKey = original }

        AppConfig.deepseekKey = "test-ds-key"
        XCTAssertEqual(AppConfig.apiKey(for: "deepseek"), "test-ds-key")
    }

    func testApiKeyForUnknownProvider() {
        XCTAssertEqual(AppConfig.apiKey(for: "unknown_provider"), "", "未知 provider 应返回空字符串")
    }

    // MARK: - URL Construction

    func testWsURL() {
        let original = AppConfig.backendURL
        defer { AppConfig.backendURL = original }

        AppConfig.backendURL = "http://localhost:8000"
        XCTAssertEqual(AppConfig.wsURL.absoluteString, "ws://localhost:8000/ws/chat")

        AppConfig.backendURL = "https://api.example.com"
        XCTAssertEqual(AppConfig.wsURL.absoluteString, "wss://api.example.com/ws/chat")
    }

    func testHttpBase() {
        let original = AppConfig.backendURL
        defer { AppConfig.backendURL = original }

        AppConfig.backendURL = "http://localhost:8000"
        XCTAssertEqual(AppConfig.httpBase.absoluteString, "http://localhost:8000")
    }

    // MARK: - usesOwnKey

    func testUsesOwnKeyWhenEnabled() {
        let origUseOwn = AppConfig.useOwnKey
        let origProvider = AppConfig.provider
        let origKey = AppConfig.anthropicKey
        defer {
            AppConfig.useOwnKey = origUseOwn
            AppConfig.provider = origProvider
            AppConfig.anthropicKey = origKey
        }

        AppConfig.useOwnKey = true
        AppConfig.provider = "claude"
        AppConfig.anthropicKey = "sk-test"
        XCTAssertTrue(AppConfig.usesOwnKey, "有 key + useOwnKey=true 应返回 true")
    }

    func testUsesOwnKeyWhenDisabled() {
        let origUseOwn = AppConfig.useOwnKey
        defer { AppConfig.useOwnKey = origUseOwn }

        AppConfig.useOwnKey = false
        XCTAssertFalse(AppConfig.usesOwnKey, "useOwnKey=false 应返回 false")
    }

    func testUsesOwnKeyWithEmptyKey() {
        let origUseOwn = AppConfig.useOwnKey
        let origProvider = AppConfig.provider
        let origKey = AppConfig.anthropicKey
        defer {
            AppConfig.useOwnKey = origUseOwn
            AppConfig.provider = origProvider
            AppConfig.anthropicKey = origKey
        }

        AppConfig.useOwnKey = true
        AppConfig.provider = "claude"
        AppConfig.anthropicKey = ""
        XCTAssertFalse(AppConfig.usesOwnKey, "key 为空时应返回 false")
    }

    // MARK: - configPayload

    func testConfigPayloadIncludesKeysWhenUseOwnKey() {
        let origUseOwn = AppConfig.useOwnKey
        let origKey = AppConfig.anthropicKey
        defer {
            AppConfig.useOwnKey = origUseOwn
            AppConfig.anthropicKey = origKey
        }

        AppConfig.useOwnKey = true
        AppConfig.anthropicKey = "test-key"
        let payload = AppConfig.configPayload()

        XCTAssertEqual(payload["anthropic_api_key"] as? String, "test-key")
        XCTAssertNotNil(payload["model"])
        XCTAssertNotNil(payload["provider"])
    }

    func testConfigPayloadExcludesKeysWhenNotOwnKey() {
        let origUseOwn = AppConfig.useOwnKey
        defer { AppConfig.useOwnKey = origUseOwn }

        AppConfig.useOwnKey = false
        let payload = AppConfig.configPayload()

        XCTAssertNil(payload["anthropic_api_key"], "useOwnKey=false 时不应包含 API key")
        XCTAssertNil(payload["openai_api_key"])
    }

    // MARK: - Default Values

    func testDefaultModel() {
        // 清除自定义值测试默认值
        let original = UserDefaults.standard.string(forKey: "aichat.model")
        UserDefaults.standard.removeObject(forKey: "aichat.model")
        defer {
            if let orig = original {
                UserDefaults.standard.set(orig, forKey: "aichat.model")
            }
        }

        XCTAssertEqual(AppConfig.model, "claude-sonnet-4-6")
    }

    func testDefaultProvider() {
        let original = UserDefaults.standard.string(forKey: "aichat.provider")
        UserDefaults.standard.removeObject(forKey: "aichat.provider")
        defer {
            if let orig = original {
                UserDefaults.standard.set(orig, forKey: "aichat.provider")
            }
        }

        XCTAssertEqual(AppConfig.provider, "claude")
    }
}
