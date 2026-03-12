import SwiftUI

struct MessageBubble: View {
    let message: Message
    var isStreaming: Bool = false
    var onDelete: (() -> Void)? = nil

    private var isUser: Bool { message.role == .user }
    private var hasProcess: Bool { !message.processItems.isEmpty }
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isUser { Spacer(minLength: 60) }

            // AI 头像
            if !isUser {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            }

            // 气泡内容
            VStack(alignment: .leading, spacing: 0) {
                // 处理过程（推理 + 工具调用，按出现顺序）
                if hasProcess {
                    ProcessView(items: message.processItems)
                        .padding(.bottom, message.content.isEmpty && !isStreaming ? 0 : 6)
                }

                // 用户消息中的图片
                if isUser, let imgData = message.resolvedImageData,
                   let nsImg = NSImage(data: imgData) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // 用户消息中的文件附件
                if isUser, let fileName = message.attachmentName {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .foregroundStyle(Color.clawAccent)
                        Text(fileName)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.clawAccent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 4)
                }

                // 文本内容
                if isStreaming && message.content.isEmpty {
                    TypingDots()
                } else if !message.content.isEmpty {
                    Text(message.content)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isUser ? Color.clawUserBubble : Color.clawAIBubble)
            .foregroundStyle(isUser ? .white : .primary)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(isUser ? 0.08 : 0.06), radius: 4, y: 2)
            .overlay(alignment: isUser ? .topTrailing : .topLeading) {
                if isHovered, let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .gray.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: isUser ? 6 : -6, y: -6)
                    .transition(.opacity)
                }
            }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - 处理过程（推理 + 工具合并）

struct ProcessView: View {
    let items: [Message.ProcessItem]
    @State private var expanded = false

    private var thinkingCount: Int { items.filter { if case .thinking = $0 { return true }; return false }.count }
    private var toolCallCount: Int { items.filter { if case .tool(let e) = $0 { return e.type == .call }; return false }.count }

    private var summary: String {
        var parts: [String] = []
        if thinkingCount > 0 { parts.append(L.reasoningSteps(thinkingCount)) }
        if toolCallCount > 0 { parts.append(L.toolCalls(toolCallCount)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.2")
                        .font(.caption2)
                        .foregroundStyle(Color.clawAccent)
                    Text(summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        switch item {
                        case .thinking(let text):
                            ThinkingRow(text: text)
                        case .tool(let event):
                            ToolEventRow(event: event)
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(8)
        .background(Color.clawAccentLight.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 推理行

private struct ThinkingRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "brain")
                .font(.caption2)
                .foregroundStyle(Color.clawAccent)
                .frame(width: 14)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 工具调用行

struct ToolEventRow: View {
    let event: Message.ToolEvent
    @State private var showDetail = false

    private var isError: Bool {
        event.type == .result && (
            event.detail.hasPrefix("工具执行失败") ||
            event.detail.hasPrefix("未知工具") ||
            event.detail.hasPrefix("⚠️")
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: event.type == .call ? "play.circle.fill"
                      : isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(event.type == .call ? Color.clawAccent
                                     : isError ? Color.red : Color.green)
                    .frame(width: 14)
                Text(event.type == .call ? L.callTool(event.tool)
                     : isError ? L.toolFailed(event.tool) : L.toolReturned(event.tool))
                    .font(.caption2)
                    .foregroundStyle(isError ? .red : .secondary)
                Spacer()
                Button {
                    withAnimation { showDetail.toggle() }
                } label: {
                    Text(showDetail ? L.collapse : L.details)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.clawAccent)
                }
                .buttonStyle(.plain)
            }

            if showDetail || isError {
                Text(event.detail)
                    .font(.caption2)
                    .foregroundStyle(isError ? .red : .secondary)
                    .padding(6)
                    .background((isError ? Color.red.opacity(0.08) : Color.systemBackground.opacity(0.5)))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.leading, 20)
                    .lineLimit(isError && !showDetail ? 2 : nil)
            }
        }
    }
}
