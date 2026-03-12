import Foundation

// MARK: - MCP Server Process (JSON-RPC over stdio)

final class MCPServerProcess {
    let name: String
    let command: [String]
    let envExtra: [String: String]

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var msgId: Int = 0
    private let lock = NSLock()

    var isRunning: Bool { process?.isRunning ?? false }

    init(name: String, command: [String], envExtra: [String: String] = [:]) {
        self.name = name
        self.command = command
        self.envExtra = envExtra
    }

    func start() throws {
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe() // discard stderr

        // Find executable
        guard !command.isEmpty else { throw MCPError.invalidCommand }
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = command

        // Build environment
        var env = ProcessInfo.processInfo.environment
        // Ensure common paths for npx/uvx
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                          NSHomeDirectory() + "/.nvm/versions/node/v22.0.0/bin",
                          NSHomeDirectory() + "/.local/bin"]
        let currentPath = env["PATH"] ?? "/usr/bin"
        env["PATH"] = (extraPaths + [currentPath]).joined(separator: ":")
        for (k, v) in envExtra { env[k] = v }
        proc.environment = env

        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting
        self.stdout = stdoutPipe.fileHandleForReading

        // MCP handshake: initialize
        let initResult = try rpc(method: "initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "clawbie", "version": "1.0"],
        ])

        guard initResult["protocolVersion"] != nil else {
            stop()
            throw MCPError.handshakeFailed
        }

        // Send initialized notification (no id = notification)
        send(message: ["jsonrpc": "2.0", "method": "notifications/initialized"])
        NSLog("[MCP] Server '\(name)' started, protocol ok")
    }

    func stop() {
        if let p = process, p.isRunning {
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.process?.isRunning == true {
                    self?.process?.interrupt()
                }
            }
        }
        stdin = nil
        stdout = nil
        process = nil
    }

    func listTools() throws -> [[String: Any]] {
        let result = try rpc(method: "tools/list", params: nil)
        return result["tools"] as? [[String: Any]] ?? []
    }

    func callTool(name toolName: String, arguments: [String: Any]) throws -> String {
        let result = try rpc(method: "tools/call", params: [
            "name": toolName,
            "arguments": arguments,
        ])
        // Check for MCP-level isError flag
        let isError = result["isError"] as? Bool ?? false
        // Parse content blocks
        if let content = result["content"] as? [[String: Any]] {
            let text = content.compactMap { block -> String? in
                (block["type"] as? String) == "text" ? block["text"] as? String : nil
            }.joined(separator: "\n")
            if isError {
                throw MCPError.rpcError(text)
            }
            return text
        }
        if isError {
            throw MCPError.rpcError("Tool returned error with no content")
        }
        return ""
    }

    // MARK: - JSON-RPC Internal

    private func send(message: [String: Any]) {
        guard let handle = stdin,
              let data = try? JSONSerialization.data(withJSONObject: message),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        lock.lock()
        handle.write(Data(line.utf8))
        lock.unlock()
    }

    private func recv() throws -> [String: Any] {
        guard let handle = stdout else { throw MCPError.notRunning }
        // Read line by line
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { throw MCPError.eofReached }
            buffer.append(chunk)
            if let str = String(data: buffer, encoding: .utf8), str.contains("\n") {
                let lines = str.components(separatedBy: "\n")
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    if let jsonData = trimmed.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                        return json
                    }
                }
                buffer = Data()
            }
        }
    }

    private func rpc(method: String, params: [String: Any]?) throws -> [String: Any] {
        lock.lock()
        msgId += 1
        let currentId = msgId
        lock.unlock()

        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "id": currentId,
            "method": method,
        ]
        if let p = params { msg["params"] = p }

        send(message: msg)

        // Read responses until we find matching id (skip notifications)
        for _ in 0..<100 {
            let response = try recv()
            if let respId = response["id"] as? Int, respId == currentId {
                if let error = response["error"] as? [String: Any] {
                    let errMsg = error["message"] as? String ?? "Unknown RPC error"
                    throw MCPError.rpcError(errMsg)
                }
                return response["result"] as? [String: Any] ?? [:]
            }
            // Skip notifications (no id field)
        }
        throw MCPError.timeout
    }
}

// MARK: - MCP Tool (wraps a single tool from an MCP server)

final class MCPTool: ClawTool {
    let name: String
    let serverName: String
    private let server: MCPServerProcess
    private let toolDef: [String: Any]
    private let originalName: String

    init(server: MCPServerProcess, toolDef: [String: Any]) {
        self.server = server
        self.serverName = server.name
        self.originalName = toolDef["name"] as? String ?? ""
        self.name = "mcp__\(server.name)__\(originalName)"
        self.toolDef = toolDef
    }

    var definition: [String: Any] {
        let desc = toolDef["description"] as? String ?? ""
        return [
            "name": name,
            "description": "[MCP:\(serverName)] \(desc)",
            "parameters": toolDef["inputSchema"] ?? toolDef["input_schema"] ?? [:],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let serverRef = self.server
        let toolName = self.originalName
        let sName = self.serverName
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                do {
                    let result = try serverRef.callTool(name: toolName, arguments: params)
                    cont.resume(returning: result)
                } catch {
                    let errMsg = error.localizedDescription
                    MCPManager.shared.reportError(serverName: sName, error: errMsg)
                    cont.resume(returning: "MCP 工具执行失败: \(errMsg)")
                }
            }
        }
    }
}

// MARK: - MCP Manager (manages all MCP server processes)

final class MCPManager {
    static let shared = MCPManager()
    private let configPath: URL
    private var processes: [String: MCPServerProcess] = [:]
    private var mcpTools: [String: [MCPTool]] = [:] // serverName -> tools
    private var status: [String: String] = [:] // serverName -> "loading"|"connected"|"failed"
    private var lastErrors: [String: String] = [:] // serverName -> last error message
    private let lock = NSLock()

    private init() {
        configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aichat/mcp_servers.json")
    }

    func startAll() {
        let configs = loadConfig()
        for cfg in configs {
            guard let name = cfg["name"] as? String,
                  let command = cfg["command"] as? [String] else { continue }
            let env = cfg["env"] as? [String: String] ?? [:]
            DispatchQueue.global().async {
                self.startServer(name: name, command: command, env: env)
            }
        }
    }

    func stopAll() {
        lock.lock()
        let procs = Array(processes.values)
        processes.removeAll()
        mcpTools.removeAll()
        status.removeAll()
        lastErrors.removeAll()
        lock.unlock()
        for p in procs { p.stop() }
    }

    func startServer(name: String, command: [String], env: [String: String] = [:]) {
        lock.lock()
        status[name] = "loading"
        lock.unlock()

        let proc = MCPServerProcess(name: name, command: command, envExtra: env)
        do {
            try proc.start()
            let tools = try proc.listTools()
            let mcpToolList = tools.map { MCPTool(server: proc, toolDef: $0) }

            lock.lock()
            processes[name] = proc
            mcpTools[name] = mcpToolList
            status[name] = "connected"
            lastErrors.removeValue(forKey: name)
            lock.unlock()

            NSLog("[MCP] Server '\(name)' loaded \(mcpToolList.count) tools")
        } catch {
            lock.lock()
            status[name] = "failed"
            lastErrors[name] = error.localizedDescription
            lock.unlock()
            proc.stop()
            NSLog("[MCP] Failed to start '\(name)': \(error)")
        }
    }

    func stopServer(name: String) {
        lock.lock()
        processes[name]?.stop()
        processes.removeValue(forKey: name)
        mcpTools.removeValue(forKey: name)
        status.removeValue(forKey: name)
        lastErrors.removeValue(forKey: name)
        lock.unlock()
    }

    func reloadServer(name: String) {
        let configs = loadConfig()
        guard let cfg = configs.first(where: { ($0["name"] as? String) == name }),
              let command = cfg["command"] as? [String] else { return }
        let env = cfg["env"] as? [String: String] ?? [:]
        stopServer(name: name)
        startServer(name: name, command: command, env: env)
    }

    func allTools() -> [MCPTool] {
        lock.lock()
        defer { lock.unlock() }
        return mcpTools.values.flatMap { $0 }
    }

    /// Called by MCPTool when execution fails — marks server as error state
    func reportError(serverName: String, error: String) {
        lock.lock()
        // Only mark failed if the process actually died
        if let proc = processes[serverName], !proc.isRunning {
            status[serverName] = "failed"
        }
        lastErrors[serverName] = error
        lock.unlock()
        NSLog("[MCP] Tool error on '\(serverName)': \(error)")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .mcpToolStatusChanged, object: nil,
                                            userInfo: ["server": serverName, "error": error])
        }
    }

    func serverList() -> [[String: Any]] {
        let configs = loadConfig()
        return configs.map { cfg -> [String: Any] in
            let name = cfg["name"] as? String ?? ""
            lock.lock()
            var s = status[name] ?? "stopped"
            // Check if process died since last check
            if s == "connected", let proc = processes[name], !proc.isRunning {
                s = "failed"
                status[name] = "failed"
                if lastErrors[name] == nil {
                    lastErrors[name] = "进程已退出"
                }
            }
            let count = mcpTools[name]?.count ?? 0
            let errMsg = lastErrors[name]
            lock.unlock()
            var result: [String: Any] = [
                "name": name,
                "command": cfg["command"] ?? [],
                "env": cfg["env"] ?? [:],
                "tool_count": count,
                "status": s,
            ]
            if let errMsg = errMsg {
                result["error"] = errMsg
            }
            return result
        }
    }

    func installServer(name: String, command: [String], env: [String: String]) -> Int {
        // Save to config
        var configs = loadConfig()
        configs.removeAll { ($0["name"] as? String) == name }
        configs.append(["name": name, "command": command, "env": env])
        saveConfig(configs)

        // Start
        startServer(name: name, command: command, env: env)

        lock.lock()
        let count = mcpTools[name]?.count ?? 0
        lock.unlock()
        return count
    }

    func removeServer(name: String) {
        stopServer(name: name)
        var configs = loadConfig()
        configs.removeAll { ($0["name"] as? String) == name }
        saveConfig(configs)
    }

    // MARK: - Config I/O

    func loadConfig() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: configPath),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private func saveConfig(_ configs: [[String: Any]]) {
        guard let data = try? JSONSerialization.data(withJSONObject: configs, options: .prettyPrinted) else { return }
        try? data.write(to: configPath, options: .atomic)
    }
}

// MARK: - Composio Client (supports both TuuAI proxy and direct API)

final class ComposioClient {
    static let shared = ComposioClient()
    private let configPath: URL
    private var toolkits: [String: [[String: Any]]] = [:] // slug -> [tool_defs]
    private var authErrors: [String: String] = [:] // slug -> error message

    /// 是否使用直连模式（本地模式 + 有 Composio API Key）
    var isDirectMode: Bool {
        UserDefaults.standard.bool(forKey: "aichat.local_mode") && !AppConfig.composioApiKey.isEmpty
    }

    /// 根据模式选择 base URL
    private var baseURL: String {
        if isDirectMode {
            return "https://backend.composio.dev/api/v1"
        }
        return "\(AppConfig.serviceBaseURL)/api/v1/composio"
    }

    private init() {
        configPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aichat/composio_toolkits.json")
        loadFromDisk()
    }

    func allTools(authTokenGetter: @escaping () -> String) -> [ComposioTool] {
        return toolkits.flatMap { (slug, defs) in
            defs.map { ComposioTool(toolDef: $0, slug: slug, authTokenGetter: authTokenGetter) }
        }
    }

    func installedList() -> [[String: Any]] {
        toolkits.map { entry -> [String: Any] in
            var item: [String: Any] = ["slug": entry.key, "tool_count": entry.value.count]
            if let err = authErrors[entry.key] {
                item["auth_error"] = err
            }
            return item
        }
    }

    func reportAuthError(slug: String, error: String) {
        authErrors[slug] = error
        NSLog("[Composio] Auth error for '\(slug)': \(error)")
    }

    func clearAuthError(slug: String) {
        authErrors.removeValue(forKey: slug)
    }

    func install(slug: String, authToken: String) async -> Int {
        uninstall(slug: slug)
        authErrors.removeValue(forKey: slug)
        guard let tools = await fetchTools(slug: slug, authToken: authToken) else { return 0 }
        toolkits[slug] = tools
        saveToDisk()
        return tools.count
    }

    func uninstall(slug: String) {
        toolkits.removeValue(forKey: slug)
        saveToDisk()
    }

    func refreshAll(authToken: String) async -> [String: Int] {
        var result: [String: Int] = [:]
        for slug in Array(toolkits.keys) {
            if let tools = await fetchTools(slug: slug, authToken: authToken) {
                toolkits[slug] = tools
                result[slug] = tools.count
            }
        }
        saveToDisk()
        return result
    }

    struct ExecuteResult {
        let output: String
        let successful: Bool
    }

    func execute(toolName: String, arguments: [String: Any], authToken: String) async -> ExecuteResult {
        if isDirectMode {
            return await executeDirectAPI(toolName: toolName, arguments: arguments)
        }
        return await executeViaProxy(toolName: toolName, arguments: arguments, authToken: authToken)
    }

    // MARK: - Direct Composio API (本地模式)

    /// 直连 Composio API 列出应用
    func fetchAppsDirectly(cursor: String? = nil, limit: Int = 50) async -> (items: [[String: Any]], nextCursor: String?) {
        var urlStr = "\(baseURL)/apps?limit=\(limit)"
        if let c = cursor, !c.isEmpty { urlStr += "&cursor=\(c)" }
        guard let url = URL(string: urlStr) else { return ([], nil) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(AppConfig.composioApiKey, forHTTPHeaderField: "x-api-key")

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ([], nil) }
        let items = json["items"] as? [[String: Any]] ?? []
        let next = json["next_cursor"] as? String
        return (items, next)
    }

    /// 直连 Composio API 获取某个 app 的工具定义（v2 API）
    func fetchToolsDirectly(appName: String) async -> [[String: Any]]? {
        let v2Base = "https://backend.composio.dev/api/v2"
        var allItems: [[String: Any]] = []
        var page = 1
        let pageLimit = 100

        while true {
            guard let url = URL(string: "\(v2Base)/actions?apps=\(appName)&limit=\(pageLimit)&page=\(page)") else { return nil }
            var req = URLRequest(url: url, timeoutInterval: 60)
            req.setValue(AppConfig.composioApiKey, forHTTPHeaderField: "x-api-key")

            guard let (data, _) = try? await URLSession.shared.data(for: req),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return allItems.isEmpty ? nil : allItems }
            let items = json["items"] as? [[String: Any]] ?? []
            allItems.append(contentsOf: items)

            let totalPages = json["totalPages"] as? Int ?? 1
            if page >= totalPages || items.isEmpty { break }
            page += 1
        }
        NSLog("[Composio] fetchToolsDirectly(\(appName)): got \(allItems.count) tools")
        return allItems.isEmpty ? nil : allItems
    }

    /// 直连 Composio API 执行工具（v2 API）
    private func executeDirectAPI(toolName: String, arguments: [String: Any]) async -> ExecuteResult {
        let v2Base = "https://backend.composio.dev/api/v2"
        guard let url = URL(string: "\(v2Base)/actions/\(toolName)/execute") else {
            return ExecuteResult(output: "URL error", successful: false)
        }
        var request = URLRequest(url: url, timeoutInterval: 240)
        request.httpMethod = "POST"
        request.setValue(AppConfig.composioApiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["input": arguments]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ExecuteResult(output: "Composio 调用失败（网络错误）", successful: false)
        }

        if let resultData = json["data"] ?? json["response_data"],
           let jsonData = try? JSONSerialization.data(withJSONObject: resultData, options: .prettyPrinted),
           let text = String(data: jsonData, encoding: .utf8) {
            let success = json["successfull"] as? Bool ?? json["successful"] as? Bool ?? true
            return ExecuteResult(output: text, successful: success)
        }
        let error = json["error"] as? String ?? json["message"] as? String ?? "unknown"
        return ExecuteResult(output: "执行失败: \(error)", successful: false)
    }

    /// 直连 Composio API 发起 OAuth 连接
    /// 流程：先获取 integrationId，再发起连接拿 redirectUrl
    func connectDirectly(appName: String) async -> String? {
        let apiKey = AppConfig.composioApiKey
        guard !apiKey.isEmpty else { return nil }

        // Step 1: 查找已有 integration，没有则自动创建
        var integrationId: String?

        // 1a: 查找已有
        if let intURL = URL(string: "\(baseURL)/integrations?appName=\(appName)") {
            var intReq = URLRequest(url: intURL, timeoutInterval: 30)
            intReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            if let (intData, _) = try? await URLSession.shared.data(for: intReq),
               let intJson = try? JSONSerialization.jsonObject(with: intData) as? [String: Any],
               let items = intJson["items"] as? [[String: Any]],
               let first = items.first,
               let id = first["id"] as? String {
                integrationId = id
                debugLog("[Composio] Found existing integration for \(appName): \(id)")
            }
        }

        // 1b: 没有则创建
        if integrationId == nil {
            debugLog("[Composio] No integration for \(appName), creating one...")
            guard let createURL = URL(string: "\(baseURL)/integrations") else { return nil }
            var createReq = URLRequest(url: createURL, timeoutInterval: 30)
            createReq.httpMethod = "POST"
            createReq.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let createBody: [String: Any] = [
                "name": "\(appName)-oauth",
                "appName": appName,
                "useComposioAuth": true,
            ]
            createReq.httpBody = try? JSONSerialization.data(withJSONObject: createBody)
            if let (createData, _) = try? await URLSession.shared.data(for: createReq),
               let createJson = try? JSONSerialization.jsonObject(with: createData) as? [String: Any],
               let id = createJson["id"] as? String {
                integrationId = id
                debugLog("[Composio] Created integration for \(appName): \(id)")
            } else {
                debugLog("[Composio] Failed to create integration for \(appName)")
                return nil
            }
        }

        guard let finalId = integrationId else { return nil }

        // Step 2: 发起连接
        guard let url = URL(string: "\(baseURL)/connectedAccounts") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["integrationId": finalId, "data": [:] as [String: Any]]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let redirectUrl = json["redirectUrl"] as? String
        debugLog("[Composio] Connect response redirectUrl: \(redirectUrl ?? "nil")")
        return redirectUrl
    }

    /// 直连 Composio API 列出已连接账户
    func fetchConnectionsDirectly() async -> [[String: Any]] {
        guard let url = URL(string: "\(baseURL)/connectedAccounts?showActiveOnly=true") else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(AppConfig.composioApiKey, forHTTPHeaderField: "x-api-key")

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return json["items"] as? [[String: Any]] ?? []
    }

    // MARK: - Proxy Mode (云端模式 via TuuAI)

    private func executeViaProxy(toolName: String, arguments: [String: Any], authToken: String) async -> ExecuteResult {
        guard let url = URL(string: "\(baseURL)/execute") else {
            return ExecuteResult(output: "URL error", successful: false)
        }
        var request = URLRequest(url: url, timeoutInterval: 240)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["tool_slug": toolName, "tool_input": arguments]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ExecuteResult(output: "Composio 调用失败（网络错误）", successful: false)
        }

        if json["successful"] as? Bool == true {
            if let resultData = json["data"],
               let jsonData = try? JSONSerialization.data(withJSONObject: resultData, options: .prettyPrinted),
               let text = String(data: jsonData, encoding: .utf8) {
                return ExecuteResult(output: text, successful: true)
            }
            return ExecuteResult(output: "执行成功", successful: true)
        }
        let error = json["error"] as? String ?? "unknown"
        return ExecuteResult(output: "执行失败: \(error)", successful: false)
    }

    // MARK: - Tool fetching (both modes)

    func fetchTools(slug: String, authToken: String) async -> [[String: Any]]? {
        if isDirectMode {
            return await fetchToolsDirectly(appName: slug)
        }
        return await fetchToolsViaProxy(slug: slug, authToken: authToken)
    }

    private func fetchToolsViaProxy(slug: String, authToken: String) async -> [[String: Any]]? {
        guard let url = URL(string: "\(baseURL)/tools") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["slug": slug])

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json["tools"] as? [[String: Any]]
    }

    // MARK: - Persistence

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: configPath),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for item in arr {
            if let slug = item["slug"] as? String, let tools = item["tools"] as? [[String: Any]] {
                toolkits[slug] = tools
            }
        }
    }

    private func saveToDisk() {
        let arr: [[String: Any]] = toolkits.map { ["slug": $0.key, "tools": $0.value] }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: .prettyPrinted) else { return }
        try? data.write(to: configPath, options: .atomic)
    }
}

// MARK: - Composio Tool

final class ComposioTool: ClawTool {
    let name: String
    let slug: String
    private let toolDef: [String: Any]
    private let originalName: String
    private let authTokenGetter: () -> String

    init(toolDef: [String: Any], slug: String, authTokenGetter: @escaping () -> String) {
        self.toolDef = toolDef
        self.slug = slug
        self.originalName = toolDef["name"] as? String ?? ""
        self.name = "composio__\(slug)__\(originalName)"
        self.authTokenGetter = authTokenGetter
    }

    var definition: [String: Any] {
        let desc = toolDef["description"] as? String ?? ""
        return [
            "name": name,
            "description": "[Composio:\(slug)] \(desc) (已通过OAuth授权)",
            "parameters": toolDef["parameters"] ?? toolDef["input_schema"] ?? toolDef["inputSchema"] ?? [:],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let token = authTokenGetter()
        // 直连模式不需要 authToken，代理模式需要
        if !ComposioClient.shared.isDirectMode && token.isEmpty {
            return "错误：未登录，无法执行 Composio 工具"
        }
        let result = await ComposioClient.shared.execute(toolName: originalName, arguments: params, authToken: token)
        if !result.successful {
            NSLog("[ComposioTool] Execute failed for \(slug)/\(originalName): \(result.output)")
        }
        return result.output
    }
}

// MARK: - Sub-Agent Tool

final class SubAgentTool: ClawTool {
    let name: String
    private let agentConfig: [String: Any]
    private let providerConfig: [String: Any]
    private let agentDisplayName: String

    /// Injected by orchestrator before execution — forwards sub-agent events to frontend
    var parentEmit: (([String: Any]) async -> Void)?
    /// Injected by orchestrator — propagates cancellation to sub-agent
    weak var parentOrchestrator: SwiftAgentOrchestrator?

    init(agentConfig: [String: Any], providerConfig: [String: Any]) {
        let id = agentConfig["id"] as? String ?? UUID().uuidString
        self.name = "agent__\(String(id.prefix(8)))"
        self.agentDisplayName = agentConfig["name"] as? String ?? name
        self.agentConfig = agentConfig
        self.providerConfig = providerConfig
    }

    var definition: [String: Any] {
        [
            "name": name,
            "description": agentConfig["description"] as? String ?? "",
            "parameters": [
                "type": "object",
                "properties": [
                    "task": ["type": "string", "description": "需要该 Agent 完成的具体任务描述"],
                ],
                "required": ["task"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let task = params["task"] as? String ?? ""
        guard !task.isEmpty else { return "错误：未提供任务描述" }

        // Build provider (use agent's model or fallback to main)
        var cfg = providerConfig
        if let agentModel = agentConfig["model"] as? String, !agentModel.isEmpty {
            cfg["model"] = agentModel
        }
        guard let provider = try? ProviderFactory.build(config: cfg) else {
            return "错误：无法创建 Provider"
        }

        // 1. System tools — always inherited
        var tools: [ClawTool] = []
        for def in SwiftToolRegistry.shared.allDefinitions() {
            if let n = def["name"] as? String, let tool = SwiftToolRegistry.shared.get(n) {
                tools.append(tool)
            }
        }

        // 2. MCP/Composio tools — only those explicitly selected by user in agent config
        let selectedExtTools = Set(agentConfig["tools"] as? [String] ?? [])
        if !selectedExtTools.isEmpty {
            let mcpTools = MCPManager.shared.allTools()
            let authToken = providerConfig["auth_token"] as? String ?? ""
            let composioTools = ComposioClient.shared.allTools(authTokenGetter: { authToken })

            for tool in (mcpTools as [ClawTool]) + (composioTools as [ClawTool]) {
                // Match by exact name or keyword (e.g. "gmail" matches "mcp__gmail__xxx")
                if selectedExtTools.contains(tool.name) {
                    tools.append(tool)
                    continue
                }
                for keyword in selectedExtTools {
                    if tool.name.contains("__\(keyword)__") || tool.name.hasPrefix("\(keyword)__") {
                        tools.append(tool)
                        break
                    }
                }
            }
        }
        NSLog("[SubAgent \(agentDisplayName)] tools(\(tools.count)): \(tools.map { $0.name })")

        let maxSteps = agentConfig["max_steps"] as? Int ?? 10
        let systemPrompt = agentConfig["system_prompt"] as? String ?? ""

        let orchestrator = SwiftAgentOrchestrator(
            provider: provider,
            tools: tools,
            maxSteps: maxSteps
        )

        // Propagate cancellation from parent
        if let parent = parentOrchestrator, parent.isCancelled {
            return "任务已被用户停止"
        }

        var collected: [String] = []
        let parentEmit = self.parentEmit
        let displayName = self.agentDisplayName
        let parentOrch = self.parentOrchestrator

        let emit: ([String: Any]) async -> Void = { event in
            // Propagate parent cancellation to child orchestrator
            if let parent = parentOrch, parent.isCancelled {
                orchestrator.isCancelled = true
            }

            let t = event["type"] as? String ?? ""

            // Collect final text for tool result
            if t == "text_chunk" { collected.append(event["content"] as? String ?? "") }
            else if t == "error" { collected.append("[错误] \(event["message"] ?? "")") }

            // Forward events to frontend with agent prefix
            if let forward = parentEmit {
                var fwd = event
                fwd["agent"] = displayName
                switch t {
                case "thinking":
                    // Show agent's thinking as thinking event
                    fwd["type"] = "thinking"
                    fwd["content"] = "[\(displayName)] \(event["content"] as? String ?? "")"
                    await forward(fwd)
                case "tool_call":
                    // Show which tool the agent is calling
                    fwd["type"] = "tool_call"
                    await forward(fwd)
                case "tool_result":
                    // Show tool result
                    fwd["type"] = "tool_result"
                    await forward(fwd)
                default:
                    break // don't forward done/text_chunk (main orchestrator handles those)
                }
            }
        }

        await orchestrator.run(
            userMessage: task,
            history: [],
            system: systemPrompt,
            emit: emit
        )

        let result = collected.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? "Agent 执行完成，但未产生输出。" : result
    }
}

// MARK: - MCP Error

// MARK: - Notifications for tool status changes
extension Notification.Name {
    static let mcpToolStatusChanged = Notification.Name("mcpToolStatusChanged")
    static let composioToolAuthFailed = Notification.Name("composioToolAuthFailed")
}

enum MCPError: Error, LocalizedError {
    case invalidCommand
    case handshakeFailed
    case notRunning
    case eofReached
    case timeout
    case rpcError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCommand: return "MCP 命令为空"
        case .handshakeFailed: return "MCP 握手失败"
        case .notRunning: return "MCP 服务器未运行"
        case .eofReached: return "MCP 服务器进程已退出"
        case .timeout: return "MCP RPC 超时"
        case .rpcError(let msg): return "MCP RPC 错误: \(msg)"
        }
    }
}
