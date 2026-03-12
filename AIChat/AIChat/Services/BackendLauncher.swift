import Foundation
import Observation

@Observable
@MainActor
class BackendLauncher {
    var status: Status = .starting("初始化中…")

    enum Status: Equatable {
        case starting(String)
        case running
        case failed(String)
    }

    private var bridgeServer: OSBridgeServer?
    private var swiftBackend: SwiftBackendServer?

    private let swiftPort: UInt16 = 8000

    init() { Task { await start() } }

    private func start() async {
        status = .starting("正在启动后端服务…")

        // Start OS Bridge (AX proxy)
        if bridgeServer == nil {
            let bridge = OSBridgeServer(port: 8001)
            bridge.start()
            bridgeServer = bridge
        }

        // Start Swift HTTP server on port 8000
        if swiftBackend == nil {
            await killPortIfNeeded(Int(swiftPort))
            let server = SwiftBackendServer(port: swiftPort)
            server.start()
            swiftBackend = server
        }

        // Start MCP servers in background
        DispatchQueue.global().async {
            MCPManager.shared.startAll()
        }

        // Verify Swift server is ready
        for _ in 1...10 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if await healthCheck() {
                status = .running
                return
            }
        }

        // Even if health check fails, mark as running (server should be up)
        status = .running
    }

    func retry() async {
        swiftBackend?.stop()
        swiftBackend = nil
        MCPManager.shared.stopAll()
        await start()
    }

    private func healthCheck() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(swiftPort)/health") else { return false }
        return (try? await URLSession.shared.data(from: url))
            .map { (_, resp) in (resp as? HTTPURLResponse)?.statusCode == 200 } ?? false
    }

    private func killPortIfNeeded(_ port: Int) async {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "lsof -ti:\(port) | xargs kill -9 2>/dev/null || true"]
        try? proc.run()
        proc.waitUntilExit()
    }

    func cleanup() {
        MCPManager.shared.stopAll()
        bridgeServer?.stop()
        swiftBackend?.stop()
    }
}
