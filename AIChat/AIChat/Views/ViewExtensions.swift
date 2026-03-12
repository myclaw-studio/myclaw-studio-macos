import SwiftUI

// MARK: - Clawbie 主题配色

extension Color {
    /// 主色调 - 暖橙（🦞 Clawbie 品牌色）
    static let clawAccent = Color(red: 1.0, green: 0.42, blue: 0.21)       // #FF6B35
    /// 主色调浅色背景
    static let clawAccentLight = Color(red: 1.0, green: 0.42, blue: 0.21).opacity(0.10)
    /// 用户气泡色 - 深蓝
    static let clawUserBubble = Color(red: 0.25, green: 0.47, blue: 0.96)  // #4078F5
    /// AI 气泡色 — 浅暖灰，浅色模式和深色模式均有区分度
    static let clawAIBubble = Color(NSColor.init(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1.0)   // 深色模式：深灰
            : NSColor(red: 0.94, green: 0.94, blue: 0.96, alpha: 1.0)   // 浅色模式：淡灰 #F0F0F5
    })
    /// 侧边栏背景
    static let clawSidebarBg = Color(NSColor.windowBackgroundColor)
}

// MARK: - 跨平台颜色兼容

extension Color {
    static var systemBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }
    static var secondarySystemBackground: Color {
        #if os(iOS)
        Color(UIColor.secondarySystemBackground)
        #else
        Color(NSColor.controlBackgroundColor)
        #endif
    }
    static var tertiarySystemBackground: Color {
        #if os(iOS)
        Color(UIColor.tertiarySystemBackground)
        #else
        Color(NSColor.underPageBackgroundColor)
        #endif
    }
    static var systemYellow: Color { .yellow }
}

// MARK: - View 扩展

extension View {
    func noAutocapitalization() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

// MARK: - 全屏时工具栏常驻

struct FullScreenToolbarFixer: NSViewRepresentable {
    class FixerView: NSView {
        private var observer: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = self.window, observer == nil else { return }
            // 进入全屏后，强制移除 autoHideToolbar
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window,
                queue: .main
            ) { _ in
                NSApp.presentationOptions.remove(.autoHideToolbar)
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeNSView(context: Context) -> NSView { FixerView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    func fullScreenToolbarVisible() -> some View {
        self.background(FullScreenToolbarFixer())
    }
}

// MARK: - Toolbar Background (macOS 15+)

struct ToolbarBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=5.11)
        if #available(macOS 15.0, *) {
            content.toolbarBackground(Color(NSColor.controlBackgroundColor), for: .windowToolbar)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - 页面标题栏（子页面通用）

struct PageTitleBar: View {
    let title: String
    var onBack: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("聊天")
                    }
                }
                .buttonStyle(.plain)
            }

            Text(title).font(.headline)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
