import Foundation
import Network

// MARK: - Swift Backend HTTP Server
// Handles migrated endpoints natively in Swift. Proxies remaining
// endpoints to the Python backend running on PYTHON_PORT.

final class SwiftBackendServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?
    private lazy var chatHandler = SwiftChatHandler()

    private let aichatDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".aichat")
    private var agentsFileURL: URL { aichatDir.appendingPathComponent("agents.json") }
    private var skillsFileURL: URL { aichatDir.appendingPathComponent("skills.json") }
    private var projectsRoot: URL { aichatDir.appendingPathComponent("projects") }
    private var watchlistFileURL: URL { aichatDir.appendingPathComponent("watchlist.json") }
    private var watchlistConfigURL: URL { aichatDir.appendingPathComponent("watchlist_config.json") }
    private var watchlistLogsURL: URL { aichatDir.appendingPathComponent("watchlist_logs.json") }
    private var diaryFileURL: URL { aichatDir.appendingPathComponent("diary_entries.json") }
    private var mcpServersURL: URL { aichatDir.appendingPathComponent("mcp_servers.json") }
    private func loadBuiltinSkills() -> [[String: Any]] {
        guard let url = Bundle.main.url(forResource: "builtin_skills", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    init(port: UInt16 = 8000) {
        self.port = port
        ensureDirectories()
    }

    // MARK: - Lifecycle

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params)
        } catch {
            print("[SwiftBackend] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.stateUpdateHandler = { state in
            if case .ready = state {
                print("[SwiftBackend] Listening on 127.0.0.1:\(self.port)")
            } else if case .failed(let err) = state {
                print("[SwiftBackend] Listener failed: \(err)")
            }
        }
        listener?.start(queue: .global(qos: .userInitiated))

        // Start watchlist scheduler
        WatchlistScheduler.shared.start()
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Directory Setup

    private func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: aichatDir, withIntermediateDirectories: true)
        let defaultProject = projectsRoot.appendingPathComponent("default")
        try? fm.createDirectory(at: defaultProject, withIntermediateDirectories: true)
        ensureReadme(at: defaultProject, name: "default")
    }

    // MARK: - Connection / HTTP Parsing

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receiveHTTP(conn: conn, accumulated: Data())
    }

    private func receiveHTTP(conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let headerEnd = buffer.findHeaderEnd() {
                let headerData = buffer[..<headerEnd]
                let bodyStart = buffer[headerEnd...]

                guard let headerStr = String(data: headerData, encoding: .utf8) else {
                    self.sendJSON(conn: conn, status: 400, body: ["error": "Bad request"])
                    return
                }

                let parsed = self.parseRequest(headerStr)

                if (parsed.method == "POST" || parsed.method == "PUT" || parsed.method == "PATCH")
                    && parsed.contentLength > 0 && bodyStart.count < parsed.contentLength {
                    self.receiveHTTP(conn: conn, accumulated: buffer)
                    return
                }

                let bodyData = bodyStart.prefix(max(parsed.contentLength, 0))
                self.route(conn: conn, method: parsed.method, path: parsed.path,
                          query: parsed.query, body: bodyData, rawHeader: headerStr)
            } else if isComplete || error != nil {
                conn.cancel()
            } else {
                self.receiveHTTP(conn: conn, accumulated: buffer)
            }
        }
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let query: String
        let contentLength: Int
    }

    private func parseRequest(_ header: String) -> ParsedRequest {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return ParsedRequest(method: "", path: "", query: "", contentLength: 0) }
        let parts = first.split(separator: " ", maxSplits: 2)
        let method = parts.count > 0 ? String(parts[0]) : ""
        let fullPath = parts.count > 1 ? String(parts[1]) : ""

        var path = fullPath
        var query = ""
        if let qIndex = fullPath.firstIndex(of: "?") {
            path = String(fullPath[..<qIndex])
            query = String(fullPath[fullPath.index(after: qIndex)...])
        }

        var cl = 0
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                cl = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return ParsedRequest(method: method, path: path, query: query, contentLength: cl)
    }

    private func queryParam(_ query: String, key: String) -> String? {
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 && kv[0] == key {
                return String(kv[1]).removingPercentEncoding
            }
        }
        return nil
    }

    // MARK: - Routing

    private func route(conn: NWConnection, method: String, path: String,
                       query: String, body: Data, rawHeader: String) {

        // ── WebSocket /ws/chat → Swift handles directly ───
        if path == "/ws/chat" && rawHeader.lowercased().contains("upgrade: websocket") {
            chatHandler.handleWebSocket(conn: conn, rawHeader: rawHeader)
            return
        }

        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        // Trim leading slash for matching, decode percent-encoded paths (中文等)
        let decodedPath = path.removingPercentEncoding ?? path
        let trimmed = decodedPath.hasPrefix("/") ? String(decodedPath.dropFirst()) : decodedPath
        let segments = trimmed.split(separator: "/", maxSplits: 10).map(String.init)
        let seg0 = segments.count > 0 ? segments[0] : ""
        let seg1 = segments.count > 1 ? segments[1] : ""
        let seg2 = segments.count > 2 ? segments[2] : ""

        // ── Health ─────────────────────────────────────────
        if method == "GET" && seg0 == "health" {
            sendJSON(conn: conn, status: 200, body: ["status": "ok", "version": "1.0.0"])
            return
        }

        // ── Agents ─────────────────────────────────────────
        if seg0 == "agents" {
            if method == "GET" && seg1.isEmpty {
                handleListAgents(conn: conn); return
            }
            if method == "POST" && seg1.isEmpty {
                handleCreateAgent(conn: conn, json: json); return
            }
            if method == "POST" && seg1 == "generate" {
                Task { await self.handleGenerateAgent(conn: conn, json: json) }
                return
            }
            if (method == "PUT" || method == "PATCH") && !seg1.isEmpty {
                handleUpdateAgent(conn: conn, agentId: seg1, json: json); return
            }
            if method == "DELETE" && !seg1.isEmpty {
                handleDeleteAgent(conn: conn, agentId: seg1); return
            }
        }

        // ── Skills ─────────────────────────────────────────
        if seg0 == "skills" {
            if method == "GET" && seg1.isEmpty {
                let lang = queryParam(query, key: "lang") ?? "zh"
                handleListSkills(conn: conn, lang: lang); return
            }
            if method == "POST" && seg1.isEmpty {
                handleCreateSkill(conn: conn, json: json); return
            }
            if method == "DELETE" && !seg1.isEmpty {
                handleDeleteSkill(conn: conn, skillId: seg1); return
            }
        }

        // ── Projects ───────────────────────────────────────
        if seg0 == "projects" {
            if method == "GET" && seg1.isEmpty {
                handleListProjects(conn: conn); return
            }
            if method == "POST" && !seg1.isEmpty && seg2.isEmpty {
                handleCreateProject(conn: conn, name: seg1, json: json); return
            }
            if method == "GET" && !seg1.isEmpty && seg2 == "files" {
                handleListProjectFiles(conn: conn, name: seg1); return
            }
        }

        // ── Watchlist ──────────────────────────────────────
        if seg0 == "watchlist" {
            // GET /watchlist — list all items
            if method == "GET" && seg1.isEmpty {
                handleListWatchlist(conn: conn); return
            }
            // GET /watchlist/config
            if method == "GET" && seg1 == "config" {
                handleGetWatchlistConfig(conn: conn); return
            }
            // POST /watchlist/config
            if method == "POST" && seg1 == "config" {
                handleSaveWatchlistConfig(conn: conn, json: json); return
            }
            // GET /watchlist/poll/status
            if method == "GET" && seg1 == "poll" && seg2 == "status" {
                handlePollStatus(conn: conn); return
            }
            // POST /watchlist/poll/toggle
            if method == "POST" && seg1 == "poll" && seg2 == "toggle" {
                handleTogglePoll(conn: conn, json: json); return
            }
            // POST /watchlist — create watchlist item (stub)
            if method == "POST" && seg1.isEmpty {
                handleCreateWatchlistItem(conn: conn, json: json); return
            }
            // PUT /watchlist/{id}/reparse
            if method == "PUT" && !seg1.isEmpty && seg2 == "reparse" {
                handleReparseWatchlistItem(conn: conn, itemId: seg1, json: json); return
            }
            // PUT /watchlist/{id}
            if method == "PUT" && !seg1.isEmpty && seg2.isEmpty {
                handleUpdateWatchlistItem(conn: conn, itemId: seg1, json: json); return
            }
            // DELETE /watchlist/{id}
            if method == "DELETE" && !seg1.isEmpty {
                handleDeleteWatchlistItem(conn: conn, itemId: seg1); return
            }

            // GET /watchlist/{id}/logs
            if method == "GET" && !seg1.isEmpty && seg2 == "logs" {
                handleGetWatchlistLogs(conn: conn, itemId: seg1); return
            }
        }

        // ── Memory (read-only endpoints) ─────────────────
        if seg0 == "memory" {
            // GET /memory — list all memories
            if method == "GET" && seg1.isEmpty {
                let limit = Int(queryParam(query, key: "limit") ?? "200") ?? 200
                let items = SwiftMemoryManager.shared.listAll(limit: limit)
                sendJSONArray(conn: conn, status: 200, array: items); return
            }
            // DELETE /memory — clear all memories
            if method == "DELETE" && seg1.isEmpty {
                SwiftMemoryManager.shared.clearAll()
                sendJSON(conn: conn, status: 200, body: ["ok": true]); return
            }
            // DELETE /memory/{id} — delete one memory
            if method == "DELETE" && !seg1.isEmpty && seg1 != "diary" {
                let removed = SwiftMemoryManager.shared.delete(memoryId: seg1)
                sendJSON(conn: conn, status: removed ? 200 : 404, body: ["ok": removed]); return
            }
            // POST /memory/deduplicate
            if method == "POST" && seg1 == "deduplicate" {
                let removed = SwiftMemoryManager.shared.deduplicate()
                sendJSON(conn: conn, status: 200, body: ["ok": true, "removed": removed]); return
            }
            // POST /memory/compress/{type}
            if method == "POST" && seg1 == "compress" && !seg2.isEmpty {
                Task {
                    let config = json["config"] as? [String: Any] ?? json
                    guard let provider = try? ProviderFactory.build(config: config, purpose: "utility") else {
                        self.sendJSON(conn: conn, status: 400, body: ["error": "需要 API Key"]); return
                    }
                    let result = await SwiftMemoryManager.shared.compressCategory(type: seg2, provider: provider)
                    self.sendJSON(conn: conn, status: 200, body: result)
                }
                return
            }
            // GET /memory/diary — read diary entries
            if method == "GET" && seg1 == "diary" {
                let entries = SwiftMemoryManager.shared.getDiaryEntries()
                sendJSONArray(conn: conn, status: 200, array: entries); return
            }
            // POST /memory/diary — generate diary entry
            if method == "POST" && seg1 == "diary" {
                Task {
                    let config = json["config"] as? [String: Any] ?? AppConfig.configPayload()
                    // Support both query params (from BackendService) and JSON body
                    let force = queryParam(query, key: "force") == "true" || (json["force"] as? Bool ?? false)
                    let lang = queryParam(query, key: "lang") ?? json["lang"] as? String ?? "zh"
                    guard let provider = try? ProviderFactory.build(config: config, purpose: "utility") else {
                        self.sendJSON(conn: conn, status: 400, body: ["error": "需要 API Key"]); return
                    }
                    if let entry = await SwiftMemoryManager.shared.generateDiaryEntry(provider: provider, force: force, lang: lang) {
                        // Wrap in {"entry": ...} to match DiaryResponse format
                        self.sendJSON(conn: conn, status: 200, body: ["entry": entry])
                    } else {
                        self.sendJSON(conn: conn, status: 200, body: ["entry": NSNull()])
                    }
                }
                return
            }
            // POST /memory/search (memory_search tool uses this)
            if method == "POST" && seg1 == "search" {
                let q = json["query"] as? String ?? ""
                let mode = json["mode"] as? String ?? "search"
                let typeFilter = json["type"] as? String
                let results = SwiftMemoryManager.shared.search(query: q, mode: mode, typeFilter: typeFilter)
                sendJSONArray(conn: conn, status: 200, array: results); return
            }
            // POST /memory — add a memory
            if method == "POST" && seg1.isEmpty {
                let text = json["text"] as? String ?? ""
                let type = json["type"] as? String ?? "fact"
                let tier = json["tier"] as? String ?? "general"
                guard !text.isEmpty else {
                    sendJSON(conn: conn, status: 400, body: ["error": "text is required"]); return
                }
                let id = SwiftMemoryManager.shared.add(text: text, type: type, tier: tier)
                sendJSON(conn: conn, status: 200, body: ["ok": true, "id": id]); return
            }
        }

        // ── MCP ───────────────────────────────────────────
        if seg0 == "mcp" {
            // GET /mcp/servers
            if method == "GET" && seg1 == "servers" {
                handleGetMCPServers(conn: conn); return
            }
            // POST /mcp/servers — install a new MCP server
            if method == "POST" && seg1 == "servers" {
                handleInstallMCPServer(conn: conn, json: json); return
            }
            // DELETE /mcp/servers/{name}
            if method == "DELETE" && seg1 == "servers" && !seg2.isEmpty {
                handleRemoveMCPServer(conn: conn, name: seg2); return
            }
            // POST /mcp/servers/{name}/reload
            if method == "POST" && seg1 == "servers" && segments.count > 2 && segments.last == "reload" {
                handleReloadMCPServer(conn: conn, name: seg2); return
            }
        }

        // ── Composio ─────────────────────────────────────
        if seg0 == "composio" {
            if method == "GET" && seg1 == "toolkits" {
                let list = ComposioClient.shared.installedList()
                sendJSONArray(conn: conn, status: 200, array: list); return
            }
            if method == "POST" && seg1 == "install" {
                let slug = json["slug"] as? String ?? ""
                let authToken = json["auth_token"] as? String ?? ""
                guard !slug.isEmpty, !authToken.isEmpty else {
                    sendJSON(conn: conn, status: 400, body: ["error": "slug and auth_token required"]); return
                }
                Task {
                    let count = await ComposioClient.shared.install(slug: slug, authToken: authToken)
                    self.sendJSON(conn: conn, status: 200, body: ["ok": true, "tool_count": count])
                }
                return
            }
            if method == "DELETE" && !seg1.isEmpty {
                ComposioClient.shared.uninstall(slug: seg1)
                sendJSON(conn: conn, status: 200, body: ["ok": true]); return
            }
            if method == "POST" && segments.count == 3 && seg2 == "clear-error" {
                ComposioClient.shared.clearAuthError(slug: seg1)
                sendJSON(conn: conn, status: 200, body: ["ok": true]); return
            }
        }

        // ── Skill Market ──────────────────────────────────
        if seg0 == "skill-market" {
            if method == "GET" && seg1.isEmpty {
                let tab = queryParam(query, key: "tab") ?? "popular"
                let q = queryParam(query, key: "q") ?? ""
                let limit = Int(queryParam(query, key: "limit") ?? "100") ?? 100
                handleGetSkillMarket(conn: conn, tab: tab, q: q, limit: limit); return
            }
            if method == "POST" && seg1 == "install" {
                handleInstallMarketSkill(conn: conn, json: json); return
            }
        }

        // ── Tools ─────────────────────────────────────────
        if seg0 == "tools" {
            // GET /tools — list all tools (system + MCP + composio)
            if method == "GET" && seg1.isEmpty {
                handleListAllTools(conn: conn); return
            }
            // POST /tools/execute — execute a tool
            if method == "POST" && seg1 == "execute" {
                handleToolExecute(conn: conn, json: json); return
            }
            // GET /tools/definitions — return tool schemas
            if method == "GET" && seg1 == "definitions" {
                var defs = SwiftToolRegistry.shared.allDefinitions()
                defs.append(contentsOf: MCPManager.shared.allTools().map { $0.definition })
                sendJSONArray(conn: conn, status: 200, array: defs)
                return
            }
            // GET /tools/swift-names — return list of tool names
            if method == "GET" && seg1 == "swift-names" {
                var names = SwiftToolRegistry.shared.allNames
                names.append(contentsOf: MCPManager.shared.allTools().map { $0.name })
                sendJSON(conn: conn, status: 200, body: ["names": names])
                return
            }
        }

        // ── Fallback: 404 ────────────────────────────────
        sendJSON(conn: conn, status: 404, body: ["detail": "Not found: \(method) \(path)"])
    }

    // MARK: - Agent Handlers

    private func handleListAgents(conn: NWConnection) {
        let agents = loadAgents()
        sendJSONArray(conn: conn, status: 200, array: agents)
    }

    private func handleCreateAgent(conn: NWConnection, json: [String: Any]) {
        var agents = loadAgents()
        var agent = json
        if (agent["id"] as? String ?? "").isEmpty {
            agent["id"] = UUID().uuidString
        }
        if (agent["created_at"] as? String ?? "").isEmpty {
            agent["created_at"] = ISO8601DateFormatter().string(from: Date())
        }
        if agent["max_steps"] == nil {
            agent["max_steps"] = 10
        }
        agents.append(agent)
        saveAgents(agents)
        sendJSON(conn: conn, status: 200, body: agent)
    }

    private func handleUpdateAgent(conn: NWConnection, agentId: String, json: [String: Any]) {
        var agents = loadAgents()
        guard let idx = agents.firstIndex(where: { ($0["id"] as? String) == agentId }) else {
            sendJSON(conn: conn, status: 404, body: ["detail": "Agent not found"])
            return
        }
        var agent = agents[idx]
        for (key, value) in json where key != "id" {
            agent[key] = value
        }
        agents[idx] = agent
        saveAgents(agents)
        sendJSON(conn: conn, status: 200, body: agent)
    }

    private func handleGenerateAgent(conn: NWConnection, json: [String: Any]) async {
        let description = json["description"] as? String ?? ""
        let language = json["language"] as? String ?? "zh"
        let config = json["config"] as? [String: Any] ?? json

        guard !description.isEmpty else {
            sendJSON(conn: conn, status: 400, body: ["error": "description is required"])
            return
        }

        guard let provider = try? ProviderFactory.build(config: config, purpose: "chat") else {
            let msg = language == "en"
                ? "Please set your API Key in Settings, or log in to use the cloud service."
                : "请先在设置中填写 API Key，或登录账号使用云端服务。"
            sendJSON(conn: conn, status: 400, body: ["error": msg])
            return
        }

        // Collect available tool names for the prompt
        var toolNames = SwiftToolRegistry.shared.allNames
        toolNames.append(contentsOf: MCPManager.shared.allTools().map { $0.name })

        let systemPrompt = """
        You are an AI worker configuration generator. Given a user's description, generate a JSON object for an AI worker agent.
        You MUST respond in the SAME language as the user's input. If the user writes in Chinese, ALL fields including name, description, and system_prompt MUST be in Chinese. If in English, respond in English.
        Return ONLY valid JSON, no markdown, no explanation.
        The JSON must have these fields:
        - "name": short display name for the worker
        - "icon": a single emoji that represents this worker
        - "description": one-sentence description of what the worker does
        - "system_prompt": detailed system prompt that defines the worker's personality, capabilities, and behavior guidelines (at least 3-5 sentences)
        - "tools": array of tool name strings the worker should use (pick from available tools, or empty array if none needed)
        - "max_steps": integer 3-30, how many ReAct steps this worker typically needs

        Available tools: \(toolNames.joined(separator: ", "))
        """

        let userPrompt = "Create an AI worker based on this description: \(description)"
        let messages: [[String: Any]] = [["role": "user", "content": userPrompt]]

        do {
            let response = try await provider.chatWithTools(messages: messages, tools: [], system: systemPrompt)
            let raw = response.text
            // Extract JSON from response (handle possible markdown wrapping)
            let cleaned = raw
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard let data = cleaned.data(using: .utf8),
                  let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                sendJSON(conn: conn, status: 500, body: ["error": language == "en" ? "Failed to parse AI response" : "AI 返回格式解析失败"])
                return
            }
            sendJSON(conn: conn, status: 200, body: result)
        } catch {
            let desc = error.localizedDescription
            let msg: String
            if language == "en" {
                if desc.contains("429") || desc.lowercased().contains("rate") {
                    msg = "API rate limit exceeded. Please try again later."
                } else if desc.lowercased().contains("401") || desc.lowercased().contains("auth") {
                    msg = "API Key is invalid or expired. Please check your Settings."
                } else if desc.lowercased().contains("insufficient") || desc.lowercased().contains("quota") || desc.lowercased().contains("billing") {
                    msg = "Insufficient API balance. Please top up your account."
                } else if desc.lowercased().contains("timed out") || desc.lowercased().contains("network") || desc.lowercased().contains("internet") {
                    msg = "Network error. Please check your internet connection and try again."
                } else {
                    msg = "Generation failed: \(desc)"
                }
            } else {
                if desc.contains("429") || desc.contains("rate") || desc.contains("超限") {
                    msg = "API 请求频率超限，请稍后再试。"
                } else if desc.contains("401") || desc.contains("auth") || desc.contains("invalid") {
                    msg = "API Key 无效或已过期，请在设置中检查。"
                } else if desc.contains("insufficient") || desc.contains("quota") || desc.contains("billing") || desc.contains("余额") {
                    msg = "API 余额不足，请充值后再试。"
                } else if desc.contains("timed out") || desc.contains("network") || desc.contains("internet") || desc.contains("网络") {
                    msg = "网络连接失败，请检查网络后重试。"
                } else {
                    msg = "生成失败：\(desc)"
                }
            }
            sendJSON(conn: conn, status: 500, body: ["error": msg])
        }
    }

    private func handleDeleteAgent(conn: NWConnection, agentId: String) {
        var agents = loadAgents()
        let before = agents.count
        agents.removeAll { ($0["id"] as? String) == agentId }
        if agents.count < before {
            saveAgents(agents)
            sendJSON(conn: conn, status: 200, body: ["ok": true])
        } else {
            sendJSON(conn: conn, status: 404, body: ["detail": "Agent not found"])
        }
    }

    private func loadAgents() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: agentsFileURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Seed data
            let seeds: [[String: Any]] = [
                ["id": "seed_news_curator", "name": "News Curator", "icon": "📰",
                 "description": "Searches and summarizes top news from multiple sources every day",
                 "system_prompt": "You are a professional news curator. Search for the latest trending news, filter out noise, and present a clean summary with key takeaways. Always cite sources.",
                 "tools": ["web_search", "fetch_url"], "model": "", "max_steps": 10,
                 "created_at": "2026-03-01T10:00:00"],
                ["id": "seed_code_reviewer", "name": "Code Reviewer", "icon": "🔍",
                 "description": "Reviews code, checks quality and suggests improvements",
                 "system_prompt": "You are a senior code reviewer. Analyze code for bugs, security issues, performance problems, and style. Provide actionable suggestions with code examples.",
                 "tools": ["run_code", "file_manager"], "model": "", "max_steps": 10,
                 "created_at": "2026-03-01T10:00:00"],
                ["id": "seed_data_analyst", "name": "Data Analyst", "icon": "📊",
                 "description": "Processes CSV/Excel data, generates charts and statistical reports",
                 "system_prompt": "You are a data analyst. Load data files, clean and transform data, compute statistics, and generate visualizations using Python. Present findings clearly.",
                 "tools": ["run_code", "file_manager"], "model": "", "max_steps": 15,
                 "created_at": "2026-03-01T10:00:00"],
            ]
            saveAgents(seeds)
            return seeds
        }
        return array
    }

    private func saveAgents(_ agents: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: agents, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: agentsFileURL)
    }

    // MARK: - Skill Handlers

    private func handleListSkills(conn: NWConnection, lang: String) {
        var allSkills: [[String: Any]] = []

        // Load builtin skills from bundled JSON array
        for var skill in loadBuiltinSkills() {
            skill["builtin"] = true
            if lang == "en" {
                if let nameEN = skill["name_en"] as? String { skill["name"] = nameEN }
                if let descEN = skill["description_en"] as? String { skill["description"] = descEN }
            }
            allSkills.append(skill)
        }

        // Load user skills
        if let data = try? Data(contentsOf: skillsFileURL),
           let userSkills = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for var skill in userSkills {
                skill["builtin"] = false
                allSkills.append(skill)
            }
        }

        sendJSONArray(conn: conn, status: 200, array: allSkills)
    }

    private func handleCreateSkill(conn: NWConnection, json: [String: Any]) {
        var userSkills = loadUserSkills()
        var skill = json
        skill["builtin"] = false
        userSkills.append(skill)
        saveUserSkills(userSkills)
        sendJSON(conn: conn, status: 200, body: skill)
    }

    private func handleDeleteSkill(conn: NWConnection, skillId: String) {
        // Check if builtin
        if loadBuiltinSkills().contains(where: { ($0["id"] as? String) == skillId }) {
            sendJSON(conn: conn, status: 400, body: ["detail": "内置 Skill 不可删除"])
            return
        }

        var userSkills = loadUserSkills()
        let before = userSkills.count
        userSkills.removeAll { ($0["id"] as? String) == skillId }
        if userSkills.count < before {
            saveUserSkills(userSkills)
            sendJSON(conn: conn, status: 200, body: ["ok": true])
        } else {
            sendJSON(conn: conn, status: 404, body: ["detail": "Skill not found"])
        }
    }

    private func loadUserSkills() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: skillsFileURL),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }

    private func saveUserSkills(_ skills: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: skills, options: [.prettyPrinted]) else { return }
        try? data.write(to: skillsFileURL)
    }

    // MARK: - Project Handlers

    private func handleListProjects(conn: NWConnection) {
        let fm = FileManager.default
        let root = projectsRoot
        guard let contents = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
            sendJSONArray(conn: conn, status: 200, array: [])
            return
        }

        var projects: [[String: Any]] = []
        for item in contents {
            guard (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let name = item.lastPathComponent
            if name.hasPrefix(".") { continue }
            let files = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil))?
                .filter { !$0.hasDirectoryPath } ?? []
            let modDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            let isoFormatter = ISO8601DateFormatter()
            projects.append([
                "name": name,
                "file_count": files.count,
                "modified_at": isoFormatter.string(from: modDate)
            ])
        }

        // Sort: "default" first, then alphabetical
        projects.sort { a, b in
            let aName = a["name"] as? String ?? ""
            let bName = b["name"] as? String ?? ""
            if aName == "default" { return true }
            if bName == "default" { return false }
            return aName < bName
        }

        sendJSONArray(conn: conn, status: 200, array: projects)
    }

    private func handleCreateProject(conn: NWConnection, name: String, json: [String: Any]) {
        let target = projectsRoot.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let desc = json["description"] as? String ?? ""
        writeReadme(at: target, name: name, description: desc)
        sendJSON(conn: conn, status: 200, body: ["ok": true, "name": name])
    }

    private func handleListProjectFiles(conn: NWConnection, name: String) {
        let target = projectsRoot.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: target.path) else {
            sendJSON(conn: conn, status: 404, body: ["detail": "项目不存在"])
            return
        }
        ensureReadme(at: target, name: name)

        guard let contents = try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else {
            sendJSONArray(conn: conn, status: 200, array: [])
            return
        }

        let isoFormatter = ISO8601DateFormatter()
        var files: [[String: Any]] = []
        for file in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if file.hasDirectoryPath { continue }
            let attrs = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let ext = file.pathExtension
            files.append([
                "name": file.lastPathComponent,
                "path": file.path,
                "size": attrs?.fileSize ?? 0,
                "ext": ext,
                "modified_at": isoFormatter.string(from: attrs?.contentModificationDate ?? Date())
            ])
        }

        sendJSONArray(conn: conn, status: 200, array: files)
    }

    // MARK: - Project Helpers

    private func writeReadme(at dir: URL, name: String, description: String = "") {
        let dateStr = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        }()
        var lines = ["# \(name)", ""]
        if !description.isEmpty {
            lines += [description, ""]
        }
        lines += ["---", "创建时间：\(dateStr)", ""]
        let content = lines.joined(separator: "\n")
        let readmeURL = dir.appendingPathComponent("README.md")
        try? content.write(to: readmeURL, atomically: true, encoding: .utf8)
    }

    private func ensureReadme(at dir: URL, name: String) {
        let readmeURL = dir.appendingPathComponent("README.md")
        if !FileManager.default.fileExists(atPath: readmeURL.path) {
            writeReadme(at: dir, name: name)
        }
    }

    // MARK: - Tool Execute Handler

    private func handleToolExecute(conn: NWConnection, json: [String: Any]) {
        let toolName = json["tool"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]

        // Check system tools first, then MCP tools
        let tool: ClawTool? = SwiftToolRegistry.shared.get(toolName)
            ?? MCPManager.shared.allTools().first(where: { $0.name == toolName })

        guard let tool else {
            sendJSON(conn: conn, status: 404, body: ["error": "Unknown tool: \(toolName)"])
            return
        }

        Task {
            let result = await tool.run(params: params)
            self.sendJSON(conn: conn, status: 200, body: ["result": result])
        }
    }

    // MARK: - Watchlist Handlers

    private let watchlistSeeds: [[String: Any]] = [
        ["id": "seed_morning_news", "query": "Send me hot news every morning at 10:00",
         "type": "cron", "enabled": false, "interval_minutes": 30,
         "schedule": "0 10 * * *",
         "task_prompt": "Search for the top 5 trending news stories right now. Summarize each in 2-3 sentences.",
         "summary": "Daily hot news briefing at 10:00 AM", "language": "en",
         "created_at": "2026-03-01T10:00:00", "last_checked_at": NSNull(), "last_result": NSNull(), "notify_count": 0],
        ["id": "seed_boss_email", "query": "If my boss sends me an email, please give me a call",
         "type": "poll", "enabled": false, "interval_minutes": 5, "schedule": "",
         "task_prompt": "Monitor inbox for new emails from my boss. If found, alert me immediately.",
         "summary": "Alert me when boss sends an email", "language": "en",
         "created_at": "2026-03-01T10:00:00", "last_checked_at": NSNull(), "last_result": NSNull(), "notify_count": 0],
    ]

    private func handleListWatchlist(conn: NWConnection) {
        if let data = try? Data(contentsOf: watchlistFileURL),
           let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           !items.isEmpty {
            sendJSONArray(conn: conn, status: 200, array: items)
        } else {
            // Seed data
            if let data = try? JSONSerialization.data(withJSONObject: watchlistSeeds, options: [.prettyPrinted]) {
                try? data.write(to: watchlistFileURL)
            }
            sendJSONArray(conn: conn, status: 200, array: watchlistSeeds)
        }
    }

    private func handleGetWatchlistLogs(conn: NWConnection, itemId: String) {
        guard let data = try? Data(contentsOf: watchlistLogsURL),
              let allLogs = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let logs = allLogs[itemId] as? [[String: Any]] else {
            sendJSONArray(conn: conn, status: 200, array: [])
            return
        }
        sendJSONArray(conn: conn, status: 200, array: logs)
    }

    private func handleGetWatchlistConfig(conn: NWConnection) {
        var cfg: [String: Any] = [
            "smtp_host": "", "smtp_port": 465, "smtp_user": "", "smtp_pass": "",
            "notify_email": "", "enabled": false, "poll_enabled": false,
        ]
        if let data = try? Data(contentsOf: watchlistConfigURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for (k, v) in saved { cfg[k] = v }
        }
        // Mask password
        if let pass = cfg["smtp_pass"] as? String, !pass.isEmpty {
            cfg["smtp_pass"] = "••••••••"
        }
        sendJSON(conn: conn, status: 200, body: cfg)
    }

    private func handleSaveWatchlistConfig(conn: NWConnection, json: [String: Any]) {
        var body = json
        // If masked password, keep existing
        if (body["smtp_pass"] as? String) == "••••••••" {
            if let data = try? Data(contentsOf: watchlistConfigURL),
               let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                body["smtp_pass"] = existing["smtp_pass"] ?? ""
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]) {
            try? data.write(to: watchlistConfigURL)
        }
        sendJSON(conn: conn, status: 200, body: ["ok": true])
    }

    private func handlePollStatus(conn: NWConnection) {
        var pollEnabled = false
        if let data = try? Data(contentsOf: watchlistConfigURL),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            pollEnabled = cfg["poll_enabled"] as? Bool ?? false
        }
        sendJSON(conn: conn, status: 200, body: ["poll_enabled": pollEnabled])
    }

    // MARK: - Watchlist CRUD Handlers

    private func handleTogglePoll(conn: NWConnection, json: [String: Any]) {
        var cfg: [String: Any] = [:]
        if let data = try? Data(contentsOf: watchlistConfigURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            cfg = saved
        }
        let current = cfg["poll_enabled"] as? Bool ?? false
        cfg["poll_enabled"] = !current
        if let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) {
            try? data.write(to: watchlistConfigURL)
        }
        sendJSON(conn: conn, status: 200, body: ["poll_enabled": !current])
    }

    private func handleCreateWatchlistItem(conn: NWConnection, json: [String: Any]) {
        let query = json["query"] as? String ?? ""
        let config = json["config"] as? [String: Any] ?? AppConfig.configPayload()
        let id = UUID().uuidString
        let createdAt = ISO8601DateFormatter().string(from: Date())

        Task {
            let parsed = await self.parseWatchQuery(query: query, config: config)
            var item: [String: Any] = [
                "id": id,
                "query": query,
                "type": parsed["type"] ?? "poll",
                "enabled": true,
                "interval_minutes": parsed["interval_minutes"] ?? 30,
                "schedule": parsed["schedule"] ?? "",
                "task_prompt": parsed["task_prompt"] ?? query,
                "summary": parsed["summary"] ?? query,
                "created_at": createdAt,
                "last_checked_at": NSNull(),
                "last_result": NSNull(),
                "notify_count": 0,
            ]
            // Merge any extra fields from json
            for (k, v) in json where k != "query" && k != "config" && k != "language" {
                item[k] = v
            }
            var items = self.loadWatchlistItems()
            items.insert(item, at: 0)
            self.saveWatchlistItems(items)
            self.sendJSON(conn: conn, status: 200, body: item)
        }
    }

    private func handleUpdateWatchlistItem(conn: NWConnection, itemId: String, json: [String: Any]) {
        var items = loadWatchlistItems()
        guard let idx = items.firstIndex(where: { ($0["id"] as? String) == itemId }) else {
            sendJSON(conn: conn, status: 404, body: ["detail": "Watchlist item not found"])
            return
        }
        var item = items[idx]
        for (key, value) in json where key != "id" {
            item[key] = value
        }
        items[idx] = item
        saveWatchlistItems(items)
        sendJSON(conn: conn, status: 200, body: item)
    }

    private func handleReparseWatchlistItem(conn: NWConnection, itemId: String, json: [String: Any]) {
        let newQuery = json["query"] as? String ?? ""
        let config = json["config"] as? [String: Any] ?? AppConfig.configPayload()

        Task {
            var items = self.loadWatchlistItems()
            guard let idx = items.firstIndex(where: { ($0["id"] as? String) == itemId }) else {
                self.sendJSON(conn: conn, status: 404, body: ["detail": "Watchlist item not found"])
                return
            }
            var item = items[idx]
            if !newQuery.isEmpty {
                let parsed = await self.parseWatchQuery(query: newQuery, config: config)
                item["query"] = newQuery
                item["type"] = parsed["type"] ?? item["type"] ?? "poll"
                item["interval_minutes"] = parsed["interval_minutes"] ?? item["interval_minutes"] ?? 30
                item["schedule"] = parsed["schedule"] ?? item["schedule"] ?? ""
                item["task_prompt"] = parsed["task_prompt"] ?? newQuery
                item["summary"] = parsed["summary"] ?? newQuery
            }
            items[idx] = item
            self.saveWatchlistItems(items)
            self.sendJSON(conn: conn, status: 200, body: item)
        }
    }

    private func handleDeleteWatchlistItem(conn: NWConnection, itemId: String) {
        var items = loadWatchlistItems()
        let before = items.count
        items.removeAll { ($0["id"] as? String) == itemId }
        if items.count < before {
            saveWatchlistItems(items)
            sendJSON(conn: conn, status: 200, body: ["ok": true])
        } else {
            sendJSON(conn: conn, status: 404, body: ["detail": "Watchlist item not found"])
        }
    }

    private func loadWatchlistItems() -> [[String: Any]] {
        if let data = try? Data(contentsOf: watchlistFileURL),
           let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return items
        }
        return watchlistSeeds
    }

    private func saveWatchlistItems(_ items: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted]) {
            try? data.write(to: watchlistFileURL)
        }
    }

    // MARK: - Watch Query AI Parser

    /// Use LLM to parse natural language query into structured watchlist fields.
    /// Returns: type, schedule, interval_minutes, task_prompt, summary
    private func parseWatchQuery(query: String, config: [String: Any]) async -> [String: Any] {
        let fallback: [String: Any] = [
            "type": "poll",
            "interval_minutes": 30,
            "schedule": "",
            "task_prompt": query,
            "summary": query
        ]

        // Try config from request, fall back to AppConfig
        let effectiveConfig: [String: Any]
        if let _ = config["anthropic_api_key"] as? String, !((config["anthropic_api_key"] as? String) ?? "").isEmpty {
            effectiveConfig = config
        } else if let _ = config["openai_api_key"] as? String, !((config["openai_api_key"] as? String) ?? "").isEmpty {
            effectiveConfig = config
        } else if let _ = config["auth_token"] as? String, !((config["auth_token"] as? String) ?? "").isEmpty {
            effectiveConfig = config
        } else {
            effectiveConfig = AppConfig.configPayload()
        }

        print("[SwiftBackend] parseWatchQuery: query=\(query), provider=\(effectiveConfig["provider"] ?? "nil"), hasAuthToken=\(!((effectiveConfig["auth_token"] as? String) ?? "").isEmpty), hasAnthropicKey=\(!((effectiveConfig["anthropic_api_key"] as? String) ?? "").isEmpty)")

        // Debug: write log to file since print() may not show in system logs
        let debugLog = aichatDir.appendingPathComponent("watchlist_parse_debug.log")
        func logDebug(_ msg: String) {
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: debugLog.path) {
                    if let fh = try? FileHandle(forWritingTo: debugLog) {
                        fh.seekToEndOfFile(); fh.write(data); fh.closeFile()
                    }
                } else {
                    try? data.write(to: debugLog)
                }
            }
        }

        logDebug("query=\(query), provider=\(effectiveConfig["provider"] ?? "nil"), hasAnthropicKey=\(!((effectiveConfig["anthropic_api_key"] as? String) ?? "").isEmpty), hasAuthToken=\(!((effectiveConfig["auth_token"] as? String) ?? "").isEmpty)")

        guard let provider = try? ProviderFactory.build(config: effectiveConfig, purpose: "utility") else {
            logDebug("ProviderFactory.build FAILED")
            return fallback
        }
        logDebug("ProviderFactory.build OK, calling singleCall...")

        let system = """
        You are a task parser. Given a user's natural language task description, extract structured fields.
        Respond ONLY with a valid JSON object, no markdown, no explanation. Fields:
        - "type": "cron" if user specified a specific time/date/schedule (e.g. "每天10点", "下午3点", "周一到周五"), otherwise "poll"
        - "schedule": crontab expression (5 fields: minute hour day month weekday, e.g. "0 10 * * *") if type is cron, empty string "" if poll
        - "interval_minutes": polling interval in minutes (default 30) if type is poll, 0 if cron
        - "task_prompt": rewrite the user's request as a clear, actionable instruction for an AI assistant to execute
        - "summary": a short one-line summary of what this task does

        Examples:
        Input: "每天早上10点给我发新闻摘要"
        Output: {"type":"cron","schedule":"0 10 * * *","interval_minutes":0,"task_prompt":"搜索今日热门新闻，整理成摘要，包含5条最重要的新闻标题和简要内容","summary":"每天10:00 发送新闻摘要"}

        Input: "每隔5分钟检查下我的邮箱有没有老板的邮件"
        Output: {"type":"poll","schedule":"","interval_minutes":5,"task_prompt":"检查邮箱中是否有来自老板的新邮件，如果有则立即提醒","summary":"每5分钟检查老板邮件"}

        Input: "十点11分给我发一份新闻热点总结"
        Output: {"type":"cron","schedule":"11 10 * * *","interval_minutes":0,"task_prompt":"搜索当前最热门的新闻事件，整理成热点总结报告，包含主要新闻标题和简要分析","summary":"10:11 发送新闻热点总结"}
        """

        do {
            let rawResult = try await provider.singleCall(prompt: query, system: system)
            logDebug("singleCall returned: \(rawResult.prefix(300))")

            // Extract JSON from response (might be wrapped in markdown code block)
            var jsonStr = rawResult
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            // Try to find JSON object in response
            if let start = jsonStr.firstIndex(of: "{"),
               let end = jsonStr.lastIndex(of: "}") {
                jsonStr = String(jsonStr[start...end])
            }

            if let data = jsonStr.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                var result = fallback
                if let t = parsed["type"] as? String { result["type"] = t }
                if let s = parsed["schedule"] as? String { result["schedule"] = s }
                if let i = parsed["interval_minutes"] as? Int { result["interval_minutes"] = i }
                else if let i = parsed["interval_minutes"] as? Double { result["interval_minutes"] = Int(i) }
                if let p = parsed["task_prompt"] as? String { result["task_prompt"] = p }
                if let sm = parsed["summary"] as? String { result["summary"] = sm }
                print("[SwiftBackend] parseWatchQuery parsed: type=\(result["type"]!), schedule=\(result["schedule"]!)")
                return result
            } else {
                print("[SwiftBackend] parseWatchQuery: failed to parse JSON from: \(jsonStr)")
            }
        } catch {
            logDebug("singleCall FAILED: \(error)")
        }
        return fallback
    }

    // MARK: - MCP Handlers

    private func handleGetMCPServers(conn: NWConnection) {
        let servers = MCPManager.shared.serverList()
        sendJSONArray(conn: conn, status: 200, array: servers)
    }

    private func handleInstallMCPServer(conn: NWConnection, json: [String: Any]) {
        let name = json["name"] as? String ?? ""
        let command = json["command"] as? [String] ?? []
        let env = json["env"] as? [String: String] ?? [:]
        guard !name.isEmpty, !command.isEmpty else {
            sendJSON(conn: conn, status: 400, body: ["error": "name and command required"])
            return
        }
        let count = MCPManager.shared.installServer(name: name, command: command, env: env)
        sendJSON(conn: conn, status: 200, body: ["ok": true, "tool_count": count])
    }

    private func handleRemoveMCPServer(conn: NWConnection, name: String) {
        MCPManager.shared.removeServer(name: name)
        sendJSON(conn: conn, status: 200, body: ["ok": true])
    }

    private func handleReloadMCPServer(conn: NWConnection, name: String) {
        MCPManager.shared.reloadServer(name: name)
        sendJSON(conn: conn, status: 200, body: ["ok": true])
    }

    // MARK: - Tools List Handler

    private func handleListAllTools(conn: NWConnection) {
        var result: [[String: Any]] = []

        // System tools
        for def in SwiftToolRegistry.shared.allDefinitions() {
            result.append([
                "name": def["name"] ?? "",
                "description": def["description"] ?? "",
                "type": "api",
                "server": NSNull(),
                "removable": false,
            ])
        }

        // MCP tools
        for tool in MCPManager.shared.allTools() {
            result.append([
                "name": tool.name,
                "description": tool.definition["description"] ?? "",
                "type": "mcp",
                "server": tool.serverName,
                "removable": true,
            ])
        }

        // Composio tools (display only - execution requires auth_token at chat time)
        for info in ComposioClient.shared.installedList() {
            let slug = info["slug"] as? String ?? ""
            let count = info["tool_count"] as? Int ?? 0
            result.append([
                "name": "composio__\(slug)",
                "description": "Composio \(slug) toolkit (\(count) tools)",
                "type": "composio",
                "server": slug,
                "removable": true,
            ])
        }

        sendJSONArray(conn: conn, status: 200, array: result)
    }

    // MARK: - Skill Market Handlers

    private func handleGetSkillMarket(conn: NWConnection, tab: String, q: String, limit: Int) {
        let baseURL = "\(AppConfig.serviceBaseURL)/api/v1/clawhub"
        let urlString: String
        if !q.isEmpty {
            let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            urlString = "\(baseURL)/search?q=\(encoded)&limit=\(limit)"
        } else {
            urlString = "\(baseURL)/skills?tab=\(tab)&limit=\(limit)"
        }

        guard let url = URL(string: urlString) else {
            sendJSONArray(conn: conn, status: 200, array: [])
            return
        }

        let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            guard let self else { conn.cancel(); return }

            guard let data else {
                self.sendJSONArray(conn: conn, status: 200, array: [])
                return
            }

            // API may return {"ok": true, "data": [...]} or plain array
            var skills: [[String: Any]]
            if let wrapper = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = wrapper["data"] as? [[String: Any]] {
                skills = arr
            } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                skills = arr
            } else {
                self.sendJSONArray(conn: conn, status: 200, array: [])
                return
            }

            // Mark installed skills (check all skills: builtin + user)
            var allIds = Set<String>()
            // Builtin skill IDs
            for s in self.loadBuiltinSkills() {
                if let id = s["id"] as? String { allIds.insert(id) }
            }
            // User skill IDs
            let userSkills = self.loadUserSkills()
            for s in userSkills {
                if let id = s["id"] as? String { allIds.insert(id) }
                if let slug = s["slug"] as? String { allIds.insert(slug) }
            }

            for i in skills.indices {
                let slug = skills[i]["slug"] as? String ?? ""
                let id = skills[i]["id"] as? String ?? ""
                skills[i]["installed"] = allIds.contains(slug) || allIds.contains(id)
            }

            self.sendJSONArray(conn: conn, status: 200, array: skills)
        }
        task.resume()
    }

    private func handleInstallMarketSkill(conn: NWConnection, json: [String: Any]) {
        let slug = json["slug"] as? String ?? ""
        if slug.isEmpty {
            sendJSON(conn: conn, status: 400, body: ["detail": "缺少 slug"])
            return
        }

        var userSkills = loadUserSkills()

        // Build skill entry from market data
        let skill: [String: Any] = [
            "id": slug,
            "slug": slug,
            "name": json["display_name"] as? String ?? slug,
            "description": json["summary"] as? String ?? "",
            "icon": "⚡",
            "system_prompt": "",
            "tools": [] as [String],
            "builtin": false,
            "owner_handle": json["owner_handle"] as? String ?? "",
            "downloads": json["downloads"] as? Int ?? 0,
            "stars": json["stars"] as? Int ?? 0,
            "is_certified": json["is_certified"] as? Bool ?? false,
            "clawhub_url": json["clawhub_url"] as? String ?? "",
        ]

        // Avoid duplicate
        userSkills.removeAll { ($0["id"] as? String) == slug || ($0["slug"] as? String) == slug }
        userSkills.append(skill)
        saveUserSkills(userSkills)

        sendJSON(conn: conn, status: 200, body: ["ok": true, "skill": skill])
    }


    // MARK: - HTTP Responses

    private func sendJSON(conn: NWConnection, status: Int, body: [String: Any]) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        sendRawResponse(conn: conn, status: status, data: jsonData)
    }

    private func sendJSONArray(conn: NWConnection, status: Int, array: [[String: Any]]) {
        let jsonData = (try? JSONSerialization.data(withJSONObject: array)) ?? Data()
        sendRawResponse(conn: conn, status: status, data: jsonData)
    }

    private func sendRawResponse(conn: NWConnection, status: Int, data: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 422: statusText = "Unprocessable Entity"
        case 502: statusText = "Bad Gateway"
        default: statusText = "Error"
        }

        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)

        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - Data Extension (shared with OSBridgeServer)

extension Data {
    func findHeaderEnd() -> Data.Index? {
        let separator = Data("\r\n\r\n".utf8)
        guard count >= separator.count else { return nil }
        for i in startIndex...(endIndex - separator.count) {
            if self[i..<(i + separator.count)] == separator {
                return i + separator.count
            }
        }
        return nil
    }
}
