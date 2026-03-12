import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var auth: AuthViewModel
    @Binding var activePage: SidebarPage
    @ObservedObject var vm: ChatViewModel

    @State private var showPortrait = false
    @State private var showPricing = false
    @State private var showSettings = false
    @AppStorage("aichat.language") private var language = "en"

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    sidebarButton("Clawbie", icon: "bubble.left.and.bubble.right", color: Color.clawAccent,
                                  isActive: activePage == .chat) { activePage = .chat }
                    sidebarButton(L.isEN ? "Clawbie's Toolbox" : "Clawbie的工具箱", icon: "hammer", color: .blue,
                                  isActive: activePage == .tools) {
                        activePage = activePage == .tools ? .chat : .tools
                    }
                    sidebarButton(L.memoryMgmt, icon: "brain", color: .pink,
                                  isActive: activePage == .memory) {
                        activePage = activePage == .memory ? .chat : .memory
                    }
                    sidebarButton(L.clawbieDiary, icon: "book", color: Color.clawAccent) {
                        showPortrait = true
                    }
                }

                Section(header: Text(L.isEN ? "Your Workspace" : "主人工作空间")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ) {
                    sidebarButton(L.projects, icon: "folder", color: .purple,
                                  isActive: activePage == .projects) {
                        activePage = activePage == .projects ? .chat : .projects
                    }
                    sidebarButton(L.watchlist, icon: "eye", color: .green,
                                  isActive: activePage == .watchlist) {
                        activePage = activePage == .watchlist ? .chat : .watchlist
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .sheet(isPresented: $showPortrait) {
                DiaryFeedView()
                    .frame(minWidth: 440, minHeight: 560)
            }

            // ── 用户信息 ────────────────────────────────
            Divider()

            VStack(spacing: 0) {
                if !auth.isLocalMode {
                    // 用户头像 + Token 余额
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(Color.clawAccent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(auth.tokenBalance) tokens")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            if auth.isTrialActive, let days = auth.trialDaysLeft {
                                Text(L.trialDaysLeft(days))
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.orange)
                            } else if auth.isTrialExpired {
                                Text(L.trialExpired)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(.red)
                            } else {
                                Text(L.isEN ? "Sonnet equivalent" : "按 Sonnet 计价")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                } else {
                    // 本地模式：简单用户信息
                    HStack(spacing: 10) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 28))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(auth.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Text(L.isEN ? "Local Mode" : "本地模式")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }

                // 升级套餐
                bottomButton(L.upgrade, icon: "crown", color: auth.isLocalMode ? .gray : Color.clawAccent) {
                    if !auth.isLocalMode { showPricing = true }
                }
                .opacity(auth.isLocalMode ? 0.5 : 1)
                // 设置
                bottomButton(L.settings, icon: "gearshape", color: .secondary) {
                    showSettings = true
                }
                // 语言切换
                bottomButton(language == "en" ? "中文" : "EN", icon: "globe", color: .secondary) {
                    language = language == "en" ? "zh" : "en"
                }
                // 退出
                if auth.isLocalMode {
                    bottomButton(L.isEN ? "Switch to Cloud" : "切换到云模式", icon: "cloud", color: .secondary) {
                        auth.exitLocalMode()
                    }
                } else {
                    bottomButton(L.signOut, icon: "rectangle.portrait.and.arrow.right", color: .secondary) {
                        auth.signOut()
                    }
                }
                // 版本号
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.bottom, 8)
        }
        .background(Color(NSColor.controlBackgroundColor))
        .sheet(isPresented: $showPricing) {
            PricingView()
                .environmentObject(auth)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(vm: vm)
                .environmentObject(auth)
        }
    }

    // MARK: - 底部按钮

    private func bottomButton(_ title: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 侧边栏按钮

    private func sidebarButton(_ title: String, icon: String, color: Color, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isActive ? color.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
