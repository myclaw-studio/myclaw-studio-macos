# My Claw 项目开发指南

## 项目概览

My Claw 是一款 macOS 原生 AI 聊天助手应用，AI 人格名为 **Clawbie**（🦞 龙虾）。
架构：**全栈 Swift**（SwiftUI 前端 + Swift 后端服务），Bundle ID：`studio.myclaw.app`。

```
AIChat/
├── AIChat/AIChat/              # Swift 主工程
│   ├── AIChatApp.swift         # App 入口
│   ├── ContentView.swift       # 主界面（侧栏 + 聊天）
│   ├── L.swift                 # 所有 UI 文案（中英文）
│   ├── Models/                 # 数据模型（AppConfig, Skill, WatchItem 等）
│   ├── Services/               # 后端服务（SwiftBackendServer, WatchlistScheduler）
│   ├── ViewModels/             # 聊天 ViewModel
│   └── Views/                  # 各页面 View
├── scripts/
│   ├── notarize-local.sh       # 本地公证脚本（4 阶段：预检/提交/诊断/Staple）
│   └── setup-notary-keychain.sh # 一次性配置 Keychain 公证凭据
├── .github/
│   ├── workflows/              # CI/CD（build-dmg-arm64, build-dmg-intel, feishu-notify）
│   ├── entitlements.plist      # 代码签名权限
│   └── copilot-instructions.md # Agent 行为规则（机器可读）
├── docs/
│   └── feat_notarize.md        # 公证流程设计文档
└── package.sh                  # 本地打包脚本
```

---

## 日常开发流程

### 本地构建

```bash
# 使用 Xcode 打开项目
open AIChat/AIChat.xcodeproj

# 命令行构建 DMG（签名但不公证）
./package.sh

# 本地公证（CI 构建完成后下载 artifact 执行）
./scripts/notarize-local.sh path/to/my_claw.dmg
```

### 后端服务（Swift）

| 文件 | 职责 |
|------|------|
| `Services/SwiftBackendServer.swift` | Swift 内嵌后端服务核心 |
| `Services/WatchlistScheduler.swift` | 关注事项定时调度 |
| `Views/WatchlistView.swift` | 关注事项 UI |

### 新增功能常见模式

1. **新增 Service 端点** → `Services/SwiftBackendServer.swift` → 对应 View 调用
2. **新增页面** → `Views/XxxView.swift` → 在 `ContentView.swift` 添加路由
3. **新增 UI 文案** → 必须在 `L.swift` 定义，支持中英切换

---

## 版本发布

1. 修改 `package.sh` 中的 `VERSION="x.x.x"`
2. 提交 PR 到 `dev`，测试通过后发起 `dev → main` PR
3. CI 自动构建 DMG（arm64 + x86_64）并上传 S3
4. 本地执行公证：`./scripts/notarize-local.sh`

---

## 分支策略与 PR 规范

### 分支流

```
main          生产分支，只接受来自 dev 的 PR，由维护者合并
│
dev           集成分支，接受开发者 PR，CI 通过后可合并
│
feat/xxx      功能分支  ─┐
fix/xxx       修复分支   ├─ 均向 dev 提 PR，不允许直接向 main 提 PR
ci/xxx        CI 分支   ─┘
docs/xxx      文档分支
```

### 操作步骤

```bash
# 1. 从 dev 拉取最新代码，创建分支
git checkout dev && git pull origin dev
git checkout -b feat/my-feature

# 2. 开发 + 提交（遵循 Conventional Commits）
git commit -m "feat: add my feature"

# 3. 推送并向 dev 提 PR（不是 main）
git push origin feat/my-feature
gh pr create --base dev

# 4. CI 通过 + Review 通过 → 合并到 dev
# 5. dev 稳定后，维护者发起 dev → main 的 PR
```

### 分支命名

| 前缀 | 用途 | 示例 |
|------|------|------|
| `feat/` | 新功能 | `feat/add-voice-input` |
| `fix/` | Bug 修复 | `fix/open-url-ax-permission` |
| `docs/` | 文档 | `docs/update-architecture` |
| `ci/` | CI/CD | `ci/upgrade-runner-macos15` |
| `refactor/` | 重构 | `refactor/extract-tool-base` |
| `test/` | 测试 | `test/add-orchestrator-tests` |
| `chore/` | 依赖/杂项 | `chore/bump-fastapi` |

### Commit 规范

```
<type>: <简短描述（中英文均可）>

type: feat | fix | docs | ci | refactor | test | chore
```

### PR 规则

| | `main` | `dev` |
|--|------|-----|
| 允许来源 | 仅 `dev` | `feat/*` `fix/*` 等 |
| 需要 Review | ✅ | ✅ |
| CI 必须通过 | ✅ | ✅ |
| 直接 push | ❌ | ❌ |
| Force push | ❌ | ❌ |

> **CI 强制检查**：`branch-protection.yml` 会自动校验 PR 目标分支。
> 若非 `dev` 分支向 `main` 提 PR，CI 直接失败阻断合并。
