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
                if !targets.contains(where: { $0.localPath == path }) {
                    let newId = url.lastPathComponent
                    let type: MountType = isRclone ? .rclone : .smb
                    let newTarget = MountTarget(id: newId, remotePath: nil, localPath: path, type: type, isActive: false, state: .connected)
                    targets.append(newTarget)
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
            DispatchQueue.main.async {
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
    
    func connect(id: String) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        let target = targets[index]
        
        if target.type == .rclone {
            // For rclone, we use the external script
            runProcess(executable: "/bin/bash", arguments: ["-c", "/Users/kael/Library/Services/alist/start_mount.sh \(target.id)"])
            // UI State will be updated passively when didMountNotification triggers
        } else if target.type == .smb {
            guard let remote = target.remotePath else { return }
            try? FileManager.default.createDirectory(atPath: target.localPath, withIntermediateDirectories: true)
            runProcess(executable: "/sbin/mount_smbfs", arguments: [remote, target.localPath])
        }
    }
    
    func removeTarget(id: String) {
        targets.removeAll { $0.id == id }
    }
    
    func disconnect(id: String) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        let target = targets[index]
        
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
    
    // MARK: - Internal Handlers
    
    private func handleMountEvent(url: URL) {
        let path = url.path
        // If it's in our known targets, mark it connected
        if let index = targets.firstIndex(where: { $0.localPath == path || $0.id == url.lastPathComponent }) {
            targets[index].state = .connected
            targets[index].retryCount = 0
            IslandStateModel.shared.showNotification(text: "✅ \(targets[index].id) 已连接", mode: .disk)
        } else {
            // If it's a new unknown volume, maybe we just passively add it?
            // Optional: Auto-discover passively mounted network drives
        }
    }
    
    private func handleUnmountEvent(url: URL) {
        let path = url.path
        if let index = targets.firstIndex(where: { $0.localPath == path || $0.id == url.lastPathComponent }) {
            targets[index].state = .disconnected
            IslandStateModel.shared.showNotification(text: "⚠️ \(targets[index].id) 已断开", mode: .disk)
            
            // Trigger retry logic if it's an active SMB mount and network is available
            if targets[index].isActive && isNetworkAvailable {
                scheduleRetry(for: targets[index].id)
            }
        }
    }
    
    private func triggerAutoReconnect() {
        // Find all active targets that are disconnected and try to reconnect them
        for target in targets where target.isActive && target.state == .disconnected {
            scheduleRetry(for: target.id)
        }
    }
    
    private func scheduleRetry(for id: String) {
        guard let index = targets.firstIndex(where: { $0.id == id }) else { return }
        guard isNetworkAvailable else { return } // Safe check
        
        // Max retries
        if targets[index].retryCount >= 5 {
            print("[DiskMonitor] Max retries reached for \\(id). Waiting for manual intervention.")
            targets[index].state = .disconnected
            return
        }
        
        targets[index].state = .retrying
        let currentRetry = targets[index].retryCount
        targets[index].retryCount += 1
        
        // Exponential backoff: 5, 15, 45... (for simplicity: 5 * 3^n)
        let delay = 5.0 * pow(3.0, Double(currentRetry))
        
        print("[DiskMonitor] Scheduling retry for \\(id) in \\(delay) seconds (Attempt \\(currentRetry + 1)/5)")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // Re-check conditions before attempting
            if let tIndex = self.targets.firstIndex(where: { $0.id == id }), 
               self.targets[tIndex].state == .retrying,
               self.isNetworkAvailable {
                print("[DiskMonitor] Attempting to reconnect \\(id)...")
                self.connect(id: id)
            }
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
