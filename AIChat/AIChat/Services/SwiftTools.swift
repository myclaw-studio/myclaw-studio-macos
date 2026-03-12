import Foundation

// MARK: - ClawTool Protocol

protocol ClawTool {
    var name: String { get }
    var definition: [String: Any] { get }
    func run(params: [String: Any]) async -> String
}

// MARK: - Tool Registry

final class SwiftToolRegistry {
    static let shared = SwiftToolRegistry()
    private var tools: [String: ClawTool] = [:]

    private init() {
        register(FileManagerTool())
        register(ProjectManagerTool())
        register(SystemInfoTool())
        register(CodeRunnerTool())
        register(SaveSkillTool())
        register(FetchURLTool())
        register(UIControlTool())
        register(WebSearchTool())
        register(MemorySearchTool())
        register(ManageToolsTool())
    }

    private func register(_ tool: ClawTool) {
        tools[tool.name] = tool
    }

    func get(_ name: String) -> ClawTool? { tools[name] }
    func allDefinitions() -> [[String: Any]] { tools.values.map { $0.definition } }
    var allNames: [String] { Array(tools.keys) }
}

// MARK: - FileManagerTool

final class FileManagerTool: ClawTool {
    let name = "file_manager"
    private let maxReadChars = 12000
    private var defaultDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aichat/projects/default")
    }

    var definition: [String: Any] {
        [
            "name": name,
            "description": """
                管理本地文件和目录。
                相对路径默认在 ~/.aichat/projects/default/ 下，绝对路径和 ~ 开头不受限。

                action 说明：
                  read   = 读文件（仅支持 UTF-8 文本文件，最大 12000 字符）
                  write  = 覆盖写入（整文件替换）
                  edit   = 精准编辑：用 old_string 定位内容，替换为 new_string
                  append = 追加写入
                  list   = 列目录（显示文件名和大小）
                  delete = 删除文件或目录
                  mkdir  = 创建目录

                注意：read 只能读纯文本文件（txt/csv/json/代码等）。
                二进制文件（docx/xlsx/pptx/zip/图片等）请用 run_code 工具配合相应 Python 库处理。
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["read", "write", "edit", "append", "list", "delete", "mkdir"],
                        "description": "操作类型",
                    ],
                    "path": [
                        "type": "string",
                        "description": "文件或目录路径。相对路径 → ~/.aichat/projects/default/<path>；~ 开头或绝对路径按原样处理。",
                    ],
                    "content": [
                        "type": "string",
                        "description": "写入内容（write / append 操作时必填）",
                    ],
                    "old_string": [
                        "type": "string",
                        "description": "edit 操作：要被替换的原始内容（必须在文件中唯一存在）",
                    ],
                    "new_string": [
                        "type": "string",
                        "description": "edit 操作：替换后的新内容",
                    ],
                ],
                "required": ["action", "path"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let action = params["action"] as? String ?? ""
        let path = params["path"] as? String ?? ""
        let content = params["content"] as? String ?? ""
        let oldString = params["old_string"] as? String ?? ""
        let newString = params["new_string"] as? String ?? ""

        let p = resolve(path)

        switch action {
        case "read":
            do {
                let text = try String(contentsOf: p, encoding: .utf8)
                if text.count > maxReadChars {
                    return String(text.prefix(maxReadChars)) + "\n\n[文件已截断，共 \(text.count) 字符，显示前 \(maxReadChars) 字符]"
                }
                return text
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == 260 {
                    return "文件不存在: \(p.path)"
                }
                return "读取失败: \(error.localizedDescription)"
            }

        case "write":
            if content.isEmpty {
                return "写入失败: content 为空，请提供要写入的内容。如果你的回复被截断了，请分段写入或简化内容。"
            }
            do {
                try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
                try content.write(to: p, atomically: true, encoding: .utf8)
                return "已写入: \(p.path)（\(content.count) 字符）"
            } catch {
                return "写入失败: \(error.localizedDescription)"
            }

        case "edit":
            if oldString.isEmpty {
                return "edit 操作需要提供 old_string（要替换的原始内容）。"
            }
            do {
                var text = try String(contentsOf: p, encoding: .utf8)
                let count = text.components(separatedBy: oldString).count - 1
                if count == 0 {
                    return "未找到要替换的内容，请检查 old_string 是否正确。"
                }
                if count > 1 {
                    return "找到 \(count) 处匹配，old_string 不唯一，请提供更多上下文以精确定位。"
                }
                if let range = text.range(of: oldString) {
                    text.replaceSubrange(range, with: newString)
                }
                try text.write(to: p, atomically: true, encoding: .utf8)
                return "已编辑: \(p.path)"
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == 260 {
                    return "文件不存在: \(p.path)"
                }
                return "编辑失败: \(error.localizedDescription)"
            }

        case "append":
            if content.isEmpty {
                return "追加失败: content 为空，请提供要追加的内容。"
            }
            do {
                try FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: p.path) {
                    let handle = try FileHandle(forWritingTo: p)
                    handle.seekToEndOfFile()
                    handle.write(content.data(using: .utf8)!)
                    handle.closeFile()
                } else {
                    try content.write(to: p, atomically: true, encoding: .utf8)
                }
                return "已追加: \(p.path)（+\(content.count) 字符）"
            } catch {
                return "追加失败: \(error.localizedDescription)"
            }

        case "list":
            do {
                guard FileManager.default.fileExists(atPath: p.path) else {
                    return "路径不存在: \(p.path)"
                }
                let entries = try FileManager.default.contentsOfDirectory(at: p, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
                let sorted = entries.sorted { a, b in
                    let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if aDir != bDir { return aDir }
                    return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
                }
                if sorted.isEmpty { return "（空目录）" }
                var lines: [String] = []
                for entry in sorted {
                    let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDir {
                        lines.append("📁 \(entry.lastPathComponent)/")
                    } else {
                        let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        lines.append("📄 \(entry.lastPathComponent)  \(humanSize(size))")
                    }
                }
                return lines.joined(separator: "\n")
            } catch {
                return "列目录失败: \(error.localizedDescription)"
            }

        case "delete":
            do {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir) else {
                    return "路径不存在: \(p.path)"
                }
                try FileManager.default.removeItem(at: p)
                return "已删除: \(p.path)"
            } catch {
                return "删除失败: \(error.localizedDescription)"
            }

        case "mkdir":
            do {
                try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
                return "目录已创建: \(p.path)"
            } catch {
                return "创建目录失败: \(error.localizedDescription)"
            }

        default:
            return "未知操作: \(action)，可用操作：read, write, append, list, delete, mkdir"
        }
    }

    private func resolve(_ path: String) -> URL {
        var expanded = path
        if expanded.hasPrefix("~") {
            expanded = (expanded as NSString).expandingTildeInPath
        }
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return defaultDir.appendingPathComponent(expanded)
    }
}

// MARK: - ProjectManagerTool

final class ProjectManagerTool: ClawTool {
    let name = "project_manager"
    private var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aichat/projects")
    }

    var definition: [String: Any] {
        [
            "name": name,
            "description": """
                管理用户项目。所有项目统一存放在 ~/.aichat/projects/ 下。
                【重要】：只要用户提到「新建项目」「做一个XX项目」「建个XX」，
                必须先调用此工具创建项目目录，再用 file_manager 在项目内操作文件。
                action 说明：
                  list   → 列出所有项目
                  create → 新建项目（必须先建再写文件）
                  tree   → 查看项目文件树（理解项目结构）
                  info   → 项目统计信息（文件数、大小、类型分布）
                  delete → 删除整个项目
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["list", "create", "tree", "info", "delete"],
                        "description": "操作类型",
                    ],
                    "project": [
                        "type": "string",
                        "description": "项目名称（list 操作时可省略）",
                    ],
                    "description": [
                        "type": "string",
                        "description": "项目介绍，create 时必填，1-2句话说明项目目标和内容",
                    ],
                ],
                "required": ["action"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let action = params["action"] as? String ?? ""
        let project = params["project"] as? String ?? ""
        let desc = params["description"] as? String ?? ""
        try? FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)

        switch action {
        case "list": return listProjects()
        case "create": return createProject(project, description: desc)
        case "tree": return treeProject(project)
        case "info": return infoProject(project)
        case "delete": return deleteProject(project)
        default: return "未知操作: \(action)"
        }
    }

    private func listProjects() -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]) else {
            return "暂无项目。使用 action='create' 新建一个项目。"
        }
        let dirs = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if dirs.isEmpty { return "暂无项目。使用 action='create' 新建一个项目。" }

        var lines = ["=== 项目列表 ===", "路径：\(projectsRoot.path)", ""]
        for dir in dirs {
            let fileCount = countFiles(in: dir)
            let totalSize = totalFileSize(in: dir)
            let mtime = modificationDate(of: dir)
            lines.append("📁 \(dir.lastPathComponent)  (\(fileCount) 个文件, \(humanSize(totalSize)), \(mtime))")
        }
        return lines.joined(separator: "\n")
    }

    private func createProject(_ project: String, description: String) -> String {
        guard !project.isEmpty else { return "请提供项目名称。" }
        let p = projectsRoot.appendingPathComponent(project)
        if FileManager.default.fileExists(atPath: p.path) {
            return "项目「\(project)」已存在：\(p.path)"
        }
        do {
            try FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            let dateStr = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
            var readme = "# \(project)\n\n"
            if !description.isEmpty { readme += "\(description)\n\n" }
            readme += "---\n创建时间：\(dateStr)\n"
            try readme.write(to: p.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            return "✅ 项目「\(project)」已创建：\(p.path)\n现在可以用 file_manager 在此目录下创建文件。"
        } catch {
            return "创建失败: \(error.localizedDescription)"
        }
    }

    private func treeProject(_ project: String) -> String {
        guard !project.isEmpty else { return "请提供项目名称。" }
        let p = projectsRoot.appendingPathComponent(project)
        guard FileManager.default.fileExists(atPath: p.path) else {
            return "项目「\(project)」不存在，请先用 action='create' 创建。"
        }
        var lines = ["=== \(project) 文件树 ===", "路径：\(p.path)", ""]
        walkTree(p, lines: &lines, prefix: "")
        let result = lines.joined(separator: "\n")
        if result.count > 5000 { return String(result.prefix(5000)) + "\n\n[内容已截断]" }
        return result
    }

    private func walkTree(_ dir: URL, lines: inout [String], prefix: String) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { return }
        let sorted = entries.sorted { a, b in
            let aDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let bDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if aDir != bDir { return aDir }
            return a.lastPathComponent < b.lastPathComponent
        }
        for (i, entry) in sorted.enumerated() {
            let isLast = i == sorted.count - 1
            let connector = isLast ? "└── " : "├── "
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                lines.append("\(prefix)\(connector)\(entry.lastPathComponent)/")
                walkTree(entry, lines: &lines, prefix: prefix + (isLast ? "    " : "│   "))
            } else {
                let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                lines.append("\(prefix)\(connector)\(entry.lastPathComponent)  (\(humanSize(size)))")
            }
        }
    }

    private func infoProject(_ project: String) -> String {
        guard !project.isEmpty else { return "请提供项目名称。" }
        let p = projectsRoot.appendingPathComponent(project)
        guard FileManager.default.fileExists(atPath: p.path) else {
            return "项目「\(project)」不存在。"
        }
        let files = allFiles(in: p)
        let totalSize = files.reduce(0) { $0 + (fileSize(of: $1)) }
        let mtime = modificationDate(of: p)
        var extCount: [String: Int] = [:]
        for f in files {
            let ext = (f.pathExtension.isEmpty ? "(无后缀)" : ".\(f.pathExtension)").lowercased()
            extCount[ext, default: 0] += 1
        }
        let extLines = extCount.sorted { $0.value > $1.value }
            .map { "  \($0.key): \($0.value) 个" }
            .joined(separator: "\n")
        return """
            === 项目信息：\(project) ===
            路径：\(p.path)
            文件数：\(files.count)
            总大小：\(humanSize(totalSize))
            最后修改：\(mtime)
            文件类型：
            \(extLines.isEmpty ? "  （空项目）" : extLines)
            """
    }

    private func deleteProject(_ project: String) -> String {
        guard !project.isEmpty else { return "请提供项目名称。" }
        if project == "default" { return "⚠️ default 项目不允许删除。" }
        let p = projectsRoot.appendingPathComponent(project)
        guard FileManager.default.fileExists(atPath: p.path) else {
            return "项目「\(project)」不存在。"
        }
        do {
            try FileManager.default.removeItem(at: p)
            return "✅ 项目「\(project)」已删除。"
        } catch {
            return "删除失败: \(error.localizedDescription)"
        }
    }

    private func countFiles(in dir: URL) -> Int {
        allFiles(in: dir).count
    }
    private func totalFileSize(in dir: URL) -> Int {
        allFiles(in: dir).reduce(0) { $0 + fileSize(of: $1) }
    }
    private func fileSize(of url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    private func allFiles(in dir: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    private func modificationDate(of url: URL) -> String {
        guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) else { return "unknown" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: date)
    }
}

// MARK: - SystemInfoTool

final class SystemInfoTool: ClawTool {
    let name = "system_info"

    var definition: [String: Any] {
        [
            "name": name,
            "description": """
                获取 macOS 系统环境信息，让机器人了解操作上下文。
                info_type 可选：
                  'apps' → 已安装的应用列表（/Applications）
                  'processes' → 当前运行中的 App 列表
                  'system' → 系统版本、硬件、磁盘、内存等
                  'all' → 以上全部
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "info_type": [
                        "type": "string",
                        "enum": ["apps", "processes", "system", "all"],
                        "description": "要获取的信息类型",
                        "default": "all",
                    ],
                ],
                "required": [] as [String],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let infoType = params["info_type"] as? String ?? "all"
        var parts: [String] = []
        if infoType == "apps" || infoType == "all" { parts.append(getInstalledApps()) }
        if infoType == "processes" || infoType == "all" { parts.append(getRunningProcesses()) }
        if infoType == "system" || infoType == "all" { parts.append(getSystemInfo()) }
        return parts.joined(separator: "\n\n")
    }

    private func sh(_ cmd: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", cmd]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "（获取失败: \(error)）"
        }
    }

    private func getInstalledApps() -> String {
        var lines = ["=== 已安装的应用（/Applications）==="]
        let appsDir = URL(fileURLWithPath: "/Applications")
        if let entries = try? FileManager.default.contentsOfDirectory(at: appsDir, includingPropertiesForKeys: nil) {
            let apps = entries.filter { $0.pathExtension == "app" }.map { $0.deletingPathExtension().lastPathComponent }.sorted { $0.lowercased() < $1.lowercased() }
            lines.append(contentsOf: apps)
        }
        let userApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        if let entries = try? FileManager.default.contentsOfDirectory(at: userApps, includingPropertiesForKeys: nil) {
            let apps = entries.filter { $0.pathExtension == "app" }.map { $0.deletingPathExtension().lastPathComponent }
            lines.append(contentsOf: apps)
        }
        return lines.joined(separator: "\n")
    }

    private func getRunningProcesses() -> String {
        var lines = ["=== 当前运行中的 App ==="]
        let result = sh("osascript -e 'tell application \"System Events\" to get name of every process whose background only is false'")
        if !result.isEmpty {
            let procs = result.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.sorted()
            lines.append(contentsOf: procs)
        } else {
            let ps = sh("ps -eo comm | sort -u | grep -v '^-'")
            lines.append(ps)
        }
        return lines.joined(separator: "\n")
    }

    private func getSystemInfo() -> String {
        var lines = ["=== 系统信息 ==="]
        lines.append(sh("sw_vers"))
        lines.append("CPU/芯片: \(sh("sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model"))")
        if let memBytes = Int(sh("sysctl -n hw.memsize")) {
            lines.append("内存: \(memBytes / (1024*1024*1024)) GB")
        }
        lines.append("磁盘(/): \(sh("df -h / | tail -1 | awk '{print \"总量: \"$2\", 已用: \"$3\", 可用: \"$4}'"))")
        lines.append("用户: \(sh("whoami"))，主目录: \(FileManager.default.homeDirectoryForCurrentUser.path)")
        let res = sh("system_profiler SPDisplaysDataType 2>/dev/null | grep Resolution | head -1 | xargs")
        if !res.isEmpty { lines.append("屏幕: \(res)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - CodeRunnerTool

final class CodeRunnerTool: ClawTool {
    let name = "run_code"
    private let timeout: TimeInterval = 60
    private let maxOutputChars = 8000
    private var userPackagesDir: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aichat/packages").path
    }

    // MARK: - Environment Detection (lazy, cached)

    /// Full PATH including homebrew, user local, cargo, etc.
    private lazy var richPATH: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Candidate paths — cover Intel (/usr/local) + ARM (/opt/homebrew) + user local
        let candidates = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",       // ARM Mac homebrew
            "/usr/local/bin", "/usr/local/sbin",              // Intel Mac homebrew
            "\(home)/.local/bin",                             // pipx, user scripts
            "\(home)/.cargo/bin",                             // Rust
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",         // System essentials
        ]
        let basePATH = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existing = Set(basePATH.components(separatedBy: ":"))
        let extras = candidates.filter { !existing.contains($0) && FileManager.default.fileExists(atPath: $0) }
        return (extras + basePATH.components(separatedBy: ":")).joined(separator: ":")
    }()

    /// Resolved paths for key commands (cached after first lookup)
    private lazy var envInfo: String = {
        var info: [String] = []
        let fm = FileManager.default
        // Detect python3
        let python3 = resolveCommand("python3")
        info.append("python3: \(python3 ?? "⚠️ 未找到")")
        // Detect pip3
        let pip3 = resolveCommand("pip3")
        info.append("pip3: \(pip3 ?? "⚠️ 未找到，可用 python3 -m pip 代替")")
        // Detect brew
        let brew = resolveCommand("brew")
        info.append("brew: \(brew ?? "⚠️ 未安装")")
        return info.joined(separator: "\n")
    }()

    private func resolveCommand(_ name: String) -> String? {
        let searchPaths = richPATH.components(separatedBy: ":")
        for dir in searchPaths {
            let full = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    var definition: [String: Any] {
        [
            "name": name,
            "description": """
                在本地执行代码并返回输出。
                language='python'：子进程执行，用于数据处理、文件解析、计算等。
                language='shell'：子进程执行，用于系统命令、安装包、调用外部程序。
                超时 \(Int(timeout)) 秒，输出超过 \(maxOutputChars) 字符会截断。

                ## 当前环境
                \(envInfo)
                packages目录: \(userPackagesDir)

                ## 缺包处理
                import 报 ModuleNotFoundError 时，用 shell 模式安装到用户目录：
                  pip3 install --target \(userPackagesDir) <包名>
                安装一次后永久可用，再用 python 模式 import 即可。
                ⚠️ 始终用 pip3 而不是 pip（macOS 没有 pip 命令）。
                如果 pip3 也不可用，用 python3 -m pip 代替。

                ## 常见文件处理
                - Word (.docx): `pip3 install --target ... python-docx` → `from docx import Document`
                - Excel (.xlsx): `pip3 install --target ... openpyxl` → `import openpyxl`
                - PPT (.pptx): `pip3 install --target ... python-pptx` → `from pptx import Presentation`
                - PDF: `pip3 install --target ... pdfplumber` → `import pdfplumber`
                - 数据分析: `pip3 install --target ... pandas` → `import pandas`
                - 图片处理: `pip3 install --target ... Pillow` → `from PIL import Image`

                ## 错误自救原则
                - "command not found" → 先用 which/command -v 检查命令位置，或尝试绝对路径（/opt/homebrew/bin/xxx, /usr/local/bin/xxx）
                - brew 未安装 → 不要卡住，用替代方案（curl 下载、python 实现、或系统自带工具）
                - 安装包失败 → 尝试 python3 -m pip；如果 pip 本身缺失，用 python3 -m ensurepip 先装 pip
                - 不要反复重试同一个失败方案，换思路解决
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "code": [
                        "type": "string",
                        "description": "要执行的代码",
                    ],
                    "language": [
                        "type": "string",
                        "enum": ["python", "shell"],
                        "description": "编程语言：python（数据/计算）或 shell（系统命令/安装包）",
                        "default": "python",
                    ],
                ],
                "required": ["code"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let code = params["code"] as? String ?? ""
        let language = params["language"] as? String ?? "python"

        switch language {
        case "python": return await runPython(code)
        case "shell": return await runShell(code)
        default: return "不支持的语言: \(language)"
        }
    }

    private func buildRichEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = richPATH
        let existingPythonPath = env["PYTHONPATH"] ?? ""
        env["PYTHONPATH"] = existingPythonPath.isEmpty ? userPackagesDir : "\(userPackagesDir):\(existingPythonPath)"
        // Ensure HOME is set (some tools need it)
        if env["HOME"] == nil {
            env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        }
        return env
    }

    private func runPython(_ code: String) async -> String {
        // Ensure packages dir exists
        try? FileManager.default.createDirectory(atPath: userPackagesDir, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolveCommand("python3") ?? "/usr/bin/python3")
        proc.arguments = ["-c", code]
        proc.environment = buildRichEnv()
        return await runProcess(proc)
    }

    private func runShell(_ code: String) async -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", code]
        proc.environment = buildRichEnv()
        return await runProcess(proc)
    }

    private func runProcess(_ proc: Process) async -> String {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        do {
            try proc.run()
        } catch {
            return "执行失败: \(error.localizedDescription)"
        }

        // Wait with timeout
        let deadline = Date().addingTimeInterval(timeout)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let waitResult = proc.waitUntilExitOrTimeout(deadline: deadline)
                if !waitResult {
                    proc.terminate()
                    continuation.resume(returning: "执行超时（>\(Int(self.timeout))s）")
                    return
                }
                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: self.formatOutput(stdout, stderr))
            }
        }
    }

    private func formatOutput(_ stdout: String, _ stderr: String) -> String {
        var parts: [String] = []
        if !stdout.isEmpty { parts.append("stdout:\n\(stdout)") }
        if !stderr.isEmpty { parts.append("stderr:\n\(stderr)") }
        if parts.isEmpty { return "（无输出）" }
        var result = parts.joined(separator: "\n")
        if result.count > maxOutputChars {
            result = String(result.prefix(maxOutputChars)) + "\n\n[输出已截断，共 \(result.count) 字符]"
        }
        return result
    }
}

extension Process {
    func waitUntilExitOrTimeout(deadline: Date) -> Bool {
        while isRunning {
            if Date() > deadline { return false }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return true
    }
}

// MARK: - SaveSkillTool

final class SaveSkillTool: ClawTool {
    let name = "save_skill"
    private var skillsFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".aichat/skills.json")
    }

    var definition: [String: Any] {
        [
            "name": name,
            "description": "将当前完成的工作流程或解决方案保存为可复用的 Skill，方便以后直接调用。",
            "parameters": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "Skill 名称，简短有力，如「飞书日报助手」",
                    ],
                    "description": [
                        "type": "string",
                        "description": "Skill 用途的一句话说明",
                    ],
                    "icon": [
                        "type": "string",
                        "description": "代表该 Skill 的 emoji 图标",
                    ],
                    "system_prompt": [
                        "type": "string",
                        "description": "指导 AI 完成该 Skill 任务的 system prompt，包含角色定位和操作步骤",
                    ],
                    "tools": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "该 Skill 需要的工具列表，从 web_search/run_code/file_manager/feishu_send 中选择",
                    ] as [String: Any],
                ],
                "required": ["name", "description", "icon", "system_prompt", "tools"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let skillName = params["name"] as? String ?? ""
        let desc = params["description"] as? String ?? ""
        let icon = params["icon"] as? String ?? ""
        let systemPrompt = params["system_prompt"] as? String ?? ""
        let tools = params["tools"] as? [String] ?? ["web_search", "run_code", "file_manager"]

        // Generate ID
        var skillId = skillName.lowercased()
            .replacingOccurrences(of: "[^a-z0-9_]", with: "_", options: .regularExpression)
        if skillId.count > 24 { skillId = String(skillId.prefix(24)) }
        skillId = skillId.trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        // Load existing skills
        var skills: [[String: Any]] = []
        if let data = try? Data(contentsOf: skillsFileURL),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            skills = arr
        }

        // Avoid duplicate ID
        let baseId = skillId
        var counter = 2
        while skills.contains(where: { ($0["id"] as? String) == skillId }) {
            skillId = "\(baseId)_\(counter)"
            counter += 1
        }

        let skill: [String: Any] = [
            "id": skillId,
            "name": skillName,
            "description": desc,
            "icon": icon,
            "system_prompt": systemPrompt,
            "tools": tools,
        ]

        skills.append(skill)
        if let data = try? JSONSerialization.data(withJSONObject: skills, options: .prettyPrinted) {
            try? data.write(to: skillsFileURL)
        }

        return "✅ Skill「\(skillName)」已保存！可在左侧边栏 Skills 列表中选择使用。"
    }
}

// MARK: - FetchURLTool

final class FetchURLTool: ClawTool {
    let name = "fetch_url"
    private let fetchTimeout: TimeInterval = 30

    var definition: [String: Any] {
        [
            "name": name,
            "description": "获取指定网页的正文内容，适合阅读文章、新闻、文档原文。比 web_search 更深入，可获取完整内容。",
            "parameters": [
                "type": "object",
                "properties": [
                    "url": [
                        "type": "string",
                        "description": "要获取的网页 URL",
                    ],
                    "max_chars": [
                        "type": "integer",
                        "description": "返回的最大字符数，默认 4000",
                        "default": 4000,
                    ],
                ],
                "required": ["url"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let urlStr = params["url"] as? String ?? ""
        let maxChars = params["max_chars"] as? Int ?? 4000

        guard let url = URL(string: urlStr) else {
            return "无效的 URL: \(urlStr)"
        }

        var request = URLRequest(url: url, timeoutInterval: fetchTimeout)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,*/*", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse else {
                return "获取失败: 非 HTTP 响应"
            }
            if httpResp.statusCode >= 400 {
                return "HTTP 错误: \(httpResp.statusCode)"
            }

            // Detect charset
            var encoding: String.Encoding = .utf8
            if let contentType = httpResp.value(forHTTPHeaderField: "Content-Type"),
               let charsetRange = contentType.range(of: "charset=") {
                let charset = String(contentType[charsetRange.upperBound...]).components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? "utf-8"
                if charset.lowercased().contains("gbk") || charset.lowercased().contains("gb2312") {
                    encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
                }
            }

            let html = String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) ?? ""
            var text = htmlToText(html)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "页面内容为空或无法提取文字（可能是 JS 渲染页面）。"
            }

            if text.count > maxChars {
                text = String(text.prefix(maxChars)) + "\n\n[内容已截断，原文共约 \(text.count) 字符，显示前 \(maxChars) 字符]"
            }
            return text
        } catch {
            if (error as NSError).code == NSURLErrorTimedOut {
                return "请求超时（>\(Int(fetchTimeout))s）"
            }
            return "获取失败: \(error.localizedDescription)"
        }
    }

    private func htmlToText(_ html: String) -> String {
        let skipTags: Set<String> = ["script", "style", "nav", "footer", "header", "aside", "noscript", "iframe", "svg", "form"]
        let blockTags: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "tr", "br", "section", "article", "blockquote"]

        var result = ""
        var skipDepth = 0
        var i = html.startIndex

        while i < html.endIndex {
            if html[i] == "<" {
                // Find end of tag
                guard let tagEnd = html[i...].firstIndex(of: ">") else { break }
                let tagContent = String(html[html.index(after: i)..<tagEnd])
                let isClosing = tagContent.hasPrefix("/")
                let tagName = (isClosing ? String(tagContent.dropFirst()) : tagContent)
                    .split(separator: " ").first.map(String.init)?.lowercased() ?? ""

                if skipTags.contains(tagName) {
                    if isClosing {
                        skipDepth = max(0, skipDepth - 1)
                    } else {
                        skipDepth += 1
                    }
                } else if blockTags.contains(tagName) && skipDepth == 0 {
                    result += "\n"
                }
                i = html.index(after: tagEnd)
            } else {
                if skipDepth == 0 {
                    result.append(html[i])
                }
                i = html.index(after: i)
            }
        }

        // Clean up whitespace
        result = result.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - UIControlTool

final class UIControlTool: ClawTool {
    let name = "ui_control"
    private let bridgeBase = "http://127.0.0.1:8001/os/ax"
    private let bridgeTimeout: TimeInterval = 30

    var definition: [String: Any] {
        [
            "name": name,
            "description": """
                macOS 通用 UI 自动化工具。可以读取任意 App 的界面元素、点击按钮、输入文字、按快捷键。
                open_url 可直接在指定浏览器打开网址（无需辅助功能权限）。
                典型流程：先 inspect 看界面 → 再 click/type/press 操作。不确定快捷键时用 menu 查看菜单栏快捷键。
                需要系统辅助功能权限（设置 → 隐私与安全性 → 辅助功能 → 打开 My Claw）。
                注意：如果 inspect 看不到窗口，可能是辅助功能权限未授予（重新安装后需要重新授权），
                请提示主人到系统设置中将 My Claw 删掉并重新添加到辅助功能列表。
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "app_name": [
                        "type": "string",
                        "description": "App 名称（如 Safari、Feishu、Finder）。不确定时先用 action=list_apps 查看。",
                    ],
                    "action": [
                        "type": "string",
                        "enum": ["inspect", "click", "type", "press", "menu", "list_apps", "screenshot", "activate", "open_url"],
                        "description": """
                            inspect: 读取 UI 元素树；click: 点击匹配的元素（需 target）；type: 输入文字（需 text）；press: 按快捷键（需 keys）；menu: 读取 App 菜单栏所有快捷键；list_apps: 列出当前运行中的所有 App；screenshot: 截取当前屏幕截图（返回图片供分析）；activate: 激活并前置指定 App 窗口（需 app_name）；open_url: 在指定浏览器打开网址（需 url）
                            """,
                    ],
                    "url": [
                        "type": "string",
                        "description": "open_url 时必填。要打开的网址。",
                    ],
                    "target": [
                        "type": "string",
                        "description": "click 时必填。要点击的元素标识，格式：'role:title'（如 'AXButton:发送'）。",
                    ],
                    "text": [
                        "type": "string",
                        "description": "type 时必填。要输入的文字内容。",
                    ],
                    "keys": [
                        "type": "string",
                        "description": "press 时必填。快捷键描述，如 'command+k'、'return'。",
                    ],
                    "depth": [
                        "type": "integer",
                        "description": "inspect 时的元素树层深，默认 2，最大 4。",
                        "default": 2,
                    ],
                ],
                "required": ["action"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let action = params["action"] as? String ?? ""
        let appName = params["app_name"] as? String ?? ""
        let target = params["target"] as? String ?? ""
        let text = params["text"] as? String ?? ""
        let keys = params["keys"] as? String ?? ""
        let depth = params["depth"] as? Int ?? 2
        let urlStr = params["url"] as? String ?? ""

        // Local actions (no OS Bridge needed)
        if action == "screenshot" { return await takeScreenshot() }
        if action == "activate" {
            if appName.isEmpty { return "activate 需要指定 app_name。" }
            return await activateApp(appName)
        }
        if action == "open_url" {
            if urlStr.isEmpty { return "open_url 需要 url 参数。" }
            return await openURL(urlStr, browser: appName.isEmpty ? "Safari" : appName)
        }

        // OS Bridge actions
        do {
            if action == "list_apps" {
                return try await bridgePost("/list-apps", json: [:])
            }
            if appName.isEmpty {
                return "需要指定 app_name（用 action=list_apps 查看可用名称）。"
            }
            switch action {
            case "inspect":
                return try await bridgePost("/inspect", json: ["app_name": appName, "depth": max(1, min(depth, 4))])
            case "click":
                if target.isEmpty { return "click 需要 target 参数（如 'AXButton:发送'）。" }
                return try await bridgePost("/click", json: ["app_name": appName, "target": target])
            case "type":
                if text.isEmpty { return "type 需要 text 参数。" }
                return try await bridgePost("/type", json: ["app_name": appName, "text": text])
            case "press":
                if keys.isEmpty { return "press 需要 keys 参数（如 'command+k'）。" }
                return try await bridgePost("/press", json: ["app_name": appName, "keys": keys])
            case "menu":
                return try await bridgePost("/menu", json: ["app_name": appName])
            default:
                return "未知 action: \(action)"
            }
        } catch {
            let errStr = error.localizedDescription
            if errStr.contains("Connection refused") || errStr.contains("Could not connect") {
                return "OS Bridge 未启动，无法执行 UI 操作。请确保 My Claw 应用正在运行。"
            }
            return "OS Bridge 调用失败：\(errStr)"
        }
    }

    private func bridgePost(_ endpoint: String, json: [String: Any]) async throws -> String {
        let url = URL(string: "\(bridgeBase)\(endpoint)")!
        var request = URLRequest(url: url, timeoutInterval: bridgeTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)

        let (data, _) = try await URLSession.shared.data(for: request)
        if let resp = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Return the most relevant field
            for key in ["tree", "apps_text", "message", "menu"] {
                if let val = resp[key] as? String { return val }
            }
            return String(data: data, encoding: .utf8) ?? ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func takeScreenshot() async -> String {
        let tmpPath = NSTemporaryDirectory() + "claw_screenshot_\(UUID().uuidString).jpg"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // Capture
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-t", "jpg", tmpPath]
        do {
            try capture.run()
            capture.waitUntilExit()
        } catch {
            return "截图失败：\(error)"
        }

        // Resize
        let sips = Process()
        sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        sips.arguments = ["--resampleWidth", "1280", tmpPath]
        sips.standardOutput = Pipe()
        sips.standardError = Pipe()
        try? sips.run()
        sips.waitUntilExit()

        guard let imgData = try? Data(contentsOf: URL(fileURLWithPath: tmpPath)) else {
            return "截图失败：无法读取截图文件"
        }

        let b64 = imgData.base64EncodedString()
        let result: [String: Any] = [
            "__image__": true,
            "text": "已截取当前屏幕截图",
            "image_base64": b64,
            "media_type": "image/jpeg",
        ]
        if let data = try? JSONSerialization.data(withJSONObject: result) {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return "截图失败：序列化错误"
    }

    private func activateApp(_ appName: String) async -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"\(appName)\" to activate"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0 ? "已激活 \(appName)" : "激活 \(appName) 失败"
        } catch {
            return "激活 \(appName) 失败：\(error)"
        }
    }

    private func openURL(_ urlStr: String, browser: String) async -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", "tell application \"\(browser)\" to open location \"\(urlStr)\""]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                return "已在 \(browser) 中打开：\(urlStr)"
            }
            // Fallback: open command
            let fallback = Process()
            fallback.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            fallback.arguments = ["-a", browser, urlStr]
            try fallback.run()
            fallback.waitUntilExit()
            return fallback.terminationStatus == 0 ? "已在 \(browser) 中打开：\(urlStr)" : "打开 URL 失败"
        } catch {
            return "打开 URL 失败：\(error)"
        }
    }
}

// MARK: - WebSearchTool

final class WebSearchTool: ClawTool {
    let name = "web_search"
    private let searchTimeout: TimeInterval = 30

    var definition: [String: Any] {
        [
            "name": name,
            "description": """
                搜索互联网获取信息。
                mode='news' 用于搜索新闻事件、时事动态（结果含发布日期和来源）；
                mode='text' 用于搜索知识、教程、文档等通用内容。
                time_range 可限制结果时间范围：d=今天, w=本周, m=本月, y=今年。
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": [
                        "type": "string",
                        "description": "搜索关键词",
                    ],
                    "mode": [
                        "type": "string",
                        "enum": ["text", "news"],
                        "description": "搜索模式：text=通用网页，news=新闻（有日期）",
                        "default": "text",
                    ],
                    "max_results": [
                        "type": "integer",
                        "description": "返回结果数量，默认 5，最多 10",
                        "default": 5,
                    ],
                    "time_range": [
                        "type": "string",
                        "enum": ["d", "w", "m", "y"],
                        "description": "时间范围：d=今天, w=本周, m=本月, y=今年（可选）",
                    ],
                ],
                "required": ["query"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let query = params["query"] as? String ?? ""
        let mode = params["mode"] as? String ?? "text"
        let maxResults = min(params["max_results"] as? Int ?? 5, 10)
        let timeRange = params["time_range"] as? String

        // Use DuckDuckGo HTML API
        if mode == "news" {
            // Try news first, fall back to text
            if let result = await searchDDG(query: query, mode: "news", maxResults: maxResults, timeRange: timeRange), !result.isEmpty {
                return result
            }
        }
        if let result = await searchDDG(query: query, mode: "text", maxResults: maxResults, timeRange: timeRange) {
            return result
        }
        return "搜索失败: No results found."
    }

    private func searchDDG(query: String, mode: String, maxResults: Int, timeRange: String?) async -> String? {
        // Use DuckDuckGo Lite HTML endpoint
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        var urlStr = "https://lite.duckduckgo.com/lite/?q=\(encoded)"
        if let tr = timeRange { urlStr += "&df=\(tr)" }

        guard let url = URL(string: urlStr) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: searchTimeout)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200 else { continue }
                let html = String(data: data, encoding: .utf8) ?? ""
                let results = parseDDGResults(html: html, maxResults: maxResults)
                if !results.isEmpty {
                    return formatResults(results, mode: mode)
                }
            } catch {
                let errStr = error.localizedDescription.lowercased()
                if errStr.contains("timeout") || errStr.contains("rate") { continue }
                break
            }
        }
        return nil
    }

    private func parseDDGResults(html: String, maxResults: Int) -> [[String: String]] {
        var results: [[String: String]] = []

        let snippetPattern = #"<td class="result-snippet">([^<]*(?:<[^>]*>[^<]*)*)</td>"#
        let aPattern = #"<a rel="nofollow" href="([^"]+)" class='result-link'>([^<]+)</a>"#
        let regex = try? NSRegularExpression(pattern: aPattern, options: [])
        let snippetRegex = try? NSRegularExpression(pattern: snippetPattern, options: [])

        let nsHtml = html as NSString
        let linkMatches = regex?.matches(in: html, range: NSRange(location: 0, length: nsHtml.length)) ?? []
        let snippetMatches = snippetRegex?.matches(in: html, range: NSRange(location: 0, length: nsHtml.length)) ?? []

        for (i, match) in linkMatches.enumerated() {
            if results.count >= maxResults { break }
            let href = nsHtml.substring(with: match.range(at: 1))
            let title = nsHtml.substring(with: match.range(at: 2))
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&#x27;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")

            var snippet = ""
            if i < snippetMatches.count {
                snippet = nsHtml.substring(with: snippetMatches[i].range(at: 1))
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            results.append(["title": title, "href": href, "body": snippet])
        }
        return results
    }

    private func formatResults(_ results: [[String: String]], mode: String) -> String {
        if results.isEmpty { return mode == "news" ? "没有找到相关新闻。" : "没有找到相关搜索结果。" }
        return results.enumerated().map { i, r in
            "[\(i+1)] \(r["title"] ?? "")\n    URL: \(r["href"] ?? "")\n    \(r["body"] ?? "")"
        }.joined(separator: "\n\n")
    }
}

// MARK: - Shared Utility

private func humanSize(_ size: Int) -> String {
    var s = Double(size)
    for unit in ["B", "KB", "MB", "GB"] {
        if s < 1024 {
            return unit == "B" ? "\(Int(s))B" : String(format: "%.1f%@", s, unit)
        }
        s /= 1024
    }
    return String(format: "%.1fTB", s)
}

// MARK: - Memory Search Tool

final class MemorySearchTool: ClawTool {
    let name = "memory_search"

    var definition: [String: Any] {
        [
            "name": name,
            "description": """
                搜索关于主人的长期记忆。当你需要回忆主人的个人信息（邮箱、地址、联系人、电话）、\
                偏好习惯、项目细节、过往事件等信息时，主动调用此工具。
                使用场景：
                - 需要用到主人的具体信息（联系方式、偏好等）但 system prompt 中没有
                - 用户提到某人/某事，需要查找相关记忆
                - 执行任务前需要确认细节（如发邮件前查邮箱地址）

                mode 说明：
                - 'search'：语义模糊搜索，适合不确定关键词时
                - 'lookup'：精确关键词匹配，适合搜具体内容（邮箱、人名、项目名）
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "搜索内容，如「邮箱」「灵旋」「最近的项目」"],
                    "mode": ["type": "string", "enum": ["search", "lookup"], "description": "搜索模式：search（语义模糊）或 lookup（关键词精确）"],
                    "sub_core_k": ["type": "integer", "description": "次核心记忆返回条数，默认5"],
                    "general_k": ["type": "integer", "description": "一般记忆返回条数，默认5"],
                ],
                "required": ["query"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let query = params["query"] as? String ?? ""
        let mode = params["mode"] as? String ?? "search"
        let subCoreK = params["sub_core_k"] as? Int ?? 5
        let generalK = params["general_k"] as? Int ?? 5

        let results = SwiftMemoryManager.shared.search(
            query: query, subCoreK: subCoreK, generalK: generalK,
            mode: mode
        )

        if results.isEmpty { return "未找到相关记忆。" }

        var lines: [String] = []
        var currentTier: String?
        for r in results {
            let tier = r["tier"] as? String ?? ""
            if tier != currentTier {
                let label = tier == "sub_core" ? "次核心记忆" : "一般记忆"
                lines.append("\n【\(label)】")
                currentTier = tier
            }
            let weight = r["weight"] as? Double ?? 0
            let hitCount = r["hit_count"] as? Int ?? 0
            let type = r["type"] as? String ?? ""
            let text = r["text"] as? String ?? ""
            lines.append("- [\(type)] \(text) (权重\(String(format: "%.2f", weight)), 命中\(hitCount)次)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - ManageToolsTool

final class ManageToolsTool: ClawTool {
    let name = "manage_tools"

    var definition: [String: Any] {
        [
            "name": name,
            "description": """
                管理工具箱。
                action 说明：
                  list_installed  = 查看我的所有工具（系统工具 + 已添加的 Composio 工具 + MCP 工具）
                  search_market   = 在 Composio 工具市场搜索工具（需提供 keyword）
                  install_mcp     = 安装一个 MCP 服务器（需提供 name + command，可选 env）
                  remove_mcp      = 卸载一个 MCP 服务器（需提供 name）
                  reload_mcp      = 重启一个已安装的 MCP 服务器（需提供 name）
                注意：Composio 工具的添加/移除需要主人在工具市场 UI 中操作（涉及 OAuth 授权）。
                """,
            "parameters": [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["list_installed", "search_market", "install_mcp", "remove_mcp", "reload_mcp"],
                               "description": "操作类型"],
                    "name": ["type": "string", "description": "MCP 服务器名称（install_mcp/remove_mcp/reload_mcp 时必填）"],
                    "keyword": ["type": "string", "description": "搜索关键词（search_market 时必填），如 \"gmail\"、\"slack\"、\"github\""],
                    "command": ["type": "array", "items": ["type": "string"],
                                "description": "启动命令（install_mcp 时必填），如 [\"npx\", \"-y\", \"@modelcontextprotocol/server-filesystem\", \"~\"]"],
                    "env": ["type": "object", "description": "环境变量（install_mcp 时可选），如 {\"GITHUB_TOKEN\": \"xxx\"}"],
                ],
                "required": ["action"],
            ] as [String: Any],
        ]
    }

    func run(params: [String: Any]) async -> String {
        let action = params["action"] as? String ?? ""
        let serverName = params["name"] as? String ?? ""

        switch action {
        case "list_installed":
            var lines: [String] = []

            // 1. System tools
            let systemDefs = SwiftToolRegistry.shared.allDefinitions()
            lines.append("## 系统工具（\(systemDefs.count) 个）")
            for def in systemDefs {
                let name = def["name"] as? String ?? ""
                let desc = def["description"] as? String ?? ""
                let shortDesc = desc.count > 60 ? String(desc.prefix(60)) + "..." : desc
                lines.append("- \(name): \(shortDesc)")
            }

            // 2. Composio tools
            let composioList = ComposioClient.shared.installedList()
            if !composioList.isEmpty {
                let totalTools = composioList.reduce(0) { $0 + ($1["tool_count"] as? Int ?? 0) }
                lines.append("\n## Composio 工具（\(composioList.count) 个套件，共 \(totalTools) 个工具）")
                for info in composioList {
                    let slug = info["slug"] as? String ?? ""
                    let count = info["tool_count"] as? Int ?? 0
                    if let err = info["auth_error"] as? String {
                        lines.append("- \(slug): \(count) tools ⚠️ 授权异常: \(err)")
                    } else {
                        lines.append("- \(slug): \(count) tools ✅")
                    }
                }
            }

            // 3. MCP tools
            let mcpList = MCPManager.shared.serverList()
            if !mcpList.isEmpty {
                lines.append("\n## MCP 工具服务器（\(mcpList.count) 个）")
                for s in mcpList {
                    let name = s["name"] as? String ?? ""
                    let status = s["status"] as? String ?? "unknown"
                    let count = s["tool_count"] as? Int ?? 0
                    lines.append("- \(name): \(status) (\(count) tools)")
                }
            }

            if composioList.isEmpty && mcpList.isEmpty {
                lines.append("\n💡 目前只有系统工具。主人可以在「工具市场」中添加更多 Composio 工具（900+ 可选），或让我安装 MCP 服务器。")
            }

            return lines.joined(separator: "\n")

        case "search_market":
            let keyword = params["keyword"] as? String ?? ""
            guard !keyword.isEmpty else { return "错误：keyword 参数不能为空" }

            let (items, _) = await ComposioClient.shared.fetchAppsDirectly(cursor: nil, limit: 20)
            if items.isEmpty {
                return "搜索失败，请检查网络连接或 Composio API Key 配置。"
            }

            let lowerKeyword = keyword.lowercased()
            let matched = items.filter { item in
                let name = (item["name"] as? String ?? "").lowercased()
                let key = (item["key"] as? String ?? "").lowercased()
                let desc = (item["description"] as? String ?? "").lowercased()
                return name.contains(lowerKeyword) || key.contains(lowerKeyword) || desc.contains(lowerKeyword)
            }

            if matched.isEmpty {
                return "在工具市场中未找到与「\(keyword)」相关的工具。可以换个关键词试试。"
            }

            var lines = ["在工具市场中找到 \(matched.count) 个相关工具："]
            for item in matched.prefix(10) {
                let name = item["name"] as? String ?? ""
                let key = item["key"] as? String ?? ""
                let desc = item["description"] as? String ?? ""
                let shortDesc = desc.count > 80 ? String(desc.prefix(80)) + "..." : desc
                lines.append("- **\(name)** (\(key)): \(shortDesc)")
            }
            lines.append("\n💡 如需添加，请让主人在「工具市场」UI 中搜索并授权安装。")
            return lines.joined(separator: "\n")

        case "install_mcp":
            guard !serverName.isEmpty else { return "错误：name 参数不能为空" }
            let command = params["command"] as? [String] ?? []
            guard !command.isEmpty else { return "错误：command 参数不能为空" }
            let env = params["env"] as? [String: String] ?? [:]
            let count = MCPManager.shared.installServer(name: serverName, command: command, env: env)
            return count > 0
                ? "已安装 MCP 服务器 \(serverName)，加载了 \(count) 个工具。"
                : "安装 \(serverName) 失败，请检查命令是否正确。"

        case "remove_mcp":
            guard !serverName.isEmpty else { return "错误：name 参数不能为空" }
            MCPManager.shared.removeServer(name: serverName)
            return "已卸载 MCP 服务器 \(serverName)。"

        case "reload_mcp":
            guard !serverName.isEmpty else { return "错误：name 参数不能为空" }
            MCPManager.shared.reloadServer(name: serverName)
            return "已重新启动 MCP 服务器 \(serverName)。"

        default:
            return "未知操作: \(action)"
        }
    }
}
