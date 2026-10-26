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
            registerTarget(id: mount.id, localPath: mount.localPath, remotePath: mount.remotePath, type: .smb, isActive: true)
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
                            IslandStateModel.shared.showNotification(text: "❌ \(id) 自动重试失败", mode: .disk)
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
            if targets[index].state == .retrying {
                targets[index].state = .disconnected
            }
            print("[DiskMonitor] Cancelled retry for \(id)")
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
        
        if target.type == .rclone {
            // For rclone, use external script
            runProcess(executable: "/bin/bash", arguments: ["-c", "/Users/kael/Library/Services/alist/stop_mount.sh \(target.id)"])
        } else {
            // For SMB or general
            runProcess(executable: "/usr/sbin/diskutil", arguments: ["unmount", "force", target.localPath])
        }
        
        // Reset retry count on manual disconnect
        targets[index].retryCount = 0
    }
    
    // MARK: - Internal Helpers
    
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
            process.arguments = ["-e", "mount volume \"\(escapedUrl)\""]
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
            IslandStateModel.shared.showNotification(text: "⚠️ \(targets[index].id) 已断开", mode: .disk)
            
            // Trigger retry logic if it's an active SMB mount and network is available, and was not manually disconnected
            if manuallyDisconnectedIDs.contains(targetId) {
                manuallyDisconnectedIDs.remove(targetId)
                print("[DiskMonitor] Target \(targetId) was manually disconnected, skipping auto-retry.")
            } else if targets[index].isActive && isNetworkAvailable {
                scheduleRetry(for: targetId)
            }
        }
    }
    
    private func triggerAutoReconnect() {
        // Find all active targets that are disconnected and try to reconnect them
        for target in targets where target.isActive {
            if target.state == .disconnected {
                scheduleRetry(for: target.id)
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
            print("[DiskMonitor] Max retries reached for \(id). Waiting for manual intervention.")
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
