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

## 🎩 Alfred 神级联动 (Alfred Workflow)

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
