import Foundation

/// Centralized localization — all UI strings in one place.
/// Reads `AppConfig.language` ("en" / "zh") to pick the right text.
struct L {
    static var isEN: Bool { AppConfig.language == "en" }

    // MARK: - Common

    static var save: String { isEN ? "Save" : "保存" }
    static var cancel: String { isEN ? "Cancel" : "取消" }
    static var close: String { isEN ? "Close" : "关闭" }
    static var retry: String { isEN ? "Retry" : "重试" }
    static var install: String { isEN ? "Install" : "安装" }
    static var installed: String { isEN ? "Installed" : "已安装" }
    static var loading: String { isEN ? "Loading..." : "加载中…" }
    static var all: String { isEN ? "All" : "全部" }
    static var other: String { isEN ? "Other" : "其他" }
    static var done: String { isEN ? "Done" : "完成" }
    static var add: String { isEN ? "Add" : "添加" }
    static var name: String { isEN ? "Name" : "名称" }
    static var remove: String { isEN ? "Remove" : "移除" }
    static var description_: String { isEN ? "Description" : "简介" }
    static var repository: String { isEN ? "Repository" : "项目地址" }
    static var version: String { isEN ? "Version" : "版本" }
    static var tags: String { isEN ? "Tags" : "标签" }
    static var info: String { isEN ? "Info" : "信息" }
    static func developer(_ name: String) -> String { isEN ? "Developer: \(name)" : "开发者：\(name)" }
    static func loadError(_ err: String) -> String { isEN ? "Load failed: \(err)" : "加载失败：\(err)" }

    // MARK: - Sidebar

    static var skills: String { isEN ? "Skills" : "技能" }
    static var tools: String { isEN ? "Tools" : "工具" }
    static var projects: String { isEN ? "Projects" : "项目文件" }
    static var memoryMgmt: String { isEN ? "Clawbie's Memory" : "Clawbie的记忆" }
    static var clawbieDiary: String { isEN ? "Clawbie's Diary" : "Clawbie 的日记" }
    static var upgrade: String { isEN ? "Upgrade" : "升级套餐" }
    static var settings: String { isEN ? "Settings" : "设置" }
    static var signOut: String { isEN ? "Sign Out" : "退出登录" }

    // MARK: - Settings

    static var clawbieCloud: String { isEN ? "Clawbie Cloud" : "Clawbie 云端服务" }
    static var ownAPIKey: String { isEN ? "Own API Key" : "自带 API Key" }
    static var loadingModels: String { isEN ? "Loading models..." : "加载模型列表..." }
    static var chatModel: String { isEN ? "Chat Model" : "聊天模型" }
    static var utilityModel: String { isEN ? "Utility Model" : "辅助模型" }
    static var refreshModels: String { isEN ? "Refresh Models" : "刷新模型列表" }
    static var modelSelection: String { isEN ? "Model" : "模型选择" }
    static var utilityModelFooter: String {
        isEN ? "Background tasks (diary, memory, summary) use utility model"
             : "后台任务（日记、画像、摘要等）使用辅助模型"
    }
    static var forClaudeModels: String { isEN ? "For Claude models" : "用于 Claude 系列模型" }
    static var forGPTModels: String { isEN ? "For GPT models" : "用于 GPT 系列模型" }
    static var providerLabel: String { isEN ? "Provider" : "模型提供商" }
    static var versionLabel: String { isEN ? "Version" : "版本" }
    static var providerClaude: String { "Claude" }
    static var providerChatGPT: String { "ChatGPT" }
    static var providerGemini: String { "Gemini" }
    static var providerDeepSeek: String { "DeepSeek" }
    static var providerKimi: String { "Kimi" }
    static var providerQwen: String { "通义千问" }
    static var providerDoubao: String { "豆包" }
    static var providerYuanbao: String { "元宝" }
    static var refreshVersionsFromAPI: String { isEN ? "Refresh versions from API" : "从 API 获取最新版本" }
    static var apiKeysSection: String { isEN ? "API Keys" : "API 密钥" }
    static var apiKeysSectionHint: String { isEN ? "Fill in API key to start using provider" : "填写 API Key 后可以开始使用提供商" }
    static var anthropicKeyLabel: String { isEN ? "Anthropic API Key (Claude)" : "Anthropic API Key（Claude）" }
    static var openaiKeyLabel: String { isEN ? "OpenAI API Key (ChatGPT)" : "OpenAI API Key（ChatGPT）" }
    static var googleKeyLabel: String { isEN ? "Google API Key (Gemini)" : "Google API Key（Gemini）" }
    static var cloudServiceDesc: String {
        isEN ? "Conversations processed via Clawbie cloud, billed by subscription. No API Key needed."
             : "对话通过 Clawbie 云端处理，按订阅套餐扣费。无需配置 API Key。"
    }

    // MARK: - Chat / Content

    static var sendMessage: String { isEN ? "Message..." : "发消息…" }
    static var clearChat: String { isEN ? "Clear Chat" : "清空对话" }
    static var selectImage: String { isEN ? "Select Image" : "选择图片" }
    static var stopGeneration: String { isEN ? "Stop" : "停止生成" }
    static var backendOffline: String { isEN ? "Backend offline — run start.sh" : "后端未连接 — 请运行 start.sh" }
    static var selectImageForClawbie: String { isEN ? "Select image to send to Clawbie" : "选择要发送给 Clawbie 的图片" }
    static var analyzeImage: String { isEN ? "Please analyze this image" : "请分析这张图片" }
    static func suggestSkill(_ name: String) -> String { isEN ? "Suggest saving skill: \(name)" : "建议保存技能：\(name)" }

    // MARK: - Message Bubble

    static func reasoningSteps(_ n: Int) -> String { isEN ? "Reasoning \(n) steps" : "推理 \(n) 步" }
    static func toolCalls(_ n: Int) -> String { isEN ? "Tool \(n) calls" : "工具 \(n) 次" }
    static func callTool(_ name: String) -> String { isEN ? "Call \(name)" : "调用 \(name)" }
    static func toolReturned(_ name: String) -> String { isEN ? "\(name) returned" : "\(name) 返回" }
    static func toolFailed(_ name: String) -> String { isEN ? "\(name) failed" : "\(name) 失败" }
    static var collapse: String { isEN ? "Collapse" : "收起" }
    static var details: String { isEN ? "Details" : "详情" }

    // MARK: - Pricing

    static var choosePlan: String { isEN ? "Choose Your Plan" : "选择你的套餐" }
    static func currentBalance(_ tokens: Int) -> String { isEN ? "Balance: \(tokens) tokens" : "当前余额：\(tokens) tokens" }
    static var paymentRedirect: String { isEN ? "Redirected to payment, waiting..." : "已跳转支付页面，等待支付完成..." }
    static var paymentSuccess: String { isEN ? "Payment successful! Balance updated" : "支付成功！余额已更新" }
    static var paymentIncomplete: String { isEN ? "Payment incomplete" : "支付未完成" }
    static var pleaseSignIn: String { isEN ? "Please sign in first" : "请先登录" }
    static func subscriptionFailed(_ err: String) -> String { isEN ? "Subscription failed: \(err)" : "订阅失败：\(err)" }
    static var mostPopular: String { isEN ? "Most Popular" : "最受欢迎" }
    static var paying: String { isEN ? "Paying..." : "支付中..." }
    static var subscribe: String { isEN ? "Subscribe" : "立即订阅" }
    static var currentPlan: String { isEN ? "Current Plan" : "当前套餐" }
    static var upgradeBtn: String { isEN ? "Upgrade" : "升级" }
    static var currentBadge: String { isEN ? "Current" : "当前" }
    static var planUnavailable: String { isEN ? "Unavailable" : "不可选" }
    static var cancelSubscription: String { isEN ? "Cancel subscription" : "取消订阅" }
    static var cancelSubscriptionHint: String { isEN ? "No longer need renewal?" : "不再续费？" }
    static var cancelSubscriptionConfirmMessage: String {
        isEN ? "After confirming, your plan will not renew after the current period ends."
             : "确认后，当前周期结束后将不再自动续费。"
    }
    static var confirmCancel: String { isEN ? "Confirm" : "确认取消" }
    static var cancelSubscriptionSuccess: String { isEN ? "Subscription canceled" : "已取消订阅" }
    static var expiresNoRenewal: String {
        isEN ? "Expires at period end, no auto-renewal" : "到期结束，不自动续费"
    }
    static var statusCancelled: String { isEN ? "Cancelled" : "已取消" }
    static var statusExpired: String { isEN ? "Expired" : "已过期" }
    static var resumeSubscription: String { isEN ? "Resume subscription" : "继续订阅" }
    static var resubscribe: String { isEN ? "Resubscribe" : "重新订阅" }
    static var resumeSubscriptionSuccess: String { isEN ? "Subscription resumed" : "已恢复订阅" }
    static func daysLeft(_ n: Int) -> String {
        if n <= 0 { return isEN ? "Expired" : "已到期" }
        return isEN ? "\(n) days left" : "\(n) 天后到期"
    }
    static var autoRenewOn: String { isEN ? "Auto-renewal enabled" : "自动续费已开启" }
    static var autoRenewOff: String { isEN ? "Auto-renewal disabled" : "自动续费已关闭" }
    static var resumeConfirmMessage: String {
        isEN ? "Resume auto-renewal? Your subscription will renew automatically at the end of the current period."
             : "确认恢复自动续费？当前周期结束后将自动续费。"
    }
    static var cancelledExpiresInPrefix: String { isEN ? "Subscription cancelled, will expire in " : "已取消续费，将在 " }
    static var cancelledExpiresInSuffix: String { isEN ? " days" : " 天后到期" }

    // Trial
    static var trialBadge: String { isEN ? "Trial" : "试用中" }
    static func trialDaysLeft(_ n: Int) -> String {
        if n <= 0 { return isEN ? "Trial expired" : "试用已到期" }
        return isEN ? "Trial: \(n) days left" : "试用剩余 \(n) 天"
    }
    static var trialExpired: String { isEN ? "Trial Expired" : "试用已到期" }
    static var trialExpiredMessage: String {
        isEN ? "Your 3-day free trial has ended.\nSubscribe to continue using Clawbie."
             : "你的 3 天免费试用已结束。\n请订阅后继续使用 Clawbie。"
    }
    static var subscribeToContinue: String { isEN ? "Subscribe Now" : "立即订阅" }

    // Pricing plan data
    static var planClawbieName: String { isEN ? "Clawbie Only" : "Clawbie 基础版" }
    static var planClawbieSub: String { "/ mo" }
    static var planClawbieTokens: String { isEN ? "Use your own API Key" : "自带 API Key 使用" }
    static var planClawbieFeatures: [String] {
        isEN ? ["No tokens included", "All Skills & MCP", "Full memory system", "Unlimited heartbeat tasks", "Bring your own API Key"]
             : ["不含 token 额度", "全部 Skills 与 MCP", "完整记忆功能", "无限心跳任务", "自带 API Key 使用"]
    }
    static var planBasicName: String { isEN ? "Basic" : "基础版" }
    static var planBasicTokens: String { isEN ? "Chat: Sonnet 500K / Haiku 1.8M / Opus 100K" : "聊天：Sonnet 50万 / Haiku 180万 / Opus 10万" }
    static var planBasicFeatures: [String] {
        isEN ? ["Sonnet 500K or Haiku 1.8M or Opus 100K", "Utility Haiku 500K (memory & heartbeat)", "All Skills & MCP", "Full memory system", "Unlimited heartbeat tasks"]
             : ["Sonnet 50万 或 Haiku 180万 或 Opus 10万", "辅助 Haiku 50万（记忆与心跳）", "全部 Skills 与 MCP", "完整记忆功能", "无限心跳任务"]
    }
    static var planProName: String { isEN ? "Pro" : "Pro 版" }
    static var planProTokens: String { isEN ? "Chat: Sonnet 1.5M / Haiku 5.6M / Opus 300K" : "聊天：Sonnet 150万 / Haiku 560万 / Opus 30万" }
    static var planProFeatures: [String] {
        isEN ? ["Sonnet 1.5M or Haiku 5.6M or Opus 300K", "Utility Haiku 1M (memory & heartbeat)", "All Skills & MCP", "Full memory system", "Unlimited heartbeat tasks"]
             : ["Sonnet 150万 或 Haiku 560万 或 Opus 30万", "辅助 Haiku 100万（记忆与心跳）", "全部 Skills 与 MCP", "完整记忆功能", "无限心跳任务"]
    }
    static var planMaxName: String { isEN ? "Max" : "Max 版" }
    static var planMaxTokens: String { isEN ? "Chat: Sonnet 3.5M / Haiku 13M / Opus 700K" : "聊天：Sonnet 350万 / Haiku 1300万 / Opus 70万" }
    static var planMaxFeatures: [String] {
        isEN ? ["Sonnet 3.5M or Haiku 13M or Opus 700K", "Utility Haiku 2M (memory & heartbeat)", "All Skills & MCP", "Full memory system", "Unlimited heartbeat tasks"]
             : ["Sonnet 350万 或 Haiku 1300万 或 Opus 70万", "辅助 Haiku 200万（记忆与心跳）", "全部 Skills 与 MCP", "完整记忆功能", "无限心跳任务"]
    }

    // MARK: - Tool Market

    static var myTools: String { isEN ? "My Tools" : "我的工具" }
    static var toolMarket: String { isEN ? "Tool Market" : "工具市场" }
    static var systemTool: String { isEN ? "System" : "系统工具" }
    static func toolCount(_ n: Int) -> String { isEN ? "\(n) tools" : "\(n) 个工具" }
    static var loadFailed: String { isEN ? "Load Failed" : "加载失败" }
    static var reload: String { isEN ? "Reload" : "重新加载" }
    static var searchTools: String { isEN ? "Search tools..." : "搜索工具…" }
    static var installFailed: String { isEN ? "Install Failed" : "安装失败" }
    static var customAdd: String { isEN ? "Custom Add" : "自定义添加" }
    static var getFromWebsite: String { isEN ? "Get from website" : "请去官网获取" }
    static var toolRequiresKey: String { isEN ? "This tool requires an API Key" : "此工具需要 API Key 才能使用" }
    static var toolDetails: String { isEN ? "Tool Details" : "工具详情" }
    static var serverName: String { isEN ? "Server name (unique identifier)" : "服务器名称（唯一标识）" }
    static var startCommand: String { isEN ? "Start command (one arg per line, or space-separated)" : "启动命令（每行一个参数，或空格分隔）" }
    static var customMCPServer: String { isEN ? "Custom MCP Server" : "自定义 MCP 服务器" }
    static var commandEmpty: String { isEN ? "Command cannot be empty" : "命令不能为空" }
    static func disconnectError(_ err: String) -> String { isEN ? "Disconnect failed: \(err)" : "断开失败：\(err)" }
    static func reloadError(_ err: String) -> String { isEN ? "Reload failed: \(err)" : "重新加载失败：\(err)" }
    static func addError(_ err: String) -> String { isEN ? "Add failed: \(err)" : "添加失败：\(err)" }
    static func installError(_ err: String) -> String { isEN ? "Install failed: \(err)" : "安装失败：\(err)" }

    // MARK: - Skill Market

    static var mySkills: String { isEN ? "My Skills" : "我的技能" }
    static var skillMarket: String { isEN ? "Skill Market" : "技能市场" }
    static var noSkills: String { isEN ? "No Skills" : "暂无技能" }
    static var addFirstSkill: String { isEN ? "Add your first skill from the market" : "去市场添加你的第一个技能" }
    static var builtIn: String { isEN ? "Built-in" : "内置" }
    static var deleteSkill: String { isEN ? "Delete Skill" : "删除技能" }
    static var searchSkills: String { isEN ? "Search skills..." : "搜索技能…" }
    static var loadingMarket: String { isEN ? "Loading market..." : "加载市场…" }
    static var exampleUsage: String { isEN ? "Example Usage" : "示例用法" }
    static var skillDetails: String { isEN ? "Skill Details" : "技能详情" }

    // MARK: - Memory

    // Sub-core types
    static var memIdentity: String { isEN ? "Identity" : "身份" }
    static var memContact: String { isEN ? "Contact" : "联系人" }
    static var memPreference: String { isEN ? "Preference" : "偏好" }
    static var memHabit: String { isEN ? "Habit" : "习惯" }
    static var memSkill: String { isEN ? "Skill" : "技能" }
    static var memGoal: String { isEN ? "Goal" : "目标" }
    static var memValue: String { isEN ? "Value" : "价值观" }
    // General types
    static var memTask: String { isEN ? "Task" : "任务" }
    static var memEvent: String { isEN ? "Event" : "事件" }
    static var memFact: String { isEN ? "Fact" : "事实" }
    static var memProject: String { isEN ? "Project" : "项目" }
    // Tier labels
    static var memSubCore: String { isEN ? "Important" : "次核心" }
    static var memGeneral: String { isEN ? "General" : "一般" }
    static var loadingMemories: String { isEN ? "Loading memories..." : "加载记忆中…" }
    static var noCategoryMemories: String { isEN ? "No memories in this category" : "该分类暂无记忆" }
    static var clearAllMemories: String { isEN ? "Clear all memories?" : "确定清空所有记忆？" }
    static var clear: String { isEN ? "Clear" : "清空" }
    static var deduplicate: String { isEN ? "Deduplicate" : "去重" }
    static var deduplicateHelp: String { isEN ? "Auto merge duplicate or similar memories" : "自动合并重复或高度相似的记忆" }
    static var noMemories: String { isEN ? "No memories yet" : "还没有记忆" }
    static var chatMoreForMemories: String { isEN ? "Chat more, Clawbie will remember important info" : "多聊几轮，Clawbie 会自动记下重要信息" }
    static func mergedMemories(_ n: Int) -> String { isEN ? "Merged \(n) duplicate memories" : "已合并 \(n) 条重复记忆" }
    static var noDuplicates: String { isEN ? "No duplicate memories found" : "没有发现重复记忆" }
    static var memCompress: String { isEN ? "Compress & Refine" : "压缩提纯" }
    static func memCompressed(_ label: String, _ before: Int, _ after: Int) -> String {
        isEN ? "\(label): \(before) → \(after) memories" : "\(label)：\(before) 条 → \(after) 条"
    }
    static func memCompressFailed(_ label: String) -> String {
        isEN ? "Failed to compress \(label)" : "\(label) 压缩失败"
    }

    // MARK: - Diary (MemoryPortraitView)

    static var diarySubtitle: String { isEN ? "Every day, about you and me" : "记录每一天，关于你和我的小事" }
    static var diaryLoading: String { isEN ? "Clawbie is reading diary..." : "Clawbie 正在翻阅日记…" }
    static var noDiary: String { isEN ? "No diary entries" : "还没有日记" }
    static var diaryAutoGenerate: String { isEN ? "Chat with Clawbie, diary will be auto-generated" : "和 Clawbie 聊聊天，日记就会自动生成" }
    static var diaryWriting: String { isEN ? "Clawbie is writing today's diary..." : "Clawbie 正在写今天的日记…" }
    static var diaryUpdated: String { isEN ? "Today's diary has been updated" : "今天的日记已更新" }

    // MARK: - Projects

    static var defaultProject: String { isEN ? "Default" : "默认" }
    static func fileCount(_ n: Int) -> String { isEN ? "\(n) files" : "\(n) 个文件" }
    static var newProject: String { isEN ? "New Project" : "新建项目" }
    static var noFiles: String { isEN ? "No files yet, ask Clawbie to generate some" : "暂无文件，让 Clawbie 帮你生成一些吧" }
    static var openWithDefault: String { isEN ? "Open with default app" : "用默认应用打开" }
    static var showInFinder: String { isEN ? "Show in Finder" : "在 Finder 中显示" }
    static var projectName: String { isEN ? "Project Name" : "项目名称" }
    static var projectDesc: String { isEN ? "Description (optional)" : "项目介绍（可选）" }
    static var create: String { isEN ? "Create" : "创建" }
    static var newProjectMsg: String { isEN ? "Enter name and description, README.md will be auto-generated" : "输入项目名称和介绍，将自动生成 README.md" }

    // MARK: - ChatViewModel

    static var greeting: String {
        isEN ? "Hey! I'm Clawbie, your personal assistant~ 🦞\nHow can I help you?"
             : "你好！我是 Clawbie，你的私人助理～ 🦞\n有什么我可以帮你的吗？"
    }
    static var stopped: String { isEN ? "(Stopped)" : "（已停止）" }
    static var deleteMessage: String { isEN ? "Delete" : "删除" }
    static var summarizeChat: String { isEN ? "Summarize" : "总结压缩" }
    static var networkError: String {
        isEN ? "Hang tight, my network is a bit wobbly. Clawbie will be right back~ 🦞"
             : "主人不要着急，我的网络不太好，Clawbie 会马上回来的～ 🦞"
    }

    // MARK: - Watchlist

    static var watchlist: String { isEN ? "Watchlist" : "关注事项" }
    static var noWatchItems: String { isEN ? "No watch items" : "还没有关注事项" }
    static var addWatchHint: String { isEN ? "Add items to monitor, Clawbie will notify you of updates" : "添加关注内容，Clawbie 会定期检查并通知你" }
    static var watchQuery: String { isEN ? "What to watch..." : "关注什么…" }
    static var checkInterval: String { isEN ? "Check interval" : "检查间隔" }
    static func minutesInterval(_ n: Int) -> String { isEN ? "\(n) min" : "\(n) 分钟" }
    static var notifySettings: String { isEN ? "Notification Settings" : "通知设置" }
    static var smtpHost: String { isEN ? "SMTP Host" : "SMTP 服务器" }
    static var smtpPort: String { isEN ? "Port" : "端口" }
    static var smtpUser: String { isEN ? "Username" : "用户名" }
    static var smtpPass: String { isEN ? "Password" : "密码" }
    static var notifyEmail: String { isEN ? "Notify Email" : "通知邮箱" }
    static var enableNotify: String { isEN ? "Enable email notifications" : "启用邮件通知" }
    static var lastChecked: String { isEN ? "Last checked" : "上次检查" }
    static var notYetChecked: String { isEN ? "Not checked yet" : "尚未检查" }
    static var newWatchItem: String { isEN ? "New Watch Item" : "新增关注" }
    static var scheduledTask: String { isEN ? "Scheduled" : "定时" }
    static var pollTask: String { isEN ? "Monitor" : "轮询监控" }
    static var parsing: String { isEN ? "Understanding..." : "正在理解…" }
    static var heartbeat: String { isEN ? "Heartbeat" : "心跳" }
    static var heartbeatOffHint: String { isEN ? "Scheduled tasks not affected" : "不影响定时任务" }
    static var executionLog: String { isEN ? "Execution Log" : "执行日志" }
    static var noLogs: String { isEN ? "No execution logs" : "暂无执行记录" }
    static var editTask: String { isEN ? "Edit Task" : "编辑任务" }

    // MARK: - Launch

    static var launchFailed: String { isEN ? "Launch Failed" : "启动失败" }
}
