# Cyber 注入脚本接口

### 注册播放控制 Handlers
- **URL**: `/api/cyber/media_handlers`
- **Method**: `POST`
- **说明**: 第三方插件可以通过此接口注册播放控制的脚本处理逻辑（AppleScript/JXA）。这样当用户在 TaiChi 界面点击对应按钮时，会触发所注册的脚本。
- **请求 Body (JSON)**:
  ```json
  {
    "appId": "com.netease.163music", // 目标播放器包名
    "handlers": {
      "playpause": "tell application id \"com.netease.163music\" to playpause",
      "next": "tell application id \"com.netease.163music\" to next track",
      "prev": "tell application id \"com.netease.163music\" to previous track",
      "toggleLike": "..." // 处理红心按钮的点击事件 (如切换喜欢状态)
    }
  }
  ```

### 执行注入脚本
- **URL**: `/api/cyber/evaluate`
- **Method**: `POST`
- **说明**: 执行针对某个 App 注入的临时脚本。
- **请求 Body (JSON)**:
  ```json
  {
    "appId": "com.example.app",
    "script": "return 1 + 1"
  }
  ```
