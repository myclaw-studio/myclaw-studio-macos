import Foundation

struct ToolInfo: Identifiable {
    let id: String
    let nameEN: String
    let nameZH: String
    let icon: String
    let descEN: String
    let descZH: String

    var name: String { L.isEN ? nameEN : nameZH }
    var description: String { L.isEN ? descEN : descZH }

    static let catalog: [ToolInfo] = [
        ToolInfo(id: "web_search",      nameEN: "Web Search",       nameZH: "网络搜索",  icon: "magnifyingglass",                  descEN: "Search the internet for latest news and information",                    descZH: "搜索互联网，获取最新资讯和信息"),
        ToolInfo(id: "fetch_url",       nameEN: "Fetch URL",        nameZH: "读取网页",  icon: "doc.text.magnifyingglass",         descEN: "Fetch webpage content, read articles, news, and documents",              descZH: "获取网页正文内容，阅读文章、新闻、文档原文"),
        ToolInfo(id: "run_code",        nameEN: "Run Code",         nameZH: "运行代码",  icon: "terminal",                         descEN: "Execute Python code for data processing and automation",                 descZH: "执行 Python 代码，处理数据和自动化任务"),
        ToolInfo(id: "file_manager",    nameEN: "File Manager",     nameZH: "文件管理",  icon: "folder",                           descEN: "Read and write local files, manage file system",                         descZH: "读写本地文件，管理文件系统"),
        ToolInfo(id: "ui_inspector",    nameEN: "UI Inspector",     nameZH: "界面读取",  icon: "rectangle.and.hand.point.up.left", descEN: "Read app UI element tree, let Clawbie see the current interface",        descZH: "读取指定 App 的界面元素树，让 Clawbie 看到当前操作界面"),
        ToolInfo(id: "system_info",     nameEN: "System Info",      nameZH: "系统信息",  icon: "desktopcomputer",                  descEN: "Get installed apps, running processes, system version and hardware info", descZH: "获取已安装应用、运行中进程、系统版本和硬件信息"),
        ToolInfo(id: "project_manager", nameEN: "Project Manager",  nameZH: "项目管理",  icon: "folder.badge.gearshape",           descEN: "Create, view, and delete projects under ~/.aichat/projects/",            descZH: "创建、查看、删除项目，所有项目统一在 ~/.aichat/projects/ 下管理"),
        ToolInfo(id: "save_skill",      nameEN: "Save Skill",       nameZH: "保存技能",  icon: "square.and.arrow.down",            descEN: "Save current workflow as a reusable skill",                              descZH: "将当前工作流保存为可复用技能"),
    ]
}
