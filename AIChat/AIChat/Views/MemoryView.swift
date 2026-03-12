import SwiftUI

// MARK: - Type Visual Config

struct MemoryTypeInfo {
    let label: String
    let icon: String
    let color: Color

    static func from(_ type_: String) -> MemoryTypeInfo {
        switch type_ {
        // Sub-core types
        case "identity":   return .init(label: L.memIdentity,   icon: "person.crop.square.fill", color: .indigo)
        case "contact":    return .init(label: L.memContact,    icon: "person.2.fill",           color: .purple)
        case "preference": return .init(label: L.memPreference, icon: "heart.fill",              color: .pink)
        case "habit":      return .init(label: L.memHabit,      icon: "arrow.clockwise",         color: .orange)
        case "skill":      return .init(label: L.memSkill,      icon: "star.fill",               color: .yellow)
        case "goal":       return .init(label: L.memGoal,       icon: "flag.fill",               color: .green)
        case "value":      return .init(label: L.memValue,      icon: "sparkles",                color: .cyan)
        // General types
        case "task":       return .init(label: L.memTask,       icon: "checklist",               color: .blue)
        case "event":      return .init(label: L.memEvent,      icon: "calendar",                color: .teal)
        case "project":    return .init(label: L.memProject,    icon: "hammer.fill",             color: .blue)
        default:           return .init(label: L.memFact,       icon: "pin.fill",                color: Color(white: 0.5))
        }
    }
}

// MARK: - Main View

struct MemoryView: View {
    var onBack: () -> Void = {}

    @State private var memories: [MemoryItem] = []
    @State private var isLoading = true
    @State private var filterType: String? = nil
    @State private var toastMessage: String? = nil
    @State private var compressing = false

    private let backend = BackendService()

    // Sub-core types first, then general types
    private let subCoreOrder = ["identity", "contact", "preference", "habit", "skill", "goal", "value"]
    private let generalOrder = ["task", "event", "fact", "project"]

    private var allTypes: [String] {
        let present = Set(memories.map(\.memoryType))
        let ordered = subCoreOrder + generalOrder
        return ordered.filter { present.contains($0) }
    }

    private var displayed: [MemoryItem] {
        guard let f = filterType else { return memories }
        return memories.filter { $0.memoryType == f }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !memories.isEmpty {
                typeFilterBar
            }
            Group {
                if isLoading {
                    ProgressView(L.loadingMemories)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if memories.isEmpty {
                    emptyState
                } else if displayed.isEmpty {
                    Text(L.noCategoryMemories)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    memoryList
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = toastMessage {
                Text(toast)
                    .font(.subheadline)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: toastMessage)
        .task { await load() }
    }

    // MARK: - Subviews

    private var typeFilterBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        filterChip(label: L.all, memType: nil, isTierLabel: false)

                        // Sub-core types
                        ForEach(allTypes.filter { subCoreOrder.contains($0) }, id: \.self) { t in
                            filterChip(label: MemoryTypeInfo.from(t).label, memType: t, isTierLabel: false)
                        }

                        // Separator if both tiers have types
                        let hasSubCore = allTypes.contains(where: { subCoreOrder.contains($0) })
                        let hasGeneral = allTypes.contains(where: { generalOrder.contains($0) })
                        if hasSubCore && hasGeneral {
                            Divider().frame(height: 20).padding(.horizontal, 2)
                        }

                        // General types
                        ForEach(allTypes.filter { generalOrder.contains($0) }, id: \.self) { t in
                            filterChip(label: MemoryTypeInfo.from(t).label, memType: t, isTierLabel: false)
                        }
                    }
                    .padding(.leading, 16)
                }

            }
            .padding(.trailing, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func filterChip(label: String, memType: String?, isTierLabel: Bool) -> some View {
        let selected = filterType == memType
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { filterType = memType }
        } label: {
            Text(label)
                .font(.caption)
                .fontWeight(selected ? .semibold : .regular)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(selected ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private var memoryList: some View {
        List {
            // Compress button when a specific type is selected
            if let ft = filterType, displayed.count >= 2 {
                HStack {
                    Spacer()
                    Button {
                        Task { await runCompress(type: ft) }
                    } label: {
                        Label(L.memCompress, systemImage: "arrow.triangle.merge")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(compressing)
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowSeparator(.hidden)
            }

            ForEach(displayed) { item in
                MemoryRow(item: item) {
                    memories.removeAll { $0.id == item.id }
                    Task { try? await backend.deleteMemory(id: item.id) }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "brain")
                .font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(L.noMemories)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(L.chatMoreForMemories)
                .font(.subheadline)
                .foregroundStyle(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func load() async {
        isLoading = true
        for _ in 0..<3 {
            if let result = try? await backend.fetchMemories() {
                memories = result
                break
            }
            // Only retry on network error, not on empty result
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        isLoading = false
    }

    private func runCompress(type: String) async {
        compressing = true
        let label = MemoryTypeInfo.from(type).label
        do {
            let result = try await backend.compressCategory(type: type)
            await load()
            withAnimation {
                toastMessage = L.memCompressed(label, result.before, result.after)
            }
        } catch {
            withAnimation {
                toastMessage = L.memCompressFailed(label)
            }
        }
        compressing = false
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        withAnimation { toastMessage = nil }
    }
}

// MARK: - Memory Row

struct MemoryRow: View {
    let item: MemoryItem
    var onDelete: () -> Void = {}

    private var typeInfo: MemoryTypeInfo { MemoryTypeInfo.from(item.memoryType) }

    private var shortDate: String {
        let raw = item.lastHit.isEmpty ? item.createdAt : item.lastHit
        guard !raw.isEmpty else { return "" }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fmt.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return "" }
        let df = DateFormatter()
        df.dateFormat = "MM/dd HH:mm"
        return df.string(from: date)
    }

    private var weightColor: Color {
        if item.weight >= 0.7 { return .green }
        if item.weight >= 0.4 { return .orange }
        return .secondary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Colored type indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(typeInfo.color)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                // Type badge + tier + stats
                HStack(spacing: 6) {
                    Label(typeInfo.label, systemImage: typeInfo.icon)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(typeInfo.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(typeInfo.color.opacity(0.12))
                        .clipShape(Capsule())

                    // Tier badge
                    Text(item.tier == "sub_core" ? L.memSubCore : L.memGeneral)
                        .font(.system(size: 9))
                        .foregroundStyle(item.tier == "sub_core" ? .orange : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            (item.tier == "sub_core" ? Color.orange : Color.secondary)
                                .opacity(0.1)
                        )
                        .clipShape(Capsule())

                    Spacer()

                    // Weight indicator
                    HStack(spacing: 3) {
                        Circle()
                            .fill(weightColor)
                            .frame(width: 6, height: 6)
                        Text(String(format: "%.2f", item.weight))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }

                    if item.hitCount > 0 {
                        Label("\(item.hitCount)", systemImage: "arrow.up.right.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Button(action: onDelete) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                // Memory text
                Text(item.text)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                // Date
                if !shortDate.isEmpty {
                    Text(shortDate)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
