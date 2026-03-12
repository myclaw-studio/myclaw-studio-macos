import Foundation
import SwiftUI
import Combine

extension Notification.Name {
    static let chatDidComplete = Notification.Name("chatDidComplete")
}

@MainActor
class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var errorMsg: String?
    @Published var backendOnline = false
    @Published var proposals: [SkillProposal] = [] // deprecated, kept for compile
    @Published var isSummarizing = false

    private let backend = BackendService()
    private var streamingTask: Task<Void, Never>?
    private let historyURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aichat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat_history.json")
    }()

    init() {
        loadHistory()
        Task { await checkBackend() }
        Task { await refreshProposals() }
    }

    // MARK: - 持久化

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let saved = try? JSONDecoder().decode([Message].self, from: data),
              !saved.isEmpty
        else {
            showGreeting()
            return
        }
        messages = saved
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }

    // MARK: - 对话

    private func showGreeting() {
        messages = [Message(
            content: L.greeting,
            role: .assistant
        )]
        saveHistory()
    }

    func send(_ text: String, imageData: Data? = nil, attachmentPath: String? = nil, attachmentName: String? = nil) {
        streamingTask = Task {
            await _send(text, imageData: imageData, attachmentPath: attachmentPath, attachmentName: attachmentName)
        }
    }

    func stopStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
        if isLoading {
            let idx = messages.count - 1
            if idx >= 0 && messages[idx].role == .assistant {
                if messages[idx].content.isEmpty {
                    messages[idx].content = L.stopped
                }
            }
            isLoading = false
            saveHistory()
        }
    }

    private func _send(_ text: String, imageData: Data? = nil, attachmentPath: String? = nil, attachmentName: String? = nil) async {
        errorMsg = nil

        var userMsg = Message(content: text, role: .user, imageData: imageData,
                              attachmentPath: attachmentPath, attachmentName: attachmentName)

        // 图片/PDF 持久化到磁盘
        if let imgData = imageData {
            let imagesDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".aichat/images")
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            let ext = isPDF(imgData) ? "pdf" : "jpg"
            let filePath = imagesDir.appendingPathComponent("\(userMsg.id.uuidString).\(ext)")
            try? imgData.write(to: filePath)
            userMsg.imagePath = filePath.path
        }

        // 构建发送给大模型的实际消息文本（所有附件都带路径）
        var messageText = text
        if let imgPath = userMsg.imagePath {
            let name = attachmentName ?? (isPDF(imageData!) ? "文档.pdf" : "图片.jpg")
            messageText = "\(text)\n\n[📎 \(name)]\nFile path: \(imgPath)"
        } else if let path = attachmentPath, let name = attachmentName {
            messageText = "\(text)\n\n[📎 \(name)]\nFile path: \(path)"
        }

        messages.append(userMsg)

        let assistantMsg = Message(content: "", role: .assistant)
        messages.append(assistantMsg)
        let idx = messages.count - 1

        isLoading = true
        defer {
            isLoading = false
            saveHistory()
        }

        let history = buildHistory(excluding: 2)

        // 当前消息带图片/PDF → 构建 base64 数组
        let images: [String]? = imageData.map { [($0 as Data).base64EncodedString()] }
        let isPdf = imageData.map { isPDF($0) } ?? false

        do {
            try await backend.streamChat(
                message: messageText,
                history: history,
                images: images,
                isPdf: isPdf,
                onEvent: { [weak self] event in
                    Task { @MainActor [weak self] in
                        self?.handle(event: event, at: idx)
                    }
                }
            )
        } catch {
            if !Task.isCancelled {
                messages[idx].content = "⚠️ \(error.localizedDescription)"
            }
        }

        // 聊天完成后通知刷新余额
        NotificationCenter.default.post(name: .chatDidComplete, object: nil)

        await refreshProposals()
    }

    private func isPDF(_ data: Data) -> Bool {
        data.prefix(5).elementsEqual([0x25, 0x50, 0x44, 0x46, 0x2D]) // %PDF-
    }

    func refreshProposals() async {}
    func acceptProposal(_ proposal: SkillProposal) {}
    func dismissProposal(_ proposal: SkillProposal) {}

    private func handle(event: BackendEvent, at idx: Int) {
        guard idx < messages.count else { return }
        switch event {
        case .textChunk(let chunk):
            messages[idx].content += chunk
        case .thinking(let text):
            messages[idx].thinkingSteps.append(text)
            messages[idx].processItems.append(.thinking(text))
        case .toolCall(let tool, let args, let agent):
            let displayTool = agent != nil ? "[\(agent!)] \(tool)" : tool
            let event = Message.ToolEvent(type: .call, tool: displayTool, detail: args)
            messages[idx].toolEvents.append(event)
            messages[idx].processItems.append(.tool(event))
        case .toolResult(let tool, let result, let agent):
            let displayTool = agent != nil ? "[\(agent!)] \(tool)" : tool
            let event = Message.ToolEvent(type: .result, tool: displayTool, detail: result)
            messages[idx].toolEvents.append(event)
            messages[idx].processItems.append(.tool(event))
        case .done:
            break
        case .error(let msg):
            let errorText = msg.isEmpty ? L.networkError : "⚠️ \(msg)"
            if messages[idx].content.isEmpty {
                messages[idx].content = errorText
            } else {
                messages[idx].content += "\n\n\(errorText)"
            }
        }
    }

    private func buildHistory(excluding last: Int) -> [[String: Any]] {
        let relevant = messages.dropLast(last)
        return relevant.compactMap { msg in
            guard !msg.content.isEmpty else { return nil }
            var content = msg.content
            // 带图片的历史消息：标注"发过图片"并附路径，不重复传 base64
            if let path = msg.imagePath {
                content += "\n[用户在此消息中发送了一张图片，本地路径: \(path)]"
            } else if msg.imageData != nil {
                content += "\n[用户在此消息中发送了一张图片]"
            }
            // 带文件附件的历史消息：附上路径
            if let path = msg.attachmentPath, let name = msg.attachmentName {
                content += "\n\n[📎 \(name)]\nFile path: \(path)"
            }
            return ["role": msg.role.rawValue, "content": content]
        }
    }

    func deleteMessage(_ id: UUID) {
        if isLoading, let last = messages.last, last.id == id { return }
        if let msg = messages.first(where: { $0.id == id }), let path = msg.imagePath {
            try? FileManager.default.removeItem(atPath: path)
        }
        messages.removeAll { $0.id == id }
        messages.isEmpty ? showGreeting() : saveHistory()
    }

    func summarizeAndCompact() {
        guard messages.count > 6, !isSummarizing, !isLoading else { return }
        isSummarizing = true
        Task {
            defer { isSummarizing = false }
            let keepLast = 5
            let toSummarize = messages.dropLast(keepLast)
            let payload: [[String: String]] = toSummarize.map {
                ["role": $0.role.rawValue, "content": $0.content]
            }
            guard let summary = try? await backend.summarizeChat(messages: payload, keepLast: keepLast) else { return }
            // 清理被删除消息中的图片
            for msg in toSummarize {
                if let path = msg.imagePath {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            let summaryMsg = Message(content: "📋 对话摘要\n\n\(summary)", role: .assistant)
            let kept = Array(messages.suffix(keepLast))
            messages = [summaryMsg] + kept
            saveHistory()
        }
    }

    func clearChat() {
        showGreeting()
    }

    func checkBackend() async {
        backendOnline = await backend.healthCheck()
    }
}
