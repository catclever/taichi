# TaiChi CDP Injection Architecture & Port Management

## 架构概览
TaiChi 的整体服务分为两部分：
1. **Swift 网关 (默认端口: 9216)**：主程序的 HTTP Server，负责接收来自 Hammerspoon 或其它客户端的 HTTP 请求。
2. **Node.js 注入进程 (随机端口)**：后台 Worker 进程，负责真正执行 CDP 脚本并向目标应用注入代码。

简单来说，**9216 端口是负责指挥和对外接客的“前台”，而随机端口 (Node) 是负责干脏活累活的“车间”**。

## 详细逻辑流转

### 1. 服务初始化 (启动阶段)
* **主网关启动**：TaiChi App 启动时，会在主线程通过 `Swifter` 建立一个 HTTP Server，固定监听 **9216** 端口。这个端口负责接收外部命令。
* **Node Worker 启动**：网关启动的同时，会在后台以子进程的方式拉起 `node .taichi_worker.js`。
  * Node 进程启动时监听的是**随机可用端口 (Port 0)**。
  * Node 启动成功后，会向标准输出打印 `READY:<分配的端口号>`。
  * Swift 层捕获到输出后，将该端口记录在 `workerPort` 变量中，作为内部通信的专属通道。

### 2. 触发注入 (App 启动阶段)
当通过 TaiChi 启动目标应用（例如 Antigravity 等 Electron / 网页套壳应用）时：
* **分配 CDP 端口**：Swift 从 `9222` 端口开始向上探测，寻找未被占用的端口，作为目标应用的 `targetPort`。
* **挂载参数启动**：Swift 通过 `NSWorkspace` 携带 `--remote-debugging-port=9222` 参数启动目标 App。若 App 已运行但未注入，TaiChi 会先将其强制退出再带参重启。
* **转发注入任务**：目标 App 启动延迟 1 秒后，Swift 向本地 Node Worker 发起 HTTP GET 请求：
  `http://127.0.0.1:<workerPort>/script/apps/<应用BundleID>/worker/index?port=<targetPort>`

### 3. 执行注入 (Node 运行阶段)
* **动态加载脚本**：Node Worker 收到请求后，根据路径加载针对该应用的注入脚本（`.js` 文件）。
* **CDP 连接**：注入脚本内部使用目标 App 的 `<targetPort>` 建立 Chrome DevTools Protocol (CDP) WebSocket 连接。
* **执行注入操作**：连接成功后，执行脚本内定义的 DOM 修改、CSS 注入或事件劫持等逻辑。

### 4. 容错与自愈机制
* **唤醒重连机制**：系统休眠唤醒时，目标 App 的 CDP 连接可能会断开。TaiChi 监听了系统的 `didWakeNotification` 通知，在唤醒 3 秒后自动触发 `reinjectActiveApps()`，重新建立活跃应用的注入。
* **Node 进程崩溃自愈**：
  * **问题背景**：如果 JS 注入脚本（用户自定义）存在未捕获异常（如 Promise Reject），会导致整个 Node 子进程崩溃。Swift 端的 `workerPort` 变为死端口，后续注入静默失败。
  * **自愈方案**：在 Swift 端给 Node 子进程 (`workerProcess`) 添加了 `terminationHandler` 监听。一旦 Node 进程崩溃，Swift 层会：
    1. 打印崩溃日志。
    2. 清空失效的 `workerPort`。
    3. 自动调用 `startWorker()` 重新拉起一个新的 Node 进程并分配新端口。
    4. 下次注入需求会直接使用新拉起的 Node 进程，保证服务的高可用性。
