import Foundation

struct Message: Identifiable, Codable, Equatable {
    let id: UUID
    var content: String
    let role: Role
    let timestamp: Date
    var toolEvents: [ToolEvent]
    var thinkingSteps: [String]
    var processItems: [ProcessItem]

    /// 图片数据（仅内存中持有，不持久化到 JSON）
    var imageData: Data?

    /// 图片磁盘路径（持久化到 JSON）
    var imagePath: String?

    /// 附件文件路径（非图片文件，持久化到 JSON）
    var attachmentPath: String?

    /// 附件文件名（用于 UI 显示）
    var attachmentName: String?

    /// 优先用内存 imageData，否则从 imagePath 读磁盘
    var resolvedImageData: Data? {
        if let imageData { return imageData }
        guard let imagePath else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: imagePath))
    }

    enum Role: String, Codable {
        case user
        case assistant
    }

    struct ToolEvent: Identifiable, Codable, Equatable {
        let id: UUID
        let type: EventType
        let tool: String
        var detail: String

        enum EventType: String, Codable {
            case call
            case result
        }

        init(id: UUID = UUID(), type: EventType, tool: String, detail: String) {
            self.id = id
            self.type = type
            self.tool = tool
            self.detail = detail
        }
    }

    enum ProcessItem: Identifiable, Codable, Equatable {
        case thinking(String)
        case tool(ToolEvent)

        var id: String {
            switch self {
            case .thinking(let text): return "t_\(text.hashValue)"
            case .tool(let event): return event.id.uuidString
            }
        }
    }

    // 自定义 CodingKeys：不包含 imageData，避免持久化大图片
    enum CodingKeys: String, CodingKey {
        case id, content, role, timestamp, toolEvents, thinkingSteps, processItems, imagePath, attachmentPath, attachmentName
    }

    init(
        id: UUID = UUID(),
        content: String,
        role: Role,
        timestamp: Date = Date(),
        toolEvents: [ToolEvent] = [],
        thinkingSteps: [String] = [],
        processItems: [ProcessItem] = [],
        imageData: Data? = nil,
        imagePath: String? = nil,
        attachmentPath: String? = nil,
        attachmentName: String? = nil
    ) {
        self.id = id
        self.content = content
        self.role = role
        self.timestamp = timestamp
        self.toolEvents = toolEvents
        self.thinkingSteps = thinkingSteps
        self.processItems = processItems
        self.imageData = imageData
        self.imagePath = imagePath
        self.attachmentPath = attachmentPath
        self.attachmentName = attachmentName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        role = try c.decode(Role.self, forKey: .role)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        toolEvents = try c.decode([ToolEvent].self, forKey: .toolEvents)
        thinkingSteps = try c.decode([String].self, forKey: .thinkingSteps)
        // 兼容旧数据：如果没有 processItems，从 thinkingSteps + toolEvents 构建
        if let items = try? c.decode([ProcessItem].self, forKey: .processItems) {
            processItems = items
        } else {
            var items: [ProcessItem] = thinkingSteps.map { .thinking($0) }
            items += toolEvents.map { .tool($0) }
            processItems = items
        }
        imageData = nil
        imagePath = try c.decodeIfPresent(String.self, forKey: .imagePath)
        attachmentPath = try c.decodeIfPresent(String.self, forKey: .attachmentPath)
        attachmentName = try c.decodeIfPresent(String.self, forKey: .attachmentName)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(content, forKey: .content)
        try c.encode(role, forKey: .role)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(toolEvents, forKey: .toolEvents)
        try c.encode(thinkingSteps, forKey: .thinkingSteps)
        try c.encode(processItems, forKey: .processItems)
        try c.encodeIfPresent(imagePath, forKey: .imagePath)
        try c.encodeIfPresent(attachmentPath, forKey: .attachmentPath)
        try c.encodeIfPresent(attachmentName, forKey: .attachmentName)
        // imageData 不编码
    }

    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id && lhs.content == rhs.content && lhs.role == rhs.role
        && lhs.toolEvents == rhs.toolEvents && lhs.thinkingSteps == rhs.thinkingSteps
        && lhs.processItems == rhs.processItems
    }
}
