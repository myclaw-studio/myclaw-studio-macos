# AIChat 项目启动指南

## 项目结构

```
AIChat/
├── backend/          # Python 后端 (FastAPI + ReAct Agent)
│   ├── main.py
│   ├── start.sh      # 一键启动脚本
│   ├── requirements.txt
│   ├── agent/        # ReAct 循环 + 多模型 Provider + 记忆模块
│   ├── tools/        # web_search / run_code / file_manager
│   └── skills/       # Skill 注册表 (内置 + 用户自定义)
└── AIChat/           # iOS App (SwiftUI)
    ├── Models/       # Message, Skill, AppConfig
    ├── Services/     # BackendService (WebSocket), VoiceService
    ├── ViewModels/   # ChatViewModel
    └── Views/        # ContentView, MemoryView, SkillsView, SettingsView
```

## Step 1：启动 Python 后端

```bash
cd /Users/mac/project/AIChat/backend
./start.sh
```

首次运行会自动创建虚拟环境并安装依赖（需要几分钟）。
启动成功后终端显示：`Uvicorn running on http://0.0.0.0:8000`

## Step 2：在 Xcode 打开 iOS 项目

1. 打开 Xcode → 选择已有项目（AIChat.xcodeproj）
2. 把新增文件拖入 Xcode 项目（如果有新文件未加入）：
   - `Models/AppConfig.swift`、`Models/Skill.swift`
   - `Services/BackendService.swift`、`Services/VoiceService.swift`
   - `Views/MemoryView.swift`、`Views/SkillsView.swift`
3. Info.plist 添加语音权限：
   - `NSSpeechRecognitionUsageDescription` → "用于语音输入"
   - `NSMicrophoneUsageDescription` → "用于语音输入"
4. 选择目标设备，Cmd+R 运行

## Step 3：配置 App

1. 点击右上角 `⋯` → 设置（齿轮图标）
2. 填入：
   - 后端地址（默认 `http://localhost:8000`）
   - Anthropic API Key（sk-ant-...）
   - OpenAI API Key（可选）
3. 选择默认模型，点「保存」

> **iPhone 真机注意**：手机和 Mac 在同一 Wi-Fi 下，后端地址改为 Mac 的局域网 IP，如 `http://192.168.1.100:8000`

## 功能说明

| 功能 | 说明 |
|------|------|
| 对话 | 流式输出，展示工具调用过程 |
| 语音 | 点麦克风按钮说话，自动转文字 |
| 工具 | 搜索网页、执行 Python/Shell、管理文件 |
| 记忆 | 每轮对话后自动提取关键信息，点 `⋯` → 记忆管理可查看删除 |
| Skill | 内置通用/编程/研究助手，点 `⋯` → Skill 市场可切换或新建 |
| 多模型 | Claude / GPT-4o 均支持，设置中切换 |

## Git Hooks 设置

Clone 后执行一次，启用分支保护 hook：

```bash
git config core.hooksPath scripts/hooks
```
