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

## 🚀 How to Start

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
