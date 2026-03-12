import Foundation

@MainActor
class BackendService {

    // MARK: - WebSocket Chat

    func streamChat(
        message: String,
        history: [[String: Any]],
        images: [String]? = nil,
        isPdf: Bool = false,
        onEvent: @escaping @Sendable (BackendEvent) -> Void
    ) async throws {
        let url = AppConfig.wsURL
        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        task.resume()

        var payload: [String: Any] = [
            "message": message,
            "history": history,
            "config": AppConfig.configPayload(),
        ]
        if let images = images, !images.isEmpty {
            payload["images"] = images
            if isPdf { payload["is_pdf"] = true }
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let text = String(data: data, encoding: .utf8)!
        try await task.send(.string(text))

        while true {
            let msg = try await task.receive()
            guard case .string(let str) = msg,
                  let raw = str.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  let type_ = json["type"] as? String
            else { continue }

            let event = BackendEvent.parse(type: type_, json: json)
            onEvent(event)

            if case .done = event { break }
            if case .error = event { break }
        }

        task.cancel(with: .normalClosure, reason: nil)
    }

    // MARK: - Memory REST

    func fetchMemories() async throws -> [MemoryItem] {
        let url = AppConfig.httpBase.appendingPathComponent("memory")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([MemoryItem].self, from: data)
    }

    func deleteMemory(id: String) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("memory/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    func clearAllMemories() async throws {
        let url = AppConfig.httpBase.appendingPathComponent("memory")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    @discardableResult
    func deduplicateMemories() async throws -> Int {
        let url = AppConfig.httpBase.appendingPathComponent("memory/deduplicate")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode([String: Int].self, from: data)
        return json["removed"] ?? 0
    }

    struct CompressResult: Codable {
        let before: Int
        let after: Int
        let error: String?
    }

    func compressCategory(type: String) async throws -> CompressResult {
        let url = AppConfig.httpBase.appendingPathComponent("memory/compress/\(type)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["config": AppConfig.configPayload()]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(CompressResult.self, from: data)
    }

    // MARK: - Agent Workers REST

    func fetchAgents() async throws -> [AgentWorker] {
        let url = AppConfig.httpBase.appendingPathComponent("agents")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([AgentWorker].self, from: data)
    }

    func createAgent(body: [String: Any]) async throws -> AgentWorker {
        let url = AppConfig.httpBase.appendingPathComponent("agents")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(AgentWorker.self, from: data)
    }

    func updateAgent(id: String, body: [String: Any]) async throws -> AgentWorker {
        let url = AppConfig.httpBase.appendingPathComponent("agents/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(AgentWorker.self, from: data)
    }

    func deleteAgent(id: String) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("agents/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    func generateAgentConfig(description: String, language: String = "zh") async throws -> [String: Any] {
        let url = AppConfig.httpBase.appendingPathComponent("agents/generate")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["description": description, "language": language, "config": AppConfig.configPayload()]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Agent", code: -1, userInfo: [NSLocalizedDescriptionKey: "生成失败"])
        }
        if let httpResp = resp as? HTTPURLResponse, httpResp.statusCode >= 400 {
            let msg = json["error"] as? String ?? json["detail"] as? String ?? "生成失败"
            throw NSError(domain: "Agent", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return json
    }

    // MARK: - Diary REST

    func fetchDiary() async throws -> [DiaryEntry] {
        let url = AppConfig.httpBase.appendingPathComponent("memory/diary")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([DiaryEntry].self, from: data)
    }

    func generateDiaryEntry(force: Bool = false) async throws -> DiaryEntry? {
        var url = AppConfig.httpBase.appendingPathComponent("memory/diary")
        var queryItems: [URLQueryItem] = []
        if force { queryItems.append(URLQueryItem(name: "force", value: "true")) }
        queryItems.append(URLQueryItem(name: "lang", value: AppConfig.language))
        if var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            comps.queryItems = queryItems
            url = comps.url ?? url
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: req)
        let wrapper = try JSONDecoder().decode(DiaryResponse.self, from: data)
        return wrapper.entry
    }

    // MARK: - Skills REST

    func fetchSkills() async throws -> [Skill] {
        let lang = UserDefaults.standard.string(forKey: "aichat.language") ?? "en"
        var comps = URLComponents(url: AppConfig.httpBase.appendingPathComponent("skills"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "lang", value: lang)]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode([Skill].self, from: data)
    }

    func createSkill(_ skill: [String: Any]) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("skills")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: skill)
        _ = try await URLSession.shared.data(for: req)
    }

    func deleteSkill(id: String) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("skills/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Skill Market REST

    func fetchClawHubSkills(tab: String = "popular", limit: Int = 100) async throws -> [ClawHubSkill] {
        var comps = URLComponents(url: AppConfig.httpBase.appendingPathComponent("skill-market"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "tab", value: tab),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode([ClawHubSkill].self, from: data)
    }

    func searchClawHubSkills(q: String, limit: Int = 100) async throws -> [ClawHubSkill] {
        var comps = URLComponents(url: AppConfig.httpBase.appendingPathComponent("skill-market"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "limit", value: "\(limit)"),
        ]
        let (data, _) = try await URLSession.shared.data(from: comps.url!)
        return try JSONDecoder().decode([ClawHubSkill].self, from: data)
    }

    func installClawHubSkill(_ skill: ClawHubSkill) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("skill-market/install")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "slug": skill.slug,
            "display_name": skill.displayName,
            "summary": skill.summary,
            "owner_handle": skill.ownerHandle,
            "downloads": skill.downloads,
            "stars": skill.stars,
            "is_certified": skill.isCertified,
            "clawhub_url": skill.clawhubUrl,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Skill Proposals REST

    func fetchProposals() async throws -> [SkillProposal] {
        let url = AppConfig.httpBase.appendingPathComponent("skill-proposals")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([SkillProposal].self, from: data)
    }

    func acceptProposal(id: String) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("skill-proposals/\(id)/accept")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: req)
    }

    func dismissProposal(id: String) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("skill-proposals/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Projects REST

    func fetchProjects() async throws -> [ProjectFolder] {
        let url = AppConfig.httpBase.appendingPathComponent("projects")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ProjectFolder].self, from: data)
    }

    func createProject(name: String, description: String = "") async throws {
        let url = AppConfig.httpBase.appendingPathComponent("projects/\(name)")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["description": description])
        _ = try await URLSession.shared.data(for: req)
    }

    func fetchProjectFiles(name: String) async throws -> [ProjectFile] {
        let url = AppConfig.httpBase.appendingPathComponent("projects/\(name)/files")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ProjectFile].self, from: data)
    }

    // MARK: - Tools REST

    func fetchAllTools() async throws -> [ToolItem] {
        let url = AppConfig.httpBase.appendingPathComponent("tools")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([ToolItem].self, from: data)
    }

    // MARK: - MCP REST

    func fetchMCPServers() async throws -> [MCPServer] {
        let url = AppConfig.httpBase.appendingPathComponent("mcp/servers")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([MCPServer].self, from: data)
    }

    @discardableResult
    func addMCPServer(name: String, command: [String], env: [String: String] = [:]) async throws -> Int {
        let url = AppConfig.httpBase.appendingPathComponent("mcp/servers")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["name": name, "command": command]
        if !env.isEmpty { body["env"] = env }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONDecoder().decode([String: Int].self, from: data)
        return json["tool_count"] ?? 0
    }

    func deleteMCPServer(name: String) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("mcp/servers/\(name)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    func reloadMCPServer(name: String) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("mcp/servers/\(name)/reload")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: req)
    }

    func fetchMCPPresets() async throws -> [MCPPreset] {
        let url = AppConfig.httpBase.appendingPathComponent("mcp/presets")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([MCPPreset].self, from: data)
    }

    // MARK: - Composio (Cloud API)

    // MARK: - Composio (dual mode: direct API or TuuAI proxy)

    /// 只有本地模式 + 有 Composio API Key 时才走直连
    private var isComposioDirectMode: Bool {
        UserDefaults.standard.bool(forKey: "aichat.local_mode") && !AppConfig.composioApiKey.isEmpty
    }

    private func composioURL(_ path: String) -> URL? {
        if isComposioDirectMode {
            return URL(string: "https://backend.composio.dev/api/v1/\(path)")
        }
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.isEmpty { base = AppConfig.serviceBaseURL }
        return URL(string: "\(base)/api/v1/composio/\(path)")
    }

    private func composioRequest(_ path: String, method: String = "GET", body: [String: Any]? = nil) -> URLRequest? {
        guard let url = composioURL(path) else { return nil }
        if isComposioDirectMode {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue(AppConfig.composioApiKey, forHTTPHeaderField: "x-api-key")
            if let body = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            return req
        } else {
            let token = AppConfig.authToken
            guard !token.isEmpty else { return nil }
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body = body {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            }
            return req
        }
    }

    func fetchComposioToolkits(category: String? = nil, search: String? = nil, cursor: String? = nil, limit: Int = 50) async throws -> ComposioToolkitListResponse {
        if isComposioDirectMode {
            return try await fetchComposioToolkitsDirect(category: category, search: search, cursor: cursor, limit: limit)
        }
        var path = "toolkits?limit=\(limit)"
        if let cat = category, !cat.isEmpty { path += "&category=\(cat)" }
        if let s = search, !s.isEmpty, let encoded = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&search=\(encoded)"
        }
        if let c = cursor, !c.isEmpty, let encoded = c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&cursor=\(encoded)"
        }
        guard let req = composioRequest(path) else {
            throw NSError(domain: "Composio", code: -1, userInfo: [NSLocalizedDescriptionKey: "未登录"])
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ComposioToolkitListResponse.self, from: data)
    }

    /// 直连 Composio API 获取应用列表，转为 ComposioToolkitListResponse
    private func fetchComposioToolkitsDirect(category: String?, search: String?, cursor: String?, limit: Int) async throws -> ComposioToolkitListResponse {
        var path = "apps?limit=\(limit)"
        if let cat = category, !cat.isEmpty, let encoded = cat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&category=\(encoded)"
        }
        if let s = search, !s.isEmpty, let encoded = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&search=\(encoded)"
        }
        if let c = cursor, !c.isEmpty, let encoded = c.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&cursor=\(encoded)"
        }
        guard let req = composioRequest(path) else {
            throw NSError(domain: "Composio", code: -1, userInfo: [NSLocalizedDescriptionKey: "请配置 Composio API Key"])
        }
        let (data, _) = try await URLSession.shared.data(for: req)

        // Composio direct API 返回 { items: [...], totalPages, ... }
        // 需要把每个 item 转为 ComposioToolkit 格式
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]] else {
            return ComposioToolkitListResponse(items: [], totalItems: 0, currentPage: 1, totalPages: 1, nextCursor: nil)
        }

        let toolkits: [ComposioToolkit] = items.compactMap { item in
            // Composio API 字段: key, name, displayName, description, logo, categories, no_auth, meta{actionsCount, triggersCount}
            let meta = item["meta"] as? [String: Any] ?? [:]
            let noAuth = item["no_auth"] as? Bool ?? false

            var mapped: [String: Any] = [:]
            mapped["slug"] = item["key"] ?? item["name"] ?? ""
            mapped["name"] = item["displayName"] ?? item["name"] ?? item["key"] ?? ""
            mapped["description"] = item["description"] ?? ""
            mapped["logo"] = item["logo"] ?? ""
            mapped["categories"] = (item["categories"] as? [String])?.map { ["id": $0, "name": $0] } ?? []
            mapped["auth_schemes"] = noAuth ? ["NONE"] : ["OAUTH2"]
            mapped["tools_count"] = meta["actionsCount"] ?? item["tools_count"] ?? 0
            mapped["triggers_count"] = meta["triggersCount"] ?? item["triggers_count"] ?? 0
            mapped["no_auth"] = noAuth

            guard let jsonData = try? JSONSerialization.data(withJSONObject: mapped),
                  let tk = try? JSONDecoder().decode(ComposioToolkit.self, from: jsonData) else { return nil }
            return tk
        }

        let totalItems = json["totalItems"] as? Int ?? json["total_items"] as? Int ?? toolkits.count
        let totalPages = json["totalPages"] as? Int ?? json["total_pages"] as? Int ?? 1
        let nextCursor = json["next_cursor"] as? String ?? json["nextCursor"] as? String

        return ComposioToolkitListResponse(items: toolkits, totalItems: totalItems, currentPage: 1, totalPages: totalPages, nextCursor: nextCursor)
    }

    func fetchComposioConnections() async throws -> [ComposioConnection] {
        if isComposioDirectMode {
            // 直连模式：调 Composio connectedAccounts API
            // 返回的 appUniqueId 对应 apps API 的 key（如 "gmail"）
            let conns = await ComposioClient.shared.fetchConnectionsDirectly()
            debugLog("[Composio] fetchConnectionsDirectly returned \(conns.count) items")
            return conns.compactMap { item in
                let slug = item["appUniqueId"] as? String ?? item["appName"] as? String ?? ""
                let status = item["status"] as? String ?? "ACTIVE"
                debugLog("[Composio] Connection: slug='\(slug)', status='\(status)', id=\(item["id"] ?? "?")")
                guard !slug.isEmpty else { return nil }
                let mapped: [String: String] = [
                    "id": (item["id"] as? String) ?? "",
                    "toolkit_slug": slug,
                    "toolkit_name": (item["appName"] as? String) ?? slug,
                    "toolkit_logo": (item["logo"] as? String) ?? "",
                    "status": status,
                    "created_at": (item["createdAt"] as? String) ?? "",
                ]
                guard let jsonData = try? JSONSerialization.data(withJSONObject: mapped) else {
                    debugLog("[Composio] Failed to serialize connection for slug='\(slug)'")
                    return nil
                }
                do {
                    let conn = try JSONDecoder().decode(ComposioConnection.self, from: jsonData)
                    return conn
                } catch {
                    debugLog("[Composio] Failed to decode connection for slug='\(slug)': \(error)")
                    return nil
                }
            }
        }
        guard let req = composioRequest("connections") else {
            throw NSError(domain: "Composio", code: -1, userInfo: [NSLocalizedDescriptionKey: "未登录"])
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        let resp = try JSONDecoder().decode(ComposioConnectionListResponse.self, from: data)
        return resp.connections
    }

    func composioConnect(toolkit: String, redirectUrl: String? = nil) async throws -> ComposioConnectResponse {
        if isComposioDirectMode {
            // 直连：先获取 integrationId，再发起连接拿 redirectUrl
            if let redirectURL = await ComposioClient.shared.connectDirectly(appName: toolkit),
               !redirectURL.isEmpty {
                // 手动构造兼容的 response
                let json: [String: Any] = ["redirect_url": redirectURL]
                let data = try JSONSerialization.data(withJSONObject: json)
                return try JSONDecoder().decode(ComposioConnectResponse.self, from: data)
            }
            throw NSError(domain: "Composio", code: -1, userInfo: [NSLocalizedDescriptionKey: L.isEN ? "Connection failed. The app may not support OAuth." : "连接失败，该应用可能不支持 OAuth"])
        }
        var body: [String: Any] = ["toolkit": toolkit]
        if let r = redirectUrl { body["redirect_url"] = r }
        guard let req = composioRequest("connect", method: "POST", body: body) else {
            throw NSError(domain: "Composio", code: -1, userInfo: [NSLocalizedDescriptionKey: "未登录"])
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(ComposioConnectResponse.self, from: data)
    }

    func composioDisconnect(connectionId: String) async throws {
        if isComposioDirectMode {
            guard let url = URL(string: "https://backend.composio.dev/api/v1/connectedAccounts/\(connectionId)") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "DELETE"
            req.setValue(AppConfig.composioApiKey, forHTTPHeaderField: "x-api-key")
            _ = try await URLSession.shared.data(for: req)
            return
        }
        guard let req = composioRequest("disconnect", method: "POST", body: ["connection_id": connectionId]) else {
            throw NSError(domain: "Composio", code: -1, userInfo: [NSLocalizedDescriptionKey: "未登录"])
        }
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Composio (Local Backend Sync)

    func installComposioToolkit(slug: String) async throws -> Int {
        if isComposioDirectMode {
            // 直连模式：直接通过 ComposioClient 安装
            return await ComposioClient.shared.install(slug: slug, authToken: "")
        }
        let url = AppConfig.httpBase.appendingPathComponent("composio/install")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["slug": slug, "auth_token": AppConfig.authToken]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["tool_count"] as? Int ?? 0
    }

    func uninstallComposioToolkit(slug: String) async throws {
        if isComposioDirectMode {
            ComposioClient.shared.uninstall(slug: slug)
            return
        }
        let url = AppConfig.httpBase.appendingPathComponent("composio/\(slug)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - TuuAI API / Cloud Models

    struct ModelOption: Codable {
        let id: String
        let display_name: String
        let category: String
    }

    /// 是否支持通过 API 拉取模型列表
    static func providerSupportsListAPI(_ providerId: String) -> Bool {
        ["claude", "openai", "gemini", "deepseek", "minimax"].contains(providerId)
    }

    /// 使用各家官方 list models 接口拉取当前可用模型
    func fetchProviderModels(providerId: String, apiKey: String) async throws -> [ModelOption] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        switch providerId {
        case "openai": return try await fetchOpenAIModels(apiKey: key)
        case "claude": return try await fetchAnthropicModels(apiKey: key)
        case "gemini": return try await fetchGoogleGeminiModels(apiKey: key)
        case "deepseek": return try await fetchOpenAICompatibleModels(baseURL: "https://api.deepseek.com", apiKey: key)
        case "minimax": return try await fetchOpenAICompatibleModels(baseURL: "https://api.minimaxi.com", apiKey: key)
        default: return []
        }
    }

    private func fetchOpenAIModels(apiKey: String) async throws -> [ModelOption] {
        guard let url = URL(string: "https://api.openai.com/v1/models") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "FetchModels", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "获取模型列表失败"])
        }
        return parseOpenAIFormatModels(data: data)
    }

    private func fetchAnthropicModels(apiKey: String) async throws -> [ModelOption] {
        guard let url = URL(string: "https://api.anthropic.com/v1/models?limit=100") else { return [] }
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "FetchModels", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "获取模型列表失败"])
        }
        return parseAnthropicFormatModels(data: data)
    }

    private func fetchGoogleGeminiModels(apiKey: String) async throws -> [ModelOption] {
        guard let encoded = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(encoded)") else { return [] }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "FetchModels", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "获取模型列表失败"])
        }
        return parseGoogleGeminiFormatModels(data: data)
    }

    private func fetchOpenAICompatibleModels(baseURL: String, apiKey: String) async throws -> [ModelOption] {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(base)/v1/models") else { return [] }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "FetchModels", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: [NSLocalizedDescriptionKey: "获取模型列表失败"])
        }
        return parseOpenAIFormatModels(data: data)
    }

    private func parseOpenAIFormatModels(data: Data) -> [ModelOption] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> ModelOption? in
            guard let id = item["id"] as? String else { return nil }
            let name = item["id"] as? String ?? id
            return ModelOption(id: id, display_name: name, category: "default")
        }
    }

    private func parseAnthropicFormatModels(data: Data) -> [ModelOption] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> ModelOption? in
            guard let id = item["id"] as? String else { return nil }
            let name = item["display_name"] as? String ?? id
            return ModelOption(id: id, display_name: name, category: "default")
        }
    }

    private func parseGoogleGeminiFormatModels(data: Data) -> [ModelOption] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { return [] }
        return list.compactMap { item -> ModelOption? in
            guard let nameField = item["name"] as? String else { return nil }
            let id = nameField.hasPrefix("models/") ? String(nameField.dropFirst(7)) : nameField
            let displayName = item["displayName"] as? String ?? id
            return ModelOption(id: id, display_name: displayName, category: "default")
        }
    }

    func fetchCloudModels(accessToken: String) async throws -> (models: [ModelOption], defaultModel: String) {
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.isEmpty { base = AppConfig.serviceBaseURL }
        guard let url = URL(string: "\(base)/api/v1/chat/models") else {
            throw NSError(domain: "FetchModels", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "后端地址无效"])
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw NSError(domain: "FetchModels", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: "获取模型列表失败"])
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let defaultModel = json["default_model"] as? String ?? "claude-sonnet-4-6"
        var models: [ModelOption] = []
        if let list = json["models"] as? [[String: Any]] {
            for item in list {
                if let id = item["id"] as? String,
                   let name = item["display_name"] as? String {
                    let category = item["category"] as? String ?? "sonnet"
                    models.append(ModelOption(id: id, display_name: name, category: category))
                }
            }
        }
        return (models, defaultModel)
    }

    private var tuuaiBase: String {
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        if base.isEmpty { base = AppConfig.serviceBaseURL }
        return "\(base)/api/v1"
    }

    /// 返回值: balance >= 0 成功, -1 网络/解析错误, -401 token 无效
    func fetchBalance(accessToken: String) async throws -> Int {
        let url = URL(string: "\(tuuaiBase)/credits/balance")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return -1 }
        if http.statusCode == 401 || http.statusCode == 403 {
            return -401
        }
        guard (200...299).contains(http.statusCode) else { return -1 }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let balance = json["balance_sonnet"] as? Int {
            return balance
        }
        return -1
    }

    /// 充值：传入套餐标识 "basic" / "pro" / "max"，返回支付页面 URL
    func recharge(plan: String, accessToken: String) async throws -> URL {
        let url = URL(string: "\(tuuaiBase)/recharge/checkout")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["plan": plan])
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let urlStr = json["checkout_url"] as? String,
           let paymentURL = URL(string: urlStr) {
            return paymentURL
        }

        let msg = String(data: data, encoding: .utf8) ?? "未知响应"
        throw NSError(domain: "Recharge", code: http?.statusCode ?? -1,
                       userInfo: [NSLocalizedDescriptionKey: "无法获取支付页面: \(msg)"])
    }

    // MARK: - Payment Backend (python-backend) 订阅与余额

    struct SubscriptionInfo {
        let plan: String   // "free" | "clawbie_only" | "basic" | "pro" | "max"
        let status: String // "active" | "canceled" ...
        let balanceSonnet: Int
        let balanceHaiku: Int
        let balanceOpus: Int
        let balanceAssistHaiku: Int
        let currentPeriodEnd: Date?
        let isTrial: Bool
        let trialEnd: Date?
    }

    func fetchSubscription(accessToken: String) async throws -> SubscriptionInfo {
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty,
              let url = URL(string: "\(base)/api/v1/subscription") else {
            throw NSError(domain: "FetchSubscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "支付后端地址无效"])
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "FetchSubscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "获取订阅信息失败"])
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        isoBasic.formatOptions = [.withInternetDateTime]

        func parseDate(_ key: String) -> Date? {
            guard let raw = json[key] as? String else { return nil }
            return iso.date(from: raw) ?? isoBasic.date(from: raw)
        }

        return SubscriptionInfo(
            plan: json["plan"] as? String ?? "free",
            status: json["status"] as? String ?? "active",
            balanceSonnet: json["balance_sonnet"] as? Int ?? 0,
            balanceHaiku: json["balance_haiku"] as? Int ?? 0,
            balanceOpus: json["balance_opus"] as? Int ?? 0,
            balanceAssistHaiku: json["balance_assist_haiku"] as? Int ?? 0,
            currentPeriodEnd: parseDate("current_period_end"),
            isTrial: json["is_trial"] as? Bool ?? false,
            trialEnd: parseDate("trial_end")
        )
    }

    /// 调用 python-backend POST /api/v1/subscription/create。
    /// 请求体：plan ("basic"|"pro"|"max"), success_url (myclaw://payment/success), cancel_url (myclaw://payment/cancel)。
    /// 响应只认 checkout_url（统一空白支付页，如 https://cloud.example.com/pay?checkout=xxx），用系统默认浏览器打开；绝不打开 success_redirect_url（那是支付完成后的回调）。
    func createSubscription(plan: String, accessToken: String) async throws -> URL {
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty,
              let apiURL = URL(string: "\(base)/api/v1/subscription/create") else {
            throw NSError(domain: "CreateSubscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "支付后端地址无效"])
        }
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "plan": plan,
            "success_url": AppConfig.paymentSuccessURL,
            "cancel_url": AppConfig.paymentCancelURL,
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        let bodyString = String(data: data, encoding: .utf8) ?? ""

        #if DEBUG
        print("[CreateSubscription] status=\(statusCode) body=\(bodyString)")
        #endif

        guard (200...299).contains(statusCode) else {
            print("[CreateSubscription] 接口错误 status=\(statusCode) 返回=\(bodyString)")
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            let fallback = bodyString.isEmpty ? "未知错误" : bodyString
            throw NSError(domain: "CreateSubscription", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: detail ?? msg ?? fallback])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[CreateSubscription] 响应非 JSON 返回=\(bodyString)")
            throw NSError(domain: "CreateSubscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "响应格式错误"])
        }
        // 只打开支付页 URL：checkout_url（https 空白支付页）。绝不打开 success_redirect_url（myclaw:// 是支付完成后由浏览器跳转的回调）
        guard let s = json["checkout_url"] as? String, !s.isEmpty,
              let url = URL(string: s),
              url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            print("[CreateSubscription] 缺少 checkout_url 接口返回=\(bodyString)")
            throw NSError(domain: "CreateSubscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "后端未返回支付页地址（checkout_url），请确认 python-backend 已配置 CHECKOUT_PAGE_ORIGIN"])
        }
        return url
    }

    /// 取消订阅：POST /api/v1/subscription/cancel，无 Body，Bearer 鉴权。
    func cancelSubscription(accessToken: String) async throws {
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty,
              let apiURL = URL(string: "\(base)/api/v1/subscription/cancel") else {
            throw NSError(domain: "CancelSubscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "支付后端地址无效"])
        }
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw NSError(domain: "CancelSubscription", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: detail ?? msg ?? bodyString])
        }
    }

    /// 恢复订阅：POST /api/v1/subscription/resume（取消后未到期时重新开启自动续费），无 Body。
    func resumeSubscription(accessToken: String) async throws {
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty,
              let apiURL = URL(string: "\(base)/api/v1/subscription/resume") else {
            throw NSError(domain: "ResumeSubscription", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "支付后端地址无效"])
        }
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? -1
        guard (200...299).contains(statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["detail"] as? String
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw NSError(domain: "ResumeSubscription", code: statusCode,
                          userInfo: [NSLocalizedDescriptionKey: detail ?? msg ?? bodyString])
        }
    }

    /// 从 python-backend 查询余额。返回值: balance >= 0 成功, -1 网络/解析错误, -401 token 无效
    func fetchBalanceFromPaymentBackend(accessToken: String) async throws -> Int {
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty,
              let url = URL(string: "\(base)/api/v1/credits/balance") else {
            return -1
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { return -1 }
        if http.statusCode == 401 || http.statusCode == 403 { return -401 }
        guard (200...299).contains(http.statusCode) else { return -1 }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let balance = json["balance_sonnet"] as? Int {
            return balance
        }
        return -1
    }

    /// python-backend 余额 WebSocket URL（用于实时推送）。未配置支付后端时返回 nil。
    func paymentBackendBalanceWebSocketURL(accessToken: String) -> URL? {
        var base = AppConfig.paymentBackendURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        guard !base.isEmpty else { return nil }
        let wsBase = base
            .replacingOccurrences(of: "http://", with: "ws://")
            .replacingOccurrences(of: "https://", with: "wss://")
        guard let encoded = accessToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "\(wsBase)/api/v1/credits/balance/ws?token=\(encoded)")
    }

    // MARK: - Watchlist REST

    func fetchWatchlist() async throws -> [WatchItem] {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode([WatchItem].self, from: data)
    }

    func createWatchItem(query: String) async throws -> WatchItem {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["query": query, "language": AppConfig.language]
        body["config"] = AppConfig.configPayload()
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(WatchItem.self, from: data)
    }

    func deleteWatchItem(id: String) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    func reparseWatchItem(id: String, query: String) async throws -> WatchItem {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist/\(id)/reparse")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["query": query, "language": AppConfig.language]
        body["config"] = AppConfig.configPayload()
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(WatchItem.self, from: data)
    }

    func fetchWatchItemLogs(id: String) async throws -> [[String: String]] {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist/\(id)/logs")
        let (data, _) = try await URLSession.shared.data(from: url)
        return (try? JSONSerialization.jsonObject(with: data) as? [[String: String]]) ?? []
    }

    func toggleWatchItem(id: String, enabled: Bool) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist/\(id)")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["enabled": enabled])
        _ = try await URLSession.shared.data(for: req)
    }

    func fetchWatchlistConfig() async throws -> WatchlistConfig {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist/config")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(WatchlistConfig.self, from: data)
    }

    func togglePoll() async throws -> Bool {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist/poll/toggle")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["poll_enabled"] as? Bool ?? false
    }

    func fetchPollStatus() async throws -> Bool {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist/poll/status")
        let (data, _) = try await URLSession.shared.data(from: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["poll_enabled"] as? Bool ?? false
    }

    func saveWatchlistConfig(_ config: WatchlistConfig) async throws {
        let url = AppConfig.httpBase.appendingPathComponent("watchlist/config")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(config)
        _ = try await URLSession.shared.data(for: req)
    }

    // MARK: - Chat Summarize

    func summarizeChat(messages: [[String: String]], keepLast: Int) async throws -> String {
        let url = AppConfig.httpBase.appendingPathComponent("chat/summarize")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["messages": messages, "keep_last": keepLast]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["summary"] as? String ?? ""
    }

    func healthCheck() async -> Bool {
        guard let url = URL(string: "\(AppConfig.backendURL)/health") else { return false }
        do {
            let (_, resp) = try await URLSession.shared.data(from: url)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}

// MARK: - BackendEvent

enum BackendEvent {
    case textChunk(String)
    case thinking(String)
    case toolCall(tool: String, args: String, agent: String?)
    case toolResult(tool: String, result: String, agent: String?)
    case done
    case error(String)

    static func parse(type: String, json: [String: Any]) -> BackendEvent {
        let agent = json["agent"] as? String
        switch type {
        case "text_chunk":
            return .textChunk(json["content"] as? String ?? "")
        case "thinking":
            return .thinking(json["content"] as? String ?? "")
        case "tool_call":
            let tool = json["tool"] as? String ?? ""
            let argsData = try? JSONSerialization.data(withJSONObject: json["args"] ?? [:], options: .prettyPrinted)
            let args = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return .toolCall(tool: tool, args: args, agent: agent)
        case "tool_result":
            return .toolResult(
                tool: json["tool"] as? String ?? "",
                result: json["result"] as? String ?? "",
                agent: agent
            )
        case "done":
            return .done
        case "error":
            return .error(json["message"] as? String ?? "未知错误")
        default:
            return .error("未知事件: \(type)")
        }
    }
}
