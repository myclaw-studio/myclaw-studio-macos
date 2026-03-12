import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var auth: AuthViewModel

    @State private var agreedToTerms = false
    @State private var showTermsHint = false
    @State private var selectedMode = 0 // 0 = cloud, 1 = local

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo
            VStack(spacing: 10) {
                Image("ClawbieLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 88, height: 88)
                    .shadow(color: Color.clawAccent.opacity(0.3), radius: 12, y: 4)
                Text("My Claw")
                    .font(.system(size: 26, weight: .bold))
                Text("Your Personal AI Assistant")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer().frame(height: 28)

            // Mode selector
            Picker("", selection: $selectedMode) {
                Text(L.isEN ? "Cloud Mode" : "云模式").tag(0)
                Text(L.isEN ? "Local Mode" : "本地模式").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .padding(.bottom, 16)

            // Mode description (only for local mode)
            if selectedMode == 1 {
                Text(L.isEN ? "Use your own API Key, no account needed" : "使用自己的 API Key，无需账户")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 16)
            } else {
                Spacer().frame(height: 16)
            }

            // 错误提示
            if let msg = auth.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(msg)
                }
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.bottom, 12)
            }

            if selectedMode == 0 {
                // Cloud mode: Google login
                Button {
                    if !agreedToTerms {
                        withAnimation { showTermsHint = true }
                        return
                    }
                    Task { await auth.signInWithGoogle() }
                } label: {
                    HStack(spacing: 8) {
                        if auth.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            GoogleIcon()
                        }
                        Text(auth.isLoading ? "Signing in..." : "Continue with Google")
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.secondarySystemBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.gray.opacity(0.15), lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .disabled(auth.isLoading)
                .frame(width: 280)

                // 未勾选协议提示
                if showTermsHint && !agreedToTerms {
                    Text("Please agree to the terms first")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                }

                // 协议勾选
                if CloudConfig.isCloudMode {
                    HStack(spacing: 6) {
                        Button {
                            agreedToTerms.toggle()
                        } label: {
                            Image(systemName: agreedToTerms ? "checkmark.square.fill" : "square")
                                .font(.system(size: 14))
                                .foregroundStyle(agreedToTerms ? Color.clawAccent : .secondary)
                        }
                        .buttonStyle(.plain)

                        Text("I agree to the")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Link("Terms of Service", destination: URL(string: "\(AppConfig.serviceBaseURL)/terms")!)
                            .font(.caption2)
                        Text("and")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Link("Privacy Policy", destination: URL(string: "\(AppConfig.serviceBaseURL)/privacy")!)
                            .font(.caption2)
                    }
                    .padding(.top, 14)
                }
            } else {
                // Local mode: Enter directly
                Button {
                    auth.enterLocalMode()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 18))
                        Text(L.isEN ? "Enter" : "点击进入")
                            .fontWeight(.medium)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.clawAccent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .frame(width: 280)

                Text(L.isEN ? "Configure your API Key in Settings after entering" : "进入后在设置中配置 API Key 即可使用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
            }

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct GoogleIcon: View {
    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: 20, height: 20)
            Text("G")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .red, .yellow, .green],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                )
        }
    }
}
