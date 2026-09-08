# TaiChi ☯️

macOS 的 Dock 就是个又老又古板的老登，所以我搞了这个。
(The macOS Dock is basically a stubborn old boomer, so I made this instead.)

---

## 🚀 快速启动

**1. 下载与安装**
- 前往项目的 Releases 页面下载最新的 `TaiChi.dmg`。
- 双击打开 `.dmg` 镜像文件，将里面的 `TaiChi.app` 拖入您的 `Applications` (应用程序) 文件夹中。

**2. 启动须知（必看）**
因为这个 App 暂时没有苹果开发者签名，直接双击打开可能会被 macOS 拦截，提示“无法验证开发者”或者“应用已损坏”。
别慌，这是正常现象。您有两种方式可以绕过拦截启动它：

**方式一：终端启动（推荐）**
直接打开终端 (Terminal)，执行以下命令抹除苹果的隔离标记并启动：
```bash
xattr -cr /Applications/TaiChi.app
open -a TaiChi
```

**方式二：右键强制打开法**
- 打开 Finder 的“应用程序”文件夹，找到 `TaiChi`。
- **按住键盘上的 `Control` 键**，然后再用鼠标点击 `TaiChi`（或者直接右键点击），在弹出的菜单中选择 **“打开”**。
- 在弹出的警告窗口中，无视警告，再次点击 **“打开”** 即可。

启动后，根据界面提示给一下需要的系统权限就能跑了。至于怎么用？都是大白话，自己悟吧！

---

## 🏝️ 灵动岛 (Dynamic Island)

- **状态显示**：播放音乐时，刘海下方会自动显示专辑封面和波形。
- **悬浮与固定**：鼠标悬停可展开详细面板。点击可将面板固定在屏幕顶端，此时面板变为半透明，且支持鼠标点击穿透，不影响背景应用的正常操作。
- **自适应缩放**：界面元素会根据屏幕分辨率和物理刘海大小自动进行等比缩放。

---

## 💉 Cyber 注入 (CDP Evaluate API)

- **调试模式**：可通过 Alfred 工作流自动拉起开启了远程调试端口（Remote Debugging Port）的 Electron/Chromium 应用。
- **动态执行**：提供本地 `/api/cyber/evaluate` 接口。你可以通过 POST 请求，利用 WebSocket (CDP) 向目标应用的页面上下文中注入并执行自定义 JavaScript 代码。

---

## 🛠 Hammerspoon 集成

- **自动部署**：启动时会自动在 `~/.hammerspoon` 目录下注入通信脚本，并生成 `taichi_env.lua` 配置文件。
- **双向通信**：TaiChi 与 Hammerspoon 之间建立了安全的通信 API，支持通过 Lua 脚本相互调用功能。

---

## 🎩 Alfred 联动 (Alfred Workflow)

我们为 Alfred 深度定制了 API 后端，你可以用最优雅的姿势掌控一切应用。

### 连招效果
- **全局雷达搜索**：输入 `cyber`，太极会在毫秒级全盘扫描 Mac 上所有的 Chromium/Electron 架构应用。
- **状态全息显示**：
  - `⚡️ 已注入`：应用已开启 Cyber 模式，并会展示开放的调试端口 (Port)。
  - `⚡︎ 正在普通运行`：应用目前是普通状态，回车将立刻强杀并重启进入 Cyber 模式。
  - `纯文本`：应用未启动，回车直接以 Cyber 模式拉起。

### 如何配置 Alfred Workflow
1. 在 Alfred 中创建一个 Blank Workflow。
2. 添加一个 **Script Filter** 输入节点。
3. 配置如下：
   - Keyword: `cyber`
   - Language: `/bin/bash`
   - Script: 
     ```bash
     curl -s "http://127.0.0.1:9216/api/launcher/filter?q={query}"
     ```
4. 将 Script Filter 的输出连接到一个 **Run Script** 动作节点。
5. Run Script 配置如下：
   - Language: `/bin/bash`
   - Script: 
     ```bash
     curl -s "http://127.0.0.1:9216/api/launcher/action?payload={query}"
     ```
6. 大功告成！呼出 Alfred 输入 `cyber chrome` 感受一下纯正的赛博朋克吧。

---

## 🚀 How to Start (English)

**1. Download & Install**
- Go to the repository's Releases page and download the latest `TaiChi.dmg`.
- Double-click the `.dmg` file and drag `TaiChi.app` into your `Applications` folder.

**2. Launching for the First Time (Important!)**
Because this app is currently unsigned, macOS Gatekeeper might block it and say it's "from an unidentified developer" or "damaged." 
Don't panic! You have two ways to bypass this:

**Option A: The Terminal Way (Recommended)**
Open your Terminal and run the following commands to strip the quarantine flag and launch the app:
```bash
xattr -cr /Applications/TaiChi.app
open -a TaiChi
```

**Option B: The Right-Click Way**
- Open your `Applications` folder in Finder and locate `TaiChi`.
- **Hold down the `Control` key** and click on `TaiChi` (or right-click it), then select **"Open"** from the context menu.
- A warning prompt will pop up. Ignore it and click **"Open"** again.

Once it's running, just follow the UI prompts to grant the necessary system permissions. As for how to use it... figure it out yourself!

---

## 🎩 Alfred God-Tier Integration (Alfred Workflow)

We have built a dedicated API backend for Alfred, allowing you to control any Chromium/Electron app with elegance.

### Features
- **Global Radar Search**: Type `cyber`, and TaiChi will scan all Chromium/Electron apps on your Mac in milliseconds.
- **Holographic Status Display**:
  - `⚡️ 已注入 (Injected)`: The app is in Cyber mode and its remote debugging port is displayed.
  - `⚡︎ 正在普通运行 (Running Normally)`: The app is running normally. Pressing Enter will force quit and relaunch it in Cyber mode.
  - `Plain Text`: The app is not running. Pressing Enter will launch it directly into Cyber mode.

### How to Configure Alfred Workflow
1. Create a **Blank Workflow** in Alfred.
2. Add a **Script Filter** input object.
3. Configure it as follows:
   - Keyword: `cyber`
   - Language: `/bin/bash`
   - Script: 
     ```bash
     curl -s "http://127.0.0.1:9216/api/launcher/filter?q={query}"
     ```
4. Connect the output of the Script Filter to a **Run Script** action object.
5. Configure the Run Script as follows:
   - Language: `/bin/bash`
   - Script: 
     ```bash
     curl -s "http://127.0.0.1:9216/api/launcher/action?payload={query}"
     ```
6. Done! Fire up Alfred, type `cyber chrome` and enjoy your pure cyberpunk workflow.

---

## 📋 完整功能清单 (Comprehensive Feature List)

太极 (TaiChi) 致力于将 macOS 的交互推向极致，以下是目前支持的所有核心功能板块：

### 🚀 一、基础启动与应用管理 (App Launcher & Manager)
作为一款现代化的快捷启动器，太极提供了强大的基础管理功能。
- **可视化应用抽屉**：直观展示系统中所有已安装和正在运行的应用状态。
- **快速拉起与状态监控**：一键管理应用的启动、强杀与状态监控，彻底替代 macOS 传统的 Dock。

### 💉 二、Cyber 注入系统 (CDP Remote Injection)
太极的核心魔法，用于深度控制和操控基于 Chromium / Electron 架构的应用程序。
- **动态拉起与脚本执行**：通过本地 HTTP 接口 (`/api/cyber/evaluate`)，利用 WebSocket (CDP) 向目标页面跨域注入并执行自定义 JavaScript 脚本。
- **全局雷达搜索**：深度集成 Alfred 工作流，全局扫描并毫秒级拉起应用的调试模式 (Remote Debugging Port)。
- **🕵️‍♀️ 寻星镜 (DOM Inspector)**：像浏览器开发者工具一样，在应用内可视化选取 DOM 元素。支持滚轮/方向键切换 DOM 层级，双击直接锁定目标并复制 Selector。
- **快捷重注入 (Re-inject)**：为避免快捷键冲突，直接在目标窗口悬浮的闪电图标上右键（或双指轻按），即可唤出菜单快速重新注入配置的脚本。

### 🏝️ 三、灵动岛与视觉交互 (Dynamic Island & UI)
超越硬件限制，为所有 Mac 带来优雅的交互式顶栏体验。
- **自适应状态全息屏**：完美适配有/无刘海屏幕，播放音乐时自动下沉展示专辑封面与音频波形。
- **多模式与状态栏歌词**：支持多种显示模式的无缝切换。特别新增“菜单栏歌词模式”，在顶部空间局促时也能优雅地显示滚动歌词。
- **悬浮控制面板**：鼠标悬停即可展开详细的控制台。支持将其固定在屏幕顶端，且自动进入“点击穿透”模式，不影响底层应用的正常操作。

### 🪟 四、全局视窗与系统自动化 (Hammerspoon & Automation)
通过与 Hammerspoon 的深度通信，将对系统窗口与视觉的控制力提升到新高度。
- **全局悬浮应用管理**：支持一键将特定应用窗口设为“置顶悬浮”状态，并提供快捷操作，可以瞬间全局隐藏或显示所有被太极置顶的窗口。
- **沉浸式壁纸调度**：支持通过 Hammerspoon 联动自动切换或调度系统壁纸，打造沉浸式的桌面环境体验。
- **自动化 Lua 部署**：启动太极时，底层自动向 `~/.hammerspoon` 生成并同步 `taichi_env.lua` 脚本，双向通信免去繁琐配置。

### 💽 五、系统资源与外设监控 (System & Disk Monitor)
时刻掌握你的数字资产与系统状态。
- **磁盘监控面板**：实时监控本地系统磁盘，并完美支持外部挂载盘（如网络盘或 Rclone）的容量与状态显示。
- **一键快捷挂载**：在灵动岛下拉面板中，直接一键执行外部磁盘或 Rclone 目录的挂载/卸载操作。

