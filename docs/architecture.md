# My Claw — 系统架构文档

> 版本：v1.2 | 更新日期：2026-03-07

---

## 一、当前架构概览

My Claw 是一个 macOS 原生 AI 助手，由 SwiftUI 前端 + Python FastAPI 后端组成。后端通过 PyInstaller 打包后内嵌于 App Bundle，由主进程在启动时拉起。

```
╔══════════════════════════════════════════════════════════════════════╗
║                      My Claw — 系统架构图                            ║
╚══════════════════════════════════════════════════════════════════════╝

┌─────────────────────────────────────────────────────────────────────┐
│                    macOS App (SwiftUI) — 前端层                      │
│                                                                     │
│  Views: ContentView / SidebarView / ChatView / MemoryView           │
│         SettingsView / SkillMarketView / WatchlistView              │
│         ToolMarketView (Tools / AI Workers / Skills 三 Tab)         │
│         SVGImageView (RemoteImage - 异步加载远程图片/SVG)            │
│                          ▲ @Published                               │
│  ViewModels: ChatViewModel  AuthViewModel                           │
│                          ▲                                          │
│  Services:                                                          │
│    BackendService    ── HTTP/WebSocket ──► Python Backend :8000     │
│    AuthService       ── Keychain token 存储                         │
│    BackendLauncher   ── spawn aichat-backend 子进程                 │
│    VoiceService      ── 语音输入                                    │
│                                                                     │
│  OSBridgeServer (:8001) — AX 权限代理 (Swift 持有 AX 授权)          │
│    GET  /os/ax/permission   POST /os/ax/inspect                     │
│    POST /os/ax/click        POST /os/ax/type                        │
│    POST /os/ax/press        POST /os/ax/menu                        │
│    GET  /os/ax/list-apps                                            │
└──────────────────────────┬──────────────────────────────────────────┘
                           │ HTTP localhost:8001 (AX calls)
                           │
┌──────────────────────────▼──────────────────────────────────────────┐
│                 Python Backend (FastAPI, port: 8000)                 │
│                                                                     │
│  main.py — REST + WebSocket 入口                                    │
│    WS  /ws/chat                                                     │
│    GET /health  POST /chat/summarize                                │
│    GET|POST|DELETE /memory/*  POST /memory/deduplicate              │
│    POST /memory/compress/{type}  GET|POST /memory/diary             │
│    GET|POST|DELETE /skills  GET /skill-market  POST /skill-market/* │
│    GET|POST|DELETE /projects  GET /projects/{name}/files            │
│    GET|POST|PUT|DELETE /agents  POST /agents/generate               │
│    GET /tools  GET|POST|DELETE|POST /mcp/*                          │
│    GET|POST|PUT|DELETE /watchlist  GET|POST /watchlist/config       │
│                                                                     │
│  AgentOrchestrator — ReAct 循环 (max 30 steps)                     │
│    ├─ LLM Providers: Claude / OpenAI / TuuAI                       │
│    ├─ 多模态支持: PNG/JPEG/GIF/WEBP/PDF 图像内容块                  │
│    └─ Tools:                                                        │
│         web_search      → DuckDuckGo                               │
│         fetch_url       → 网页抓取                                  │
│         code_runner     → Python/Shell 沙箱执行                     │
│         file_manager    → 读写本地文件                              │
│         ui_inspector    → OSBridgeServer:8001 → macOS AX API       │
│           └─ open_url   → osascript（无需 AX 权限）                 │
│         memory_search   → MemoryManager 语义/关键词检索（NEW）      │
│         project_manager / system_info / save_skill                 │
│         mcp_client      → 外部 MCP Server (stdio JSON-RPC)         │
│         agent__<id>     → SubAgentTool（AI 员工，可嵌套调用）        │
│                                                                     │
│  SubAgentTool / AgentWorkerRegistry (NEW)                           │
│    • 用户自定义 AI 员工，持久化至 ~/.aichat/agents.json             │
│    • 每个员工 = 独立 AgentOrchestrator 实例（专属 prompt+工具）     │
│    • 主 Agent 可像调用普通工具一样调用任意 AI 员工                  │
│    • LLM 自动生成员工配置（generate_agent_config）                  │
│                                                                     │
│  MemoryManager — 四层记忆 (~/.aichat/)                              │
│    • L1 滑动窗口：近 100 条对话（发送给 LLM）                       │
│    • L2 摘要压缩：LLM 摘要（最多 5 条）                             │
│    • L3 次核心记忆 sub_core_memories.json                           │
│         类型: identity/contact/preference/habit/skill/goal/value    │
│    • L3 一般记忆 general_memories.json                              │
│         类型: task/event/fact/project                               │
│    • 核心摘要 core_memory.json（每 2h 刷新, 注入系统 prompt）       │
│    • 权重公式: time_score×0.6 + freq_score×0.4                     │
│    • 嵌入: OpenAI text-embedding-3-small（无 key 则 hash 128-dim） │
│    • 日记系统: Clawbie 视角 LLM 日记，支持中/英文                   │
│                                                                     │
│  Skills Registry                                                    │
│    builtin/ (16个):                                                 │
│      文档: pdf / docx / xlsx / pptx / doc-coauthoring               │
│      开发: web-artifacts-builder / mcp-builder / webapp-testing     │
│            skill-creator                                            │
│      设计: canvas-design / algorithmic-art / frontend-design        │
│            slack-gif-creator / theme-factory / brand-guidelines     │
│      效率: internal-comms                                           │
│    用户自定义 Skill (JSON 配置) + Skill Market                      │
│                                                                     │
│  mcp_server.py — Clawbie MCP Server (stdio JSON-RPC)               │
│    让外部工具通过 MCP 协议调用 Clawbie 能力                         │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  外部依赖                                                           │
│  Anthropic Claude API  │  OpenAI API (含 Embeddings)               │
│  TuuAI Cloud API (tuuai.com) — 云模型路由 / Composio 集成 / 支付   │
│  Composio Toolkit — 第三方 App 集成（OAuth 连接管理）               │
│  DuckDuckGo  │  AWS S3                                              │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  CI/CD (.github/workflows/build-dmg.yml)                            │
│  Trigger: push to main/master  或 workflow_dispatch                 │
│  Matrix (并行双构建):                                               │
│    intel     macos-15-intel (x86_64, Xcode 16.2) ─┐               │
│    appleclip macos-14       (arm64,  Xcode 16.2) ──┴─ xcodebuild   │
│                             → PyInstaller → embed → DMG → S3       │
│                                                                     │
│  分支保护 (.github/workflows/branch-protection.yml)                 │
│  feature/* → dev → main 单向流，PR 分支命名强制规范                 │
│    feat/ fix/ docs/ ci/ refactor/ test/ chore/                      │
└─────────────────────────────────────────────────────────────────────┘
```

### 核心数据流

```
用户输入
  → ChatView → ChatViewModel.send()
  → BackendService (WebSocket :8000)
  → FastAPI /ws/chat
  → AgentOrchestrator [ReAct loop, max 30 steps]
      ├─ LLM Provider → tool_call
      ├─ Tool 执行
      │    ├─ ui_inspector → OSBridgeServer:8001 → Swift AX → macOS
      │    ├─ open_url → osascript → Safari（无需 AX 权限）
      │    ├─ web_search → DuckDuckGo
      │    ├─ code_runner → subprocess
      │    ├─ memory_search → MemoryManager（语义/关键词检索）
      │    └─ agent__<id>  → SubAgentTool（嵌套 AI 员工）
      │         └─ 内部独立 AgentOrchestrator [max N steps]
      │              └─ 员工专属 tools + LLM → 返回文本结果
      └─ 流式 SSE token → ChatViewModel → MessageBubble
```

### AI 员工（Agent Workers）系统

```
AgentWorkerRegistry (agents.json)
  ├─ AgentWorkerConfig: id / name / icon / description
  │   system_prompt / tools / model / max_steps
  └─ CRUD API: GET|POST|PUT|DELETE /agents
               POST /agents/generate (LLM 自动生成配置)

启动时: _register_agent_tools() 将所有员工注册为 SubAgentTool
主 Orchestrator 调用方式: agent__<id-前8位>(task="...")
工具继承规则:
  • 系统工具（非 MCP/非员工）: 自动继承
  • MCP / Composio 工具: 按员工 config.tools 显式配置
```

### 记忆检索工具（memory_search）

```
memory_search(query, mode="search"|"lookup", sub_core_k=5, general_k=5)
  ├─ search 模式: 向量余弦相似度（有 embedding）/ 字符 n-gram + 权重混合
  └─ lookup 模式: 子串关键词匹配，按权重排序
输出: 【次核心记忆】+ 【一般记忆】分组结果（含类型/文本/权重/命中数）
```

---

## 二、当前架构的问题

| 问题                                  | 影响                   |
| ------------------------------------- | ---------------------- |
| PyInstaller 打包体积大（~150-300MB）  | 分发成本高，下载慢     |
| App 启动需等 Python 进程就绪（~3-5s） | 用户体验差             |
| 后端崩溃 = 整个 App 失效              | 可用性低               |
| 无法独立更新后端                      | 必须重打包整个 App     |
| 子进程 spawn 在 macOS Sandbox 中受限  | App Store 上架受阻     |
| localhost TCP 端口冲突风险            | 多实例或端口占用时崩溃 |

---

## 三、架构演进方案

### 方案 A：LaunchAgent Daemon（推荐 ⭐ 短期）

将 Python 后端注册为 macOS LaunchAgent，用户登录后自动启动并常驻，App 只负责 UI。

```
~/Library/LaunchAgents/com.myclaw.backend.plist
  • KeepAlive: true   → 崩溃自动重启
  • RunAtLoad: true   → 用户登录自动启动
  • 独立于 App 生命周期

MyClaw.app (SwiftUI, 极轻量)
  └─ 检测 socket 是否可用 → 连接 → 展示 UI

优点：✅ App 秒启动  ✅ 后端独立更新  ✅ 崩溃自动恢复  ✅ macOS 原生
缺点：❌ 安装时需注册 plist  ❌ 后端常驻内存（~50-100MB）
```

**实现要点：**

- `installer.sh` 注册 LaunchAgent plist，`uninstaller.sh` 反注册
- App 启动时轮询 socket 可用性，不再 spawn 子进程
- `BackendLauncher` 改为 `BackendConnector`，只负责连接检测

---

### 方案 B：Unix Domain Socket 替换 TCP（渐进改进）

```
当前：HTTP over TCP
  localhost:8000 (Backend API)
  localhost:8001 (OS Bridge)

改为：HTTP over Unix Socket
  /tmp/myclaw-backend.sock
  /tmp/myclaw-osbridge.sock

优点：✅ 无端口冲突  ✅ 更快（省 TCP 握手）  ✅ 文件权限控制
缺点：❌ Swift URLSession 需要特殊配置  ❌ 调试工具支持弱于 HTTP
```

> 注意：OSBridgeServer 必须保留在 App 进程内（因为 AX 权限绑定到拥有 UI 的进程）。

---

### 方案 C：双 App Bundle 分离（适合商业化分发）

```
MyClaw.app        (SwiftUI UI,  ~5MB)
  ↕ Unix Socket / localhost
MyClaw Backend.app (Menu Bar App, Python FastAPI)
  • 独立分发、独立更新
  • 可通过 Homebrew 安装后端

优点：✅ 两者独立版本和分发  ✅ 后端可命令行使用
缺点：❌ 用户需安装两个组件  ❌ 初次配置体验割裂
```

---

### 方案 D：全 Swift 重写后端（长期 / App Store 目标）

```
MyClaw.app（纯 Swift/SwiftUI，单进程）
  • swift-anthropic / swift-openai 直调 LLM API
  • Apple Foundation Models（macOS 15 本地推理）
  • SwiftData 替代 JSON 文件记忆存储
  • App Intents 替代 Python Tool 系统
  • 无 Python 依赖，完全 MAS 合规

优点：✅ 单进程极简  ✅ 体积小（<20MB）  ✅ MAS 上架  ✅ 最佳性能
缺点：❌ 重写成本巨大  ❌ 丢失 Python 生态（MCP、DuckDuckGo 等）
```

---

## 四、方案选型建议

```
阶段          方案              核心改动
─────────────────────────────────────────────────────────
短期（快速落地）  方案 A            backend → LaunchAgent
                               移除 BackendLauncher spawn 逻辑
                               App 启动只做连接检测

中期（稳定性）   方案 A + B        LaunchAgent 常驻
                               Unix Socket 替换 TCP localhost

长期（商业化）   方案 D            逐步 Swift 重写 Agent/Tool
                               目标：Mac App Store 上架
```

---

## 五、关键技术约束

- **OSBridgeServer 必须在 App 进程内**：macOS AX 权限（辅助功能）绑定到拥有 UI 的进程，Python 后端无法直接获取，因此无论哪种方案，`OSBridgeServer` 始终运行在 SwiftUI App 进程中。
- **open_url 无需 AX**：通过 `osascript` 打开 URL，完全绕开 AX 权限限制，任何方案均适用。
- **objectVersion=77**：Xcode project 格式要求 Xcode 16+，CI 最低需要 macos-15 或 macos-14 runner。
- **MACOSX_DEPLOYMENT_TARGET=15.0**：`toolbarBackgroundVisibility` API 要求 macOS 15.0+，低于此版本无法编译。
- **SubAgent 递归深度**：SubAgentTool 内部递归调用 `AgentOrchestrator`，需注意 `max_steps` 控制防止无限嵌套（主 Agent 默认 30 步，子 Agent 默认 10 步）。
- **Composio OAuth 集成**：前端在 Tool Market 发起连接后，需在浏览器完成 OAuth 授权，App 最多轮询 30 次（2s 间隔）等待连接激活。
- **云模型路由**：当 `useOwnKey=false` 时，请求通过 TuuAI (`tuuai.com`) 云端路由，`configPayload()` 改为发送 `auth_token` 而非 `anthropic_api_key`。
