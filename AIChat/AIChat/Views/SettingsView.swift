import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: ChatViewModel
    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject private var auth: AuthViewModel
    @State private var useOwnKey = AppConfig.useOwnKey
    @State private var provider = AppConfig.provider
    @State private var anthropicKey = AppConfig.anthropicKey
    @State private var openaiKey = AppConfig.openaiKey
    @State private var googleKey = AppConfig.googleKey
    @State private var deepseekKey = AppConfig.deepseekKey
    @State private var minimaxKey = AppConfig.minimaxKey
    @State private var doubaoKey = AppConfig.doubaoKey
    @State private var model = AppConfig.model
    @State private var utilityModel = AppConfig.utilityModel
    @State private var cloudModels: [BackendService.ModelOption] = AppConfig.cachedCloudModels
    @State private var isLoadingModels = false

    // 各提供商模型列表（写死，含最新版本）
    private static let claudeModels: [(String, String, String)] = [
        ("claude-sonnet-4-6",              "Claude Sonnet 4.6 ★",    "sonnet"),
        ("claude-opus-4-6",                "Claude Opus 4.6 ★",      "opus"),
        ("claude-haiku-4-5",               "Claude Haiku 4.5 ★",     "haiku"),
        ("claude-opus-4-5",                "Claude Opus 4.5",        "opus"),
        ("claude-sonnet-4-5",              "Claude Sonnet 4.5",      "sonnet"),
        ("claude-opus-4-1",                "Claude Opus 4.1",        "opus"),
        ("claude-sonnet-4",                "Claude Sonnet 4",        "sonnet"),
        ("claude-opus-4",                  "Claude Opus 4",          "opus"),
    ]
    private static let openaiModels: [(String, String, String)] = [
        ("o3",                        "O3 ★",                "reasoning"),
        ("o4-mini",                   "O4 mini ★",           "reasoning"),
        ("gpt-4o",                    "GPT-4o",              "gpt4o"),
        ("gpt-4o-mini",               "GPT-4o mini",         "gpt4omini"),
        ("o3-pro",                    "O3 Pro",              "reasoning"),
        ("o1",                        "O1",                  "reasoning"),
        ("gpt-3.5-turbo",             "GPT-3.5 Turbo",       "gpt35"),
    ]
    private static let geminiModels: [(String, String, String)] = [
        ("gemini-3.1-pro-preview",    "Gemini 3.1 Pro Preview ★",    "pro"),
        ("gemini-3-flash-preview",    "Gemini 3 Flash Preview",      "flash"),
        ("gemini-2.5-pro",            "Gemini 2.5 Pro",              "pro"),
        ("gemini-2.5-flash",          "Gemini 2.5 Flash ★",          "flash"),
        ("gemini-2.0-flash",          "Gemini 2.0 Flash",            "flash"),
    ]
    private static let deepseekModels: [(String, String, String)] = [
        ("deepseek-chat",             "DeepSeek V3 Chat ★",   "chat"),
        ("deepseek-reasoner",         "DeepSeek V3 Reasoner ★","reasoner"),
    ]
    private static let minimaxModels: [(String, String, String)] = [
        ("MiniMax-M2.5",              "MiniMax M2.5 ★",       "default"),
        ("MiniMax-M2.5-highspeed",    "MiniMax M2.5 极速版",   "default"),
        ("MiniMax-M2.1",              "MiniMax M2.1",          "default"),
        ("MiniMax-M2.1-highspeed",    "MiniMax M2.1 极速版",   "default"),
        ("MiniMax-M2",                "MiniMax M2",            "default"),
    ]
    private static let doubaoModels: [(String, String, String)] = [
        ("doubao-seed-2-0-pro-260215",          "豆包 Seed 2.0 Pro ★",    "pro"),
        ("doubao-seed-2-0-lite-260215",         "豆包 Seed 2.0 Lite",     "lite"),
        ("doubao-seed-2-0-mini-260215",         "豆包 Seed 2.0 Mini",     "mini"),
        ("doubao-seed-2-0-code-preview-260215", "豆包 Seed 2.0 Code",     "code"),
        ("doubao-seed-1-6-251015",              "豆包 Seed 1.6",          "default"),
    ]
    private func staticModels(for providerId: String) -> [(String, String, String)] {
        switch providerId {
        case "claude": return Self.claudeModels
        case "openai": return Self.openaiModels
        case "gemini": return Self.geminiModels
        case "deepseek": return Self.deepseekModels
        case "minimax": return Self.minimaxModels
        case "doubao": return Self.doubaoModels
        default: return Self.claudeModels
        }
    }

    private var providerOptions: [(id: String, name: String)] {
        [
            ("claude", L.providerClaude),
            ("openai", L.providerChatGPT),
            ("gemini", L.providerGemini),
            ("deepseek", L.providerDeepSeek),
            ("minimax", "MiniMax"),
            ("doubao", L.providerDoubao),
        ]
    }

    /// 当前表单中该提供商是否已填 API Key（未保存也按填写状态算）
    private func hasKeyInForm(for providerId: String) -> Bool {
        let key: String
        switch providerId {
        case "claude": key = anthropicKey
        case "openai": key = openaiKey
        case "gemini": key = googleKey
        case "deepseek": key = deepseekKey
        case "minimax": key = minimaxKey
        case "doubao": key = doubaoKey
        default: key = ""
        }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func providerDisplayName(for providerId: String) -> String {
        providerOptions.first(where: { $0.id == providerId })?.name ?? providerId
    }

    private func firstProviderWithKeyInForm() -> String? {
        providerOptions.first(where: { hasKeyInForm(for: $0.id) })?.id
    }

    private var availableModels: [(String, String, String)] {
        if useOwnKey {
            return staticModels(for: provider)
        }
        if cloudModels.isEmpty {
            return Self.claudeModels
        }
        return cloudModels.map { ($0.id, $0.display_name, $0.category) }
    }

    /// 当前选中的 provider 是否可用（有 key）
    private var providerReady: Bool { hasKeyInForm(for: provider) }

    var body: some View {
        NavigationStack {
            Form {
                // 服务模式切换
                Section {
                    if auth.isLocalMode {
                        // 本地模式：直接显示自带 Key，不可切换
                        HStack {
                            Text(L.ownAPIKey)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(L.isEN ? "Local Mode" : "本地模式")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("", selection: $useOwnKey) {
                            Text(L.clawbieCloud).tag(false)
                            Text(L.ownAPIKey).tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    if isLoadingModels {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text(L.loadingModels)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: { Text(L.modelSelection) }

                // ── 自带 Key 模式 ──
                if useOwnKey {
                    // 1) 先填 API Key
                    Section {
                        LabeledContent(L.anthropicKeyLabel) {
                            SecureField("", text: $anthropicKey)
                                .autocorrectionDisabled()
                                .noAutocapitalization()
                        }
                        LabeledContent(L.openaiKeyLabel) {
                            SecureField("", text: $openaiKey)
                                .autocorrectionDisabled()
                                .noAutocapitalization()
                        }
                        LabeledContent(L.googleKeyLabel) {
                            SecureField("", text: $googleKey)
                                .autocorrectionDisabled()
                                .noAutocapitalization()
                        }
                        LabeledContent("DeepSeek API Key") {
                            SecureField("", text: $deepseekKey)
                                .autocorrectionDisabled()
                                .noAutocapitalization()
                        }
                        LabeledContent("MiniMax API Key") {
                            SecureField("", text: $minimaxKey)
                                .autocorrectionDisabled()
                                .noAutocapitalization()
                        }
                        LabeledContent("豆包 API Key（字节）") {
                            SecureField("", text: $doubaoKey)
                                .autocorrectionDisabled()
                                .noAutocapitalization()
                        }
                    } header: { Text("\(L.apiKeysSection) (\(L.apiKeysSectionHint))") }
                      footer: {
                          Text(keyFooterForProvider)
                              .font(.caption)
                              .foregroundStyle(.secondary)
                      }

                    // 2) 再选 Provider（仅已填 key 的可选）
                    Section {
                        HStack {
                            Text(L.providerLabel)
                            Spacer()
                            Menu {
                                ForEach(providerOptions, id: \.id) { option in
                                    let hasKey = hasKeyInForm(for: option.id)
                                    Button {
                                        provider = option.id
                                    } label: {
                                        Label(
                                            hasKey ? option.name : "\(option.name)（未配置）",
                                            systemImage: hasKey ? "checkmark.circle.fill" : "circle.dashed"
                                        )
                                    }
                                    .disabled(!hasKey)
                                }
                            } label: {
                                HStack {
                                    Text(providerDisplayName(for: provider))
                                    Image(systemName: "chevron.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(firstProviderWithKeyInForm() == nil)
                        }

                        // 3) 选模型版本 & 辅助模型（仅当 provider 有 key 时可选）
                        Picker(L.versionLabel, selection: $model) {
                            ForEach(availableModels, id: \.0) { id, name, _ in
                                Text(name).tag(id)
                            }
                        }
                        .disabled(!providerReady)

                        Picker(L.utilityModel, selection: $utilityModel) {
                            ForEach(availableModels, id: \.0) { id, name, _ in
                                Text(name).tag(id)
                            }
                        }
                        .disabled(!providerReady)
                    } header: { Text(L.isEN ? "Provider & Model" : "服务商 & 模型") }
                      footer: {
                          Text(L.utilityModelFooter)
                              .font(.caption)
                              .foregroundStyle(.secondary)
                      }

                } else {
                    // ── 云端模式 ──
                    Section {
                        Picker(L.chatModel, selection: $model) {
                            ForEach(availableModels, id: \.0) { id, name, _ in
                                Text(name).tag(id)
                            }
                        }

                        HStack {
                            Text(L.utilityModel)
                            Spacer()
                            Text("Claude Haiku 4.5")
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            loadCloudModels()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text(L.refreshModels)
                            }
                            .font(.caption)
                        }
                        .disabled(isLoadingModels)
                    } footer: {
                        Text(L.utilityModelFooter)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "cloud.fill")
                                .foregroundStyle(Color.clawAccent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L.clawbieCloud)
                                    .font(.caption.weight(.medium))
                                Text(L.cloudServiceDesc)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L.settings)
            .toolbar {
                // Save 存储说明：
                // - 修改前：只存 useOwnKey, anthropicKey, model, modelCategory, utilityModel（仅 Claude 一种 key）
                // - 修改后：存 useOwnKey, provider + 全部 9 个 API Key + model/modelCategory/utilityModel；自带 Key 且当前 provider 未填 key 时禁用 Save
                ToolbarItem(placement: .confirmationAction) {
                    Button(L.save) {
                        AppConfig.useOwnKey = useOwnKey
                        AppConfig.provider = provider
                        AppConfig.anthropicKey = anthropicKey
                        AppConfig.openaiKey = openaiKey
                        AppConfig.googleKey = googleKey
                        AppConfig.deepseekKey = deepseekKey
                        AppConfig.minimaxKey = minimaxKey
                        AppConfig.doubaoKey = doubaoKey
                        AppConfig.model = model
                        AppConfig.modelCategory = availableModels.first(where: { $0.0 == model })?.2 ?? "sonnet"
                        AppConfig.utilityModel = useOwnKey ? utilityModel : "claude-haiku-4-5"
                        Task { await vm.checkBackend() }
                        dismiss()
                    }
                    .disabled(useOwnKey && !hasKeyInForm(for: provider))
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(L.cancel) { dismiss() }
                }
            }
            .onAppear {
                // 本地模式强制自带 Key
                if auth.isLocalMode {
                    useOwnKey = true
                }
                // 云端模式且无缓存时才首次拉取
                if !useOwnKey && cloudModels.isEmpty {
                    loadCloudModels()
                }
                // 自带 Key：若当前选中的提供商未填 key 但其他有填，自动切到第一个有 key 的
                if useOwnKey && !hasKeyInForm(for: provider), let first = firstProviderWithKeyInForm() {
                    provider = first
                    let d = defaultModelAndUtility(for: first)
                    model = d.model
                    utilityModel = d.utility
                }
            }
            .onChange(of: useOwnKey) {
                if !useOwnKey {
                    if cloudModels.isEmpty {
                        loadCloudModels()
                    }
                    let ids = availableModels.map(\.0)
                    let haiku = ids.first(where: { $0.contains("haiku") })
                    model = haiku ?? ids.first ?? "claude-haiku-4-5"
                    utilityModel = haiku ?? ids.first ?? "claude-haiku-4-5"
                } else {
                    provider = AppConfig.provider
                    if !hasKeyInForm(for: provider), let first = firstProviderWithKeyInForm() {
                        provider = first
                    }
                    let defaults = defaultModelAndUtility(for: provider)
                    model = defaults.model
                    utilityModel = defaults.utility
                }
            }
            .onChange(of: provider) {
                if useOwnKey {
                    let defaults = defaultModelAndUtility(for: provider)
                    model = defaults.model
                    utilityModel = defaults.utility
                }
            }
            .onChange(of: anthropicKey) { handleKeyChanged(for: "claude") }
            .onChange(of: openaiKey) { handleKeyChanged(for: "openai") }
            .onChange(of: googleKey) { handleKeyChanged(for: "gemini") }
            .onChange(of: deepseekKey) { handleKeyChanged(for: "deepseek") }
            .onChange(of: minimaxKey) { handleKeyChanged(for: "minimax") }
            .onChange(of: doubaoKey) { handleKeyChanged(for: "doubao") }
        }
    }

    /// API Key 变化时自动切换 provider：
    /// - 填入 key 且当前 provider 没有 key → 自动切到刚填的 provider
    /// - 清空 key 且当前 provider 就是被清空的 → 切到下一个有 key 的 provider
    private func handleKeyChanged(for providerId: String) {
        guard useOwnKey else { return }
        if hasKeyInForm(for: providerId) {
            if !hasKeyInForm(for: provider) {
                provider = providerId
                let d = defaultModelAndUtility(for: providerId)
                model = d.model
                utilityModel = d.utility
            }
        } else if provider == providerId {
            if let next = firstProviderWithKeyInForm() {
                provider = next
                let d = defaultModelAndUtility(for: next)
                model = d.model
                utilityModel = d.utility
            }
        }
    }

    private struct DefaultModels { let model: String; let utility: String }

    private func defaultModelAndUtility(for providerId: String) -> DefaultModels {
        let list = staticModels(for: providerId)
        let first = list.first?.0 ?? "claude-sonnet-4-6"
        switch providerId {
        case "openai":    return DefaultModels(model: "o3",                     utility: "gpt-4o-mini")
        case "gemini":    return DefaultModels(model: "gemini-2.5-flash",        utility: "gemini-2.0-flash")
        case "deepseek":  return DefaultModels(model: "deepseek-chat",           utility: "deepseek-chat")
        case "minimax":   return DefaultModels(model: "MiniMax-M2.5",             utility: "MiniMax-M2.5-highspeed")
        case "doubao":    return DefaultModels(model: "doubao-seed-2-0-pro-260215", utility: "doubao-seed-2-0-mini-260215")
        default:          return DefaultModels(model: "claude-sonnet-4-6",       utility: "claude-haiku-4-5")
        }
    }

    private var keyFooterForProvider: String {
        switch provider {
        case "openai": return L.isEN ? "Used for ChatGPT models" : "用于 ChatGPT 系列模型"
        case "gemini": return L.isEN ? "Used for Gemini models" : "用于 Gemini 系列模型"
        case "deepseek": return L.isEN ? "Used for DeepSeek models" : "用于 DeepSeek 系列模型"
        case "minimax": return L.isEN ? "Used for MiniMax models" : "用于 MiniMax 系列模型"
        case "doubao": return L.isEN ? "Used for Doubao (ByteDance) models" : "用于豆包（字节）系列模型"
        default: return L.forClaudeModels
        }
    }

    private func loadCloudModels() {
        let token = AppConfig.authToken
        guard !token.isEmpty else { return }
        isLoadingModels = true
        Task {
            do {
                let result = try await BackendService().fetchCloudModels(accessToken: token)
                cloudModels = result.models
                AppConfig.cachedCloudModels = result.models
                // 当前选择不在列表中才修正
                let ids = result.models.map(\.id)
                if !ids.contains(model) {
                    model = ids.first(where: { $0.contains("haiku") }) ?? ids.first ?? "claude-haiku-4-5"
                }
                if !ids.contains(utilityModel) {
                    utilityModel = ids.first(where: { $0.contains("haiku") }) ?? ids.first ?? "claude-haiku-4-5"
                }
            } catch {
                // 加载失败，保持 fallback
            }
            isLoadingModels = false
        }
    }
}
