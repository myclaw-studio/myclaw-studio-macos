import SwiftUI

@main
struct AIChatApp: App {
    @State private var launcher = BackendLauncher()
    @StateObject private var auth = AuthViewModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if !auth.isAuthenticated {
                    LoginView()
                        .environmentObject(auth)
                } else {
                    switch launcher.status {
                    case .starting(let msg):
                        LaunchView(message: msg)
                    case .running:
                        ContentView()
                            .environmentObject(auth)
                    case .failed(let msg):
                        LaunchErrorView(message: msg) {
                            Task { await launcher.retry() }
                        }
                    }
                }
            }
            .animation(.easeInOut, value: auth.isAuthenticated)
            .onOpenURL { url in
                let path = url.host ?? ""
                let fullPath = path + url.path
                if fullPath == "payment/success" {
                    auth.paymentResult = .success
                    Task { await auth.refreshBalance() }
                } else if fullPath == "payment/cancel" {
                    auth.paymentResult = .cancelled
                }
            }
            .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
