import Foundation

// MARK: - Provider Protocol & Types

struct LLMToolCall {
    let id: String
    let name: String
    let arguments: [String: Any]
}

struct LLMResponse {
    var text: String = ""
    var toolCalls: [LLMToolCall] = []
}

protocol LLMProvider {
    var model: String { get }
    func chatWithTools(messages: [[String: Any]], tools: [[String: Any]], system: String) async throws -> LLMResponse
    func singleCall(prompt: String, system: String) async throws -> String
}

// MARK: - Claude Provider (Anthropic Messages API)

final class SwiftClaudeProvider: LLMProvider {
    let apiKey: String
    let model: String
    let utilityModel: String

    init(apiKey: String, model: String = "claude-sonnet-4-6", utilityModel: String = "claude-haiku-4-5") {
        self.apiKey = apiKey
        self.model = model
        self.utilityModel = utilityModel
    }

    func chatWithTools(messages: [[String: Any]], tools: [[String: Any]], system: String) async throws -> LLMResponse {
        let claudeTools = tools.map { t -> [String: Any] in
            ["name": t["name"] ?? "", "description": t["description"] ?? "", "input_schema": t["parameters"] ?? [:]]
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16384,
            "messages": messages,
        ]
        if !system.isEmpty { body["system"] = system }
        if !claudeTools.isEmpty { body["tools"] = claudeTools }

        let data = try await post(url: "https://api.anthropic.com/v1/messages", body: body, headers: [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse
        }

        if let error = json["error"] as? [String: Any], let msg = error["message"] as? String {
            throw ProviderError.apiError(msg)
        }

        var result = LLMResponse()
        if let content = json["content"] as? [[String: Any]] {
            for block in content {
                let type = block["type"] as? String ?? ""
                if type == "text" {
                    result.text = block["text"] as? String ?? ""
                } else if type == "tool_use" {
                    result.toolCalls.append(LLMToolCall(
                        id: block["id"] as? String ?? UUID().uuidString,
                        name: block["name"] as? String ?? "",
                        arguments: block["input"] as? [String: Any] ?? [:]
                    ))
                }
            }
        }

        if let stopReason = json["stop_reason"] as? String, stopReason == "max_tokens" {
            NSLog("[Claude] Response truncated at max_tokens")
        }

        return result
    }

    func singleCall(prompt: String, system: String) async throws -> String {
        var body: [String: Any] = [
            "model": utilityModel,
            "max_tokens": 2048,
            "messages": [["role": "user", "content": prompt]],
        ]
        if !system.isEmpty { body["system"] = system }

        let data = try await post(url: "https://api.anthropic.com/v1/messages", body: body, headers: [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            return ""
        }
        return text
    }
}

// MARK: - OpenAI Provider (Chat Completions API)

final class SwiftOpenAIProvider: LLMProvider {
    let apiKey: String
    let model: String
    let utilityModel: String

    init(apiKey: String, model: String = "gpt-4o", utilityModel: String = "gpt-4o-mini") {
        self.apiKey = apiKey
        self.model = model
        self.utilityModel = utilityModel
    }

    func chatWithTools(messages: [[String: Any]], tools: [[String: Any]], system: String) async throws -> LLMResponse {
        var allMessages: [[String: Any]] = []
        if !system.isEmpty {
            allMessages.append(["role": "system", "content": system])
        }
        for msg in messages {
            let converted = convertMessage(msg)
            allMessages.append(contentsOf: converted)
        }

        let openaiTools = tools.map { t -> [String: Any] in
            ["type": "function", "function": [
                "name": t["name"] ?? "", "description": t["description"] ?? "", "parameters": t["parameters"] ?? [:]
            ]]
        }

        var body: [String: Any] = ["model": model, "messages": allMessages]
        if !openaiTools.isEmpty { body["tools"] = openaiTools }

        let data = try await post(url: "https://api.openai.com/v1/chat/completions", body: body, headers: [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse
        }

        if let error = json["error"] as? [String: Any], let msg = error["message"] as? String {
            throw ProviderError.apiError(msg)
        }

        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw ProviderError.invalidResponse
        }

        var result = LLMResponse(text: message["content"] as? String ?? "")
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for tc in toolCalls {
                let fn = tc["function"] as? [String: Any] ?? [:]
                let argsStr = fn["arguments"] as? String ?? "{}"
                let args = (try? JSONSerialization.jsonObject(with: Data(argsStr.utf8)) as? [String: Any]) ?? [:]
                result.toolCalls.append(LLMToolCall(
                    id: tc["id"] as? String ?? UUID().uuidString,
                    name: fn["name"] as? String ?? "",
                    arguments: args
                ))
            }
        }
        return result
    }

    func singleCall(prompt: String, system: String) async throws -> String {
        var msgs: [[String: Any]] = []
        if !system.isEmpty { msgs.append(["role": "system", "content": system]) }
        msgs.append(["role": "user", "content": prompt])

        let body: [String: Any] = ["model": utilityModel, "messages": msgs, "max_tokens": 2048]
        let data = try await post(url: "https://api.openai.com/v1/chat/completions", body: body, headers: [
            "Authorization": "Bearer \(apiKey)",
            "Content-Type": "application/json",
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return ""
        }
        return message["content"] as? String ?? ""
    }

    /// Convert Claude-style content blocks to OpenAI messages format.
    private func convertMessage(_ msg: [String: Any]) -> [[String: Any]] {
        let role = msg["role"] as? String ?? "user"
        guard let content = msg["content"] as? [[String: Any]] else {
            return [msg]
        }

        // tool_result blocks → separate "tool" messages
        if role == "user" && content.contains(where: { ($0["type"] as? String) == "tool_result" }) {
            return content.compactMap { block -> [String: Any]? in
                guard (block["type"] as? String) == "tool_result" else { return nil }
                var blockContent = block["content"]
                if let list = blockContent as? [[String: Any]] {
                    blockContent = list.compactMap { b -> String? in
                        (b["type"] as? String) == "text" ? b["text"] as? String : nil
                    }.joined(separator: " ")
                }
                return ["role": "tool", "tool_call_id": block["tool_use_id"] ?? "", "content": blockContent ?? ""]
            }
        }

        // assistant blocks → single message with tool_calls
        if role == "assistant" {
            var textParts: [String] = []
            var toolCalls: [[String: Any]] = []
            for block in content {
                guard let type = block["type"] as? String else { continue }
                if type == "text" { textParts.append(block["text"] as? String ?? "") }
                else if type == "tool_use" {
                    let inputData = (try? JSONSerialization.data(withJSONObject: block["input"] ?? [:])) ?? Data()
                    toolCalls.append([
                        "id": block["id"] ?? "",
                        "type": "function",
                        "function": ["name": block["name"] ?? "", "arguments": String(data: inputData, encoding: .utf8) ?? "{}"],
                    ])
                }
            }
            var result: [String: Any] = ["role": "assistant", "content": textParts.joined(separator: " ")]
            if !toolCalls.isEmpty { result["tool_calls"] = toolCalls }
            return [result]
        }

        // user image blocks → OpenAI vision format
        var openaiContent: [[String: Any]] = []
        for block in content {
            guard let type = block["type"] as? String else { continue }
            if type == "text" {
                openaiContent.append(["type": "text", "text": block["text"] ?? ""])
            } else if type == "image" {
                let source = block["source"] as? [String: Any] ?? [:]
                let mediaType = source["media_type"] as? String ?? "image/jpeg"
                let b64 = source["data"] as? String ?? ""
                openaiContent.append(["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(b64)"]])
            }
        }
        return [["role": role, "content": openaiContent]]
    }
}

// MARK: - TuuAI Provider (Cloud Claude)

final class SwiftTuuAIProvider: LLMProvider {
    let authToken: String
    let model: String
    let utilityModel: String

    init(authToken: String, model: String = "claude-sonnet-4-6", utilityModel: String = "claude-haiku-4-5") {
        self.authToken = authToken
        self.model = model
        self.utilityModel = utilityModel
    }

    func chatWithTools(messages: [[String: Any]], tools: [[String: Any]], system: String) async throws -> LLMResponse {
        var body: [String: Any] = [
            "messages": messages,
            "max_tokens": 16384,
            "model": model,
        ]
        if !system.isEmpty { body["system"] = system }
        if !tools.isEmpty {
            body["tools"] = tools.map { t -> [String: Any] in
                ["name": t["name"] ?? "", "description": t["description"] ?? "", "input_schema": t["parameters"] ?? [:]]
            }
            body["tool_choice"] = "auto"
        }

        let data = try await post(url: "\(AppConfig.serviceBaseURL)/api/v1/chat", body: body, headers: [
            "Authorization": "Bearer \(authToken)",
            "Content-Type": "application/json",
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.invalidResponse
        }

        return parseResponse(json)
    }

    func singleCall(prompt: String, system: String) async throws -> String {
        var body: [String: Any] = [
            "messages": [["role": "user", "content": prompt]],
            "max_tokens": 4096,
            "model": utilityModel,
        ]
        if !system.isEmpty { body["system"] = system }

        let data = try await post(url: "\(AppConfig.serviceBaseURL)/api/v1/assist", body: body, headers: [
            "Authorization": "Bearer \(authToken)",
            "Content-Type": "application/json",
        ])

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return parseResponse(json).text
    }

    private func parseResponse(_ data: [String: Any]) -> LLMResponse {
        var result = LLMResponse()
        let content = data["content"]

        if let blocks = content as? [[String: Any]] {
            for block in blocks {
                let type = block["type"] as? String ?? ""
                if type == "text" {
                    result.text = block["text"] as? String ?? ""
                } else if type == "tool_use" {
                    result.toolCalls.append(LLMToolCall(
                        id: block["id"] as? String ?? UUID().uuidString,
                        name: block["name"] as? String ?? "",
                        arguments: block["input"] as? [String: Any] ?? [:]
                    ))
                }
            }
        } else if let text = content as? String {
            result.text = text
        }
        return result
    }
}

// MARK: - Provider Factory

enum ProviderError: Error, LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(String)
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "请在设置中填写当前所选提供商的 API Key，或使用 Clawbie 云端服务"
        case .invalidResponse: return "AI 服务返回了无效的响应"
        case .apiError(let msg): return msg
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        }
    }
}

struct ProviderFactory {
    static func build(config: [String: Any], purpose: String = "chat") throws -> LLMProvider {
        let modelId = config["model"] as? String ?? "claude-sonnet-4-6"
        let utilityModel = config["utility_model"] as? String ?? "claude-haiku-4-5"
        let authToken = config["auth_token"] as? String ?? ""
        let provider = config["provider"] as? String ?? "claude"
        let anthropicKey = config["anthropic_api_key"] as? String ?? ""
        let openaiKey = config["openai_api_key"] as? String ?? ""

        if purpose == "chat" {
            if provider == "openai" && !openaiKey.isEmpty {
                return SwiftOpenAIProvider(apiKey: openaiKey, model: modelId, utilityModel: utilityModel)
            }
            if (provider == "claude" || provider.isEmpty) && !anthropicKey.isEmpty {
                return SwiftClaudeProvider(apiKey: anthropicKey, model: modelId, utilityModel: utilityModel)
            }
            if !authToken.isEmpty {
                return SwiftTuuAIProvider(authToken: authToken, model: modelId, utilityModel: utilityModel)
            }
            throw ProviderError.noAPIKey
        } else {
            // utility
            if provider == "openai" && !openaiKey.isEmpty {
                return SwiftOpenAIProvider(apiKey: openaiKey, model: utilityModel, utilityModel: utilityModel)
            }
            if (provider == "claude" || provider.isEmpty) && !anthropicKey.isEmpty {
                return SwiftClaudeProvider(apiKey: anthropicKey, utilityModel: utilityModel)
            }
            if !authToken.isEmpty {
                return SwiftTuuAIProvider(authToken: authToken, utilityModel: utilityModel)
            }
            throw ProviderError.noAPIKey
        }
    }
}

// MARK: - HTTP Helper

private func post(url urlString: String, body: [String: Any], headers: [String: String]) async throws -> Data {
    guard let url = URL(string: urlString) else { throw ProviderError.invalidResponse }
    var request = URLRequest(url: url, timeoutInterval: 240)
    request.httpMethod = "POST"
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    if let httpResp = response as? HTTPURLResponse, httpResp.statusCode >= 400 {
        let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
        // Check for quota/rate limit errors
        if httpResp.statusCode == 429 {
            throw ProviderError.apiError("API 请求超限（429），请稍后重试或检查该提供商的用量与计费。")
        }
        throw ProviderError.httpError(httpResp.statusCode, errorText)
    }
    return data
}
