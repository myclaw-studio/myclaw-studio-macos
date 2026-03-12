import SwiftUI

struct DiaryFeedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [DiaryEntry] = []
    @State private var isLoading = true
    @State private var isGenerating = false
    @State private var spinDegrees = 0.0
    @State private var toastMessage: String? = nil

    private let service = BackendService()

    var body: some View {
        ZStack(alignment: .top) {
            // Background
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.08, blue: 0.18),
                    Color(red: 0.15, green: 0.10, blue: 0.22),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Top bar ─────────────────────────────────────────────
                HStack {
                    Button(L.done) { dismiss() }
                        .font(.body)
                        .foregroundStyle(.white.opacity(0.75))
                        .buttonStyle(.plain)

                    Spacer()

                    Button {
                        guard !isGenerating && !isLoading else { return }
                        Task { await generate(force: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body.weight(.medium))
                            .foregroundStyle(isGenerating ? .white.opacity(0.3) : .white.opacity(0.7))
                            .rotationEffect(.degrees(spinDegrees))
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || isGenerating)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)

                // ── Header ──────────────────────────────────────────────
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.pink.opacity(0.2))
                            .frame(width: 68, height: 68)
                        Image("ClawbieLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 48)
                    }
                    .padding(.top, 12)

                    Text(L.clawbieDiary)
                        .font(.title2).fontWeight(.semibold)
                        .foregroundStyle(.white)

                    Text(L.diarySubtitle)
                        .font(.subheadline).italic()
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.bottom, 18)

                // ── Content ─────────────────────────────────────────────
                if isLoading {
                    Spacer()
                    VStack(spacing: 14) {
                        ProgressView()
                            .tint(.white.opacity(0.5))
                            .scaleEffect(1.2)
                        Text(L.diaryLoading)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    Spacer()
                } else if entries.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        Text("📖")
                            .font(.system(size: 40))
                        Text(L.noDiary)
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(L.diaryAutoGenerate)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 14) {
                            // 生成中提示
                            if isGenerating {
                                HStack(spacing: 8) {
                                    ProgressView()
                                        .tint(.white.opacity(0.5))
                                        .scaleEffect(0.8)
                                    Text(L.diaryWriting)
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                                .padding(.vertical, 8)
                            }

                            ForEach(entries) { entry in
                                DiaryEntryCard(entry: entry)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                    }
                }
            }
        }
        .task {
            await loadAndGenerate()
        }
        .overlay(alignment: .top) {
            if let msg = toastMessage {
                Text(msg)
                    .font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    // MARK: - Data

    private func loadAndGenerate() async {
        isLoading = true
        entries = (try? await service.fetchDiary()) ?? []
        isLoading = false

        // 自动生成今天的日记（非 force）
        await generate(force: false)
    }

    private func generate(force: Bool) async {
        isGenerating = true
        if force {
            withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: false)) {
                spinDegrees = 360
            }
        }

        // Trigger generation
        let generated = try? await service.generateDiaryEntry(force: force)

        // Always re-fetch full list to ensure UI consistency
        let updated = (try? await service.fetchDiary()) ?? []
        withAnimation {
            entries = updated
        }

        // Show toast on force update success
        if force && generated != nil {
            withAnimation { toastMessage = L.diaryUpdated }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            withAnimation { toastMessage = nil }
        }

        withAnimation(.default) { spinDegrees = 0 }
        isGenerating = false
    }
}

// MARK: - Diary Entry Card

struct DiaryEntryCard: View {
    let entry: DiaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Card header: weather + date + mood
            HStack(spacing: 8) {
                Text(entry.weather)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.formattedDate)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white.opacity(0.9))
                    Text(entry.mood)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                Text(entry.date)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.25))
            }

            // Card body: diary content
            Text(entry.content)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.pink.opacity(0.2), lineWidth: 1)
                )
        )
    }
}
