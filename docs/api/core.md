# 变量与事件接口

### 获取/设置变量
- **URL**: `/api/var/:key`
- **Method**: `GET` 或 `POST`
- **说明**: 
  - `GET /api/var/myKey` 返回对应的值。
  - `POST /api/var/myKey` 与 body `{"value": "someData"}` 将持久化该变量。

### 触发事件
- **URL**: `/api/event`
- **Method**: `POST`
- **说明**: 触发 TaiChi 内部定义的各种事件钩子。
- **请求 Body (JSON)**:
  ```json
  {
    "name": "eventName",
    "payload": { ... }
  }
  ```
