import Foundation

struct Skill: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let systemPrompt: String
    let tools: [String]
    let builtin: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, icon, tools, builtin
        case systemPrompt = "system_prompt"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "⚡"
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        builtin = try c.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
    }
}

struct MarketSkill: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let tools: [String]
    let author: String
    let tags: [String]
    let category: String
    let repoUrl: String
    let examplePrompts: [String]
    let version: String
    let downloads: Int
    let installed: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, description, icon, tools, author, tags, category, version, downloads, installed
        case repoUrl = "repo_url"
        case examplePrompts = "example_prompts"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.decode(String.self, forKey: .description)
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? "⚡"
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        repoUrl = try c.decodeIfPresent(String.self, forKey: .repoUrl) ?? ""
        examplePrompts = try c.decodeIfPresent([String].self, forKey: .examplePrompts) ?? []
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "1.0.0"
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
    }
}

struct ClawHubSkill: Identifiable, Codable {
    var id: String { slug }
    let slug: String
    let displayName: String
    let summary: String
    let downloads: Int
    let stars: Int
    let ownerHandle: String
    let createdAt: String
    let updatedAt: String
    let isCertified: Bool
    let isDeleted: Bool
    let clawhubUrl: String
    var installed: Bool

    enum CodingKeys: String, CodingKey {
        case slug, summary, downloads, stars, installed
        case displayName = "display_name"
        case ownerHandle = "owner_handle"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isCertified = "is_certified"
        case isDeleted = "is_deleted"
        case clawhubUrl = "clawhub_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        stars = try c.decodeIfPresent(Int.self, forKey: .stars) ?? 0
        ownerHandle = try c.decodeIfPresent(String.self, forKey: .ownerHandle) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        isCertified = try c.decodeIfPresent(Bool.self, forKey: .isCertified) ?? false
        isDeleted = try c.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
        clawhubUrl = try c.decodeIfPresent(String.self, forKey: .clawhubUrl) ?? ""
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
    }
}

struct SkillProposal: Identifiable, Codable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let systemPrompt: String
    let tools: [String]
    let snippet: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, description, icon, tools, snippet
        case systemPrompt = "system_prompt"
        case createdAt = "created_at"
    }
}

struct DiaryEntry: Identifiable, Codable {
    let id: String
    let date: String
    let weather: String
    let mood: String
    let content: String
    let generatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, date, weather, mood, content
        case generatedAt = "generated_at"
    }

    var formattedDate: String {
        // "2026-03-03" → "03月03日"
        let parts = date.split(separator: "-")
        guard parts.count == 3 else { return date }
        return "\(parts[1])月\(parts[2])日"
    }
}

struct DiaryResponse: Codable {
    let entry: DiaryEntry?
}

struct MemoryItem: Identifiable, Codable {
    let id: String
    let text: String
    let tier: String
    let memoryType: String
    let createdAt: String
    let lastHit: String
    let hitCount: Int
    let weight: Double

    enum CodingKeys: String, CodingKey {
        case id, text, tier, weight
        case memoryType = "type"
        case createdAt = "created_at"
        case lastHit = "last_hit"
        case hitCount = "hit_count"
    }
}

struct ProjectFolder: Identifiable, Codable {
    let name: String
    let fileCount: Int
    let modifiedAt: String
    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case fileCount = "file_count"
        case modifiedAt = "modified_at"
    }
}

struct ProjectFile: Identifiable, Codable {
    let name: String
    let path: String
    let size: Int
    let ext: String
    let modifiedAt: String
    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name, path, size, ext
        case modifiedAt = "modified_at"
    }
}

// MARK: - Agent Worker

struct AgentWorker: Identifiable, Codable, Hashable {
    static func == (lhs: AgentWorker, rhs: AgentWorker) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    let id: String
    var name: String
    var icon: String
    var description: String
    var systemPrompt: String
    var tools: [String]
    var model: String
    var maxSteps: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, icon, description, tools, model
        case systemPrompt = "system_prompt"
        case maxSteps = "max_steps"
        case createdAt = "created_at"
    }

    init(id: String, name: String, icon: String, description: String, systemPrompt: String = "", tools: [String] = [], model: String = "", maxSteps: Int = 10, createdAt: String = "") {
        self.id = id; self.name = name; self.icon = icon; self.description = description
        self.systemPrompt = systemPrompt; self.tools = tools; self.model = model
        self.maxSteps = maxSteps; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        icon = try c.decodeIfPresent(String.self, forKey: .icon) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? ""
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        maxSteps = try c.decodeIfPresent(Int.self, forKey: .maxSteps) ?? 10
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
    }

}

struct ToolItem: Identifiable, Codable {
    var id: String { server.map { "\($0)__\(name)" } ?? name }
    let name: String
    let description: String
    let type: String      // "api" | "mcp"
    let server: String?   // MCP 工具所属服务器名，内置工具为 nil
    let removable: Bool

    var typeLabel: String { type.uppercased() }  // "API" | "MCP"
}

struct MCPServer: Identifiable, Codable {
    var id: String { name }
    let name: String
    let command: [String]
    let toolCount: Int
    let status: String
    let error: String?

    enum CodingKeys: String, CodingKey {
        case name, command, status, error
        case toolCount = "tool_count"
    }

    var isConnected: Bool { status == "connected" }
}

// MARK: - Watchlist

struct WatchItem: Identifiable, Codable {
    let id: String
    let query: String
    var enabled: Bool
    let intervalMinutes: Int
    let createdAt: String
    let lastCheckedAt: String?
    let lastResult: String?
    let notifyCount: Int
    let type: String
    let schedule: String?
    let taskPrompt: String?
    let summary: String?

    enum CodingKeys: String, CodingKey {
        case id, query, enabled, type, schedule, summary
        case intervalMinutes = "interval_minutes"
        case createdAt = "created_at"
        case lastCheckedAt = "last_checked_at"
        case lastResult = "last_result"
        case notifyCount = "notify_count"
        case taskPrompt = "task_prompt"
    }

    init(id: String, query: String, enabled: Bool = true, intervalMinutes: Int = 30,
         createdAt: String = "", lastCheckedAt: String? = nil, lastResult: String? = nil,
         notifyCount: Int = 0, type: String = "poll", schedule: String? = nil,
         taskPrompt: String? = nil, summary: String? = nil) {
        self.id = id; self.query = query; self.enabled = enabled
        self.intervalMinutes = intervalMinutes; self.createdAt = createdAt
        self.lastCheckedAt = lastCheckedAt; self.lastResult = lastResult
        self.notifyCount = notifyCount; self.type = type; self.schedule = schedule
        self.taskPrompt = taskPrompt; self.summary = summary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        query = try c.decode(String.self, forKey: .query)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 30
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        lastCheckedAt = try c.decodeIfPresent(String.self, forKey: .lastCheckedAt)
        lastResult = try c.decodeIfPresent(String.self, forKey: .lastResult)
        notifyCount = try c.decodeIfPresent(Int.self, forKey: .notifyCount) ?? 0
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "poll"
        schedule = try c.decodeIfPresent(String.self, forKey: .schedule)
        taskPrompt = try c.decodeIfPresent(String.self, forKey: .taskPrompt)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
    }

    /// 显示名称：优先 summary，fallback 到 query
    var displayName: String { summary ?? query }

    /// 频率标签
    var frequencyLabel: String {
        if type == "cron", let s = schedule, !s.isEmpty {
            return L.scheduledTask + " " + s
        }
        return L.minutesInterval(intervalMinutes)
    }

}

struct WatchlistConfig: Codable {
    var smtpHost: String
    var smtpPort: Int
    var smtpUser: String
    var smtpPass: String
    var notifyEmail: String
    var enabled: Bool

    enum CodingKeys: String, CodingKey {
        case enabled
        case smtpHost = "smtp_host"
        case smtpPort = "smtp_port"
        case smtpUser = "smtp_user"
        case smtpPass = "smtp_pass"
        case notifyEmail = "notify_email"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        smtpHost = try c.decodeIfPresent(String.self, forKey: .smtpHost) ?? ""
        smtpPort = try c.decodeIfPresent(Int.self, forKey: .smtpPort) ?? 465
        smtpUser = try c.decodeIfPresent(String.self, forKey: .smtpUser) ?? ""
        smtpPass = try c.decodeIfPresent(String.self, forKey: .smtpPass) ?? ""
        notifyEmail = try c.decodeIfPresent(String.self, forKey: .notifyEmail) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    static var empty: WatchlistConfig {
        WatchlistConfig(smtpHost: "", smtpPort: 465, smtpUser: "", smtpPass: "", notifyEmail: "", enabled: false)
    }

    init(smtpHost: String, smtpPort: Int, smtpUser: String, smtpPass: String, notifyEmail: String, enabled: Bool) {
        self.smtpHost = smtpHost
        self.smtpPort = smtpPort
        self.smtpUser = smtpUser
        self.smtpPass = smtpPass
        self.notifyEmail = notifyEmail
        self.enabled = enabled
    }
}

// MARK: - Composio

struct ComposioToolkitCategory: Codable, Identifiable {
    let id: String
    let name: String
}

struct ComposioToolkit: Identifiable, Codable {
    var id: String { slug }
    let slug: String
    let name: String
    let description: String
    let logo: String
    let categories: [ComposioToolkitCategory]
    let authSchemes: [String]
    let toolsCount: Int
    let triggersCount: Int
    let noAuth: Bool

    enum CodingKeys: String, CodingKey {
        case slug, name, description, logo, categories
        case authSchemes = "auth_schemes"
        case toolsCount = "tools_count"
        case triggersCount = "triggers_count"
        case noAuth = "no_auth"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug          = try c.decode(String.self, forKey: .slug)
        name          = try c.decode(String.self, forKey: .name)
        description   = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        logo          = try c.decodeIfPresent(String.self, forKey: .logo) ?? ""
        categories    = try c.decodeIfPresent([ComposioToolkitCategory].self, forKey: .categories) ?? []
        authSchemes   = try c.decodeIfPresent([String].self, forKey: .authSchemes) ?? []
        toolsCount    = try c.decodeIfPresent(Int.self, forKey: .toolsCount) ?? 0
        triggersCount = try c.decodeIfPresent(Int.self, forKey: .triggersCount) ?? 0
        noAuth        = try c.decodeIfPresent(Bool.self, forKey: .noAuth) ?? false
    }

    var categoryName: String {
        categories.first?.name ?? "Other"
    }

    /// Whether this toolkit truly requires user authorization.
    /// Uses authSchemes as the source of truth instead of noAuth flag.
    var requiresAuth: Bool {
        if authSchemes.isEmpty { return false }
        let dominated = authSchemes.map { $0.uppercased() }
        if dominated == ["NONE"] || dominated == ["NO_AUTH"] { return false }
        return true
    }
}

struct ComposioToolkitListResponse: Codable {
    let items: [ComposioToolkit]
    let totalItems: Int
    let currentPage: Int
    let totalPages: Int
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case totalItems = "total_items"
        case currentPage = "current_page"
        case totalPages = "total_pages"
        case nextCursor = "next_cursor"
    }
}

struct ComposioConnection: Identifiable, Codable {
    let id: String
    let toolkitSlug: String
    let toolkitName: String
    let toolkitLogo: String
    let status: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case toolkitSlug = "toolkit_slug"
        case toolkitName = "toolkit_name"
        case toolkitLogo = "toolkit_logo"
        case createdAt = "created_at"
    }

    var isActive: Bool { status == "ACTIVE" }
}

struct ComposioConnectionListResponse: Codable {
    let connections: [ComposioConnection]
}

struct ComposioConnectResponse: Codable {
    let authUrl: String?
    let connectionId: String?

    enum CodingKeys: String, CodingKey {
        case authUrl = "redirect_url"
        case connectionId = "id"
    }
}

struct MCPPreset: Identifiable, Codable {
    var id: String { name }
    let name: String
    let displayName: String
    let description: String
    let icon: String
    let type: String
    let command: [String]
    let installed: Bool
    let author: String
    let repoUrl: String
    let requiresKey: Bool
    let envKey: String
    let keyUrl: String
    let category: String

    var typeLabel: String { type.uppercased() }

    enum CodingKeys: String, CodingKey {
        case name, description, icon, type, command, installed, author, category
        case displayName = "display_name"
        case repoUrl = "repo_url"
        case requiresKey = "requires_key"
        case envKey = "env_key"
        case keyUrl = "key_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name        = try c.decode(String.self, forKey: .name)
        displayName = try c.decode(String.self, forKey: .displayName)
        description = try c.decode(String.self, forKey: .description)
        icon        = try c.decodeIfPresent(String.self, forKey: .icon) ?? "🔧"
        type        = try c.decodeIfPresent(String.self, forKey: .type) ?? "mcp"
        command     = try c.decode([String].self, forKey: .command)
        installed   = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        author      = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
        repoUrl     = try c.decodeIfPresent(String.self, forKey: .repoUrl) ?? ""
        requiresKey = try c.decodeIfPresent(Bool.self, forKey: .requiresKey) ?? false
        envKey      = try c.decodeIfPresent(String.self, forKey: .envKey) ?? ""
        keyUrl      = try c.decodeIfPresent(String.self, forKey: .keyUrl) ?? ""
        category    = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
    }
}
