import SwiftUI

struct WatchlistView: View {
    var onBack: () -> Void = {}

    @State private var items: [WatchItem] = []
    @State private var isLoading = true
    @State private var showAddSheet = false
    @State private var pollEnabled = false
    @State private var collapsedLogIds: Set<String> = []
    @State private var logCache: [String: [[String: String]]] = [:]
    @State private var editingItem: WatchItem? = nil

    private let backend = BackendService()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                HStack(spacing: 6) {
                    Text(L.heartbeat)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: $pollEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                        .onChange(of: pollEnabled) {
                            Task {
                                pollEnabled = (try? await backend.togglePoll()) ?? pollEnabled
                            }
                        }
                    if !pollEnabled {
                        Text(L.heartbeatOffHint)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Button { showAddSheet = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .medium))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Content
            Group {
                if isLoading {
                    ProgressView(L.loading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if items.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showAddSheet) {
            AddWatchSheet { query in
                Task {
                    let item = try? await backend.createWatchItem(query: query)
                    if let item { items.insert(item, at: 0) }
                }
            }
        }
        .sheet(item: $editingItem) { item in
            EditWatchSheet(item: item) { newQuery in
                Task {
                    if let updated = try? await backend.reparseWatchItem(id: item.id, query: newQuery),
                       let idx = items.firstIndex(where: { $0.id == item.id }) {
                        items[idx] = updated
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(L.noWatchItems)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(L.addWatchHint)
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var itemList: some View {
        List {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 0) {
                    watchRow(item: item)

                    // 日志默认展开，点击可收起
                    if !collapsedLogIds.contains(item.id) {
                        logSection(for: item)
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
            .onDelete { offsets in
                let toDelete = offsets.map { items[$0] }
                items.removeAll { m in toDelete.contains(where: { $0.id == m.id }) }
                Task {
                    for item in toDelete { try? await backend.deleteWatchItem(id: item.id) }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Row

    private func watchRow(item: WatchItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(item.enabled ? Color.green : Color.gray)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.displayName)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(2)
                    Spacer()
                    // 编辑
                    Button { editingItem = item } label: {
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    // 日志展开/收起
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if collapsedLogIds.contains(item.id) {
                                collapsedLogIds.remove(item.id)
                                loadLogs(for: item.id)
                            } else {
                                collapsedLogIds.insert(item.id)
                            }
                        }
                    } label: {
                        Image(systemName: collapsedLogIds.contains(item.id) ? "text.badge.star" : "text.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(collapsedLogIds.contains(item.id) ? Color.secondary : Color.blue)
                    }
                    .buttonStyle(.plain)
                    // 开关
                    Toggle("", isOn: Binding(
                        get: { item.enabled },
                        set: { enabled in
                            Task {
                                try? await backend.toggleWatchItem(id: item.id, enabled: enabled)
                                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                                    items[idx].enabled = enabled
                                }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    // 删除
                    Button {
                        items.removeAll { $0.id == item.id }
                        Task { try? await backend.deleteWatchItem(id: item.id) }
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 12) {
                    Label(shortDate(item), systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Label(item.frequencyLabel, systemImage: item.type == "cron" ? "calendar.badge.clock" : "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if item.notifyCount > 0 {
                        Label("\(item.notifyCount)", systemImage: "envelope.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Log Section

    private func logSection(for item: WatchItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider().padding(.vertical, 4)
            let logs = logCache[item.id] ?? []
            if logs.isEmpty {
                // 未执行过：显示等待提示
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.lastCheckedAt == nil
                         ? (L.isEN ? "Waiting for Clawbie to execute..." : "等待 Clawbie 执行...")
                         : L.noLogs)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 16)
            } else {
                ForEach(Array(logs.prefix(5).enumerated()), id: \.offset) { _, log in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill((log["status"] == "success" || log["status"] == "ok") ? Color.green : Color.orange)
                            .frame(width: 5, height: 5)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatTime(log["time"] ?? ""))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(log["result"] ?? "")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 16)
                }
            }
        }
        .padding(.bottom, 4)
        .onAppear { loadLogs(for: item.id) }
    }

    // MARK: - Helpers

    private func shortDate(_ item: WatchItem) -> String {
        guard let raw = item.lastCheckedAt, !raw.isEmpty else { return L.notYetChecked }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fmt.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return String(raw.prefix(16)).replacingOccurrences(of: "T", with: " ") }
        let df = DateFormatter()
        df.dateFormat = "MM/dd HH:mm"
        return df.string(from: date)
    }

    private func formatTime(_ iso: String) -> String {
        guard !iso.isEmpty else { return "" }
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    private func loadLogs(for itemId: String) {
        Task {
            logCache[itemId] = (try? await backend.fetchWatchItemLogs(id: itemId)) ?? []
        }
    }

    private func load() async {
        isLoading = true
        items = (try? await backend.fetchWatchlist()) ?? []
        pollEnabled = (try? await backend.fetchPollStatus()) ?? false
        isLoading = false
    }
}

// MARK: - Add Watch Sheet

struct AddWatchSheet: View {
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isAdding = false

    var body: some View {
        VStack(spacing: 16) {
            Text(L.newWatchItem)
                .font(.headline)

            TextField(L.watchQuery, text: $query, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .disabled(isAdding)

            if isAdding {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.parsing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAdding)
                Spacer()
                Button(L.add) {
                    let q = query.trimmingCharacters(in: .whitespaces)
                    guard !q.isEmpty else { return }
                    isAdding = true
                    onAdd(q)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - Edit Watch Sheet

struct EditWatchSheet: View {
    let item: WatchItem
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var isSaving = false

    var body: some View {
        VStack(spacing: 16) {
            Text(L.editTask)
                .font(.headline)

            TextField(L.watchQuery, text: $query, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .disabled(isSaving)

            if isSaving {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L.parsing)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                Button(L.save) {
                    let q = query.trimmingCharacters(in: .whitespaces)
                    guard !q.isEmpty else { return }
                    isSaving = true
                    onSave(q)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { query = item.query }
    }
}

// MARK: - Notify Config Sheet

struct NotifyConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var config = WatchlistConfig.empty
    @State private var isLoading = true
    @State private var portText = "465"

    private let backend = BackendService()

    var body: some View {
        VStack(spacing: 16) {
            Text(L.notifySettings)
                .font(.headline)

            if isLoading {
                ProgressView()
                    .frame(height: 100)
            } else {
                Form {
                    Toggle(L.enableNotify, isOn: $config.enabled)

                    TextField(L.smtpHost, text: $config.smtpHost)
                        .textFieldStyle(.roundedBorder)
                    TextField(L.smtpPort, text: $portText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    TextField(L.smtpUser, text: $config.smtpUser)
                        .textFieldStyle(.roundedBorder)
                    SecureField(L.smtpPass, text: $config.smtpPass)
                        .textFieldStyle(.roundedBorder)
                    TextField(L.notifyEmail, text: $config.notifyEmail)
                        .textFieldStyle(.roundedBorder)
                }
                .formStyle(.grouped)
            }

            HStack {
                Button(L.cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L.save) {
                    config.smtpPort = Int(portText) ?? 465
                    Task {
                        try? await backend.saveWatchlistConfig(config)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420, height: 360)
        .task {
            config = (try? await backend.fetchWatchlistConfig()) ?? .empty
            portText = "\(config.smtpPort)"
            isLoading = false
        }
    }
}
