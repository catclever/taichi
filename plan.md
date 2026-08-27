# TaiChi Island Mode Switcher & Disk Monitor

## 目标
将灵动岛从单一的“音乐播放器”升级为“多模块中枢”，支持无缝切换视图，并保持 UI 极简。

## 核心设计 (UI & 交互)
1. **模式定义**: `IslandStateModel` 中新增 `enum IslandMode { case media, disk }` 和 `currentMode`。
2. **视图解耦**:
   - 悬停展开时，根据 `currentMode` 决定显示 `ExpandedPanelView` (音乐) 还是 `MountPanelView` (硬盘)。
3. **右键切换 (Mode Switcher)**:
   - 在 `IslandManager` 的鼠标事件监听中，捕获 `rightMouseDown`。
   - 如果右键点击了灵动岛区域，触发状态进入 `.modeSwitcher` (新增的 `IslandState`)。
   - 渲染 `ModeSwitcherView` (水平或垂直排列的图标：🎵 音乐 | 💽 硬盘)。
4. **默认与上下文悬停 (Context-Aware Hover)**:
   - 默认空闲时，`currentMode` 为 `.media`。悬停始终展开音乐面板。
   - 当 `DiskMonitorManager` 抛出 ⚠️ 断开或 ✅ 连接通知时，临时将 `currentMode` 设为 `.disk`（或添加标记）。此时用户悬停，直接展开为 `MountPanelView`。
5. **设置面板 (TaiChi Menu)**:
   - 在 `SettingsView` 中新增一个 Tab 或区域：【网络硬盘】。
   - 允许添加 SMB 路径 (例如 `smb://192.168.1.1/Share`) 和挂载点名称，保存至 `UserDefaults`，同步给 `DiskMonitorManager` 注册。

## 实施步骤
1. **底层状态更新**: 修改 `IslandStateModel.swift` 引入 `IslandMode` 和相关状态。
2. **右键与手势注入**: 修改 `IslandManager.swift` 拦截右键点击，抛出切换事件。
3. **视图路由修改**: 修改 `IslandView.swift`，根据 `state` 和 `mode` 分发渲染 `ExpandedPanelView`、`MountPanelView` 或 `ModeSwitcherView`。
4. **配置项打通**: 修改 `SettingsView.swift` 和 `Models.swift` (TaiChiConfig) 以支持 SMB 配置列表保存。
