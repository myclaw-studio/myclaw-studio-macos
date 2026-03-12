import SwiftUI

struct SkillMarketView: View {
    @EnvironmentObject private var auth: AuthViewModel
    var onBack: () -> Void = {}

    @State private var mySkills: [Skill] = []
    @State private var clawHubSkills: [ClawHubSkill] = []
    @State private var isLoading = false
    @State private var marketLoading = false
    @State private var showMarketSheet = false
    @State private var searchText = ""
    @State private var activeTab = "popular"
    @State private var installingSlug: String?

    // Detail sheets
    @State private var selectedSkill: Skill?
    @State private var selectedClawHubSkill: ClawHubSkill?

    private let service = BackendService()

    private let cardColumns = [
        GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 12)
    ]

    private var tabs: [(key: String, label: String)] {
        [
            ("popular", L.isEN ? "Popular" : "热门"),
            ("top-stars", L.isEN ? "Top Stars" : "最多收藏"),
            ("newest", L.isEN ? "Newest" : "最新"),
            ("certified", L.isEN ? "Certified" : "官方认证"),
        ]
    }

    @State private var importError: String?

    var body: some View {
        mainBody
    }

    private func importSkillFiles() {
        importError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .folder]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.message = L.isEN ? "Select SKILL.md files or skill folders" : "选择 SKILL.md 文件或技能文件夹"

        guard panel.runModal() == .OK else { return }

        var imported = 0
        for url in panel.urls {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

            let mdURL: URL
            if isDir.boolValue {
                // 文件夹：查找 SKILL.md
                mdURL = url.appendingPathComponent("SKILL.md")
                guard FileManager.default.fileExists(atPath: mdURL.path) else {
                    importError = L.isEN
                        ? "No SKILL.md found in folder: \(url.lastPathComponent)"
                        : "文件夹中未找到 SKILL.md：\(url.lastPathComponent)"
                    continue
                }
            } else {
                mdURL = url
            }

            guard let content = try? String(contentsOf: mdURL, encoding: .utf8) else {
                importError = L.isEN
                    ? "Cannot read file: \(mdURL.lastPathComponent)"
                    : "无法读取文件：\(mdURL.lastPathComponent)"
                continue
            }

            guard let skill = parseSkillMD(content, folderName: url.lastPathComponent) else {
                importError = L.isEN
                    ? "Invalid SKILL.md: \(mdURL.lastPathComponent). Must have YAML frontmatter with 'name'."
                    : "无效的 SKILL.md：\(mdURL.lastPathComponent)，需包含 name 字段的 YAML frontmatter"
                continue
            }

            Task {
                try? await service.createSkill(skill)
                await reloadMySkills()
            }
            imported += 1
        }
        if imported > 0 && importError == nil {
            importError = nil
        }
    }

    /// 解析 SKILL.md：YAML frontmatter + Markdown 正文作为 system_prompt
    private func parseSkillMD(_ content: String, folderName: String) -> [String: Any]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

        var frontmatter: [String: String] = [:]
        var body = trimmed

        // 解析 YAML frontmatter（--- ... ---）
        if trimmed.hasPrefix("---") {
            let parts = trimmed.dropFirst(3).components(separatedBy: "\n---")
            if parts.count >= 2 {
                let yamlBlock = parts[0]
                body = parts.dropFirst().joined(separator: "\n---").trimmingCharacters(in: .whitespacesAndNewlines)

                for line in yamlBlock.components(separatedBy: .newlines) {
                    let kv = line.split(separator: ":", maxSplits: 1)
                    if kv.count == 2 {
                        let key = kv[0].trimmingCharacters(in: .whitespaces)
                        let val = kv[1].trimmingCharacters(in: .whitespaces)
                        frontmatter[key] = val
                    }
                }
            }
        }

        // system_prompt 就是 md 正文
        guard !body.isEmpty else { return nil }

        // name: frontmatter 优先，fallback 到文件夹名
        let name = frontmatter["name"] ?? folderName.replacingOccurrences(of: ".md", with: "")
        let description = frontmatter["description"] ?? ""

        var skill: [String: Any] = [
            "id": UUID().uuidString,
            "name": name,
            "description": description,
            "icon": "⚡",
            "system_prompt": body,
            "tools": [String](),
            "builtin": false
        ]

        if let icon = frontmatter["icon"] { skill["icon"] = icon }

        return skill
    }

    // MARK: - Main Body

    private var mainBody: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // 系统技能
                    let builtinSkills = mySkills.filter { $0.builtin }
                    if !builtinSkills.isEmpty {
                        sectionHeader(L.isEN ? "System Skills" : "系统技能")
                        LazyVGrid(columns: cardColumns, spacing: 12) {
                            ForEach(builtinSkills) { skill in
                                mySkillCard(skill)
                                    .onTapGesture { selectedSkill = skill }
                            }
                        }
                    }

                    // 已安装技能
                    sectionHeader(L.installed)

                    if let err = importError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                    }

                    LazyVGrid(columns: cardColumns, spacing: 12) {
                        // + 添加技能卡片（市场 / 本地模式灰色提示）
                        if auth.isLocalMode {
                            VStack(spacing: 8) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.gray)
                                    .frame(width: 40, height: 40)
                                Text(L.isEN ? "Add Skill" : "添加技能")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.gray)
                                Text("Cloud mode to use 10000+ skills")
                                    .font(.caption2)
                                    .foregroundStyle(.gray)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(height: 28)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.gray.opacity(0.08)))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(.gray.opacity(0.3)))
                        } else {
                            Button { openMarket() } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.purple)
                                        .frame(width: 40, height: 40)
                                    Text(L.isEN ? "Add Skill" : "添加技能")
                                        .font(.subheadline.weight(.medium))
                                    Text(L.isEN ? "Browse & install" : "浏览并安装")
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
                        }

                        // + 导入技能卡片（本地模式额外提供）
                        if auth.isLocalMode {
                            Button { importSkillFiles() } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "square.and.arrow.down")
                                        .font(.system(size: 28))
                                        .foregroundStyle(.orange)
                                        .frame(width: 40, height: 40)
                                    Text(L.isEN ? "Import Skill" : "导入技能")
                                        .font(.subheadline.weight(.medium))
                                    Text(L.isEN ? "SKILL.md or folder" : "SKILL.md 或文件夹")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(height: 28)
                                    Text(L.isEN ? "Import" : "导入")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6])).foregroundStyle(.orange.opacity(0.3)))
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(mySkills.filter { !$0.builtin }) { skill in
                            mySkillCard(skill)
                                .onTapGesture { selectedSkill = skill }
                        }
                    }
                }
                .padding(12)
            }
        }
        .task { await loadMySkills() }
        .sheet(isPresented: $showMarketSheet) {
            VStack(spacing: 0) {
                HStack {
                    Text(L.isEN ? "ClawHub Skill Market" : "ClawHub 技能市场")
                        .font(.headline)
                    Spacer()
                    Button(L.close) { showMarketSheet = false }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                marketSheetContent
            }
            .frame(minWidth: 560, minHeight: 520)
        }
        .sheet(item: $selectedSkill) { skill in
            SkillDetailSheet(skill: skill) {
                try? await service.deleteSkill(id: skill.id)
                await reloadMySkills()
            }
        }
    }

    // MARK: - 我的技能卡片

    private func mySkillCard(_ skill: Skill) -> some View {
        VStack(spacing: 8) {
            Text(skill.icon)
                .font(.system(size: 24))
                .frame(width: 40, height: 40)

            Text(skill.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text(skill.description)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 28)

            if skill.builtin {
                Text("Anthropic")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.1))
                    .clipShape(Capsule())
            } else {
                Button(role: .destructive) {
                    Task {
                        try? await service.deleteSkill(id: skill.id)
                        await reloadMySkills()
                    }
                } label: {
                    Text(L.remove).font(.caption2)
                }.buttonStyle(.bordered).controlSize(.mini)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }

    // MARK: - ClawHub 市场 Sheet

    private var marketSheetContent: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L.isEN ? "Search skills..." : "搜索技能...", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await loadMarket() } }
                    .onChange(of: searchText) { _, newValue in
                        Task { await loadMarket() }
                    }
            }
            .padding(8)
            .background(.bar)

            // 分类 Tab（搜索时隐藏）
            if searchText.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tabs, id: \.key) { tab in
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    activeTab = tab.key
                                    Task { await loadMarket() }
                                }
                            } label: {
                                Text(tab.label)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(activeTab == tab.key ? Color.accentColor : Color.secondary.opacity(0.12))
                                    .foregroundStyle(activeTab == tab.key ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .background(.bar)
            }

            // 技能列表
            if marketLoading {
                ProgressView(L.isEN ? "Loading..." : "加载中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if clawHubSkills.isEmpty {
                Text(searchText.isEmpty ? (L.isEN ? "No skills" : "暂无技能") : (L.isEN ? "No results" : "未找到相关技能"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 400), spacing: 12)], spacing: 12) {
                        ForEach(clawHubSkills) { skill in
                            clawHubSkillCard(skill)
                                .onTapGesture { selectedClawHubSkill = skill }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .sheet(item: $selectedClawHubSkill) { skill in
            ClawHubDetailSheet(skill: skill) {
                await handleInstall(skill)
            }
        }
    }

    // MARK: - ClawHub 技能卡片

    private func clawHubSkillCard(_ skill: ClawHubSkill) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(skill.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if skill.isCertified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }

                Text(skill.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Label("\(formatCount(skill.downloads))", systemImage: "arrow.down.circle")
                    Label("\(formatCount(skill.stars))", systemImage: "star")
                    if !skill.ownerHandle.isEmpty {
                        Text("@\(skill.ownerHandle)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            if skill.installed {
                Text(L.isEN ? "Added" : "已添加")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.1))
                    .clipShape(Capsule())
            } else if installingSlug == skill.slug {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await handleInstall(skill) }
                } label: {
                    Text(L.isEN ? "Add" : "添加")
                        .font(.caption2.weight(.medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(skill.installed ? Color.green.opacity(0.3) : Color.secondary.opacity(0.15), lineWidth: 1)
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

    // MARK: - 数据操作

    private func loadMySkills() async {
        guard mySkills.isEmpty else { return }
        await reloadMySkills()
    }

    private func reloadMySkills() async {
        isLoading = true
        mySkills = (try? await service.fetchSkills()) ?? []
        isLoading = false
    }

    private func openMarket() {
        showMarketSheet = true
        Task { await loadMarket() }
    }

    private func loadMarket() async {
        marketLoading = true
        if searchText.isEmpty {
            clawHubSkills = (try? await service.fetchClawHubSkills(tab: activeTab)) ?? []
        } else {
            clawHubSkills = (try? await service.searchClawHubSkills(q: searchText)) ?? []
        }
        marketLoading = false
    }

    private func handleInstall(_ skill: ClawHubSkill) async {
        installingSlug = skill.slug
        try? await service.installClawHubSkill(skill)
        await loadMarket()
        await reloadMySkills()
        installingSlug = nil
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1fw", Double(n) / 10000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

// MARK: - 已安装技能详情 Sheet（Composio 风格）

private struct SkillDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skill: Skill
    let onDelete: () async -> Void

    @State private var isDeleting = false

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
                Text(skill.icon)
                    .font(.system(size: 48))

                Text(skill.name)
                    .font(.title2.weight(.bold))

                HStack(spacing: 12) {
                    if skill.builtin {
                        Label("Anthropic", systemImage: "checkmark.seal.fill")
                    }
                    if !skill.tools.isEmpty {
                        Label("\(skill.tools.count) tools", systemImage: "wrench")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if skill.builtin {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(L.isEN ? "System Skill" : "系统技能")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.blue)
                }
            }
            .padding(.bottom, 16)

            Divider().padding(.horizontal)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(skill.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if !skill.tools.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L.isEN ? "Tools" : "使用工具")
                                .font(.subheadline.weight(.medium))
                            ForEach(skill.tools, id: \.self) { tool in
                                HStack(spacing: 8) {
                                    Image(systemName: "wrench")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Text(tool)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Bottom action
            HStack(spacing: 12) {
                if skill.builtin {
                    Text(L.isEN ? "System Skill" : "系统内置技能")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    Button(role: .destructive) {
                        Task {
                            isDeleting = true
                            await onDelete()
                            isDeleting = false
                            dismiss()
                        }
                    } label: {
                        if isDeleting {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(L.remove)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isDeleting)
                }
            }
            .padding(16)
        }
        .frame(width: 400, height: 480)
    }
}

// MARK: - ClawHub 技能详情 Sheet（Composio 风格）

private struct ClawHubDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let skill: ClawHubSkill
    let onInstall: () async -> Void

    @State private var isInstalling = false

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
                Text("⚡")
                    .font(.system(size: 48))

                Text(skill.displayName)
                    .font(.title2.weight(.bold))

                HStack(spacing: 12) {
                    if !skill.ownerHandle.isEmpty {
                        Label("@\(skill.ownerHandle)", systemImage: "person")
                    }
                    if skill.isCertified {
                        Label(L.isEN ? "Certified" : "官方认证", systemImage: "checkmark.seal.fill")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if skill.installed {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(L.isEN ? "Added" : "已添加")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
                }
            }
            .padding(.bottom, 16)

            Divider().padding(.horizontal)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(skill.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(spacing: 10) {
                        infoRow(L.isEN ? "Downloads" : "下载量", value: formatCount(skill.downloads))
                        infoRow(L.isEN ? "Stars" : "收藏", value: formatCount(skill.stars))
                        if !skill.clawhubUrl.isEmpty {
                            infoRow(L.isEN ? "Source" : "来源", value: skill.clawhubUrl)
                        }
                    }
                }
                .padding(20)
            }

            Divider()

            // Bottom action
            HStack(spacing: 12) {
                if skill.installed {
                    Text(L.isEN ? "Added" : "已添加")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    Button {
                        Task { await install() }
                    } label: {
                        if isInstalling {
                            ProgressView().controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text(L.isEN ? "Add" : "添加")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isInstalling)
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
                .lineLimit(1)
        }
    }

    private func install() async {
        isInstalling = true
        await onInstall()
        try? await Task.sleep(nanoseconds: 500_000_000)
        isInstalling = false
        dismiss()
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 10000 { return String(format: "%.1fw", Double(n) / 10000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}
