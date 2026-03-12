import XCTest
@testable import MyClaw

final class ComposioModelTests: XCTestCase {

    // MARK: - ComposioToolkit Decoding

    func testToolkitDecodingFromDirectAPI() throws {
        // 模拟 Composio 直连 API 经过 BackendService 转换后的 JSON
        let json: [String: Any] = [
            "slug": "gmail",
            "name": "Gmail",
            "description": "Gmail integration",
            "logo": "https://logos.composio.dev/api/gmail",
            "categories": [["id": "communication", "name": "communication"]],
            "auth_schemes": ["OAUTH2"],
            "tools_count": 60,
            "triggers_count": 5,
            "no_auth": false,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let toolkit = try JSONDecoder().decode(ComposioToolkit.self, from: data)

        XCTAssertEqual(toolkit.slug, "gmail")
        XCTAssertEqual(toolkit.name, "Gmail")
        XCTAssertEqual(toolkit.toolsCount, 60)
        XCTAssertTrue(toolkit.requiresAuth)
        XCTAssertFalse(toolkit.noAuth)
        XCTAssertEqual(toolkit.id, "gmail") // id == slug
    }

    func testToolkitNoAuthDetection() throws {
        let json: [String: Any] = [
            "slug": "code_analysis",
            "name": "Code Analysis",
            "description": "Analyze code",
            "logo": "",
            "categories": [] as [[String: Any]],
            "auth_schemes": ["NONE"],
            "tools_count": 3,
            "triggers_count": 0,
            "no_auth": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let toolkit = try JSONDecoder().decode(ComposioToolkit.self, from: data)

        XCTAssertFalse(toolkit.requiresAuth, "noAuth 工具不应要求授权")
        XCTAssertTrue(toolkit.noAuth)
    }

    func testToolkitCategoryFallback() throws {
        let json: [String: Any] = [
            "slug": "test",
            "name": "Test",
            "description": "",
            "logo": "",
            "categories": [] as [[String: Any]],
            "auth_schemes": ["NONE"],
            "tools_count": 0,
            "triggers_count": 0,
            "no_auth": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let toolkit = try JSONDecoder().decode(ComposioToolkit.self, from: data)

        XCTAssertEqual(toolkit.categoryName, "Other", "无分类时应返回 Other")
    }

    // MARK: - ComposioConnection Decoding

    func testConnectionDecodingFromMappedJSON() throws {
        // 模拟 fetchComposioConnections 直连模式映射后的 JSON
        let mapped: [String: String] = [
            "id": "abc-123",
            "toolkit_slug": "gmail",
            "toolkit_name": "gmail",
            "toolkit_logo": "",
            "status": "ACTIVE",
            "created_at": "2026-01-01T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: mapped)
        let conn = try JSONDecoder().decode(ComposioConnection.self, from: data)

        XCTAssertEqual(conn.id, "abc-123")
        XCTAssertEqual(conn.toolkitSlug, "gmail")
        XCTAssertTrue(conn.isActive)
    }

    func testConnectionInactiveStatus() throws {
        let mapped: [String: String] = [
            "id": "abc-456",
            "toolkit_slug": "github",
            "toolkit_name": "github",
            "toolkit_logo": "",
            "status": "INACTIVE",
            "created_at": "",
        ]
        let data = try JSONSerialization.data(withJSONObject: mapped)
        let conn = try JSONDecoder().decode(ComposioConnection.self, from: data)

        XCTAssertFalse(conn.isActive, "INACTIVE 状态应返回 false")
    }

    func testConnectionDecodingWithEmptyLogo() throws {
        // 这是之前的 bug：logo 为 null 导致解码失败
        let mapped: [String: String] = [
            "id": "xyz",
            "toolkit_slug": "slack",
            "toolkit_name": "Slack",
            "toolkit_logo": "",  // 之前是 null 导致崩溃
            "status": "ACTIVE",
            "created_at": "",
        ]
        let data = try JSONSerialization.data(withJSONObject: mapped)
        let conn = try JSONDecoder().decode(ComposioConnection.self, from: data)
        XCTAssertEqual(conn.toolkitLogo, "")
    }

    /// 验证 null logo 不应该出现在映射后的 JSON 中（回归测试）
    func testConnectionDecodingFailsWithNullLogo() {
        // 模拟修复前的 bug：[String: Any] 中 logo 为 NSNull
        let mapped: [String: Any] = [
            "id": "xyz",
            "toolkit_slug": "slack",
            "toolkit_name": "Slack",
            "toolkit_logo": NSNull(),  // 这会导致解码失败
            "status": "ACTIVE",
            "created_at": "",
        ]
        let data = try? JSONSerialization.data(withJSONObject: mapped)
        XCTAssertNotNil(data)
        let conn = try? JSONDecoder().decode(ComposioConnection.self, from: data!)
        XCTAssertNil(conn, "NSNull logo 应导致解码失败，确认我们的映射层必须使用 as? String ?? \"\"")
    }

    // MARK: - ComposioConnectResponse

    func testConnectResponseWithRedirectUrl() throws {
        let json: [String: Any] = ["redirect_url": "https://accounts.google.com/oauth", "id": "conn-id"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let resp = try JSONDecoder().decode(ComposioConnectResponse.self, from: data)

        XCTAssertEqual(resp.authUrl, "https://accounts.google.com/oauth")
        XCTAssertEqual(resp.connectionId, "conn-id")
    }

    func testConnectResponseWithoutRedirectUrl() throws {
        let json: [String: Any] = ["id": "conn-id"]
        let data = try JSONSerialization.data(withJSONObject: json)
        let resp = try JSONDecoder().decode(ComposioConnectResponse.self, from: data)

        XCTAssertNil(resp.authUrl)
        XCTAssertEqual(resp.connectionId, "conn-id")
    }

    // MARK: - ComposioToolkitListResponse

    func testToolkitListResponseDecoding() throws {
        let json: [String: Any] = [
            "items": [[
                "slug": "gmail",
                "name": "Gmail",
                "description": "",
                "logo": "",
                "categories": [] as [[String: Any]],
                "auth_schemes": ["OAUTH2"],
                "tools_count": 10,
                "triggers_count": 0,
                "no_auth": false,
            ]],
            "total_items": 100,
            "current_page": 1,
            "total_pages": 2,
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let resp = try JSONDecoder().decode(ComposioToolkitListResponse.self, from: data)

        XCTAssertEqual(resp.items.count, 1)
        XCTAssertEqual(resp.totalItems, 100)
        XCTAssertEqual(resp.totalPages, 2)
    }
}
