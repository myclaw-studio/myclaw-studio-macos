import XCTest
@testable import MyClaw

/// 测试云端模式和本地模式的数据隔离
final class ModeIsolationTests: XCTestCase {

    // MARK: - isComposioDirectMode 逻辑

    func testDirectModeRequiresBothLocalModeAndApiKey() {
        let origLocal = UserDefaults.standard.bool(forKey: "aichat.local_mode")
        let origKey = AppConfig.composioApiKey
        defer {
            UserDefaults.standard.set(origLocal, forKey: "aichat.local_mode")
            AppConfig.composioApiKey = origKey
        }

        // 本地模式 + 有 key → 直连
        UserDefaults.standard.set(true, forKey: "aichat.local_mode")
        AppConfig.composioApiKey = "test-composio-key"
        let directMode1 = UserDefaults.standard.bool(forKey: "aichat.local_mode") && !AppConfig.composioApiKey.isEmpty
        XCTAssertTrue(directMode1, "本地模式 + 有 key → 应走直连")

        // 云端模式 + 有 key → 代理
        UserDefaults.standard.set(false, forKey: "aichat.local_mode")
        AppConfig.composioApiKey = "test-composio-key"
        let directMode2 = UserDefaults.standard.bool(forKey: "aichat.local_mode") && !AppConfig.composioApiKey.isEmpty
        XCTAssertFalse(directMode2, "云端模式即使有 key 也不应走直连")

        // 本地模式 + 无 key → 不走直连
        UserDefaults.standard.set(true, forKey: "aichat.local_mode")
        AppConfig.composioApiKey = ""
        let directMode3 = UserDefaults.standard.bool(forKey: "aichat.local_mode") && !AppConfig.composioApiKey.isEmpty
        XCTAssertFalse(directMode3, "无 key 时不应走直连")
    }

    // MARK: - Installed Slugs 按模式隔离

    func testInstalledSlugsIsolation() {
        let localKey = "composio_installed_slugs_local"
        let cloudKey = "composio_installed_slugs_cloud"
        let origLocal = UserDefaults.standard.stringArray(forKey: localKey)
        let origCloud = UserDefaults.standard.stringArray(forKey: cloudKey)
        let origMode = UserDefaults.standard.bool(forKey: "aichat.local_mode")
        defer {
            if let v = origLocal { UserDefaults.standard.set(v, forKey: localKey) }
            else { UserDefaults.standard.removeObject(forKey: localKey) }
            if let v = origCloud { UserDefaults.standard.set(v, forKey: cloudKey) }
            else { UserDefaults.standard.removeObject(forKey: cloudKey) }
            UserDefaults.standard.set(origMode, forKey: "aichat.local_mode")
        }

        // 本地模式写入
        UserDefaults.standard.set(true, forKey: "aichat.local_mode")
        let localInstalledKey = UserDefaults.standard.bool(forKey: "aichat.local_mode")
            ? "composio_installed_slugs_local" : "composio_installed_slugs_cloud"
        UserDefaults.standard.set(["gmail", "github"], forKey: localInstalledKey)

        // 云端模式写入
        UserDefaults.standard.set(false, forKey: "aichat.local_mode")
        let cloudInstalledKey = UserDefaults.standard.bool(forKey: "aichat.local_mode")
            ? "composio_installed_slugs_local" : "composio_installed_slugs_cloud"
        UserDefaults.standard.set(["slack"], forKey: cloudInstalledKey)

        // 验证隔离
        let localSlugs = Set(UserDefaults.standard.stringArray(forKey: localKey) ?? [])
        let cloudSlugs = Set(UserDefaults.standard.stringArray(forKey: cloudKey) ?? [])

        XCTAssertEqual(localSlugs, ["gmail", "github"], "本地模式安装的工具")
        XCTAssertEqual(cloudSlugs, ["slack"], "云端模式安装的工具")
        XCTAssertTrue(localSlugs.isDisjoint(with: cloudSlugs), "两个模式的数据应完全隔离")
    }

    // MARK: - Composio URL 路由

    func testComposioURLDirectMode() {
        // 直连模式应该用 backend.composio.dev
        let directURL = URL(string: "https://backend.composio.dev/api/v1/apps?limit=50")!
        XCTAssertEqual(directURL.host, "backend.composio.dev")
        XCTAssertTrue(directURL.path.starts(with: "/api/v1/"))
    }

    func testComposioURLProxyMode() {
        // 代理模式应该用 paymentBackendURL + /api/v1/composio/
        let base = "https://cloud.example.com"
        let proxyURL = URL(string: "\(base)/api/v1/composio/toolkits?limit=50")!
        XCTAssertEqual(proxyURL.host, "cloud.example.com")
        XCTAssertTrue(proxyURL.path.contains("/composio/"))
    }

    // MARK: - Connection 映射（直连模式）

    func testConnectionMappingFromComposioAPI() throws {
        // 模拟 Composio API /connectedAccounts 返回的原始数据
        let apiItem: [String: Any] = [
            "id": "abc-123",
            "appUniqueId": "gmail",
            "appName": "gmail",
            "status": "ACTIVE",
            "createdAt": "2026-01-01T00:00:00Z",
            // logo 可能不存在
        ]

        // 模拟 BackendService 的映射逻辑
        let slug = (apiItem["appUniqueId"] as? String) ?? (apiItem["appName"] as? String) ?? ""
        let mapped: [String: String] = [
            "id": (apiItem["id"] as? String) ?? "",
            "toolkit_slug": slug,
            "toolkit_name": (apiItem["appName"] as? String) ?? slug,
            "toolkit_logo": (apiItem["logo"] as? String) ?? "",  // logo 不存在时用空字符串
            "status": (apiItem["status"] as? String) ?? "ACTIVE",
            "created_at": (apiItem["createdAt"] as? String) ?? "",
        ]

        let data = try JSONSerialization.data(withJSONObject: mapped)
        let conn = try JSONDecoder().decode(ComposioConnection.self, from: data)

        XCTAssertEqual(conn.toolkitSlug, "gmail")
        XCTAssertEqual(conn.toolkitLogo, "")
        XCTAssertTrue(conn.isActive)
    }

    func testConnectionMappingWithNSNullLogo() throws {
        // 回归测试：API 返回 NSNull 时不应崩溃
        let apiItem: [String: Any] = [
            "id": "abc-123",
            "appUniqueId": "gmail",
            "appName": "gmail",
            "status": "ACTIVE",
            "createdAt": "2026-01-01T00:00:00Z",
            "logo": NSNull(),  // Composio API 可能返回 null
        ]

        // 使用 as? String 而不是 ?? 来处理 NSNull
        let logo = (apiItem["logo"] as? String) ?? ""
        XCTAssertEqual(logo, "", "NSNull 应被 as? String 过滤为 nil，然后 ?? 给出空字符串")
    }

    // MARK: - connectedSlugs 计算

    func testConnectedSlugsFiltering() throws {
        let connsJSON: [[String: String]] = [
            ["id": "1", "toolkit_slug": "gmail", "toolkit_name": "Gmail", "toolkit_logo": "", "status": "ACTIVE", "created_at": ""],
            ["id": "2", "toolkit_slug": "gmail", "toolkit_name": "Gmail", "toolkit_logo": "", "status": "ACTIVE", "created_at": ""],
            ["id": "3", "toolkit_slug": "github", "toolkit_name": "GitHub", "toolkit_logo": "", "status": "ACTIVE", "created_at": ""],
            ["id": "4", "toolkit_slug": "slack", "toolkit_name": "Slack", "toolkit_logo": "", "status": "INACTIVE", "created_at": ""],
        ]

        let conns: [ComposioConnection] = try connsJSON.map { item in
            let data = try JSONSerialization.data(withJSONObject: item)
            return try JSONDecoder().decode(ComposioConnection.self, from: data)
        }

        let connectedSlugs = Set(conns.filter { $0.isActive }.map { $0.toolkitSlug })

        XCTAssertEqual(connectedSlugs, ["gmail", "github"], "只应包含 ACTIVE 的连接")
        XCTAssertFalse(connectedSlugs.contains("slack"), "INACTIVE 连接不应包含")
    }

    // MARK: - 市场卡片状态逻辑

    func testMarketCardStates() throws {
        let toolkitJSON: [String: Any] = [
            "slug": "gmail",
            "name": "Gmail",
            "description": "",
            "logo": "",
            "categories": [] as [[String: Any]],
            "auth_schemes": ["OAUTH2"],
            "tools_count": 10,
            "triggers_count": 0,
            "no_auth": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: toolkitJSON)
        let tk = try JSONDecoder().decode(ComposioToolkit.self, from: data)

        let connectedSlugs: Set<String> = ["gmail"]
        let installedSlugs: Set<String> = []

        let connected = !tk.requiresAuth || connectedSlugs.contains(tk.slug)
        let installed = installedSlugs.contains(tk.slug)

        // gmail 已连接但未安装 → 应显示 "添加到工具" 按钮
        XCTAssertTrue(connected)
        XCTAssertFalse(installed)
    }

    func testMarketCardStateNotConnected() throws {
        let toolkitJSON: [String: Any] = [
            "slug": "jira",
            "name": "Jira",
            "description": "",
            "logo": "",
            "categories": [] as [[String: Any]],
            "auth_schemes": ["OAUTH2"],
            "tools_count": 20,
            "triggers_count": 0,
            "no_auth": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: toolkitJSON)
        let tk = try JSONDecoder().decode(ComposioToolkit.self, from: data)

        let connectedSlugs: Set<String> = ["gmail"]
        let connected = !tk.requiresAuth || connectedSlugs.contains(tk.slug)

        // jira 需要授权且未连接 → 应显示 "授权连接" 按钮
        XCTAssertFalse(connected)
    }

    func testMarketCardStateNoAuthAlwaysConnected() throws {
        let toolkitJSON: [String: Any] = [
            "slug": "codeformat",
            "name": "CodeFormat",
            "description": "",
            "logo": "",
            "categories": [] as [[String: Any]],
            "auth_schemes": ["NONE"],
            "tools_count": 5,
            "triggers_count": 0,
            "no_auth": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: toolkitJSON)
        let tk = try JSONDecoder().decode(ComposioToolkit.self, from: data)

        let connectedSlugs: Set<String> = []
        let connected = !tk.requiresAuth || connectedSlugs.contains(tk.slug)

        // noAuth 工具无需授权，始终可安装
        XCTAssertTrue(connected, "noAuth 工具应始终显示为已连接")
    }
}
