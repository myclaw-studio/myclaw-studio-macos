import SwiftUI

func debugLog(_ msg: String) {
    let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(ts)] \(msg)\n"
    let path = NSHomeDirectory() + "/composio_debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        fh.seekToEndOfFile()
        fh.write(line.data(using: .utf8)!)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
    }
    NSLog("%@", msg)
}

// Simple flow layout for tags
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0; var y: CGFloat = 0; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxW && x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX; var y = bounds.minY; var rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX && x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}

struct ToolMarketView: View {
    @EnvironmentObject private var auth: AuthViewModel
    var onBack: () -> Void = {}
    private let service = BackendService()

    @State private var allTools: [ToolItem] = []
    @State private var servers: [MCPServer] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedTab = 0

    // Agents
    @State private var agents: [AgentWorker] = []
    @State private var showCreateAgent = false

    // Composio
    @State private var toolkits: [ComposioToolkit] = []
    @State private var connections: [ComposioConnection] = []
    @State private var connectedSlugs: Set<String> = []
    @State private var installedComposioSlugs: Set<String> = Self.loadInstalledSlugs()
    @State private var selectedToolkit: ComposioToolkit?
    @State private var searchText = ""
    @State private var selectedCategory = "all"
    @State private var nextCursor: String?
    @State private var isLoadingMore = false
    @State private var totalItems = 0
    private let didActivate = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    private let mcpStatusChanged = NotificationCenter.default.publisher(for: .mcpToolStatusChanged)
    @State private var composioAuthErrors: [String: String] = [:] // slug -> error message

    private let cardColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
    ]

    @State private var showToolMarketSheet = false
    @State private var selectedSystemTool: ToolItem?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text(L.tools).tag(0)
                Text(L.isEN ? "AI Workers" : "AI 员工").tag(1)
                Text(L.isEN ? "Skills" : "技能").tag(2)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            if selectedTab == 0 {
                myToolsTab
            } else if selectedTab == 1 {
                agentsTab
            } else {
                SkillMarketView()
            }
        }
        .task {
            if let tools = try? await service.fetchAllTools() { allTools = tools }
            if let s = try? await service.fetchMCPServers() { servers = s }
            if let a = try? await service.fetchAgents() { agents = a }
            if let resp = try? await service.fetchComposioToolkits() { toolkits = resp.items }
            if let conns = try? await service.fetchComposioConnections() {
                connections = conns
                connectedSlugs = Set(conns.filter { $0.isActive }.map { $0.toolkitSlug })
            }
            await refreshComposioAuthErrors()
        }
        .onReceive(didActivate) { _ in
            Task {
                await refreshConnections()
                await refreshComposioAuthErrors()
                if let s = try? await service.fetchMCPServers() { servers = s }
            }
        }
        .sheet(isPresented: $showToolMarketSheet) {
            if auth.isLocalMode {
                if AppConfig.composioApiKey.isEmpty {
                    composioKeyInputSheet
                } else {
                    NavigationStack {
                        composioMarketTab
                            .navigationTitle(L.toolMarket)
                            .inlineNavigationTitle()
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button(L.close) { showToolMarketSheet = false }
                                }
                            }
                    }
                    .frame(minWidth: 560, minHeight: 520)
                }
            } else {
                NavigationStack {
                    composioMarketTab
                        .navigationTitle(L.toolMarket)
                        .inlineNavigationTitle()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L.close) { showToolMarketSheet = false }
                            }
                        }
                }
                .frame(minWidth: 560, minHeight: 520)
            }
        }
    }

    // MARK: - Installed slugs persistence（按模式隔离）

    /// 云端模式和本地模式使用不同的 key，避免数据混淆
    private static var installedKey: String {
        UserDefaults.standard.bool(forKey: "aichat.local_mode") ? "composio_installed_slugs_local" : "composio_installed_slugs_cloud"
    }

    private static func loadInstalledSlugs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: installedKey) ?? [])
    }

    private func saveInstalledSlugs() {
        UserDefaults.standard.set(Array(installedComposioSlugs), forKey: Self.installedKey)
    }

    /// 切换模式时重新加载对应模式的数据
    private func reloadInstalledSlugs() {
        installedComposioSlugs = Self.loadInstalledSlugs()
    }

    // MARK: - My Tools Tab

    private var installedComposioToolkits: [ComposioToolkit] {
        toolkits.filter { installedComposioSlugs.contains($0.slug) }
    }

    private var myToolsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // System tools
                if !allTools.filter({ !$0.removable }).isEmpty {
                    sectionHeader(L.isEN ? "System Tools" : "系统工具")
                    LazyVGrid(columns: cardColumns, spacing: 12) {
                        ForEach(allTools.filter { !$0.removable }) { tool in
                            systemToolCard(tool)
                                .onTapGesture { selectedSystemTool = tool }
                        }
                    }
                }

                // Composio tools
                sectionHeader(L.isEN ? "Installed" : "已安装")
                LazyVGrid(columns: cardColumns, spacing: 12) {
                    // + 添加工具卡片
                    Button { showToolMarketSheet = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(.purple)
                                .frame(width: 40, height: 40)
                            Text(L.isEN ? "Add Tool" : "添加工具")
                                .font(.subheadline.weight(.medium))
                            Text(L.isEN ? "Tool Market" : "工具市场")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(height: 28)
                            Text(L.isEN ? "Add" : "添加")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(.purple.opacity(0.3)))
                    }
                    .buttonStyle(.plain)

                    ForEach(installedComposioToolkits) { tk in
                        installedComposioCard(tk)
                    }
                }

                if allTools.isEmpty && servers.isEmpty {
                    Text("暂无工具")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(12)
        }
        .onReceive(mcpStatusChanged) { _ in
            Task {
                if let s = try? await service.fetchMCPServers() { servers = s }
            }
        }
        .task(id: servers.contains(where: { $0.status == "loading" })) {
            guard servers.contains(where: { $0.status == "loading" }) else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                if let updated = try? await service.fetchMCPServers() {
                    servers = updated
                    if !servers.contains(where: { $0.status == "loading" }) { break }
                }
            }
        }
        .sheet(item: $selectedSystemTool) { tool in
            SystemToolDetailSheet(tool: tool)
        }
    }

    // MARK: - System Tool Card

    private func systemToolCard(_ tool: ToolItem) -> some View {
        VStack(spacing: 8) {
            Image(systemName: ToolInfo.catalog.first(where: { $0.id == tool.name })?.icon ?? "wrench")
                .font(.system(size: 24))
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)

            Text(ToolInfo.catalog.first(where: { $0.id == tool.name })?.name ?? tool.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text(ToolInfo.catalog.first(where: { $0.id == tool.name })?.description ?? tool.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28)

            Text(L.isEN ? "System" : "系统")
                .font(.caption2)
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.blue.opacity(0.1))
                .clipShape(Capsule())
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    // MARK: - MCP Server Card

    private func mcpServerCard(_ server: MCPServer) -> some View {
        VStack(spacing: 8) {
            Text("📦")
                .font(.system(size: 24))
                .frame(width: 40, height: 40)

            Text(server.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Group {
                if server.status == "connected" {
                    Text("\(server.toolCount) tools")
                        .foregroundStyle(.secondary)
                } else if server.status == "loading" {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text(L.isEN ? "Loading" : "加载中")
                    }.foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 2) {
                        Text(L.isEN ? "Failed" : "加载失败").foregroundStyle(.red)
                        if let err = server.error {
                            Text(err)
                                .foregroundStyle(.red.opacity(0.7))
                                .lineLimit(2)
                        }
                    }
                }
            }
            .font(.caption2)
            .frame(height: 28)

            HStack(spacing: 6) {
                if server.status == "failed" {
                    Button { Task { await handleReload(serverName: server.name) } } label: {
                        Text(L.isEN ? "Retry" : "重试").font(.caption2)
                    }.buttonStyle(.bordered).controlSize(.mini)
                }
                Button(role: .destructive) {
                    Task { await handleRemoveMCP(serverName: server.name) }
                } label: {
                    Text(L.isEN ? "Remove" : "移除").font(.caption2)
                }.buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    // MARK: - Installed Composio Card

    private func installedComposioCard(_ tk: ComposioToolkit) -> some View {
        let connected = !tk.requiresAuth || connectedSlugs.contains(tk.slug)
        let hasAuthError = composioAuthErrors[tk.slug] != nil

        return VStack(spacing: 8) {
            RemoteImage(url: tk.logo, size: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(tk.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            if hasAuthError || !connected {
                VStack(spacing: 4) {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text(L.isEN ? "Auth expired" : "授权异常")
                            .foregroundStyle(.red)
                    }
                    .font(.caption2)

                    Button {
                        composioAuthErrors.removeValue(forKey: tk.slug)
                        Task { await handleConnect(toolkit: tk) }
                    } label: {
                        Text(L.isEN ? "Reauthorize" : "重新授权")
                            .font(.caption2.weight(.medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange))
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 28)
            } else {
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text(L.isEN ? "Connected" : "已连接")
                        .foregroundStyle(.green)
                }
                .font(.caption2)
                .frame(height: 28)
            }

            Button(role: .destructive) {
                installedComposioSlugs.remove(tk.slug)
                saveInstalledSlugs()
                composioAuthErrors.removeValue(forKey: tk.slug)
                Task { try? await service.uninstallComposioToolkit(slug: tk.slug) }
            } label: {
                Text(L.isEN ? "Remove" : "移除").font(.caption2)
            }.buttonStyle(.bordered).controlSize(.mini)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(
            (hasAuthError || !connected) ? Color.red.opacity(0.3) : Color.green.opacity(0.3),
            lineWidth: 1
        ))
    }

    // MARK: - Agents Tab

    private var agentsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: cardColumns, spacing: 12) {
                    // + 新建卡片
                    Button { showCreateAgent = true } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(.purple)
                                .frame(width: 40, height: 40)
                            Text(L.isEN ? "New Worker" : "新建员工")
                                .font(.subheadline.weight(.medium))
                            Text(L.isEN ? "Describe & create" : "描述即创建")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(height: 28)
                            Text(L.isEN ? "Add" : "添加")
                                .font(.caption2)
                                .foregroundStyle(.purple)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(.purple.opacity(0.3)))
                    }
                    .buttonStyle(.plain)

                    ForEach(agents) { agent in
                        agentCard(agent)
                    }
                }
            }
            .padding(12)
        }
        .task {
            if let a = try? await service.fetchAgents() { agents = a }
        }
        .sheet(isPresented: $showCreateAgent) {
            CreateAgentSheet(service: service, authorizedToolkits: toolkits.filter { $0.noAuth || connectedSlugs.contains($0.slug) }) { newAgent in
                agents.append(newAgent)
            }
        }
        .sheet(item: $editingAgent) { agent in
            EditAgentSheet(agent: agent, service: service, authorizedToolkits: toolkits.filter { $0.noAuth || connectedSlugs.contains($0.slug) }) { updated in
                if let idx = agents.firstIndex(where: { $0.id == updated.id }) {
                    agents[idx] = updated
                }
            }
        }
    }

    // MARK: - Agent Card

    @State private var editingAgent: AgentWorker?

    private func agentCard(_ agent: AgentWorker) -> some View {
        VStack(spacing: 8) {
            Text(agent.icon.isEmpty ? "🤖" : agent.icon)
                .font(.system(size: 24))
                .frame(width: 40, height: 40)

            Text(agent.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text(agent.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28)

            HStack(spacing: 6) {
                Button {
                    editingAgent = agent
                } label: {
                    Text(L.isEN ? "Edit" : "修改").font(.caption2)
                }.buttonStyle(.bordered).controlSize(.mini)

                Button(role: .destructive) {
                    Task {
                        try? await service.deleteAgent(id: agent.id)
                        if let a = try? await service.fetchAgents() { agents = a }
                    }
                } label: {
                    Text(L.remove).font(.caption2)
                }.buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.purple.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Composio Market Tab

    private var composioCategories: [String] {
        var seen = Set<String>()
        var result = ["all"]
        for tk in toolkits {
            let cat = tk.categoryName
            if !cat.isEmpty && seen.insert(cat).inserted {
                result.append(cat)
            }
        }
        return result
    }

    private var filteredToolkits: [ComposioToolkit] {
        toolkits.filter { tk in
            (selectedCategory == "all" || tk.categoryName == selectedCategory)
            && (searchText.isEmpty
                || tk.name.localizedCaseInsensitiveContains(searchText)
                || tk.description.localizedCaseInsensitiveContains(searchText))
        }
    }

    @State private var composioKeyInput = AppConfig.composioApiKey
    @State private var composioKeyVerifying = false
    @State private var composioKeyError: String?

    private var composioKeyInputSheet: some View {
        VStack(spacing: 20) {
            HStack {
                Text(L.isEN ? "Connect Composio" : "连接 Composio")
                    .font(.headline)
                Spacer()
                Button(L.close) { showToolMarketSheet = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            Image(systemName: "bolt.shield")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text(L.isEN
                 ? "Enter your Composio API Key to unlock\n1000+ tools (Gmail, GitHub, Slack...)"
                 : "输入 Composio API Key 即可解锁\n1000+ 工具（Gmail、GitHub、Slack…）")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                SecureField("Composio API Key", text: $composioKeyInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)

                if let err = composioKeyError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    Task { await verifyAndSaveComposioKey() }
                } label: {
                    if composioKeyVerifying {
                        ProgressView().controlSize(.small)
                            .frame(width: 120)
                    } else {
                        Text(L.isEN ? "Connect" : "连接")
                            .frame(width: 120)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(composioKeyInput.trimmingCharacters(in: .whitespaces).isEmpty || composioKeyVerifying)

                Button {
                    if let url = URL(string: "https://app.composio.dev/settings") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(L.isEN ? "Get API Key from composio.dev" : "从 composio.dev 获取 API Key")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            Spacer()
        }
        .frame(minWidth: 420, minHeight: 380)
    }

    private func verifyAndSaveComposioKey() async {
        composioKeyVerifying = true
        composioKeyError = nil

        let key = composioKeyInput.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else {
            composioKeyError = L.isEN ? "Please enter an API Key" : "请输入 API Key"
            composioKeyVerifying = false
            return
        }

        // 验证 Key：尝试调一次 apps 接口
        guard let url = URL(string: "https://backend.composio.dev/api/v1/apps?limit=1") else {
            composioKeyError = "URL error"
            composioKeyVerifying = false
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(key, forHTTPHeaderField: "x-api-key")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 401 {
                composioKeyError = L.isEN ? "Invalid API Key" : "API Key 无效"
                composioKeyVerifying = false
                return
            }
            // 检查返回是否有 items
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["items"] != nil {
                // 验证成功，保存
                AppConfig.composioApiKey = key
                composioKeyVerifying = false
                // 关闭当前 sheet，重新打开时会显示市场
                showToolMarketSheet = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showToolMarketSheet = true
                }
                return
            }
            composioKeyError = L.isEN ? "Unexpected response" : "响应异常"
        } catch {
            composioKeyError = L.isEN ? "Network error: \(error.localizedDescription)" : "网络错误：\(error.localizedDescription)"
        }
        composioKeyVerifying = false
    }

    private var composioMarketTab: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L.searchTools, text: $searchText).textFieldStyle(.plain)
            }
            .padding(8)
            .background(.bar)

            // Categories
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(composioCategories, id: \.self) { cat in
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { selectedCategory = cat }
                        } label: {
                            Text(cat == "all" ? L.all : cat)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(selectedCategory == cat ? Color.accentColor : Color.secondary.opacity(0.12))
                                .foregroundStyle(selectedCategory == cat ? .white : .primary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(.bar)

            // Cards
            ScrollView {
                LazyVGrid(columns: cardColumns, spacing: 12) {
                    ForEach(filteredToolkits) { tk in
                        marketCard(tk)
                            .onTapGesture { selectedToolkit = tk }
                            .onAppear {
                                if tk.id == filteredToolkits.last?.id {
                                    Task { await loadMoreToolkits() }
                                }
                            }
                    }
                }
                .padding(12)

                if isLoadingMore {
                    ProgressView()
                        .padding()
                }

                if totalItems > 0 {
                    Text("已加载 \(toolkits.count) / \(totalItems)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 8)
                }

                if let msg = errorMessage {
                    Text(msg).font(.caption).foregroundStyle(.red).padding()
                }
            }
            .refreshable { await loadComposioData(reset: true) }
        }
        .task { await loadComposioData(reset: true) }
        .onReceive(didActivate) { _ in
            // 无论 selectedTab 值如何，只要 composioMarketTab 可见就刷新
            // （此视图可能在 sheet 中显示，selectedTab 与 sheet 无关）
            Task { await refreshConnections() }
        }
        .sheet(item: $selectedToolkit) { tk in
            ComposioDetailSheet(
                toolkit: tk,
                isConnected: tk.noAuth || connectedSlugs.contains(tk.slug),
                isInstalled: installedComposioSlugs.contains(tk.slug),
                onConnect: { await handleConnect(toolkit: tk) },
                onDisconnect: {
                    if let conn = connections.first(where: { $0.toolkitSlug == tk.slug }) {
                        await handleDisconnect(connectionId: conn.id)
                    }
                }
            )
        }
    }

    // MARK: - Market Card

    private func marketCard(_ tk: ComposioToolkit) -> some View {
        let connected = !tk.requiresAuth || connectedSlugs.contains(tk.slug)
        let installed = installedComposioSlugs.contains(tk.slug)
        return VStack(spacing: 8) {
            RemoteImage(url: tk.logo, size: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(tk.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text(tk.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28)

            // Status + action
            if installed {
                Text("已添加")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())
            } else if connected {
                Button {
                    installedComposioSlugs.insert(tk.slug)
                    saveInstalledSlugs()
                    Task { try? await service.installComposioToolkit(slug: tk.slug) }
                } label: {
                    Text("添加到工具")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            } else {
                Button {
                    Task { await handleConnect(toolkit: tk) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill")
                        Text(L.isEN ? "Authorize" : "授权连接")
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.orange))
                }
                .buttonStyle(.plain)
            }

            Text("\(tk.toolsCount) tools")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    installed ? Color.blue.opacity(0.3) :
                    connected ? Color.green.opacity(0.3) :
                    Color.secondary.opacity(0.15),
                    lineWidth: 1
                )
        )
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 4)
    }

    // MARK: - Data

    private func loadComposioData(reset: Bool = false) async {
        isLoading = true
        errorMessage = nil
        if reset {
            toolkits = []
            nextCursor = nil
            totalItems = 0
        }
        do {
            let tkResp = try await service.fetchComposioToolkits()
            toolkits = tkResp.items
            totalItems = tkResp.totalItems
            nextCursor = tkResp.nextCursor
            debugLog("[Composio] loadComposioData: loaded \(tkResp.items.count) toolkits")
        } catch {
            debugLog("[Composio] loadComposioData toolkits error: \(error)")
            errorMessage = "加载失败: \(error.localizedDescription)"
        }
        // 连接状态单独获取，不影响工具列表加载
        do {
            let conns = try await service.fetchComposioConnections()
            connections = conns
            connectedSlugs = Set(conns.filter { $0.isActive }.map { $0.toolkitSlug })
            debugLog("[Composio] loadComposioData: \(conns.count) connections, slugs=\(connectedSlugs)")
        } catch {
            debugLog("[Composio] loadComposioData connections error: \(error)")
        }
        isLoading = false
    }

    private func loadMoreToolkits() async {
        guard let cursor = nextCursor, !cursor.isEmpty, !isLoadingMore else { return }
        isLoadingMore = true
        do {
            let resp = try await service.fetchComposioToolkits(cursor: cursor)
            let existingSlugs = Set(toolkits.map { $0.slug })
            let newItems = resp.items.filter { !existingSlugs.contains($0.slug) }
            toolkits.append(contentsOf: newItems)
            nextCursor = resp.nextCursor
            totalItems = resp.totalItems
        } catch {
            errorMessage = "加载更多失败: \(error.localizedDescription)"
        }
        isLoadingMore = false
    }

    private func refreshConnections() async {
        if let conns = try? await service.fetchComposioConnections() {
            connections = conns
            let slugs = Set(conns.filter { $0.isActive }.map { $0.toolkitSlug })
            debugLog("[Composio] refreshConnections: \(conns.count) connections, active slugs=\(slugs)")
            connectedSlugs = slugs
        } else {
            debugLog("[Composio] refreshConnections: fetch failed")
        }
    }

    private func refreshComposioAuthErrors() async {
        // Fetch auth errors from local backend (ComposioClient tracks them)
        guard let url = URL(string: "http://127.0.0.1:8000/composio/toolkits"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var errors: [String: String] = [:]
        for item in list {
            if let slug = item["slug"] as? String, let err = item["auth_error"] as? String {
                errors[slug] = err
            }
        }
        composioAuthErrors = errors
    }

    private func handleConnect(toolkit: ComposioToolkit) async {
        // Clear local auth error state
        composioAuthErrors.removeValue(forKey: toolkit.slug)
        // Clear backend auth error
        clearBackendAuthError(slug: toolkit.slug)
        do {
            let resp = try await service.composioConnect(toolkit: toolkit.slug)
            if let authUrl = resp.authUrl, !authUrl.isEmpty, let url = URL(string: authUrl) {
                // 需要 OAuth：打开浏览器，然后轮询等待连接
                debugLog("[Composio] OAuth started for \(toolkit.slug), polling for connection...")
                await MainActor.run { NSWorkspace.shared.open(url) }
                for i in 0..<60 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let conns = try await service.fetchComposioConnections()
                    let slugs = Set(conns.filter { $0.isActive }.map { $0.toolkitSlug })
                    debugLog("[Composio] Poll #\(i+1): found \(conns.count) connections, slugs=\(slugs), looking for '\(toolkit.slug)'")
                    connections = conns
                    connectedSlugs = slugs
                    if slugs.contains(toolkit.slug) {
                        debugLog("[Composio] ✓ Connected: \(toolkit.slug)")
                        break
                    }
                }
            } else {
                // noAuth：连接已直接建立，刷新状态即可
                try? await Task.sleep(nanoseconds: 500_000_000)
                await refreshConnections()
            }
        } catch {
            debugLog("[Composio] Connect error: \(error)")
            errorMessage = L.isEN ? "Connection failed: \(error.localizedDescription)" : "连接失败: \(error.localizedDescription)"
        }
    }

    private func clearBackendAuthError(slug: String) {
        guard let url = URL(string: "http://127.0.0.1:8000/composio/\(slug)/clear-error") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        Task { _ = try? await URLSession.shared.data(for: req) }
    }

    private func handleDisconnect(connectionId: String) async {
        do {
            try await service.composioDisconnect(connectionId: connectionId)
            await loadComposioData()
        } catch {
            errorMessage = "断开失败: \(error.localizedDescription)"
        }
    }

    private func handleReload(serverName: String) async {
        if let _ = try? await service.reloadMCPServer(name: serverName),
           let s = try? await service.fetchMCPServers() { servers = s }
    }

    private func handleRemoveMCP(serverName: String) async {
        do {
            try await service.deleteMCPServer(name: serverName)
            if let s = try? await service.fetchMCPServers() { servers = s }
            if let t = try? await service.fetchAllTools() { allTools = t }
        } catch {
            errorMessage = L.disconnectError(error.localizedDescription)
        }
    }
}

// MARK: - Detail Sheet (Clean Layout)

private struct ComposioDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let toolkit: ComposioToolkit
    let isConnected: Bool
    let isInstalled: Bool
    let onConnect: () async -> Void
    let onDisconnect: () async -> Void

    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            // Top bar with close button
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Header
            VStack(spacing: 12) {
                RemoteImage(url: toolkit.logo, size: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                Text(toolkit.name)
                    .font(.title2.weight(.bold))

                HStack(spacing: 12) {
                    Label("\(toolkit.toolsCount) tools", systemImage: "wrench")
                    if !toolkit.categoryName.isEmpty {
                        Label(toolkit.categoryName, systemImage: "tag")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // Connection status
                if isConnected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("已连接")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                }
            }
            .padding(.bottom, 16)

                Divider().padding(.horizontal)

                // Description
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(toolkit.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Info grid
                        VStack(spacing: 10) {
                            infoRow("认证方式", value: toolkit.noAuth ? "无需认证" : toolkit.authSchemes.joined(separator: ", "))
                            if toolkit.triggersCount > 0 {
                                infoRow("触发器", value: "\(toolkit.triggersCount)")
                            }
                        }
                    }
                    .padding(20)
                }

                Divider()

                // Bottom action
                HStack(spacing: 12) {
                    if isConnected {
                        Button(role: .destructive) {
                            Task {
                                isLoading = true
                                await onDisconnect()
                                isLoading = false
                                dismiss()
                            }
                        } label: {
                            Text("断开连接")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Button {
                            Task {
                                isLoading = true
                                await onConnect()
                                isLoading = false
                                dismiss()
                            }
                        } label: {
                            if isLoading {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity)
                            } else {
                                Text("连接")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isLoading)
                    }
                }
                .padding(16)
            }
        .frame(width: 400, height: 480)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }
}

// MARK: - Create Agent Sheet

private struct CreateAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let service: BackendService
    let authorizedToolkits: [ComposioToolkit]
    let onCreated: (AgentWorker) -> Void

    @State private var descriptionText = ""
    @State private var isGenerating = false
    @State private var generated = false
    @State private var errorMsg: String?

    // Generated fields (editable)
    @State private var agentName = ""
    @State private var agentIcon = ""
    @State private var agentDescription = ""
    @State private var agentPrompt = ""
    @State private var agentTools: [String] = []
    @State private var agentModel = ""
    @State private var agentMaxSteps = 10
    @State private var isSaving = false
    @AppStorage("aichat.language") private var language = "en"

    // Available items for dropdowns
    @State private var availableSkills: [Skill] = []
    @State private var cloudModels: [BackendService.ModelOption] = AppConfig.cachedCloudModels
    @State private var mcpSearch = ""
    @State private var skillSearch = ""
    @State private var showMCPDropdown = false
    @State private var showSkillDropdown = false

    fileprivate static let providerModels: [String: [(String, String)]] = [
        "claude": [
            ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
            ("claude-opus-4-6", "Claude Opus 4.6"),
            ("claude-haiku-4-5", "Claude Haiku 4.5"),
        ],
        "openai": [
            ("o3", "O3"),
            ("o4-mini", "O4 mini"),
            ("gpt-4o", "GPT-4o"),
            ("gpt-4o-mini", "GPT-4o mini"),
        ],
        "gemini": [
            ("gemini-3.1-pro-preview", "Gemini 3.1 Pro Preview"),
            ("gemini-2.5-flash", "Gemini 2.5 Flash"),
            ("gemini-2.0-flash", "Gemini 2.0 Flash"),
        ],
        "deepseek": [
            ("deepseek-chat", "DeepSeek V3 Chat"),
            ("deepseek-reasoner", "DeepSeek V3 Reasoner"),
        ],
        "minimax": [
            ("MiniMax-M2.5", "MiniMax M2.5"),
            ("MiniMax-M2.5-highspeed", "MiniMax M2.5 极速版"),
        ],
        "doubao": [
            ("doubao-seed-2-0-pro-260215", "豆包 Seed 2.0 Pro"),
            ("doubao-seed-2-0-lite-260215", "豆包 Seed 2.0 Lite"),
        ],
    ]

    private var modelOptions: [(id: String, name: String)] {
        if AppConfig.useOwnKey {
            if AppConfig.currentProviderKey.isEmpty {
                return []
            }
            let models = Self.providerModels[AppConfig.provider] ?? Self.providerModels["claude"]!
            return models.map { (id: $0.0, name: $0.1) }
        }
        if !cloudModels.isEmpty {
            return cloudModels.map { (id: $0.id, name: $0.display_name) }
        }
        let models = Self.providerModels[AppConfig.provider] ?? Self.providerModels["claude"]!
        return models.map { (id: $0.0, name: $0.1) }
    }

    // Reusable card section
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func sectionLabel(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.isEN ? "New AI Worker" : "新建 AI 员工")
                        .font(.headline)
                    Text(L.isEN ? "Describe your needs, Clawbie will configure it"
                              : "描述你的需求，Clawbie 帮你自动配置")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            if !generated {
                // Step 1: Describe
                VStack(spacing: 0) {
                    Spacer()

                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.purple.opacity(0.2), .purple.opacity(0.05)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 80, height: 80)
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 32))
                                .foregroundStyle(.purple)
                        }

                        Text(L.isEN ? "Describe what you need" : "描述你需要的 AI 员工")
                            .font(.title3.weight(.semibold))
                    }

                    Spacer().frame(height: 24)

                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $descriptionText)
                            .font(.body)
                            .frame(height: 110)
                            .padding(10)
                            .scrollContentBackground(.hidden)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.purple.opacity(descriptionText.isEmpty ? 0 : 0.3), lineWidth: 1)
                            )
                            .overlay(
                                Group {
                                    if descriptionText.isEmpty {
                                        Text(L.isEN ? "e.g. An email assistant that can read, send, and organize Gmail"
                                                  : "例如：一个能帮我收发邮件、整理 Gmail 的邮件助手")
                                            .foregroundStyle(.tertiary)
                                            .padding(.leading, 14)
                                            .padding(.top, 18)
                                            .allowsHitTesting(false)
                                    }
                                }, alignment: .topLeading
                            )

                        if let err = errorMsg {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer().frame(height: 20)

                    Button {
                        Task { await generateConfig() }
                    } label: {
                        Group {
                            if isGenerating {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text(L.isEN ? "Clawbie is crafting..." : "Clawbie 正在打造...")
                                }
                            } else {
                                Text(L.isEN ? "Generate" : "生成配置")
                                    .fontWeight(.medium)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 20)
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(
                            descriptionText.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating
                            ? Color.purple.opacity(0.4) : Color.purple
                        ))
                    }
                    .buttonStyle(.plain)
                    .disabled(descriptionText.trimmingCharacters(in: .whitespaces).isEmpty || isGenerating)
                    .padding(.horizontal, 24)

                    Spacer()
                }
            } else {
                // Step 2: Review & edit
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        // Identity card
                        sectionCard {
                            HStack(spacing: 14) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.purple.opacity(0.1))
                                        .frame(width: 52, height: 52)
                                    Text(agentIcon.isEmpty ? "🤖" : agentIcon)
                                        .font(.system(size: 28))
                                }
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField(L.isEN ? "Name" : "名称", text: $agentName)
                                        .font(.headline)
                                        .textFieldStyle(.plain)
                                    TextField(L.isEN ? "Description" : "简介", text: $agentDescription)
                                        .font(.caption)
                                        .textFieldStyle(.plain)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        // System Prompt
                        sectionCard {
                            sectionLabel(L.isEN ? "System Prompt" : "系统提示词", icon: "text.quote")
                            TextEditor(text: $agentPrompt)
                                .font(.caption)
                                .frame(minHeight: 80, maxHeight: 120)
                                .padding(8)
                                .scrollContentBackground(.hidden)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                        }

                        // Model
                        sectionCard {
                            sectionLabel(L.isEN ? "Model" : "模型", icon: "cpu")
                            if modelOptions.isEmpty {
                                Text(L.isEN ? "No API Key configured" : "未配置 API Key")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                Picker("", selection: $agentModel) {
                                    Text(L.isEN ? "Default (same as Clawbie)" : "默认（跟随 Clawbie）").tag("")
                                    ForEach(modelOptions, id: \.id) { opt in
                                        Text(opt.name).tag(opt.id)
                                    }
                                }
                                .labelsHidden()
                            }
                        }

                        // Tools & Skills
                        sectionCard {
                            HStack {
                                sectionLabel(L.isEN ? "Tools" : "工具", icon: "wrench.and.screwdriver")
                                Spacer()
                                Text(L.isEN ? "Authorize more in Tool Market" : "去工具市场授权更多")
                                    .font(.caption2)
                                    .foregroundStyle(.purple.opacity(0.7))
                            }
                            composioToolkitDropdown()

                            Divider().padding(.vertical, 4)

                            sectionLabel(L.isEN ? "Skills" : "技能", icon: "sparkles")
                            searchableDropdown(
                                placeholder: L.isEN ? "Search skills..." : "搜索技能...",
                                searchText: $skillSearch,
                                isOpen: $showSkillDropdown,
                                items: availableSkills.map { (id: $0.id, label: "\($0.icon) \($0.name)") },
                                selected: $agentTools
                            )

                            HStack(spacing: 4) {
                                Image(systemName: "info.circle")
                                Text(L.isEN ? "System tools (search, code, files...) are inherited by all workers"
                                          : "系统工具（搜索、代码、文件等）所有员工自动继承")
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                        }

                        // Max steps
                        sectionCard {
                            HStack {
                                sectionLabel(L.isEN ? "Max Steps" : "最大步数", icon: "arrow.triangle.2.circlepath")
                                Spacer()
                                Stepper("\(agentMaxSteps)", value: $agentMaxSteps, in: 3...30)
                                    .font(.subheadline)
                            }
                        }

                        if let err = errorMsg {
                            Text(err).font(.caption).foregroundStyle(.red).padding(.horizontal, 4)
                        }
                    }
                    .padding(16)
                }

                Divider()

                HStack(spacing: 12) {
                    Button {
                        generated = false
                    } label: {
                        Text(L.isEN ? "Back" : "返回修改")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Button {
                        Task { await saveAgent() }
                    } label: {
                        Group {
                            if isSaving {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(L.isEN ? "Create" : "创建")
                                    .fontWeight(.medium)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(
                            agentName.isEmpty || isSaving ? Color.purple.opacity(0.4) : Color.purple
                        ))
                    }
                    .buttonStyle(.plain)
                    .disabled(agentName.isEmpty || isSaving)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 500, height: 600)
        .task {
            if let skills = try? await service.fetchSkills() {
                availableSkills = skills
            }
            if !AppConfig.useOwnKey, let token = tryGetToken() {
                if let result = try? await service.fetchCloudModels(accessToken: token) {
                    cloudModels = result.models
                }
            }
        }
    }

    // MARK: - Searchable Dropdown

    private func searchableDropdown(
        placeholder: String,
        searchText: Binding<String>,
        isOpen: Binding<Bool>,
        items: [(id: String, label: String)],
        selected: Binding<[String]>
    ) -> some View {
        let selectedItems = items.filter { selected.wrappedValue.contains($0.id) }
        let filtered = items.filter {
            searchText.wrappedValue.isEmpty
            || $0.label.localizedCaseInsensitiveContains(searchText.wrappedValue)
        }

        return VStack(alignment: .leading, spacing: 4) {
            // Selected tags
            if !selectedItems.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selectedItems, id: \.id) { item in
                        HStack(spacing: 3) {
                            Text(item.label).font(.caption2).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(Capsule())
                        .onTapGesture {
                            selected.wrappedValue.removeAll { $0 == item.id }
                        }
                    }
                }
            }

            // Search field + toggle
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField(placeholder, text: searchText)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .onTapGesture { isOpen.wrappedValue = true }
                if isOpen.wrappedValue {
                    Button { isOpen.wrappedValue = false } label: {
                        Image(systemName: "chevron.up").font(.caption2)
                    }.buttonStyle(.plain)
                } else {
                    Button { isOpen.wrappedValue = true } label: {
                        Image(systemName: "chevron.down").font(.caption2)
                    }.buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            // Dropdown list
            if isOpen.wrappedValue {
                ScrollView {
                    VStack(spacing: 0) {
                        if filtered.isEmpty {
                            Text(L.isEN ? "No results" : "无结果")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(8)
                        } else {
                            ForEach(filtered, id: \.id) { item in
                                let isSelected = selected.wrappedValue.contains(item.id)
                                HStack {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? .purple : .secondary)
                                        .font(.caption)
                                    Text(item.label)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isSelected {
                                        selected.wrappedValue.removeAll { $0 == item.id }
                                    } else {
                                        selected.wrappedValue.append(item.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
        }
    }

    private func tryGetToken() -> String? {
        let token = AppConfig.authToken
        return token.isEmpty ? nil : token
    }

    // MARK: - Tools Dropdown (installed only)

    private func composioToolkitDropdown() -> some View {
        let selectedItems = authorizedToolkits.filter { agentTools.contains($0.slug) }
        let filtered = authorizedToolkits.filter {
            mcpSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(mcpSearch)
        }

        return VStack(alignment: .leading, spacing: 4) {
            if !selectedItems.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selectedItems) { tk in
                        HStack(spacing: 3) {
                            Text(tk.name).font(.caption2).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(Capsule())
                        .onTapGesture { agentTools.removeAll { $0 == tk.slug } }
                    }
                }
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField(L.isEN ? "Search tools..." : "搜索工具...", text: $mcpSearch)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .onTapGesture { showMCPDropdown = true }
                if showMCPDropdown {
                    Button { showMCPDropdown = false } label: {
                        Image(systemName: "chevron.up").font(.caption2)
                    }.buttonStyle(.plain)
                } else {
                    Button { showMCPDropdown = true } label: {
                        Image(systemName: "chevron.down").font(.caption2)
                    }.buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            if showMCPDropdown {
                ScrollView {
                    VStack(spacing: 0) {
                        if filtered.isEmpty {
                            Text(L.isEN ? "No authorized tools" : "暂无已授权工具")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(8)
                        } else {
                            ForEach(filtered) { tk in
                                let isSelected = agentTools.contains(tk.slug)
                                HStack {
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isSelected ? .purple : .secondary)
                                        .font(.caption)
                                    Text(tk.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isSelected {
                                        agentTools.removeAll { $0 == tk.slug }
                                    } else {
                                        agentTools.append(tk.slug)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
        }
    }

    // MARK: - Actions

    private func generateConfig() async {
        isGenerating = true
        errorMsg = nil
        do {
            let config = try await service.generateAgentConfig(description: descriptionText, language: language)
            agentName = config["name"] as? String ?? ""
            agentIcon = config["icon"] as? String ?? ""
            agentDescription = config["description"] as? String ?? ""
            agentPrompt = config["system_prompt"] as? String ?? ""
            agentTools = config["tools"] as? [String] ?? []
            agentMaxSteps = config["max_steps"] as? Int ?? 10
            generated = true
        } catch {
            errorMsg = L.isEN ? "Generation failed: \(error.localizedDescription)"
                              : "生成失败：\(error.localizedDescription)"
        }
        isGenerating = false
    }

    private func saveAgent() async {
        isSaving = true
        errorMsg = nil
        let body: [String: Any] = [
            "name": agentName,
            "icon": agentIcon,
            "description": agentDescription,
            "system_prompt": agentPrompt,
            "tools": agentTools,
            "model": agentModel,
            "max_steps": agentMaxSteps,
        ]
        do {
            let agent = try await service.createAgent(body: body)
            onCreated(agent)
            dismiss()
        } catch {
            errorMsg = L.isEN ? "Save failed: \(error.localizedDescription)"
                              : "保存失败：\(error.localizedDescription)"
        }
        isSaving = false
    }
}

// MARK: - Edit Agent Sheet

private struct EditAgentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agent: AgentWorker
    let service: BackendService
    let authorizedToolkits: [ComposioToolkit]
    let onUpdated: (AgentWorker) -> Void

    @State private var agentName: String
    @State private var agentIcon: String
    @State private var agentDescription: String
    @State private var agentPrompt: String
    @State private var agentModel: String
    @State private var agentTools: [String]
    @State private var agentMaxSteps: Int
    @State private var isSaving = false
    @State private var errorMsg: String?

    // Dropdowns
    @State private var availableSkills: [Skill] = []
    @State private var mcpSearch = ""
    @State private var skillSearch = ""
    @State private var showMCPDropdown = false
    @State private var showSkillDropdown = false
    @State private var cloudModels: [BackendService.ModelOption] = AppConfig.cachedCloudModels

    init(agent: AgentWorker, service: BackendService, authorizedToolkits: [ComposioToolkit], onUpdated: @escaping (AgentWorker) -> Void) {
        self.agent = agent
        self.service = service
        self.authorizedToolkits = authorizedToolkits
        self.onUpdated = onUpdated
        _agentName = State(initialValue: agent.name)
        _agentIcon = State(initialValue: agent.icon)
        _agentDescription = State(initialValue: agent.description)
        _agentPrompt = State(initialValue: agent.systemPrompt)
        _agentModel = State(initialValue: agent.model)
        _agentTools = State(initialValue: agent.tools)
        _agentMaxSteps = State(initialValue: agent.maxSteps)
    }

    private var modelOptions: [(id: String, name: String)] {
        if AppConfig.useOwnKey {
            if AppConfig.currentProviderKey.isEmpty { return [] }
            let models = CreateAgentSheet.providerModels[AppConfig.provider] ?? CreateAgentSheet.providerModels["claude"]!
            return models.map { (id: $0.0, name: $0.1) }
        }
        if !cloudModels.isEmpty {
            return cloudModels.map { (id: $0.id, name: $0.display_name) }
        }
        let models = CreateAgentSheet.providerModels[AppConfig.provider] ?? CreateAgentSheet.providerModels["claude"]!
        return models.map { (id: $0.0, name: $0.1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L.isEN ? "Edit AI Worker" : "修改 AI 员工")
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Text(agentIcon.isEmpty ? "🤖" : agentIcon)
                            .font(.system(size: 32))
                        VStack(alignment: .leading, spacing: 2) {
                            TextField(L.isEN ? "Name" : "名称", text: $agentName)
                                .font(.headline)
                            TextField(L.isEN ? "Description" : "简介", text: $agentDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    Text(L.isEN ? "System Prompt" : "系统提示词")
                        .font(.subheadline.weight(.medium))
                    TextEditor(text: $agentPrompt)
                        .font(.caption)
                        .frame(minHeight: 80, maxHeight: 120)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

                    // Model
                    Text(L.isEN ? "Model" : "模型")
                        .font(.subheadline.weight(.medium))
                    Picker("", selection: $agentModel) {
                        Text(L.isEN ? "Default (same as Clawbie)" : "默认（跟随 Clawbie）").tag("")
                        ForEach(modelOptions, id: \.id) { opt in
                            Text(opt.name).tag(opt.id)
                        }
                    }
                    .labelsHidden()

                    // Tools
                    HStack {
                        Text(L.isEN ? "Tools" : "工具")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Text(L.isEN ? "Authorize more in Tool Market" : "去工具市场授权更多工具")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    editComposioDropdown()

                    // Skills
                    Text(L.isEN ? "Skills" : "技能")
                        .font(.subheadline.weight(.medium))
                    editSearchableDropdown(
                        placeholder: L.isEN ? "Search skills..." : "搜索技能...",
                        searchText: $skillSearch,
                        isOpen: $showSkillDropdown,
                        items: availableSkills.map { (id: $0.id, label: "\($0.icon) \($0.name)") },
                        selected: $agentTools
                    )

                    // System tools hint
                    HStack(spacing: 4) {
                        Image(systemName: "info.circle")
                        Text(L.isEN ? "System tools (search, code, files...) are inherited by all workers"
                                  : "系统工具（搜索、代码、文件等）所有员工自动继承")
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                    // Max steps
                    HStack {
                        Text(L.isEN ? "Max Steps" : "最大步数")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Stepper("\(agentMaxSteps)", value: $agentMaxSteps, in: 3...30)
                            .font(.subheadline)
                    }

                    if let err = errorMsg {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .task {
                if let skills = try? await service.fetchSkills() { availableSkills = skills }
                if !AppConfig.useOwnKey {
                    let token = AppConfig.authToken
                    if !token.isEmpty, let result = try? await service.fetchCloudModels(accessToken: token) {
                        cloudModels = result.models
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Text(L.isEN ? "Cancel" : "取消")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button {
                    Task { await save() }
                } label: {
                    Group {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L.isEN ? "Save" : "保存")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(
                        agentName.isEmpty || isSaving ? Color.purple.opacity(0.4) : Color.purple
                    ))
                }
                .buttonStyle(.plain)
                .disabled(agentName.isEmpty || isSaving)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
    }

    // MARK: - Tools Dropdown (installed only, Edit)

    private func editComposioDropdown() -> some View {
        let selectedItems = authorizedToolkits.filter { agentTools.contains($0.slug) }
        let filtered = authorizedToolkits.filter {
            mcpSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(mcpSearch)
        }
        return VStack(alignment: .leading, spacing: 4) {
            if !selectedItems.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selectedItems) { tk in
                        HStack(spacing: 3) {
                            Text(tk.name).font(.caption2).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(Capsule())
                        .onTapGesture { agentTools.removeAll { $0 == tk.slug } }
                    }
                }
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField(L.isEN ? "Search tools..." : "搜索工具...", text: $mcpSearch)
                    .font(.caption).textFieldStyle(.plain)
                    .onTapGesture { showMCPDropdown = true }
                Button { showMCPDropdown.toggle() } label: {
                    Image(systemName: showMCPDropdown ? "chevron.up" : "chevron.down").font(.caption2)
                }.buttonStyle(.plain)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            if showMCPDropdown {
                ScrollView {
                    VStack(spacing: 0) {
                        if filtered.isEmpty {
                            Text(L.isEN ? "No authorized tools" : "暂无已授权工具")
                                .font(.caption).foregroundStyle(.tertiary).padding(8)
                        } else {
                            ForEach(filtered) { tk in
                                let sel = agentTools.contains(tk.slug)
                                HStack {
                                    Image(systemName: sel ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(sel ? .purple : .secondary).font(.caption)
                                    Text(tk.name).font(.caption).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if sel { agentTools.removeAll { $0 == tk.slug } }
                                    else { agentTools.append(tk.slug) }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 150)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
        }
    }

    // MARK: - Searchable Dropdown (Edit)

    private func editSearchableDropdown(
        placeholder: String, searchText: Binding<String>, isOpen: Binding<Bool>,
        items: [(id: String, label: String)], selected: Binding<[String]>
    ) -> some View {
        let selectedItems = items.filter { selected.wrappedValue.contains($0.id) }
        let filtered = items.filter {
            searchText.wrappedValue.isEmpty || $0.label.localizedCaseInsensitiveContains(searchText.wrappedValue)
        }
        return VStack(alignment: .leading, spacing: 4) {
            if !selectedItems.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(selectedItems, id: \.id) { item in
                        HStack(spacing: 3) {
                            Text(item.label).font(.caption2).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Color.purple.opacity(0.12))
                        .clipShape(Capsule())
                        .onTapGesture { selected.wrappedValue.removeAll { $0 == item.id } }
                    }
                }
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.caption)
                TextField(placeholder, text: searchText).font(.caption).textFieldStyle(.plain)
                    .onTapGesture { isOpen.wrappedValue = true }
                Button { isOpen.wrappedValue.toggle() } label: {
                    Image(systemName: isOpen.wrappedValue ? "chevron.up" : "chevron.down").font(.caption2)
                }.buttonStyle(.plain)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))

            if isOpen.wrappedValue {
                ScrollView {
                    VStack(spacing: 0) {
                        if filtered.isEmpty {
                            Text(L.isEN ? "No results" : "无结果").font(.caption).foregroundStyle(.tertiary).padding(8)
                        } else {
                            ForEach(filtered, id: \.id) { item in
                                let sel = selected.wrappedValue.contains(item.id)
                                HStack {
                                    Image(systemName: sel ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(sel ? .purple : .secondary).font(.caption)
                                    Text(item.label).font(.caption).lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if sel { selected.wrappedValue.removeAll { $0 == item.id } }
                                    else { selected.wrappedValue.append(item.id) }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
        }
    }

    // MARK: - Save

    private func save() async {
        isSaving = true
        errorMsg = nil
        let body: [String: Any] = [
            "name": agentName,
            "icon": agentIcon,
            "description": agentDescription,
            "system_prompt": agentPrompt,
            "tools": agentTools,
            "model": agentModel,
            "max_steps": agentMaxSteps,
        ]
        do {
            let updated = try await service.updateAgent(id: agent.id, body: body)
            onUpdated(updated)
            dismiss()
        } catch {
            errorMsg = L.isEN ? "Save failed: \(error.localizedDescription)"
                              : "保存失败：\(error.localizedDescription)"
        }
        isSaving = false
    }
}

// MARK: - 系统工具详情 Sheet（Composio 风格）

private struct SystemToolDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tool: ToolItem

    private var info: ToolInfo? {
        ToolInfo.catalog.first { $0.id == tool.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Header
            VStack(spacing: 12) {
                Image(systemName: info?.icon ?? "wrench")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)
                    .frame(width: 64, height: 64)

                Text(info?.name ?? tool.name)
                    .font(.title2.weight(.bold))

                HStack(spacing: 12) {
                    Label(L.isEN ? "System" : "系统", systemImage: "checkmark.seal.fill")
                    Label(tool.type.uppercased(), systemImage: "gearshape")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text(L.isEN ? "Built-in" : "内置工具")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.blue)
            }
            .padding(.bottom, 16)

            Divider().padding(.horizontal)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(info?.description ?? tool.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 10) {
                        infoRow(L.isEN ? "ID" : "标识", value: tool.name)
                        infoRow(L.isEN ? "Type" : "类型", value: tool.type.uppercased())
                    }
                }
                .padding(20)
            }

            Divider()

            HStack {
                Text(L.isEN ? "System Built-in Tool" : "系统内置工具")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .padding(16)
        }
        .frame(width: 400, height: 480)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
        }
    }
}
