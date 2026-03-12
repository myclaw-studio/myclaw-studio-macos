import Foundation
import Network
import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - OS Bridge HTTP Server
// Lightweight HTTP server on 127.0.0.1:8001 exposing macOS Accessibility APIs.
// The Swift host process (My Claw) already has AX permissions, so the Python
// backend can call these endpoints instead of using pyobjc directly.

final class OSBridgeServer: @unchecked Sendable {
    private let port: UInt16
    private var listener: NWListener?

    init(port: UInt16 = 8001) {
        self.port = port
    }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        // Allow address reuse so restart doesn't fail
        params.allowLocalEndpointReuse = true

        do {
            listener = try NWListener(using: params)
        } catch {
            print("[OSBridge] Failed to create listener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[OSBridge] Listening on 127.0.0.1:\(self.port)")
            case .failed(let err):
                print("[OSBridge] Listener failed: \(err)")
            default:
                break
            }
        }

        listener?.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .userInitiated))
        receiveHTTP(conn: conn, accumulated: Data())
    }

    private func receiveHTTP(conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }

            var buffer = accumulated
            if let data { buffer.append(data) }

            // Check if we have complete headers
            if let headerEnd = buffer.findHeaderEnd() {
                let headerData = buffer[..<headerEnd]
                let bodyStart = buffer[headerEnd...]

                guard let headerStr = String(data: headerData, encoding: .utf8) else {
                    self.sendResponse(conn: conn, status: 400, body: ["error": "Bad request"])
                    return
                }

                let (method, path, contentLength) = self.parseRequestLine(headerStr)

                if method == "POST" && contentLength > 0 && bodyStart.count < contentLength {
                    // Need more body data
                    self.receiveHTTP(conn: conn, accumulated: buffer)
                    return
                }

                let bodyData = bodyStart.prefix(max(contentLength, 0))
                self.route(conn: conn, method: method, path: path, body: bodyData)
            } else if isComplete || error != nil {
                // Connection closed before headers complete
                conn.cancel()
            } else {
                // Need more header data
                self.receiveHTTP(conn: conn, accumulated: buffer)
            }
        }
    }

    private func parseRequestLine(_ header: String) -> (method: String, path: String, contentLength: Int) {
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return ("", "", 0) }
        let parts = first.split(separator: " ", maxSplits: 2)
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : ""

        var cl = 0
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                cl = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return (method, path, cl)
    }

    // MARK: - Routing

    private func route(conn: NWConnection, method: String, path: String, body: Data) {
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        switch (method, path) {
        case ("GET", "/os/ax/permission"):
            let granted = AXIsProcessTrusted()
            sendResponse(conn: conn, status: 200, body: ["granted": granted])

        case ("POST", "/os/ax/list-apps"):
            let result = listApps()
            sendResponse(conn: conn, status: 200, body: ["apps_text": result])

        case ("POST", "/os/ax/inspect"):
            let appName = json["app_name"] as? String ?? ""
            let depth = json["depth"] as? Int ?? 2
            if appName.isEmpty {
                sendResponse(conn: conn, status: 400, body: ["error": "app_name required"])
                return
            }
            let result = inspect(appName: appName, depth: max(1, min(depth, 4)))
            sendResponse(conn: conn, status: 200, body: ["tree": result])

        case ("POST", "/os/ax/click"):
            let appName = json["app_name"] as? String ?? ""
            let target = json["target"] as? String ?? ""
            if appName.isEmpty || target.isEmpty {
                sendResponse(conn: conn, status: 400, body: ["error": "app_name and target required"])
                return
            }
            let (ok, msg) = click(appName: appName, target: target)
            sendResponse(conn: conn, status: 200, body: ["ok": ok, "message": msg])

        case ("POST", "/os/ax/type"):
            let appName = json["app_name"] as? String ?? ""
            let text = json["text"] as? String ?? ""
            if appName.isEmpty || text.isEmpty {
                sendResponse(conn: conn, status: 400, body: ["error": "app_name and text required"])
                return
            }
            let (ok, msg) = typeText(appName: appName, text: text)
            sendResponse(conn: conn, status: 200, body: ["ok": ok, "message": msg])

        case ("POST", "/os/ax/press"):
            let appName = json["app_name"] as? String ?? ""
            let keys = json["keys"] as? String ?? ""
            if appName.isEmpty || keys.isEmpty {
                sendResponse(conn: conn, status: 400, body: ["error": "app_name and keys required"])
                return
            }
            let (ok, msg) = pressKeys(appName: appName, keys: keys)
            sendResponse(conn: conn, status: 200, body: ["ok": ok, "message": msg])

        case ("POST", "/os/ax/menu"):
            let appName = json["app_name"] as? String ?? ""
            if appName.isEmpty {
                sendResponse(conn: conn, status: 400, body: ["error": "app_name required"])
                return
            }
            let result = readMenuShortcuts(appName: appName)
            sendResponse(conn: conn, status: 200, body: ["menu": result])

        default:
            sendResponse(conn: conn, status: 404, body: ["error": "Not found: \(method) \(path)"])
        }
    }

    // MARK: - HTTP Response

    private func sendResponse(conn: NWConnection, status: Int, body: [String: Any]) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default: statusText = "Error"
        }

        let jsonData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(jsonData.count)\r\nConnection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(jsonData)

        conn.send(content: response, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - App Helpers

    private func findApp(name: String) -> NSRunningApplication? {
        for app in NSWorkspace.shared.runningApplications {
            let localName = app.localizedName ?? ""
            let bundleLast = (app.bundleIdentifier ?? "").split(separator: ".").last.map(String.init) ?? ""
            if localName == name || bundleLast.lowercased() == name.lowercased() {
                return app
            }
        }
        return nil
    }

    private func ensureApp(name: String) -> (pid: pid_t?, error: String?) {
        var app = findApp(name: name)

        if app == nil {
            // Try to launch
            NSWorkspace.shared.launchApplication(name)
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.5)
                app = findApp(name: name)
                if app != nil { break }
            }
        }

        guard let app else {
            let names = NSWorkspace.shared.runningApplications
                .filter { !$0.isHidden && $0.activationPolicy == .regular }
                .compactMap(\.localizedName)
                .sorted()
            return (nil, "未能启动「\(name)」。运行中的 App：\(names.joined(separator: ", "))")
        }

        app.activate(options: .activateIgnoringOtherApps)
        Thread.sleep(forTimeInterval: 0.5)
        return (app.processIdentifier, nil)
    }

    // MARK: - AX Helpers

    private func axGet(_ element: AXUIElement, _ attr: String) -> AnyObject? {
        var value: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, attr as CFString, &value)
        return err == .success ? value : nil
    }

    // MARK: - list-apps

    private func listApps() -> String {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
            .sorted()
        return "当前运行的 App：\n" + apps.map { "- \($0)" }.joined(separator: "\n")
    }

    // MARK: - menu shortcuts

    private func readMenuShortcuts(appName: String) -> String {
        let (pid, err) = ensureApp(name: appName)
        if let err { return err }
        guard let pid else { return "找不到 App" }

        let appRef = AXUIElementCreateApplication(pid)
        guard let menuBar = axGet(appRef, kAXMenuBarAttribute) else {
            return "无法读取「\(appName)」的菜单栏"
        }
        let menuBarElement = menuBar as! AXUIElement
        guard let menuBarItems = axGet(menuBarElement, kAXChildrenAttribute) as? [AXUIElement] else {
            return "菜单栏为空"
        }

        var lines = ["=== \(appName) 菜单快捷键 ==="]
        for barItem in menuBarItems {
            let menuTitle = axGet(barItem, kAXTitleAttribute) as? String ?? ""
            // Skip Apple menu
            if menuTitle.isEmpty || menuTitle == "Apple" { continue }

            guard let subMenu = axGet(barItem, kAXChildrenAttribute) as? [AXUIElement],
                  let menu = subMenu.first,
                  let menuItems = axGet(menu, kAXChildrenAttribute) as? [AXUIElement] else { continue }

            var menuLines: [String] = []
            scanMenuItems(menuItems, depth: 0, lines: &menuLines)
            if !menuLines.isEmpty {
                lines.append("\n[\(menuTitle)]")
                lines.append(contentsOf: menuLines)
            }
        }

        if lines.count == 1 {
            return "「\(appName)」没有发现带快捷键的菜单项"
        }
        return lines.joined(separator: "\n")
    }

    private func scanMenuItems(_ items: [AXUIElement], depth: Int, lines: inout [String]) {
        let indent = String(repeating: "  ", count: depth)
        for item in items {
            let title = axGet(item, kAXTitleAttribute) as? String ?? ""
            if title.isEmpty { continue }

            let cmdChar = axGet(item, "AXMenuItemCmdChar") as? String ?? ""
            let cmdMods = axGet(item, "AXMenuItemCmdModifiers") as? Int

            if !cmdChar.isEmpty {
                // Decode modifier flags: 0=Cmd, 1=Cmd+Shift, 2=Cmd+Option, 4=Cmd+Ctrl
                var modStr = "Cmd+"
                if let mods = cmdMods {
                    switch mods {
                    case 1: modStr = "Cmd+Shift+"
                    case 2: modStr = "Cmd+Option+"
                    case 3: modStr = "Cmd+Shift+Option+"
                    case 4: modStr = "Cmd+Ctrl+"
                    case 5: modStr = "Cmd+Ctrl+Shift+"
                    case 6: modStr = "Cmd+Ctrl+Option+"
                    default: break
                    }
                }
                lines.append("\(indent)\(title): \(modStr)\(cmdChar)")
            }

            // Recurse into submenus
            if let subMenus = axGet(item, kAXChildrenAttribute) as? [AXUIElement] {
                for sub in subMenus {
                    if let subItems = axGet(sub, kAXChildrenAttribute) as? [AXUIElement], !subItems.isEmpty {
                        lines.append("\(indent)[\(title) ▸]")
                        scanMenuItems(subItems, depth: depth + 1, lines: &lines)
                    }
                }
            }
        }
    }

    // MARK: - inspect

    private func inspect(appName: String, depth: Int) -> String {
        let (pid, err) = ensureApp(name: appName)
        if let err { return err }
        guard let pid else { return "找不到 App" }

        let appRef = AXUIElementCreateApplication(pid)
        guard let windows = axGet(appRef, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            if !AXIsProcessTrusted() {
                return "「\(appName)」无法读取窗口——辅助功能权限未授予。请让主人到「系统设置 → 隐私与安全性 → 辅助功能」中将 My Claw 删掉并重新添加，打开开关后重启 My Claw。"
            }
            return "「\(appName)」没有打开的窗口（App 可能最小化了或还未完全加载）。"
        }

        var lines = ["=== \(appName) UI Tree (depth=\(depth)) ==="]
        for win in windows {
            let title = axGet(win, kAXTitleAttribute) as? String ?? "(untitled)"
            lines.append("\n[Window] \(title)")
            scanElement(win, currentDepth: 1, maxDepth: depth, lines: &lines)
        }

        var output = lines.joined(separator: "\n")
        if output.count > 6000 {
            output = String(output.prefix(6000)) + "\n\n[内容已截断，建议减小 depth]"
        }
        return output
    }

    private func scanElement(_ element: AXUIElement, currentDepth: Int, maxDepth: Int, lines: inout [String]) {
        guard let children = axGet(element, kAXChildrenAttribute) as? [AXUIElement] else { return }

        let indent = String(repeating: "  ", count: currentDepth)
        for child in children {
            let role = axGet(child, kAXRoleAttribute) as? String ?? ""
            if role == "AXUnknown" { continue }

            var label = "\(indent)\(role)"
            if let title = axGet(child, kAXTitleAttribute) as? String, !title.isEmpty {
                label += " '\(title)'"
            }
            if let desc = axGet(child, kAXDescriptionAttribute) as? String, !desc.isEmpty {
                label += " [\(desc)]"
            }
            if let value = axGet(child, kAXValueAttribute) {
                let vs = "\(value)"
                if !vs.isEmpty && vs.count < 80 {
                    label += ": \(vs)"
                }
            }
            lines.append(label)

            if currentDepth < maxDepth {
                scanElement(child, currentDepth: currentDepth + 1, maxDepth: maxDepth, lines: &lines)
            }
        }
    }

    // MARK: - click

    private func click(appName: String, target: String) -> (ok: Bool, message: String) {
        let (pid, err) = ensureApp(name: appName)
        if let err { return (false, err) }
        guard let pid else { return (false, "找不到 App") }

        let wantRole: String
        let wantTitle: String
        if target.contains(":") {
            let parts = target.split(separator: ":", maxSplits: 1)
            wantRole = String(parts[0])
            wantTitle = String(parts[1])
        } else {
            wantRole = ""
            wantTitle = target
        }

        let appRef = AXUIElementCreateApplication(pid)
        guard let windows = axGet(appRef, kAXWindowsAttribute) as? [AXUIElement] else {
            return (false, "无法获取窗口")
        }

        for win in windows {
            if let found = findElement(win, wantRole: wantRole, wantTitle: wantTitle) {
                if AXUIElementPerformAction(found, kAXPressAction as CFString) == .success {
                    return (true, "已点击「\(target)」")
                }
                if AXUIElementPerformAction(found, kAXConfirmAction as CFString) == .success {
                    return (true, "已点击「\(target)」")
                }
                return (false, "找到「\(target)」但点击失败")
            }
        }
        return (false, "未找到「\(target)」。建议先 inspect 查看当前界面元素。")
    }

    private func findElement(_ element: AXUIElement, wantRole: String, wantTitle: String) -> AXUIElement? {
        let role = axGet(element, kAXRoleAttribute) as? String ?? ""
        let title = axGet(element, kAXTitleAttribute) as? String ?? ""
        let desc = axGet(element, kAXDescriptionAttribute) as? String ?? ""

        let roleOk = wantRole.isEmpty || role == wantRole
        let titleOk = title.contains(wantTitle) || desc.contains(wantTitle)

        if roleOk && titleOk { return element }

        if let children = axGet(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                if let found = findElement(child, wantRole: wantRole, wantTitle: wantTitle) {
                    return found
                }
            }
        }
        return nil
    }

    // MARK: - type

    private func typeText(appName: String, text: String) -> (ok: Bool, message: String) {
        let (_, err) = ensureApp(name: appName)
        if let err { return (false, err) }

        // Paste via clipboard (supports Chinese)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        Thread.sleep(forTimeInterval: 0.1)

        // Cmd+V
        postKey(keyCode: UInt16(kVK_ANSI_V), cmd: true)
        Thread.sleep(forTimeInterval: 0.3)

        return (true, "已输入文字（\(text.count) 字符）")
    }

    // MARK: - press

    private static let keyMap: [String: UInt16] = [
        "return": UInt16(kVK_Return), "enter": UInt16(kVK_Return),
        "escape": UInt16(kVK_Escape), "esc": UInt16(kVK_Escape),
        "tab": UInt16(kVK_Tab), "space": UInt16(kVK_Space),
        "delete": UInt16(kVK_Delete), "backspace": UInt16(kVK_Delete),
        "up": UInt16(kVK_UpArrow), "down": UInt16(kVK_DownArrow),
        "left": UInt16(kVK_LeftArrow), "right": UInt16(kVK_RightArrow),
        "a": UInt16(kVK_ANSI_A), "b": UInt16(kVK_ANSI_B), "c": UInt16(kVK_ANSI_C),
        "d": UInt16(kVK_ANSI_D), "e": UInt16(kVK_ANSI_E), "f": UInt16(kVK_ANSI_F),
        "g": UInt16(kVK_ANSI_G), "h": UInt16(kVK_ANSI_H), "i": UInt16(kVK_ANSI_I),
        "j": UInt16(kVK_ANSI_J), "k": UInt16(kVK_ANSI_K), "l": UInt16(kVK_ANSI_L),
        "m": UInt16(kVK_ANSI_M), "n": UInt16(kVK_ANSI_N), "o": UInt16(kVK_ANSI_O),
        "p": UInt16(kVK_ANSI_P), "q": UInt16(kVK_ANSI_Q), "r": UInt16(kVK_ANSI_R),
        "s": UInt16(kVK_ANSI_S), "t": UInt16(kVK_ANSI_T), "u": UInt16(kVK_ANSI_U),
        "v": UInt16(kVK_ANSI_V), "w": UInt16(kVK_ANSI_W), "x": UInt16(kVK_ANSI_X),
        "y": UInt16(kVK_ANSI_Y), "z": UInt16(kVK_ANSI_Z),
        "0": UInt16(kVK_ANSI_0), "1": UInt16(kVK_ANSI_1), "2": UInt16(kVK_ANSI_2),
        "3": UInt16(kVK_ANSI_3), "4": UInt16(kVK_ANSI_4), "5": UInt16(kVK_ANSI_5),
        "6": UInt16(kVK_ANSI_6), "7": UInt16(kVK_ANSI_7), "8": UInt16(kVK_ANSI_8),
        "9": UInt16(kVK_ANSI_9),
        "f1": UInt16(kVK_F1), "f2": UInt16(kVK_F2), "f3": UInt16(kVK_F3),
        "f4": UInt16(kVK_F4), "f5": UInt16(kVK_F5),
    ]

    private func postKey(keyCode: UInt16, cmd: Bool = false, shift: Bool = false,
                         option: Bool = false, ctrl: Bool = false) {
        var flags = CGEventFlags()
        if cmd { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        if option { flags.insert(.maskAlternate) }
        if ctrl { flags.insert(.maskControl) }

        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { return }

        if !flags.isEmpty {
            down.flags = flags
            up.flags = flags
        }

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
    }

    private func pressKeys(appName: String, keys: String) -> (ok: Bool, message: String) {
        let (_, err) = ensureApp(name: appName)
        if let err { return (false, err) }

        var results: [String] = []
        for combo in keys.split(separator: ",") {
            let combo = combo.trimmingCharacters(in: .whitespaces).lowercased()
            if combo.isEmpty { continue }

            let parts = combo.split(separator: "+")
            let keyPart = String(parts.last!).trimmingCharacters(in: .whitespaces)
            let mods = Set(parts.dropLast().map { $0.trimmingCharacters(in: .whitespaces) })

            guard let keyCode = Self.keyMap[keyPart] else {
                results.append("未知按键: \(keyPart)")
                continue
            }

            postKey(
                keyCode: keyCode,
                cmd: mods.contains("command") || mods.contains("cmd"),
                shift: mods.contains("shift"),
                option: mods.contains("option") || mods.contains("alt"),
                ctrl: mods.contains("control") || mods.contains("ctrl")
            )
            results.append("已按下 \(combo)")
            Thread.sleep(forTimeInterval: 0.3)
        }

        return (true, results.joined(separator: "\n"))
    }
}

// findHeaderEnd() is defined in SwiftBackendServer.swift as a shared Data extension
