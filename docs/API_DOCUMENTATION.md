# TaiChi 本地 HTTP 接口文档

TaiChi 在本地的 `9216` 端口启动了一个 HTTP 服务器，提供了一系列接口，用于与外部脚本、 Hammerspoon 插件或播放器扩展进行通信。

所有请求默认使用 `http://127.0.0.1:9216` 作为 Base URL。

---

## 接口分类目录

为了方便查阅，接口文档已按照功能模块拆分：

1. **[多媒体与歌词相关接口](api/media.md)**
   - 包含：推送歌词 (`/api/lyrics/push`)、推送“喜欢”状态 (`/api/media/like_status`) 等。
2. **[Cyber 注入脚本接口](api/cyber.md)**
   - 包含：注册播放控制 Handlers (`/api/cyber/media_handlers`)、执行注入脚本 (`/api/cyber/evaluate`)。
3. **[壁纸控制接口](api/wallpaper.md)**
   - 包含：切换下一张/上一张壁纸 (`/api/wallpaper/change`, `/api/wallpaper/previous`)、保存当前壁纸 (`/api/wallpaper/save`)。
4. **[变量与事件接口](api/core.md)**
   - 包含：获取/设置全局变量 (`/api/var/:key`)、触发系统事件 (`/api/event`)。
5. **[Launcher (灵动岛) 接口](api/launcher.md)**
   - 包含：列表过滤 (`/api/launcher/filter`)、执行动作 (`/api/launcher/action`)、激活 Inspector (`/api/inspector/activate`)。

