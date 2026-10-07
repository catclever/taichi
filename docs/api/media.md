# 多媒体与歌词相关接口

### 推送歌词
- **URL**: `/api/lyrics/push`
- **Method**: `POST`
- **说明**: 播放软件可以通过此接口向 TaiChi 推送当前的歌词内容，支持 LRC 格式。
- **请求 Body (JSON)**:
  ```json
  {
    "title": "歌曲名",
    "artist": "歌手名",
    "lrc": "[00:00.00]歌词第一句\n[00:05.00]歌词第二句",
    "failed": false // 如果获取歌词失败，可传 true，TaiChi 会尝试 fallback 到内部获取
  }
  ```

### 推送"喜欢(红心)"状态
- **URL**: `/api/media/like_status`
- **Method**: `POST`
- **说明**: 播放软件可以推送当前播放歌曲的“喜欢”状态。如果推送了此状态，TaiChi 播控面板上将会渲染红心按钮。如果取消了推送或传入 `null`，红心按钮将隐藏。
- **请求 Body (JSON)**:
  ```json
  {
    "isLiked": true  // true (实心红心), false (空心红心), 传入 null 或不传表示隐藏红心按钮
  }
  ```
