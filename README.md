<p align="center">
  <img src="https://www.myclaw.studio/soft_release/logo.png" alt="MyClaw Logo" width="128" height="128">
</p>

<h1 align="center">MyClaw — Your AI Desktop Companion for macOS</h1>

<p align="center">
  <strong>A full-stack Swift AI assistant that lives on your Mac.</strong><br>
  Run local LLMs, connect to cloud providers, automate your desktop — all from one native app.
</p>

<p align="center">
  <a href="#installation">Installation</a> &bull;
  <a href="#key-features">Features</a> &bull;
  <a href="#architecture">Architecture</a> &bull;
  <a href="#getting-started">Get Started</a> &bull;
  <a href="#contributing">Contributing</a> &bull;
  <a href="#license">License</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-5.0-orange" alt="Swift 5.0">
  <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License">
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen" alt="Zero Dependencies">
</p>

---

## Why MyClaw?

Most AI chat apps are Electron wrappers around web UIs. MyClaw is different:

- **100% native Swift** — No Electron, no Python backend, no Node.js. Just SwiftUI + a lightweight embedded HTTP server. The entire app is a single binary under 15 MB.
- **Zero external dependencies** — Built entirely on Apple system frameworks (Network, CryptoKit, SwiftUI). No CocoaPods, no SPM packages, no `node_modules`.
- **Runs on your Mac, not in a browser** — Full macOS integration: Accessibility API, file system access, shell execution, system notifications, and native UI controls.
- **Your keys, your data** — In local mode, API keys are stored in macOS UserDefaults on your machine. No data leaves your Mac except direct API calls to your chosen provider.

---

## Key Features

### Multi-Provider AI Chat

Connect to the AI provider of your choice with a single API key:

| Provider | Models | Tool Calling |
|----------|--------|:------------:|
| **Anthropic Claude** | Sonnet 4.6, Haiku 4.5, and more | Yes |
| **OpenAI** | GPT-4o, GPT-4o-mini, and more | Yes |
| **Google Gemini** | Gemini Pro, Flash | Yes |
| **DeepSeek** | DeepSeek Chat, Coder | Yes |

All providers support the full ReAct agent loop with tool calling — not just simple chat.

### 10 Built-in System Tools

MyClaw ships with a powerful set of tools that the AI can use autonomously:

| Tool | What It Does |
|------|-------------|
| **File Manager** | Read, write, edit, and organize files in your project directory |
| **Code Runner** | Execute Python and Shell scripts with full PATH detection |
| **Web Search** | Search the web via DuckDuckGo (text and news) |
| **URL Fetcher** | Fetch and extract content from any webpage |
| **UI Control** | Automate your Mac: click buttons, type text, take screenshots, open apps |
| **System Info** | Query installed apps, running processes, hardware specs |
| **Memory Search** | Retrieve from Clawbie's long-term memory about you |
| **Project Manager** | Create and manage project workspaces |
| **Skill Saver** | Save useful workflows as reusable skills |
| **Tool Manager** | Install MCP servers and Composio integrations on the fly |

### MCP (Model Context Protocol) Integration

MyClaw is a full MCP client. Install any MCP-compatible server and your AI gains new capabilities:

```
You: "Install the filesystem MCP server"
Clawbie: [installs mcp server] Done! I can now read and manage files
         outside the project directory.
```

- JSON-RPC over stdio transport
- Auto-discovery and handshake
- Tools persist across sessions (`~/.aichat/mcp_servers.json`)
- The AI can self-install new MCP servers via the `manage_tools` tool

### Composio: 900+ Third-Party Tool Integrations

Connect to Gmail, Slack, GitHub, Google Calendar, Notion, and hundreds more through [Composio](https://composio.dev):

1. Browse the Composio marketplace from inside MyClaw
2. Authorize with OAuth (opens in your browser)
3. The AI immediately gains access to the new tools

No code changes needed. No API wiring. Just authorize and go.

### Agent Workers (Sub-Agents)

Create specialized AI agents that work autonomously:

- **Custom system prompts** — Give each agent a focused persona and instructions
- **Selective tool access** — Assign only the tools each agent needs
- **Independent execution** — Agents run their own ReAct loops with separate step limits
- **Real-time transparency** — Watch agent thinking, tool calls, and results stream live
- **AI-assisted creation** — Describe what you want and let MyClaw generate the agent config

### Long-Term Memory

Clawbie remembers you across conversations:

- **Sub-core memory**: Your identity, preferences, habits, skills, and goals
- **General memory**: Tasks, events, facts, and project context
- **Core memory**: An AI-generated distilled profile, auto-refreshed every 2 hours
- **Semantic search**: Fuzzy character n-gram matching (works for all languages including CJK)
- **Auto-extraction**: Key information is automatically extracted after each conversation

### Diary System

Clawbie writes a first-person diary entry at the end of each day, reflecting on your conversations with weather and mood annotations.

### Watchlist (Scheduled Tasks)

Set up recurring tasks with cron expressions or polling intervals:

```
You: "Check Hacker News every 2 hours and notify me of any AI-related posts"
Clawbie: [creates watchlist item] I'll check HN every 2 hours and send
         you a notification when I find relevant posts.
```

### macOS Desktop Automation

Through the built-in UI Control tool and OS Bridge:

- **Inspect** any UI element on screen
- **Click** buttons, menus, and controls
- **Type** text into any application
- **Take screenshots** for visual context
- **Open URLs** and launch applications
- **Navigate menus** programmatically

Requires macOS Accessibility permissions (the app will prompt you).

### Additional Features

- **Image & PDF support** — Drag and drop images or PDFs into chat; Claude processes them natively
- **Voice input** — Speak to Clawbie using macOS speech recognition
- **Skill marketplace** — Browse, install, and share reusable AI workflows
- **Project workspaces** — Organize files and context per project
- **Bilingual UI** — Full English and Chinese interface
- **Chat history** — Persistent conversation logs with search

---

## Architecture

```
+---------------------------------------------+
|              SwiftUI Frontend                |
|   ContentView - ChatView - SettingsView     |
+---------------------------------------------+
|         WebSocket (ws://127.0.0.1:8000)      |
+---------------------------------------------+
|          Swift HTTP Backend Server           |
|  +-------------+  +----------------------+  |
|  | Chat Handler |  |   REST API Routes    |  |
|  |  (WebSocket) |  | /agents /skills /mem |  |
|  +------+------+  +----------------------+  |
|         |                                    |
|  +------v----------------------------------+ |
|  |       Agent Orchestrator (ReAct)        | |
|  |  LLM Call -> Tool Execution -> Loop     | |
|  +------+----------------------------------+ |
|         |                                    |
|  +------v------+ +--------+ +-----------+   |
|  | System Tools| |  MCP   | | Composio  |   |
|  |  (10 built- | |Servers | |  (900+    |   |
|  |   in tools) | |(stdio) | |   tools)  |   |
|  +-------------+ +--------+ +-----------+   |
+---------------------------------------------+
|          OS Bridge (port 8001)              |
|     macOS Accessibility API proxy           |
+---------------------------------------------+
```

- **Frontend**: Pure SwiftUI with reactive state management
- **Backend**: Embedded Swift HTTP server on `127.0.0.1:8000` using Apple's Network framework
- **Agent Loop**: ReAct pattern — up to 30 steps of LLM reasoning + tool execution per turn
- **OS Bridge**: Separate HTTP server on port 8001 exposing macOS Accessibility APIs
- **Zero IPC overhead**: Everything runs in-process; no shell-outs, no child processes (except MCP servers)

---

## Installation

### Download Pre-built DMG

Download the latest release from the [Releases](https://github.com/myclaw-studio/myclaw-studio-macos/releases) page:

- **Apple Silicon (M1/M2/M3/M4)**: `my_claw-macos-swift-*-arm64-*.dmg`
- **Intel**: `my_claw-macos-intel-*-x86_64-*.dmg`

### Build from Source

**Requirements:**
- macOS 14.0 (Sonoma) or later
- Xcode 15.0 or later

```bash
# Clone the repository
git clone https://github.com/myclaw-studio/myclaw-studio-macos.git
cd myclaw-studio-macos

# Build and install (creates DMG, copies to /Applications, launches)
./package.sh

# Or build with Xcode
open AIChat/AIChat.xcodeproj
# Select scheme "AIChat" -> My Mac -> Build & Run
```

The build produces a universal binary (arm64 + x86_64) with ad-hoc signing. No Apple Developer account required.

---

## Getting Started

### 1. Launch MyClaw

Open the app from `/Applications/MyClaw.app`. On first launch, you'll be prompted to grant Accessibility permissions (required for UI automation features).

### 2. Configure Your AI Provider

Go to **Settings** and enter your API key for any supported provider:

- **Anthropic**: Get your key at [console.anthropic.com](https://console.anthropic.com)
- **OpenAI**: Get your key at [platform.openai.com](https://platform.openai.com)

### 3. Start Chatting

That's it. Type a message and Clawbie will respond. Ask it to:

- *"Search the web for the latest macOS release notes"*
- *"Create a Python script that converts CSV to JSON"*
- *"Open Safari and take a screenshot"*
- *"Read my project files and suggest improvements"*

### 4. Extend with Tools

Install MCP servers or connect Composio integrations to give Clawbie new capabilities:

```
You: "Search the tool market for a database tool"
Clawbie: [searches Composio marketplace] I found PostgreSQL, MongoDB,
         MySQL integrations. Would you like to install one?
```

---

## Project Structure

```
AIChat/
├── AIChat.xcodeproj/          # Xcode project
├── AIChat/
│   ├── AIChatApp.swift        # App entry point
│   ├── ContentView.swift      # Main UI (chat, sidebar, input)
│   ├── Models/
│   │   ├── AppConfig.swift    # UserDefaults-backed configuration
│   │   └── Message.swift      # Chat message model
│   ├── ViewModels/
│   │   └── ChatViewModel.swift # Chat state management
│   ├── Views/
│   │   ├── SettingsView.swift # Settings panel
│   │   ├── WatchlistView.swift # Scheduled tasks UI
│   │   └── ...
│   ├── Services/
│   │   ├── SwiftBackendServer.swift  # Embedded HTTP server
│   │   ├── SwiftOrchestrator.swift   # ReAct agent loop
│   │   ├── SwiftProviders.swift      # LLM provider implementations
│   │   ├── SwiftTools.swift          # 10 system tools
│   │   ├── SwiftMCPClient.swift      # MCP + Composio + SubAgent
│   │   ├── SwiftMemoryManager.swift  # Long-term memory system
│   │   ├── BackendService.swift      # WebSocket chat client
│   │   └── ...
│   └── Resources/
│       └── cloud_config.json  # Cloud service config (empty by default)
├── scripts/
│   ├── notarize-local.sh      # Apple notarization helper
│   └── setup-notary-keychain.sh
└── package.sh                 # Build & package script
```

---

## Configuration

### Local Mode (Default for Open Source)

MyClaw runs in **local mode** by default. All AI calls go directly from your Mac to the provider's API. You need your own API key.

### Data Storage

All user data is stored locally at `~/.aichat/`:

```
~/.aichat/
├── projects/          # Project workspaces
├── memories/          # Long-term memory store
├── chat_logs/         # Daily JSONL chat logs
├── skills.json        # Saved skills
├── agents.json        # Agent worker configs
├── mcp_servers.json   # MCP server configs
└── composio_toolkits.json  # Composio integrations
```

---

## Contributing

We welcome contributions! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines.

### Quick Start for Contributors

```bash
git clone https://github.com/myclaw-studio/myclaw-studio-macos.git
cd myclaw-studio-macos
open AIChat/AIChat.xcodeproj
```

Build and run the `AIChat` scheme. The app will start the backend server automatically on port 8000.

---

## License

MyClaw is released under the [MIT License](LICENSE). You are free to use, modify, and distribute this software.

Copyright (c) 2025 MyClaw Studio

---

<p align="center">
  <sub>Built with pure Swift. No Electron. No dependencies. Just a native Mac app.</sub>
</p>
