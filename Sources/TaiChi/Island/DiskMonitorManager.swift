import Cocoa
import Network
import Combine

enum MountType: String, Codable {
    case smb
    case rclone
}

enum MountState: String, Codable {
    case connected
    case disconnected
    case retrying
}

struct MountTarget: Identifiable, Equatable {
    var id: String // e.g., "CyberData"
    var remotePath: String? // e.g., "//guest:@192.168.1.100/SteamLibrary"
    var localPath: String // e.g., "/Volumes/CyberData"
    var type: MountType
    var isActive: Bool // true: auto-retry if disconnected, false: passive monitoring
    var state: MountState
    var retryCount: Int = 0
}

@MainActor
class DiskMonitorManager: ObservableObject {
    static let shared = DiskMonitorManager()
    
    @Published var targets: [MountTarget] = []
    @Published var isNetworkAvailable: Bool = false
    
    private let maxRetries = 5
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var manuallyDisconnectedIDs: Set<String> = []
    
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "fun.upup.taichi.diskMonitor")
    
    private init() {
        setupNetworkMonitor()
        setupWorkspaceObserver()
        
        loadRcloneConfigs()
        
        let mounts = TaiChiSettings.shared.activeSMBMounts
        for mount in mounts {
            registerTarget(id: mount.id, localPath: mount.localPath, remotePath: mount.remotePath, type: .smb, isActive: mount.isActive)
        }
        
        checkExistingMounts()
    }
    
    private func getMountCommandOutput() -> [String] {
        let task = Process()
        task.launchPath = "/sbin/mount"
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            return output.components(separatedBy: .newlines)
        }
        return []
    }

    private func checkExistingMounts() {
        let keys: [URLResourceKey] = [.volumeIsLocalKey]
        let mountedURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) ?? []
        var mountedPaths = mountedURLs.map { $0.path }
        
        // Fallback: Check raw mount command output for rclone fuse mounts that might not register as standard volumes
        let mountOutput = getMountCommandOutput()
        for line in mountOutput {
            if line.contains(" on ") {
                let parts = line.components(separatedBy: " on ")
                if parts.count >= 2 {
                    let pathPart = parts[1].components(separatedBy: " (").first ?? ""
                    let path = pathPart.trimmingCharacters(in: .whitespaces)
                    if !mountedPaths.contains(path) && (line.contains("macfuse") || line.contains("osxfuse") || line.contains("rclone")) {
                        mountedPaths.append(path)
                    }
                }
            }
        }
        
        // Check configured active targets
        for i in 0..<targets.count {
            if mountedPaths.contains(targets[i].localPath) {
                targets[i].state = .connected
                targets[i].retryCount = 0
            } else {
                targets[i].state = .disconnected
                targets[i].retryCount = 0
                if targets[i].isActive && isNetworkAvailable {
                    scheduleRetry(for: targets[i].id)
                }
            }
        }
        
        // Passively add other network drives
        for url in mountedURLs {
            let path = url.path
            // Allow /Volumes/ (standard SMB) and /Users/ (standard rclone), block system paths like /home or /System/
            guard path.hasPrefix("/Volumes/") || path.hasPrefix("/Users/") else { continue }
            
            var isNetwork = false
            if let values = try? url.resourceValues(forKeys: Set(keys)) {
                isNetwork = (values.volumeIsLocal == false)
            }
            
            let isRclone = path.lowercased().contains("alist") || path.lowercased().contains("rclone") || targets.contains(where: { $0.localPath == path && $0.type == .rclone })
            
            if isNetwork || isRclone {
                let newId = url.lastPathComponent
                if !targets.contains(where: { $0.localPath == path || $0.id == newId }) {
                    if isRclone {
                        let newTarget = MountTarget(id: newId, remotePath: nil, localPath: path, type: .rclone, isActive: false, state: .connected)
                        targets.append(newTarget)
                    } else {
                        var remotePath: String? = nil
                        for line in mountOutput {
                            if line.contains(" on \(path) (smbfs") || line.contains(" on \(path) (") {
                                let remotePart = line.components(separatedBy: " on ").first?.trimmingCharacters(in: .whitespaces) ?? ""
                                if remotePart.hasPrefix("//") {
                                    remotePath = remotePart
                                }
                                break
                            }
                        }
                        
                        let newTarget = MountTarget(id: newId, remotePath: remotePath, localPath: path, type: .smb, isActive: true, state: .connected)
                        targets.append(newTarget)
                        
                        if !TaiChiSettings.shared.activeSMBMounts.contains(where: { $0.id == newId || $0.localPath == path }) {
                            let newMountConfig = SMBMountConfig(id: newId, remotePath: remotePath ?? "", localPath: path)
                            TaiChiSettings.shared.activeSMBMounts.append(newMountConfig)
                        }
                    }
                }
            }
        }
    }
    
    private func loadRcloneConfigs() {
        let confPath = "/Users/kael/Library/Services/alist/mounts.conf"
        guard let confString = try? String(contentsOfFile: confPath, encoding: .utf8) else { return }
        
        for line in confString.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") { continue }
            
            // Extract content between quotes
            guard let firstQuote = trimmed.firstIndex(of: "\""),
                  let lastQuote = trimmed.lastIndex(of: "\""),
                  firstQuote != lastQuote else { continue }
                  
            let inner = trimmed[trimmed.index(after: firstQuote)..<lastQuote]
            let parts = inner.components(separatedBy: "|")
            guard parts.count >= 3 else { continue }
            
            let id = parts[0]
            var localPath = parts[2]
            localPath = localPath.replacingOccurrences(of: "$HOME", with: "/Users/kael")
            
            if !targets.contains(where: { $0.id == id }) {
                let target = MountTarget(id: id, remotePath: nil, localPath: localPath, type: .rclone, isActive: false, state: .disconnected)
                targets.append(target)
            }
        }
    }
    
    private func setupNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.isNetworkAvailable = available
                if available {
                    self?.triggerAutoReconnect()
                }
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }
    
    private func setupWorkspaceObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.handleMountEvent(url: volumeURL) }
        }
        
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] notification in
            guard let volumeURL = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.handleUnmountEvent(url: volumeURL) }
        }
    }
    
    // MARK: - Public API
    
    /// Register a new target to monitor
    func registerTarget(id: String, localPath: String, remotePath: String? = nil, type: MountType, isActive: Bool) {
        if let index = targets.firstIndex(where: { $0.id == id }) {
            targets[index].remotePath = remotePath
            targets[index].localPath = localPath
            targets[index].type = type
            targets[index].isActive = isActive
        } else {
            let mountedURLs = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
            let mountedPaths = mountedURLs.map { $0.path }
            let state: MountState = mountedPaths.contains(localPath) ? .connected : .disconnected
            let newTarget = MountTarget(id: id, remotePath: remotePath, localPath: localPath, type: type, isActive: isActive, state: state)
            targets.append(newTarget)
        }
    }
    
    func connect(id: String, isRetry: Bool = false) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        let target = targets[index]
        
        if !isRetry {
            cancelRetry(id: id)
            manuallyDisconnectedIDs.remove(id)
            targets[index].isActive = true
            if let configIdx = TaiChiSettings.shared.activeSMBMounts.firstIndex(where: { $0.id == id }) {
                TaiChiSettings.shared.activeSMBMounts[configIdx].isActive = true
            }
        }
        
        if target.type == .rclone {
            // For rclone, we use the external script
            runProcess(executable: "/bin/bash", arguments: ["-c", "/Users/kael/Library/Services/alist/start_mount.sh \(target.id)"])
            // UI State will be updated passively when didMountNotification triggers
        } else if target.type == .smb {
            guard let remote = target.remotePath else {
                print("[DiskMonitor] Cannot connect \(id): remotePath is nil")
                return
            }
            let formattedURL = formatSMBURL(remote)
            
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // Fast TCP port probe before executing heavy mount command (timeout 2.0s for resilience)
                if let (host, port) = self.extractHostAndPort(from: remote) {
                    let reachable = await self.isHostReachable(host: host, port: port, timeoutSeconds: 2.0)
                    if !reachable {
                        print("[DiskMonitor] SMB host \(host):\(port) is unreachable.")
                        guard let currentIndex = self.targets.firstIndex(where: { $0.id == id }) else { return }
                        
                        if isRetry {
                            self.targets[currentIndex].retryCount += 1
                            if self.targets[currentIndex].retryCount < self.maxRetries {
                                self.scheduleRetry(for: id)
                            } else {
                                print("[DiskMonitor] Max retries reached for \(id). Resetting to disconnected.")
                                self.targets[currentIndex].state = .disconnected
                                self.targets[currentIndex].retryCount = 0
                                self.retryTasks.removeValue(forKey: id)
                                IslandStateModel.shared.showNotification(text: "❌ \(id) 自动重试已暂停", mode: .disk)
                            }
                        } else {
                            self.targets[currentIndex].state = .disconnected
                            self.targets[currentIndex].retryCount = 0
                            self.retryTasks[id]?.cancel()
                            self.retryTasks.removeValue(forKey: id)
                            IslandStateModel.shared.showNotification(text: "❌ \(id) 主机离线", mode: .disk)
                        }
                        return
                    }
                }
                
                print("[DiskMonitor] Mounting SMB volume: \(formattedURL) (isRetry: \(isRetry))")
                let (success, errorMsg) = await self.mountSMBVolume(urlString: formattedURL)
                
                guard let currentIndex = self.targets.firstIndex(where: { $0.id == id }) else { return }
                
                if success {
                    print("[DiskMonitor] SMB mount succeeded for \(id)")
                    self.targets[currentIndex].state = .connected
                    self.targets[currentIndex].retryCount = 0
                    self.retryTasks.removeValue(forKey: id)
                } else {
                    print("[DiskMonitor] SMB mount failed for \(id): \(errorMsg ?? "unknown error")")
                    
                    if isRetry {
                        // Ensure retry wasn't cancelled while mount was running
                        guard self.targets[currentIndex].state == .retrying else {
                            print("[DiskMonitor] Retry for \(id) was cancelled during mount attempt.")
                            return
                        }
                        
                        self.targets[currentIndex].retryCount += 1
                        if self.targets[currentIndex].retryCount < self.maxRetries {
                            self.scheduleRetry(for: id)
                        } else {
                            print("[DiskMonitor] Max retries reached for \(id). Resetting to disconnected.")
                            self.targets[currentIndex].state = .disconnected
                            self.targets[currentIndex].retryCount = 0
                            self.retryTasks.removeValue(forKey: id)
                            IslandStateModel.shared.showNotification(text: "❌ \(id) 自动重试已暂停", mode: .disk)
                        }
                    } else {
                        self.targets[currentIndex].state = .disconnected
                        self.targets[currentIndex].retryCount = 0
                        IslandStateModel.shared.showNotification(text: "❌ \(id) 挂载失败", mode: .disk)
                    }
                }
            }
        }
    }
    
    func cancelRetry(id: String) {
        retryTasks[id]?.cancel()
        retryTasks.removeValue(forKey: id)
        if let index = targets.firstIndex(where: { $0.id == id }) {
            targets[index].retryCount = 0
            targets[index].isActive = false
            if targets[index].state == .retrying {
                targets[index].state = .disconnected
            }
            if let configIdx = TaiChiSettings.shared.activeSMBMounts.firstIndex(where: { $0.id == id }) {
                TaiChiSettings.shared.activeSMBMounts[configIdx].isActive = false
            }
            print("[DiskMonitor] Cancelled retry for \(id), set isActive = false")
        }
    }
    
    func removeTarget(id: String) {
        cancelRetry(id: id)
        targets.removeAll { $0.id == id }
        TaiChiSettings.shared.activeSMBMounts.removeAll { $0.id == id }
    }
    
    func disconnect(id: String) {
        cancelRetry(id: id)
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        let target = targets[index]
        manuallyDisconnectedIDs.insert(id)
        
        targets[index].isActive = false
        targets[index].retryCount = 0
        if let configIdx = TaiChiSettings.shared.activeSMBMounts.firstIndex(where: { $0.id == id }) {
            TaiChiSettings.shared.activeSMBMounts[configIdx].isActive = false
        }
        
        if target.type == .rclone {
            // For rclone, use external script
            runProcess(executable: "/bin/bash", arguments: ["-c", "/Users/kael/Library/Services/alist/stop_mount.sh \(target.id)"])
        } else {
            // For SMB or general
            runProcess(executable: "/usr/sbin/diskutil", arguments: ["unmount", "force", target.localPath])
        }
    }
    
    // MARK: - Internal Helpers
    
    private func extractHostAndPort(from remotePath: String) -> (host: String, port: UInt16)? {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatted = formatSMBURL(trimmed)
        if let url = URL(string: formatted), let host = url.host, !host.isEmpty {
            let port = UInt16(url.port ?? 445)
            return (host, port)
        }
        
        var stripped = trimmed
        if stripped.hasPrefix("smb://") {
            stripped = String(stripped.dropFirst(6))
        } else if stripped.hasPrefix("//") {
            stripped = String(stripped.dropFirst(2))
        }
        if let atIndex = stripped.firstIndex(of: "@") {
            stripped = String(stripped[stripped.index(after: atIndex)...])
        }
        let hostPart = stripped.components(separatedBy: "/").first?.components(separatedBy: ":").first
        if let host = hostPart, !host.isEmpty {
            return (host, 445)
        }
        return nil
    }

    private func isHostReachable(host: String, port: UInt16 = 445, timeoutSeconds: Double = 2.0) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_protocol = IPPROTO_TCP
            
            var servinfo: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &servinfo) == 0, let info = servinfo else {
                return false
            }
            defer { freeaddrinfo(servinfo) }
            
            var p: UnsafeMutablePointer<addrinfo>? = info
            while let current = p {
                let sock = socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
                if sock >= 0 {
                    let flags = fcntl(sock, F_GETFL, 0)
                    _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
                    
                    let ret = Darwin.connect(sock, current.pointee.ai_addr, current.pointee.ai_addrlen)
                    if ret == 0 {
                        close(sock)
                        return true
                    }
                    
                    if errno == EINPROGRESS {
                        var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                        let pollRes = poll(&pfd, 1, Int32(timeoutSeconds * 1000))
                        if pollRes > 0 && (pfd.revents & Int16(POLLOUT)) != 0 {
                            var err: Int32 = 0
                            var len = socklen_t(MemoryLayout<Int32>.size)
                            if getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0 {
                                close(sock)
                                return true
                            }
                        }
                    }
                    close(sock)
                }
                p = current.pointee.ai_next
            }
            return false
        }.value
    }
    
    private func formatSMBURL(_ remotePath: String) -> String {
        let trimmed = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("smb://") {
            return trimmed
        } else if trimmed.hasPrefix("//") {
            return "smb:" + trimmed
        } else if trimmed.hasPrefix("/") {
            return "smb:/" + trimmed
        } else {
            return "smb://" + trimmed
        }
    }
    
    private func mountSMBVolume(urlString: String) async -> (success: Bool, error: String?) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            let escapedUrl = urlString.replacingOccurrences(of: "\\", with: "\\\\")
                                      .replacingOccurrences(of: "\"", with: "\\\"")
            // Wrap in try...on error to suppress macOS NetFS GUI alert dialog!
            let script = "try\nmount volume \"\(escapedUrl)\"\non error errMsg number errNum\nerror errMsg number errNum\nend try"
            process.arguments = ["-e", script]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            let outPipe = Pipe()
            process.standardOutput = outPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                let success = (process.terminationStatus == 0)
                var errorString: String? = nil
                if !success {
                    let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    errorString = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                return (success, errorString)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }
    
    // MARK: - Internal Handlers
    
    private func handleMountEvent(url: URL) {
        let path = url.path
        if let index = targets.firstIndex(where: { $0.localPath == path || $0.id == url.lastPathComponent }) {
            let targetId = targets[index].id
            targets[index].state = .connected
            targets[index].retryCount = 0
            cancelRetry(id: targetId)
            IslandStateModel.shared.showNotification(text: "✅ \(targets[index].id) 已连接", mode: .disk)
        } else {
            // Auto-discover passively mounted network drives
            guard path.hasPrefix("/Volumes/") else { return }
            
            // Get remote path from mount command
            let mountOutput = getMountCommandOutput()
            for line in mountOutput {
                if line.contains(" on \(path) (smbfs") || line.contains(" on \(path) (") {
                    let remotePart = line.components(separatedBy: " on ").first ?? ""
                    if remotePart.hasPrefix("//") {
                        let id = url.lastPathComponent
                        if !self.targets.contains(where: { $0.id == id }) {
                            let newTarget = MountTarget(id: id, remotePath: remotePart, localPath: path, type: .smb, isActive: true, state: .connected)
                            self.targets.append(newTarget)
                            
                            let newMountConfig = SMBMountConfig(id: id, remotePath: remotePart, localPath: path)
                            TaiChiSettings.shared.activeSMBMounts.append(newMountConfig)
                            
                            IslandStateModel.shared.showNotification(text: "🔗 \(id) 自动加入监控", mode: .disk)
                        }
                    }
                    break
                }
            }
        }
    }
    
    private func handleUnmountEvent(url: URL) {
        let path = url.path
        if let index = targets.firstIndex(where: { $0.localPath == path || $0.id == url.lastPathComponent }) {
            let targetId = targets[index].id
            targets[index].state = .disconnected
            targets[index].retryCount = 0
            retryTasks[targetId]?.cancel()
            retryTasks.removeValue(forKey: targetId)
            
            if manuallyDisconnectedIDs.contains(targetId) {
                manuallyDisconnectedIDs.remove(targetId)
                targets[index].isActive = false
                if let configIdx = TaiChiSettings.shared.activeSMBMounts.firstIndex(where: { $0.id == targetId }) {
                    TaiChiSettings.shared.activeSMBMounts[configIdx].isActive = false
                }
                print("[DiskMonitor] Target \(targetId) was manually disconnected.")
                IslandStateModel.shared.showNotification(text: "⚠️ \(targets[index].id) 已卸载", mode: .disk)
            } else {
                print("[DiskMonitor] Target \(targetId) unmounted. Preserving isActive=\(targets[index].isActive).")
                IslandStateModel.shared.showNotification(text: "⚠️ \(targets[index].id) 已断开", mode: .disk)
                
                if targets[index].isActive && isNetworkAvailable {
                    scheduleRetry(for: targetId)
                }
            }
        }
    }
    
    private func triggerAutoReconnect() {
        // Find all active targets that are disconnected and try to reconnect them
        for target in targets where target.isActive {
            if target.state == .disconnected {
                if target.type == .smb, let remote = target.remotePath, let (host, port) = extractHostAndPort(from: remote) {
                    Task { @MainActor [weak self] in
                        guard let self = self else { return }
                        let reachable = await self.isHostReachable(host: host, port: port, timeoutSeconds: 2.0)
                        if reachable {
                            self.scheduleRetry(for: target.id)
                        } else {
                            print("[DiskMonitor] triggerAutoReconnect: \(target.id) host \(host):\(port) offline. Skipping retry.")
                        }
                    }
                } else {
                    scheduleRetry(for: target.id)
                }
            } else if target.state == .retrying && retryTasks[target.id] == nil {
                // If it was in retrying state but had no active retry task, restart retry
                scheduleRetry(for: target.id)
            }
        }
    }
    
    private func scheduleRetry(for id: String) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        guard isNetworkAvailable else { return } // Safe check
        guard targets[index].isActive else { return }
        
        // Max retries
        if targets[index].retryCount >= maxRetries {
            print("[DiskMonitor] Max retries reached for \(id). Pausing until network changes or manual retry.")
            targets[index].state = .disconnected
            targets[index].retryCount = 0
            retryTasks.removeValue(forKey: id)
            return
        }
        
        targets[index].state = .retrying
        let currentRetry = targets[index].retryCount
        
        // Exponential backoff: 5, 15, 45... (5 * 3^n)
        let delay = 5.0 * pow(3.0, Double(currentRetry))
        
        print("[DiskMonitor] Scheduling retry for \(id) in \(delay) seconds (Attempt \(currentRetry + 1)/\(maxRetries))")
        
        retryTasks[id]?.cancel()
        retryTasks[id] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                // Task was cancelled
                return
            }
            guard let self = self, !Task.isCancelled else { return }
            // Re-check conditions before attempting
            guard let tIndex = self.targets.firstIndex(where: { $0.id == id }),
                  self.targets[tIndex].state == .retrying,
                  self.isNetworkAvailable else {
                return
            }
            
            print("[DiskMonitor] Attempting to reconnect \(id) (Attempt \(currentRetry + 1)/\(self.maxRetries))...")
            self.connect(id: id, isRetry: true)
        }
    }
    
    private func runProcess(executable: String, arguments: [String]) {
        DispatchQueue.global().async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: executable)
            task.arguments = arguments
            try? task.run()
        }
    }
}
