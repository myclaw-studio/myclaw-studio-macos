//
//  ContentView.swift
//  AIChat
//

import SwiftUI
import UniformTypeIdentifiers

enum SidebarPage: Hashable {
    case chat, tools, projects, memory, watchlist
}

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()
    @StateObject private var voice = VoiceService()
    @State private var input = ""
    @State private var selectedImageData: Data?
    @State private var selectedFilePath: String?
    @State private var selectedFileName: String?
    @State private var activePage: SidebarPage = .chat
    @AppStorage("aichat.language") private var language = "en"

    @EnvironmentObject private var auth: AuthViewModel
    @State private var showTrialPricing = false
    @State private var dismissedTrialOverlay = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 0) {
                    SidebarView(activePage: $activePage, vm: vm)
                        .frame(width: 220)

                    Divider()

                    Group {
                        switch activePage {
                        case .chat:     chatView
                        case .tools:    ToolMarketView(onBack: { activePage = .chat })
                        case .projects: ProjectsView(onBack: { activePage = .chat })
                        case .memory:   MemoryView(onBack: { activePage = .chat })
                        case .watchlist: WatchlistView(onBack: { activePage = .chat })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }

            // Trial expired overlay (skip in local mode)
            if !auth.isLocalMode && auth.isTrialExpired && !dismissedTrialOverlay {
                trialExpiredOverlay
            }
        }
        .id(language)
        .task { await syncComposioToolkits() }
        .modifier(ToolbarBackgroundModifier())
        .fullScreenToolbarVisible()
        .sheet(isPresented: $showTrialPricing) {
            PricingView()
                .environmentObject(auth)
        }
    }

    private var trialExpiredOverlay: some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()

            ZStack(alignment: .topTrailing) {
                VStack(spacing: 20) {
                    Image("ClawbieLogo")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 64)

                    Text(L.trialExpired)
                        .font(.title2.bold())

                    Text(L.trialExpiredMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button {
                        showTrialPricing = true
                    } label: {
                        Text(L.subscribeToContinue)
                            .fontWeight(.medium)
                            .frame(minWidth: 200)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.clawAccent)
                }
                .padding(40)

                Button {
                    dismissedTrialOverlay = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(12)
            }
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(radius: 20)
            )
        }
    }

    private var chatView: some View {
        VStack(spacing: 0) {
            if !vm.backendOnline {
                OfflineBanner()
            }

            GeometryReader { outerGeo in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 14) {
                            ForEach(vm.messages) { msg in
                                let streaming = vm.isLoading && msg.id == vm.messages.last?.id
                                MessageBubble(
                                    message: msg,
                                    isStreaming: streaming,
                                    onDelete: streaming ? nil : { vm.deleteMessage(msg.id) }
                                )
                                .id(msg.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .frame(minHeight: outerGeo.size.height, alignment: .top)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: vm.messages.count) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: vm.messages.last?.content) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }

            Divider()

            InputBar(
                input: $input,
                selectedImageData: $selectedImageData,
                selectedFilePath: $selectedFilePath,
                selectedFileName: $selectedFileName,
                isLoading: vm.isLoading,
                isSummarizing: vm.isSummarizing,
                hasMessages: !vm.messages.isEmpty,
                voice: voice,
                onSend: sendIfPossible,
                onStop: { vm.stopStreaming() },
                onClear: { vm.clearChat() },
                onSummarize: { vm.summarizeAndCompact() }
            )
        }
        .onAppear {
            voice.requestPermission()
            voice.onTranscript = { [self] transcript in
                input = voice.inputPrefix + transcript
            }
        }
        .task {
            // 启动时自动生成今天的日记（基于昨天的聊天记录）
            try? await BackendService().generateDiaryEntry(force: false)
        }
    }

    private func syncComposioToolkits() async {
        // Migrate: remove legacy key that lacked mode isolation
        if UserDefaults.standard.stringArray(forKey: "composio_installed_slugs") != nil {
            UserDefaults.standard.removeObject(forKey: "composio_installed_slugs")
        }

        let key = UserDefaults.standard.bool(forKey: "aichat.local_mode")
            ? "composio_installed_slugs_local"
            : "composio_installed_slugs_cloud"
        let slugs = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])

        // Remove toolkits not belonging to current mode
        let currentlyInstalled = ComposioClient.shared.installedList()
        for info in currentlyInstalled {
            if let installedSlug = info["slug"] as? String, !slugs.contains(installedSlug) {
                ComposioClient.shared.uninstall(slug: installedSlug)
            }
        }

        // Install current mode's toolkits
        let service = BackendService()
        for slug in slugs {
            try? await service.installComposioToolkit(slug: slug)
        }
    }

    private func sendIfPossible() {
        // Trial expired: block sending, show pricing (skip in local mode)
        if !auth.isLocalMode && auth.isTrialExpired {
            showTrialPricing = true
            return
        }
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty || selectedImageData != nil || selectedFilePath != nil else { return }
        guard !vm.isLoading else { return }
        let imageData = selectedImageData
        let filePath = selectedFilePath
        let fileName = selectedFileName
        input = ""
        selectedImageData = nil
        selectedFilePath = nil
        selectedFileName = nil
        voice.stopSpeaking()

        if let filePath, let fileName {
            // 非图片文件：路径注入消息
            let msgText = text.isEmpty
                ? (L.isEN ? "Please analyze this file" : "请分析这个文件")
                : text
            vm.send(msgText, attachmentPath: filePath, attachmentName: fileName)
        } else {
            vm.send(text.isEmpty ? L.analyzeImage : text, imageData: imageData)
        }
    }
}

// MARK: - InputBar

struct InputBar: View {
    @Binding var input: String
    @Binding var selectedImageData: Data?
    @Binding var selectedFilePath: String?
    @Binding var selectedFileName: String?
    @State private var fileError: String?
    let isLoading: Bool
    let isSummarizing: Bool
    let hasMessages: Bool
    let voice: VoiceService
    let onSend: () -> Void
    let onStop: () -> Void
    let onClear: () -> Void
    let onSummarize: () -> Void

    private var canSend: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty || selectedImageData != nil || selectedFilePath != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // 附件预览（图片或文件）
            if let imgData = selectedImageData, let nsImg = NSImage(data: imgData) {
                HStack {
                    Spacer()
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: nsImg)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            selectedImageData = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                    .padding(.trailing, 14)
                    .padding(.top, 8)
                }
            } else if let fileName = selectedFileName {
                HStack {
                    Spacer()
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.fill")
                                .font(.system(size: 24))
                                .foregroundStyle(Color.clawAccent)
                            Text(fileName)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.secondarySystemBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        Button {
                            selectedFilePath = nil
                            selectedFileName = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 6, y: -6)
                    }
                    .padding(.trailing, 14)
                    .padding(.top, 8)
                }
            }

            HStack(alignment: .center, spacing: 10) {
                // 清空按钮
                if hasMessages {
                    Button(action: onClear) {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .help(L.clearChat)

                    // 总结压缩按钮
                    Button(action: onSummarize) {
                        if isSummarizing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: "text.badge.minus")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading || isSummarizing)
                    .help(L.summarizeChat)
                }

                // 文件选择按钮
                Button {
                    pickFile()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help(L.isEN ? "Attach file" : "添加附件")

                // 语音按钮
                Button {
                    if voice.isListening { voice.stopListening() }
                    else { try? voice.startListening(currentInput: input) }
                } label: {
                    Image(systemName: voice.isListening ? "mic.fill" : "mic")
                        .font(.system(size: 18))
                        .foregroundStyle(voice.isListening ? Color.red : .secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)

                // 输入框
                TextField(L.sendMessage, text: $input, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.secondarySystemBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .onSubmit { if !isLoading { onSend() } }

                // 发送 / 停止按钮
                if isLoading {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.red)
                    }
                    .buttonStyle(.plain)
                    .help(L.stopGeneration)
                } else {
                    Button(action: onSend) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(
                                canSend ? Color.clawAccent : Color.gray.opacity(0.4)
                            )
                    }
                    .disabled(!canSend)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .alert(L.isEN ? "File Error" : "文件错误", isPresented: Binding(
            get: { fileError != nil },
            set: { if !$0 { fileError = nil } }
        )) {
            Button("OK") { fileError = nil }
        } message: {
            Text(fileError ?? "")
        }
    }

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "tiff", "bmp"]
    private static let pdfExtensions: Set<String> = ["pdf"]

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.item]  // 允许所有文件类型
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L.isEN ? "Select a file to send to Clawbie" : "选择要发送给 Clawbie 的文件"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let ext = url.pathExtension.lowercased()

        // 检查文件大小
        let maxSize = 10_000_000 // 10MB
        let fileSize: Int
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int {
            fileSize = size
        } else {
            fileError = L.isEN ? "Cannot read this file" : "无法读取此文件"
            return
        }

        if fileSize > maxSize {
            let sizeMB = String(format: "%.1f", Double(fileSize) / 1_000_000)
            fileError = L.isEN
                ? "File too large (\(sizeMB) MB). Maximum size is 10 MB."
                : "文件过大（\(sizeMB) MB），最大支持 10 MB"
            return
        }

        if Self.imageExtensions.contains(ext) {
            // 图片：走原有 base64 直传流程
            guard let data = try? Data(contentsOf: url) else {
                fileError = L.isEN ? "Cannot read this file" : "无法读取此文件"
                return
            }
            if data.count > 4_000_000, let nsImg = NSImage(data: data),
               let tiff = nsImg.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                selectedImageData = jpeg
            } else {
                selectedImageData = data
            }
            selectedFilePath = nil
            selectedFileName = nil
        } else if Self.pdfExtensions.contains(ext) {
            // PDF：走 base64 直传（Claude 原生支持）
            guard let data = try? Data(contentsOf: url) else {
                fileError = L.isEN ? "Cannot read this file" : "无法读取此文件"
                return
            }
            selectedImageData = data
            selectedFilePath = nil
            selectedFileName = nil
        } else {
            // 其他所有文件：记录路径，让大模型用工具读取
            selectedImageData = nil
            selectedFilePath = url.path
            selectedFileName = url.lastPathComponent
        }
    }
}

// MARK: - DeletableBubble

// DeletableBubble removed — delete button is now inside MessageBubble

// MARK: - 辅助视图

struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.clawAccent)
            Text(L.backendOffline)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.clawAccentLight)
    }
}

// MARK: - Proposal Strip

struct ProposalStrip: View {
    let proposals: [SkillProposal]
    let onAccept: (SkillProposal) -> Void
    let onDismiss: (SkillProposal) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(proposals) { proposal in
                ProposalRow(proposal: proposal,
                            onAccept: { onAccept(proposal) },
                            onDismiss: { onDismiss(proposal) })
                if proposal.id != proposals.last?.id {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(Color.clawAccentLight)
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.clawAccent.opacity(0.2)), alignment: .top)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct ProposalRow: View {
    let proposal: SkillProposal
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(proposal.icon).font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text(L.suggestSkill(proposal.name))
                    .font(.caption).fontWeight(.medium)
                if !proposal.description.isEmpty {
                    Text(proposal.description)
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Spacer()

            Button(L.save) { onAccept() }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
                .tint(Color.clawAccent)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

struct TypingDots: View {
    @State private var show = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().frame(width: 7, height: 7)
                    .foregroundStyle(Color.clawAccent.opacity(0.6))
                    .scaleEffect(show ? 1 : 0.5)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.15), value: show)
            }
        }
        .padding(10)
        .background(Color.secondarySystemBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear { show = true }
    }
}
