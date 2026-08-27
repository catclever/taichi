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
            let state: MountState = FileManager.default.fileExists(atPath: localPath) ? .connected : .disconnected
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
            IslandManager.shared.pushState(.text("✅ 已连接: \\(targets[index].id)"))
        } else {
            // If it's a new unknown volume, maybe we just passively add it?
            // Optional: Auto-discover passively mounted network drives
        }
    }
    
    private func handleUnmountEvent(url: URL) {
        let path = url.path
        if let index = targets.firstIndex(where: { $0.localPath == path || $0.id == url.lastPathComponent }) {
            targets[index].state = .disconnected
            IslandManager.shared.pushState(.text("⚠️ 断开: \\(targets[index].id)"))
            
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
