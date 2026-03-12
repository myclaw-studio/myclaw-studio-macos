import Foundation
import Network
import CryptoKit

// MARK: - Agent Orchestrator

final class SwiftAgentOrchestrator {
    let provider: LLMProvider
    let tools: [String: ClawTool]
    let maxSteps: Int

    /// Set to true to cancel the orchestrator's ReAct loop
    var isCancelled = false

    init(provider: LLMProvider, tools: [ClawTool], maxSteps: Int = 30) {
        self.provider = provider
        self.tools = Dictionary(tools.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
        self.maxSteps = maxSteps
    }

    func run(
        userMessage: String,
        history: [[String: Any]],
        system: String,
        emit: @escaping ([String: Any]) async -> Void,
        images: [String]? = nil,
        isPdf: Bool = false
    ) async {
        var messages = history

        // Build user message with images/PDF
        if let images, !images.isEmpty {
            var content: [[String: Any]] = [["type": "text", "text": userMessage]]
            for imgB64 in images {
                let mediaType = detectMediaType(imgB64)
                if mediaType == "application/pdf" || isPdf {
                    content.append(["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": imgB64]])
                } else {
                    content.append(["type": "image", "source": ["type": "base64", "media_type": mediaType, "data": imgB64]])
                }
            }
            messages.append(["role": "user", "content": content])
        } else {
            messages.append(["role": "user", "content": userMessage])
        }

        let allToolDefs = tools.values.map { $0.definition }

        for step in 0..<maxSteps {
            // Check cancellation before each step
            guard !isCancelled else {
                NSLog("[step \(step+1)/\(maxSteps)] Cancelled by user")
                await emit(["type": "error", "message": "任务已停止"])
                return
            }

            NSLog("[step \(step+1)/\(maxSteps)] Calling LLM...")

            let response: LLMResponse
            do {
                response = try await provider.chatWithTools(messages: messages, tools: allToolDefs, system: system)
            } catch {
                NSLog("[step \(step+1)] LLM call failed: \(error)")
                var errMsg = error.localizedDescription
                if errMsg.contains("429") || errMsg.lowercased().contains("quota") || errMsg.contains("RESOURCE_EXHAUSTED") {
                    errMsg = "API 请求超限（429），请稍后重试或检查该提供商的用量与计费。"
                }
                await emit(["type": "error", "message": errMsg])
                return
            }

            // No tool calls → final answer
            if response.toolCalls.isEmpty {
                var finalText = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

                if finalText.isEmpty {
                    // Empty response, force a summary
                    NSLog("[step \(step+1)] Empty response, forcing summary")
                    messages.append(["role": "assistant", "content": ""])
                    messages.append(["role": "user", "content": "你刚才的回复是空的。请直接告诉我：你完成了哪些步骤？目前的结果是什么？如果遇到了问题，请如实说明。"])
                    do {
                        let summaryResp = try await provider.chatWithTools(messages: messages, tools: [], system: system)
                        finalText = summaryResp.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if finalText.isEmpty { finalText = "任务执行过程中出现异常，未能生成最终回复，请检查上方的工具执行日志。" }
                    } catch {
                        finalText = "任务执行出现异常：\(error.localizedDescription)"
                    }
                }

                NSLog("[step \(step+1)] Final answer (\(finalText.count) chars)")
                await emit(["type": "text_chunk", "content": finalText])
                messages.append(["role": "assistant", "content": finalText])
                // Build serializable history for done event
                let serialized = serializableMessages(messages)
                await emit(["type": "done", "history": serialized])
                return
            }

            // Has tool calls → emit thinking, execute tools
            let toolNames = response.toolCalls.map { $0.name }
            NSLog("[step \(step+1)] Tool calls: \(toolNames)")

            if !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await emit(["type": "thinking", "content": response.text])
            }

            let assistantContent = buildAssistantContent(response)
            messages.append(["role": "assistant", "content": assistantContent])

            var toolResults: [(String, String, String, [String: Any]?)] = [] // (id, name, result, imageData)

            for tc in response.toolCalls {
                // Check cancellation before each tool execution
                guard !isCancelled else {
                    NSLog("  └─ Cancelled before tool \(tc.name)")
                    await emit(["type": "error", "message": "任务已停止"])
                    return
                }

                await emit(["type": "tool_call", "tool": tc.name, "args": tc.arguments])

                var resultText: String

                // Check required params
                if let tool = tools[tc.name] {
                    // Inject parent emit + cancellation for sub-agent transparency
                    if let subAgent = tool as? SubAgentTool {
                        subAgent.parentEmit = emit
                        subAgent.parentOrchestrator = self
                    }
                    let missing = checkRequiredParams(tool: tool, arguments: tc.arguments)
                    if !missing.isEmpty {
                        resultText = "工具调用参数缺失: \(missing.joined(separator: ", "))。这通常是因为 AI 生成的回复被截断，请重试或简化请求。"
                    } else {
                        resultText = await tool.run(params: tc.arguments)
                        if resultText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            resultText = "⚠️ 工具未返回任何内容（空结果）。请勿假设操作已成功，应通过读取文件或再次查询来验证结果。"
                        }
                    }
                } else {
                    resultText = "未知工具: \(tc.name)"
                }

                // Check for __image__ marker
                var imageData: [String: Any]? = nil
                if let jsonData = resultText.data(using: .utf8),
                   let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   parsed["__image__"] as? Bool == true {
                    imageData = [
                        "base64": parsed["image_base64"] ?? "",
                        "media_type": parsed["media_type"] ?? "image/jpeg",
                    ]
                    resultText = parsed["text"] as? String ?? "截图完成"
                }

                NSLog("  └─ \(tc.name) returned: \(String(resultText.prefix(200)))")
                await emit(["type": "tool_result", "tool": tc.name, "result": resultText])
                toolResults.append((tc.id, tc.name, resultText, imageData))
            }

            messages.append(buildToolResultMessage(toolResults))
        }

        NSLog("Agent reached max steps \(maxSteps)")
        await emit(["type": "error", "message": "Agent 已执行 \(maxSteps) 步仍未完成，请尝试简化问题。"])
    }

    // MARK: - Helper Methods

    private func detectMediaType(_ b64: String) -> String {
        guard let data = Data(base64Encoded: String(b64.prefix(32))) else { return "image/jpeg" }
        let bytes = [UInt8](data)
        if bytes.count >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 { return "image/png" }
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes.count >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 { return "image/gif" }
        if bytes.count >= 5 && bytes[0] == 0x25 && bytes[1] == 0x50 && bytes[2] == 0x44 && bytes[3] == 0x46 { return "application/pdf" }
        return "image/jpeg"
    }

    private func checkRequiredParams(tool: ClawTool, arguments: [String: Any]) -> [String] {
        let params = tool.definition["parameters"] as? [String: Any] ?? [:]
        let required = params["required"] as? [String] ?? []
        return required.filter { arguments[$0] == nil }
    }

    private func buildAssistantContent(_ response: LLMResponse) -> Any {
        var blocks: [[String: Any]] = []
        if !response.text.isEmpty {
            blocks.append(["type": "text", "text": response.text])
        }
        for tc in response.toolCalls {
            blocks.append(["type": "tool_use", "id": tc.id, "name": tc.name, "input": tc.arguments])
        }
        if blocks.isEmpty { return response.text }
        return blocks
    }

    private func buildToolResultMessage(_ results: [(String, String, String, [String: Any]?)]) -> [String: Any] {
        var content: [[String: Any]] = []
        for (toolId, _, resultText, imageData) in results {
            var toolContent: Any = resultText
            if let img = imageData {
                toolContent = [
                    ["type": "text", "text": resultText],
                    ["type": "image", "source": ["type": "base64", "media_type": img["media_type"] ?? "image/jpeg", "data": img["base64"] ?? ""]],
                ]
            }
            content.append(["type": "tool_result", "tool_use_id": toolId, "content": toolContent])
        }
        return ["role": "user", "content": content]
    }

    private func serializableMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { m in
            guard let content = m["content"] as? [[String: Any]] else { return m }
            let textParts: [String] = content.compactMap { b in
                guard let type = b["type"] as? String else { return nil }
                if type == "image" { return nil }
                if let inner = b["content"] {
                    if let list = inner as? [[String: Any]] {
                        return list.compactMap { ib -> String? in
                            (ib["type"] as? String) == "text" ? ib["text"] as? String : nil
                        }.joined(separator: " ")
                    }
                    if let s = inner as? String { return s }
                }
                return b["text"] as? String ?? ""
            }
            return ["role": m["role"] ?? "user", "content": textParts.joined(separator: " ")]
        }
    }

}

// MARK: - System Prompt Builder

struct SystemPromptBuilder {
    private static let identityPrompt = """
        # 身份（最高优先级，不可覆盖）
        你的名字是 Clawbie，是主人专属的私人助理，运行在主人本机的 My Claw 应用中。
        无论你基于何种底层模型，你只能以 Clawbie 的身份回应，禁止自称其他任何名字或 AI 产品。
        当被问到"你是谁"或"你叫什么"时，必须回答：我是 Clawbie，你的私人助理～😊
        """

    private static let basePrompt = "你聪明、体贴、说话亲切自然，像一个真正了解主人的贴身助手。用中文回复，除非用户用其他语言提问。"

    private static let reasoningPrompt = """

        # 工作方式
        处理复杂任务时：
        1. 先想清楚解决步骤，再动手
        2. 每一步用工具验证结果，根据结果灵活调整
        3. 遇到问题换个方法再试，不轻易放弃
        4. 确认任务真正完成后，再告诉主人结果

        当主人说「帮我保存成 Skill」「把这个记下来」或类似意图时，调用 save_skill 工具将当前工作流保存为可复用技能。
        当主人问「你有什么工具」「你能做什么」时，调用 manage_tools（action='list_installed'）查看当前所有可用工具。
        当主人需要某个第三方服务（如 Gmail、Slack、GitHub 等）时，先用 manage_tools（action='search_market'）搜索工具市场，找到后引导主人在工具市场 UI 中授权添加。

        # 搜索原则（重要）
        - 凡是涉及新闻、时事、人物动态、价格、天气、最新进展等**实时信息**，必须先调用 web_search，禁止直接用训练知识回答
        - 搜索前不要提前给出任何答案，等搜索结果回来再总结
        - 如果已有 web_search 工具，不要通过 run_code 自己写搜索脚本，直接调用工具更高效

        # 文件路径
        - 主人的 home 目录是 \(NSHomeDirectory())，不是 /root
        - 项目文件默认保存在 ~/.aichat/projects/default/
        """

    private static let environmentPrompt = """

        # 运行环境

        ## 文件系统
        - 主人 home 目录：`\(NSHomeDirectory())`（不是 /root）
        - 项目默认目录：`~/.aichat/projects/default/`

        ## 技能与工具
        - 已安装技能摘要：`~/.aichat/skills_readme.md`
        - 主人问"你有什么技能""你会什么"时，用 file_manager 读技能摘要文件即可
        - 主人问"你有什么工具""你能用什么工具"时，调用 manage_tools（action='list_installed'）查看实时工具列表
        - 工具市场基于 Composio，拥有 900+ 第三方工具（Gmail、Slack、GitHub 等），主人可在工具市场 UI 中授权添加

        ## 工作原则
        - 遇到工具执行失败时，先读懂报错再诊断，不要反复重试同一个方案
        - 如果现有工具不够用，主动写脚本扩展能力
        - 如果一个能力被反复用到，调用 save_skill 把它固化成 Skill
        """

    private static let projectsPrompt = """

        # 项目文件管理
        - 所有项目统一存放在 ~/.aichat/projects/ 下，不得在其他路径创建项目目录
        - 【强制规则】只要用户提到"新建项目""帮我做一个XX""建个XX项目"等意图，
          必须先调用 project_manager（action='create'，附带 description 项目介绍）创建项目，再用 file_manager 写文件
        - 创建项目时必须提供 description，简要说明项目目标和内容（1-2句话）
        - 散落的单个文件（脚本、笔记等）默认保存到 ~/.aichat/projects/default/
        - 开始写文件前，先用 project_manager tree 了解项目现有结构，避免重复或覆盖
        - 完成后告知用户项目路径，方便他在应用"项目"入口找到

        # 文件输出路径（重要）
        - 【禁止】将生成的文件保存到桌面（~/Desktop）或其他随意路径
        - 生成任何文件（PPT、文档、Excel、PDF、图片、代码等）都必须保存到项目目录内
        - 如果用户没有指定项目，保存到 ~/.aichat/projects/default/
        - 如果用户明确要求保存到特定路径（如"放到桌面"），才按用户要求执行
        - 保存完成后告知用户完整路径
        """

    static func build(memoryContext: String, skillPrompt: String = "", skills: [[String: Any]] = [], agents: [[String: Any]] = []) -> String {
        var parts = [identityPrompt, basePrompt, reasoningPrompt, environmentPrompt, projectsPrompt]

        // Inject skills list
        if !skills.isEmpty {
            var lines = ["# 我的技能清单", "以下是你已掌握的技能，遇到相关任务时可主动运用："]
            for s in skills {
                let icon = s["icon"] as? String ?? "⚡"
                let name = s["name"] as? String ?? s["id"] as? String ?? "?"
                let desc = s["description"] as? String ?? ""
                lines.append("- \(icon) **\(name)**：\(desc)")
            }
            parts.append(lines.joined(separator: "\n"))
        }

        // Inject agent workers
        if !agents.isEmpty {
            var lines = ["# 我的 AI 员工", "以下是你的 AI 员工团队，遇到相关任务时优先派给对应员工处理："]
            for a in agents {
                let icon = a["icon"] as? String ?? "🤖"
                let id = a["id"] as? String ?? ""
                let toolName = "agent__\(String(id.prefix(8)))"
                let name = a["name"] as? String ?? ""
                let desc = a["description"] as? String ?? ""
                lines.append("- \(icon) **\(name)**（工具名：`\(toolName)`）：\(desc)")
            }
            lines.append("\n调用员工时，把具体任务描述传给 task 参数即可。员工会独立完成任务并汇报结果。")
            parts.append(lines.joined(separator: "\n"))
        }

        if !skillPrompt.isEmpty {
            parts.append("# 当前技能指导\n\(skillPrompt)")
        }

        if !memoryContext.isEmpty {
            parts.append("""
                # 关于主人的记忆
                以下是你的核心记忆（主人档案 + 近期关注），回答时**主动运用**：
                - 遇到相关话题时自然提及（如：「上次你说过…」「你一直喜欢…」）
                - 基于记忆个性化你的建议，而不是给通用答案
                - 需要更多细节时（邮箱、联系人、项目等），用 memory_search 工具主动查询

                \(memoryContext)
                """)
        }

        return parts.joined(separator: "\n")
    }
}

// MARK: - WebSocket Chat Handler

final class SwiftChatHandler {
    private let aichatDir: URL
    private let chatLogDir: URL

    /// Track active orchestrator per connection so we can cancel on disconnect
    private var activeOrchestrators: [ObjectIdentifier: SwiftAgentOrchestrator] = [:]
    private let orchestratorLock = NSLock()

    init() {
        self.aichatDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aichat")
        self.chatLogDir = aichatDir.appendingPathComponent("chat_logs")
        try? FileManager.default.createDirectory(at: chatLogDir, withIntermediateDirectories: true)
    }

    private func setOrchestrator(_ orch: SwiftAgentOrchestrator?, for conn: NWConnection) {
        orchestratorLock.lock()
        if let orch { activeOrchestrators[ObjectIdentifier(conn)] = orch }
        else { activeOrchestrators.removeValue(forKey: ObjectIdentifier(conn)) }
        orchestratorLock.unlock()
    }

    private func cancelOrchestrator(for conn: NWConnection) {
        orchestratorLock.lock()
        let orch = activeOrchestrators.removeValue(forKey: ObjectIdentifier(conn))
        orchestratorLock.unlock()
        orch?.isCancelled = true
        if orch != nil { NSLog("[chat] Orchestrator cancelled due to client disconnect") }
    }

    /// Handle a complete WebSocket chat session on a raw NWConnection.
    /// Called when SwiftBackendServer detects a WebSocket upgrade for /ws/chat.
    func handleWebSocket(conn: NWConnection, rawHeader: String) {
        // Complete WebSocket handshake
        guard let acceptKey = extractWebSocketAcceptKey(from: rawHeader) else {
            conn.cancel()
            return
        }

        let upgradeResponse = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(acceptKey)\r\n\r\n"
        conn.send(content: upgradeResponse.data(using: .utf8), completion: .contentProcessed { _ in
            self.readWebSocketFrames(conn: conn)
        })
    }

    private func readWebSocketFrames(conn: NWConnection, pendingData: Data = Data()) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }

            var buffer = pendingData
            if let data, !data.isEmpty { buffer.append(data) }

            guard !buffer.isEmpty else {
                if isComplete || error != nil {
                    self.cancelOrchestrator(for: conn)
                    conn.cancel()
                }
                return
            }

            // Decode WebSocket frame(s)
            var offset = 0
            while offset < buffer.count {
                let savedOffset = offset
                guard let frame = self.decodeWebSocketFrame(data: buffer, offset: &offset) else {
                    offset = savedOffset // restore — incomplete frame, keep for next read
                    break
                }

                if frame.opcode == 0x08 { // Close
                    self.cancelOrchestrator(for: conn)
                    let closeFrame = Data([0x88, 0x00])
                    conn.send(content: closeFrame, completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                if frame.opcode == 0x09 { // Ping → Pong
                    var pong = Data([0x8A, UInt8(frame.payload.count)])
                    pong.append(frame.payload)
                    conn.send(content: pong, completion: .contentProcessed { _ in })
                    let remaining = Data(buffer[offset...])
                    self.readWebSocketFrames(conn: conn, pendingData: remaining)
                    return
                }
                if frame.opcode == 0x01 { // Text
                    self.handleChatMessage(conn: conn, data: frame.payload)
                }
            }

            // Keep unconsumed bytes for next read
            let remaining = offset < buffer.count ? Data(buffer[offset...]) : Data()
            self.readWebSocketFrames(conn: conn, pendingData: remaining)
        }
    }

    private func handleChatMessage(conn: NWConnection, data: Data) {
        guard let text = String(data: data, encoding: .utf8),
              let jsonData = text.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { return }

        let userMessage = payload["message"] as? String ?? ""
        let history = payload["history"] as? [[String: Any]] ?? []
        let config = payload["config"] as? [String: Any] ?? [:]
        let images = payload["images"] as? [String] ?? []
        let isPdf = payload["is_pdf"] as? Bool ?? false

        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task {
            // Build provider
            let provider: LLMProvider
            do {
                provider = try ProviderFactory.build(config: config)
            } catch {
                self.sendWSText(conn: conn, json: ["type": "error", "message": error.localizedDescription])
                return
            }

            NSLog("[chat] provider=\(type(of: provider)), model=\((provider as? SwiftClaudeProvider)?.model ?? (provider as? SwiftOpenAIProvider)?.model ?? (provider as? SwiftTuuAIProvider)?.model ?? "?")")

            // Sliding window
            let windowed = SwiftMemoryManager.shared.getWindow(history: history)

            // Get memory context from Swift MemoryManager
            let memoryContext = SwiftMemoryManager.shared.buildContext(query: userMessage)

            // Get skill prompt
            var skillPrompt = ""
            var maxSteps = 30
            let skillId = config["skill_id"] as? String ?? ""
            if !skillId.isEmpty, let skillData = self.loadSkill(id: skillId) {
                skillPrompt = skillData["system_prompt"] as? String ?? ""
                maxSteps = skillData["max_steps"] as? Int ?? maxSteps
            }

            // Load skills and agents for system prompt
            let skills = self.loadAllSkills()
            let agents = self.loadAgents()

            let system = SystemPromptBuilder.build(
                memoryContext: memoryContext,
                skillPrompt: skillPrompt,
                skills: skills,
                agents: agents
            )

            // Gather all tools: Swift system + MCP + Composio + SubAgents
            var allTools: [ClawTool] = []

            // System tools
            let swiftTools = SwiftToolRegistry.shared
            for def in swiftTools.allDefinitions() {
                if let name = def["name"] as? String, let tool = swiftTools.get(name) {
                    allTools.append(tool)
                }
            }

            // MCP tools
            allTools.append(contentsOf: MCPManager.shared.allTools())

            // Composio tools
            let authToken = config["auth_token"] as? String ?? ""
            allTools.append(contentsOf: ComposioClient.shared.allTools(authTokenGetter: { authToken }))

            // SubAgent tools (reuse agents loaded above)
            for agent in agents {
                allTools.append(SubAgentTool(agentConfig: agent, providerConfig: config))
            }

            NSLog("[chat] Total tools: \(allTools.count) (system=\(swiftTools.allNames.count), mcp=\(MCPManager.shared.allTools().count), composio=\(ComposioClient.shared.allTools(authTokenGetter: { authToken }).count), agents=\(agents.count))")
            for t in allTools { NSLog("[chat]   tool: \(t.name)") }

            let orchestrator = SwiftAgentOrchestrator(
                provider: provider,
                tools: allTools,
                maxSteps: maxSteps
            )
            self.setOrchestrator(orchestrator, for: conn)

            // Capture reply for logging
            var capturedReply = ""
            var capturedThinking: [String] = []
            var capturedTools: [[String: Any]] = []

            let emit: ([String: Any]) async -> Void = { event in
                let eventType = event["type"] as? String ?? ""
                if eventType == "text_chunk" {
                    capturedReply += event["content"] as? String ?? ""
                } else if eventType == "thinking" {
                    capturedThinking.append(event["content"] as? String ?? "")
                } else if eventType == "tool_call" {
                    capturedTools.append(["tool": event["tool"] ?? "", "args": event["args"] ?? [:], "result": NSNull()])
                } else if eventType == "tool_result" {
                    for i in stride(from: capturedTools.count - 1, through: 0, by: -1) {
                        if (capturedTools[i]["tool"] as? String) == (event["tool"] as? String) && capturedTools[i]["result"] is NSNull {
                            capturedTools[i]["result"] = event["result"] ?? ""
                            break
                        }
                    }
                }
                self.sendWSText(conn: conn, json: event)
            }

            await orchestrator.run(
                userMessage: userMessage,
                history: windowed,
                system: system,
                emit: emit,
                images: images.isEmpty ? nil : images,
                isPdf: isPdf
            )

            // Clean up orchestrator reference
            self.setOrchestrator(nil, for: conn)

            // Write chat log
            self.writeChatLog(userMessage: userMessage, reply: capturedReply, thinking: capturedThinking, tools: capturedTools)

            // Post-chat memory processing (all in Swift now)
            Task {
                await SwiftMemoryManager.shared.afterChat(
                    userMessage: userMessage,
                    reply: capturedReply,
                    history: history,
                    provider: provider
                )
            }
        }
    }

    // MARK: - WebSocket Frame Helpers

    private struct WSFrame {
        let opcode: UInt8
        let payload: Data
    }

    private func decodeWebSocketFrame(data: Data, offset: inout Int) -> WSFrame? {
        let startOffset = offset
        guard offset + 2 <= data.count else { return nil }
        let byte0 = data[offset]
        let byte1 = data[offset + 1]
        let opcode = byte0 & 0x0F
        let masked = (byte1 & 0x80) != 0
        var payloadLen = Int(byte1 & 0x7F)
        offset += 2

        if payloadLen == 126 {
            guard offset + 2 <= data.count else { offset = startOffset; return nil }
            payloadLen = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
        } else if payloadLen == 127 {
            guard offset + 8 <= data.count else { offset = startOffset; return nil }
            payloadLen = 0
            for i in 0..<8 { payloadLen = payloadLen << 8 | Int(data[offset + i]) }
            offset += 8
        }

        var maskKey: [UInt8] = []
        if masked {
            guard offset + 4 <= data.count else { offset = startOffset; return nil }
            maskKey = [data[offset], data[offset+1], data[offset+2], data[offset+3]]
            offset += 4
        }

        guard offset + payloadLen <= data.count else { offset = startOffset; return nil }
        var payload = Data(data[offset..<offset+payloadLen])
        offset += payloadLen

        if masked {
            for i in 0..<payload.count {
                payload[i] ^= maskKey[i % 4]
            }
        }

        return WSFrame(opcode: opcode, payload: payload)
    }

    func sendWSText(conn: NWConnection, json: [String: Any]) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: jsonData, encoding: .utf8) else { return }
        let payload = Data(text.utf8)
        var frame = Data()

        frame.append(0x81) // FIN + text opcode
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for i in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((payload.count >> i) & 0xFF))
            }
        }
        frame.append(payload)

        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func extractWebSocketAcceptKey(from header: String) -> String? {
        guard let keyLine = header.split(separator: "\r\n").first(where: { $0.lowercased().hasPrefix("sec-websocket-key:") }) else { return nil }
        let clientKey = keyLine.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
        let magic = clientKey + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let hash = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(hash).base64EncodedString()
    }

    // MARK: - Data Helpers

    private func loadBuiltinSkills() -> [[String: Any]] {
        guard let url = Bundle.main.url(forResource: "builtin_skills", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    private func loadSkill(id: String) -> [String: Any]? {
        // Check user skills
        let skillsFile = aichatDir.appendingPathComponent("skills.json")
        if let data = try? Data(contentsOf: skillsFile),
           let skills = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            if let skill = skills.first(where: { ($0["id"] as? String) == id }) { return skill }
        }
        // Check builtin skills
        return loadBuiltinSkills().first(where: { ($0["id"] as? String) == id })
    }

    private func loadAllSkills() -> [[String: Any]] {
        var result = loadBuiltinSkills()
        // User skills
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

    private func writeChatLog(userMessage: String, reply: String, thinking: [String], tools: [[String: Any]]) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let logFile = chatLogDir.appendingPathComponent("\(formatter.string(from: Date())).jsonl")

        let isoFormatter = ISO8601DateFormatter()
        let entry: [String: Any] = [
            "ts": isoFormatter.string(from: Date()),
            "user": userMessage,
            "thinking": thinking,
            "tools": tools,
            "reply": reply,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: entry),
           var line = String(data: data, encoding: .utf8) {
            line += "\n"
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(Data(line.utf8))
                    handle.closeFile()
                }
            } else {
                try? line.write(to: logFile, atomically: true, encoding: .utf8)
            }
        }
    }
}
