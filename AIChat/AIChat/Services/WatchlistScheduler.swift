import Foundation
import UserNotifications

// MARK: - Watchlist Scheduler
// Executes watchlist items: poll (heartbeat) and cron (scheduled) tasks.
// Poll tasks run when poll_enabled is on, at their interval_minutes cadence.
// Cron tasks always run based on their schedule expression.

final class WatchlistScheduler: @unchecked Sendable {
    static let shared = WatchlistScheduler()

    private let aichatDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".aichat")
    private var watchlistFileURL: URL { aichatDir.appendingPathComponent("watchlist.json") }
    private var watchlistConfigURL: URL { aichatDir.appendingPathComponent("watchlist_config.json") }
    private var watchlistLogsURL: URL { aichatDir.appendingPathComponent("watchlist_logs.json") }

    private var cronTimer: Timer?
    private var pollTimer: Timer?
    private let queue = DispatchQueue(label: "watchlist.scheduler", qos: .utility)
    private var isRunning = false

    private init() {}

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        isRunning = true
        print("[WatchlistScheduler] Starting...")

        // Cron timer: check every 60s for due cron tasks
        DispatchQueue.main.async {
            self.cronTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.tickCron()
            }
        }

        // Poll timer: check every 60s, only execute if poll_enabled
        DispatchQueue.main.async {
            self.pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                self?.tickPoll()
            }
        }
    }

    func stop() {
        isRunning = false
        cronTimer?.invalidate()
        cronTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        print("[WatchlistScheduler] Stopped.")
    }

    // MARK: - Cron Tick

    private func tickCron() {
        queue.async { [weak self] in
            guard let self else { return }
            let items = self.loadItems()
            let now = Date()

            for item in items {
                guard let type = item["type"] as? String, type == "cron",
                      let enabled = item["enabled"] as? Bool, enabled,
                      let schedule = item["schedule"] as? String, !schedule.isEmpty,
                      let id = item["id"] as? String else { continue }

                if self.cronIsDue(schedule: schedule, lastChecked: item["last_checked_at"], now: now) {
                    let prompt = item["task_prompt"] as? String ?? item["query"] as? String ?? ""
                    guard !prompt.isEmpty else { continue }
                    print("[WatchlistScheduler] Cron task due: \(id)")
                    self.executeTask(id: id, prompt: prompt)
                }
            }
        }
    }

    // MARK: - Poll Tick

    private func tickPoll() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isPollEnabled() else { return }

            let items = self.loadItems()
            let now = Date()

            for item in items {
                guard let type = item["type"] as? String, type == "poll",
                      let enabled = item["enabled"] as? Bool, enabled,
                      let id = item["id"] as? String else { continue }

                let interval = item["interval_minutes"] as? Int ?? 30
                if self.pollIsDue(intervalMinutes: interval, lastChecked: item["last_checked_at"], now: now) {
                    let prompt = item["task_prompt"] as? String ?? item["query"] as? String ?? ""
                    guard !prompt.isEmpty else { continue }
                    print("[WatchlistScheduler] Poll task due: \(id)")
                    self.executeTask(id: id, prompt: prompt)
                }
            }
        }
    }

    // MARK: - Execute Task (via Clawbie)

    private func executeTask(id: String, prompt: String) {
        Task {
            let config = AppConfig.configPayload()
            guard let provider = try? ProviderFactory.build(config: config) else {
                print("[WatchlistScheduler] No provider available, skipping task \(id)")
                return
            }

            // Build full Clawbie context: system prompt + tools + memory
            let memoryContext = SwiftMemoryManager.shared.buildContext(query: prompt)
            let skills = self.loadAllSkills()
            let agents = self.loadAgents()
            var system = SystemPromptBuilder.build(
                memoryContext: memoryContext,
                skillPrompt: "",
                skills: skills,
                agents: agents
            )

            // 追加定时任务专用指令：不许提问，必须自主完成
            system += """


            # 当前执行模式：定时任务（最高优先级）
            你正在执行一个用户预设的定时任务，这是后台自动触发的，用户不在线，无法回答你的问题。
            严格遵守以下规则：
            1. 禁止反问用户、禁止说"请告诉我"、"您希望"等等待输入的话
            2. 必须根据已有信息（记忆、工具）自主完成任务，一口气跑完
            3. 如果缺少信息（如邮箱地址），从记忆中查找，或用工具获取，实在找不到就跳过该步骤并说明原因
            4. 直接输出任务执行结果，简洁明了
            """

            // Gather all tools: system + MCP + Composio
            var allTools: [ClawTool] = []
            let swiftTools = SwiftToolRegistry.shared
            for def in swiftTools.allDefinitions() {
                if let name = def["name"] as? String, let tool = swiftTools.get(name) {
                    allTools.append(tool)
                }
            }
            allTools.append(contentsOf: MCPManager.shared.allTools())
            let authToken = config["auth_token"] as? String ?? ""
            allTools.append(contentsOf: ComposioClient.shared.allTools(authTokenGetter: { authToken }))
            for agent in agents {
                allTools.append(SubAgentTool(agentConfig: agent, providerConfig: config))
            }

            // Run Clawbie orchestrator
            let orchestrator = SwiftAgentOrchestrator(
                provider: provider,
                tools: allTools,
                maxSteps: 15
            )

            var capturedReply = ""
            let emit: ([String: Any]) async -> Void = { event in
                let eventType = event["type"] as? String ?? ""
                if eventType == "text_chunk" {
                    capturedReply += event["content"] as? String ?? ""
                }
                // Watchlist tasks run silently — no WebSocket output
            }

            await orchestrator.run(
                userMessage: prompt,
                history: [],
                system: system,
                emit: emit
            )

            let result = capturedReply.isEmpty ? "(task completed with no text output)" : capturedReply
            self.updateItemAfterExecution(id: id, result: result)
            self.appendLog(id: id, result: result, status: "success")
            self.sendNotification(id: id, result: result)
            print("[WatchlistScheduler] Task \(id) completed via Clawbie.")
        }
    }

    // MARK: - Data Helpers for Clawbie context

    private func loadAllSkills() -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let url = Bundle.main.url(forResource: "builtin_skills", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            result.append(contentsOf: arr)
        }
        let userFile = aichatDir.appendingPathComponent("skills.json")
        if let data = try? Data(contentsOf: userFile),
           let skills = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            result.append(contentsOf: skills)
        }
        return result
    }

    private func loadAgents() -> [[String: Any]] {
        let file = aichatDir.appendingPathComponent("agents.json")
        guard let data = try? Data(contentsOf: file),
              let agents = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return agents
    }

    // MARK: - Cron Parsing

    /// Simple cron expression check: "min hour dom month dow"
    /// Returns true if the cron schedule matches current time and hasn't run this minute.
    private func cronIsDue(schedule: String, lastChecked: Any?, now: Date) -> Bool {
        let parts = schedule.split(separator: " ").map(String.init)
        guard parts.count >= 5 else { return false }

        let cal = Calendar.current
        let minute = cal.component(.minute, from: now)
        let hour = cal.component(.hour, from: now)
        let day = cal.component(.day, from: now)
        let month = cal.component(.month, from: now)
        let weekday = (cal.component(.weekday, from: now) + 5) % 7 // Convert to 0=Mon..6=Sun

        guard cronFieldMatches(parts[0], value: minute) else { return false }
        guard cronFieldMatches(parts[1], value: hour) else { return false }
        guard cronFieldMatches(parts[2], value: day) else { return false }
        guard cronFieldMatches(parts[3], value: month) else { return false }
        guard cronFieldMatches(parts[4], value: weekday) else { return false }

        // Don't re-run if already ran this minute
        if let lastStr = lastChecked as? String, !lastStr.isEmpty {
            if let lastDate = parseISO8601(lastStr) {
                let diff = now.timeIntervalSince(lastDate)
                if diff < 60 { return false }
            }
        }

        return true
    }

    /// Match a single cron field: "*", "5", "*/10", "1,15", "1-5"
    private func cronFieldMatches(_ field: String, value: Int) -> Bool {
        if field == "*" { return true }

        // Handle step: */N
        if field.hasPrefix("*/"), let step = Int(field.dropFirst(2)), step > 0 {
            return value % step == 0
        }

        // Handle comma-separated: 1,5,10
        if field.contains(",") {
            let values = field.split(separator: ",").compactMap { Int($0) }
            return values.contains(value)
        }

        // Handle range: 1-5
        if field.contains("-") {
            let rangeParts = field.split(separator: "-").compactMap { Int($0) }
            if rangeParts.count == 2 {
                return value >= rangeParts[0] && value <= rangeParts[1]
            }
        }

        // Exact match
        if let exact = Int(field) {
            return value == exact
        }

        return false
    }

    // MARK: - Poll Check

    private func pollIsDue(intervalMinutes: Int, lastChecked: Any?, now: Date) -> Bool {
        guard intervalMinutes > 0 else { return false }

        if let lastStr = lastChecked as? String, !lastStr.isEmpty,
           let lastDate = parseISO8601(lastStr) {
            let elapsed = now.timeIntervalSince(lastDate)
            return elapsed >= Double(intervalMinutes * 60)
        }
        // Never checked before — due immediately
        return true
    }

    // MARK: - Data Persistence

    private func loadItems() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: watchlistFileURL),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items
    }

    private func saveItems(_ items: [[String: Any]]) {
        if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted]) {
            try? data.write(to: watchlistFileURL)
        }
    }

    private func updateItemAfterExecution(id: String, result: String) {
        var items = loadItems()
        guard let idx = items.firstIndex(where: { ($0["id"] as? String) == id }) else { return }
        items[idx]["last_checked_at"] = ISO8601DateFormatter().string(from: Date())
        items[idx]["last_result"] = result
        let count = items[idx]["notify_count"] as? Int ?? 0
        items[idx]["notify_count"] = count + 1
        saveItems(items)
    }

    private func appendLog(id: String, result: String, status: String) {
        var allLogs: [String: Any] = [:]
        if let data = try? Data(contentsOf: watchlistLogsURL),
           let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            allLogs = saved
        }

        var logs = allLogs[id] as? [[String: Any]] ?? []
        logs.append([
            "time": ISO8601DateFormatter().string(from: Date()),
            "status": status,
            "result": String(result.prefix(500))
        ])
        // Keep last 50 logs per item
        if logs.count > 50 { logs = Array(logs.suffix(50)) }
        allLogs[id] = logs

        if let data = try? JSONSerialization.data(withJSONObject: allLogs, options: [.prettyPrinted]) {
            try? data.write(to: watchlistLogsURL)
        }
    }

    private func isPollEnabled() -> Bool {
        guard let data = try? Data(contentsOf: watchlistConfigURL),
              let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return cfg["poll_enabled"] as? Bool ?? false
    }

    // MARK: - Notification

    private func sendNotification(id: String, result: String) {
        let content = UNMutableNotificationContent()
        content.title = "Clawbie Watchlist"
        content.body = String(result.prefix(200))
        content.sound = .default
        let request = UNNotificationRequest(identifier: "watchlist-\(id)-\(Date().timeIntervalSince1970)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Helpers

    private func parseISO8601(_ str: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: str) { return d }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: str) { return d }
        // Fallback: try basic format without timezone
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df.date(from: str)
    }
}
