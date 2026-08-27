import Cocoa
import SwiftUI
import Combine

// 数据模型

struct ResidentApp: Identifiable, Codable, Equatable {
    var id: String // Bundle Identifier
    var name: String
    var path: String
}

struct MonitoredApp: Identifiable, Codable, Equatable {
    var id: String // Bundle Identifier
    var name: String
    var path: String
}

struct CommonPath: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var path: String
}

struct FloatingApp: Identifiable, Codable, Equatable {
    var id: String // Bundle Identifier
    var name: String
    var path: String
}

struct MediaApp: Identifiable, Codable, Equatable {
    var id: String // Bundle Identifier
    var name: String
    var path: String
    var supportsLyrics: Bool?
    
    var isLyricSupported: Bool {
        get { supportsLyrics ?? false }
        set { supportsLyrics = newValue }
    }
}

struct ScreenInfo: Identifiable, Codable, Equatable {
    var id: String { uuid }
    var uuid: String
    var name: String
}

struct WallpaperHistoryEntry: Codable, Equatable {
    var photoId: String
    var timestamp: Date
    var channelName: String?
    var title: String?
}

struct WallpaperEngineConfig: Codable, Equatable {
    struct SourceConfig: Codable, Equatable {
        var key: String?
    }
    
    struct ChannelConfig: Codable, Equatable {
        var type: String?
        var query: String?
        var collections: [String]?
        var featured: Bool?
        var url: String?
    }

    struct AutoTimeConfig: Codable, Equatable {
        var screens: [String]?
        var times: [String]?
        var condition: String?
        var checkThresholdSeconds: Int?
    }

    struct ScreenConfig: Codable, Equatable {
        var enabled: Bool?
        var channels: [String]?
        var intervalMinutes: Int?
        var autoTimeConfig: AutoTimeConfig?
    }

    
    var isEngineEnabled: Bool?
    var globalIntervalMinutes: Int?
    var enableAutoChange: Bool?
    var autoTimeConfig: AutoTimeConfig?
    
    var sources: [String: SourceConfig]?
    var channels: [String: ChannelConfig]?
    var screens: [String: ScreenConfig]?
}

// 快捷键模型
struct HotkeyConfig: Codable, Equatable {
    var modifiers: [String]
    var key: String
}

@MainActor
class TaiChiSettings: ObservableObject {
    static let shared = TaiChiSettings()
    
    private var isInitializing = true
    
    @Published var residentApps: [ResidentApp] = [] {
        didSet { saveResidentApps() }
    }
    
    @Published var monitoredApps: [MonitoredApp] = [] {
        didSet { saveMonitoredApps() }
    }
    
    @Published var mediaApps: [MediaApp] = [] {
        didSet { saveMediaApps() }
    }
    
    @Published var floatingApps: [FloatingApp] = [] {
        didSet { saveFloatingApps() }
    }
    
    @Published var commonPaths: [CommonPath] = [] {
        didSet { saveCommonPaths() }
    }
    
    @Published var httpPort: Int = 9216 {
        didSet { saveHttpPort() }
    }
    
    @Published var scriptsPath: String = ("~/Library/Services/taichi" as NSString).expandingTildeInPath {
        didSet { saveScriptsPath() }
    }
    
    // Hammerspoon 配置
    @Published var hsConfigPath: String = ("~/.hammerspoon/v3" as NSString).expandingTildeInPath {
        didSet { saveHSConfigPath() }
    }
    
    @Published var isHSConfigModified: Bool = false
    
    @Published var isFloatingFeatureEnabled: Bool = false {
        didSet { 
            saveHSFeatures()
            if !isInitializing { isHSConfigModified = true }
        }
    }
    
    @Published var isTelescopeEnabled: Bool = false {
        didSet { 
            saveHSFeatures()
            if !isInitializing { isHSConfigModified = true }
        }
    }
    
    @Published var isWallpaperEngineEnabled: Bool = false {
        didSet { 
            saveHSFeatures() 
            if wallpaperEngineConfig.isEngineEnabled != isWallpaperEngineEnabled {
                wallpaperEngineConfig.isEngineEnabled = isWallpaperEngineEnabled
            }
        }
    }
    
    // MARK: - Audio Keep-Alive Feature
    @Published var isAudioKeepAliveEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isAudioKeepAliveEnabled, forKey: "isAudioKeepAliveEnabled")
            AudioKeepAliveManager.shared.setEnabled(isAudioKeepAliveEnabled)
        }
    }
    
    @Published var hotkeyTogglePin: HotkeyConfig = HotkeyConfig(modifiers: ["ctrl"], key: "H") {
        didSet { 
            saveHotkeys()
            if !isInitializing { isHSConfigModified = true }
        }
    }
    
    @Published var hotkeyToggleAll: HotkeyConfig = HotkeyConfig(modifiers: ["cmd", "ctrl"], key: "H") {
        didSet { 
            saveHotkeys()
            if !isInitializing { isHSConfigModified = true }
        }
    }
    
    @Published var hotkeyTelescope: HotkeyConfig = HotkeyConfig(modifiers: ["ctrl", "alt"], key: "I") {
        didSet { 
            saveHotkeys()
            if !isInitializing { isHSConfigModified = true }
        }
    }
    
    // Wallpaper Engine 配置

    @Published var wallpaperSaveDir: String = ("~/Pictures/wallpapers" as NSString).expandingTildeInPath {
        didSet { saveWallpaperSettings() }
    }
    @Published var wallpaperChannels: [String: [String]] = [:] {
        didSet { saveWallpaperSettings() }
    }
    @Published var wallpaperHistory: [String: [WallpaperHistoryEntry]] = [:] {
        didSet { saveWallpaperSettings() }
    }
    
    @Published var connectedScreens: [ScreenInfo] = []
    
    // Config read from ~/.config/taichi/wallpaper.json
    @Published var wallpaperEngineConfig: WallpaperEngineConfig = WallpaperEngineConfig() {
        didSet { saveWallpaperEngineConfig() }
    }
    
    @Published var activeInjectedApps: [MonitoredApp] = []
    
    init() {
        loadSettings()
        
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier else { return }
            Task { @MainActor in
                self?.activeInjectedApps.removeAll { $0.id == bundleId }
            }
        }
        
        loadWallpaperEngineConfig()
        isInitializing = false
    }
    private func decodeDict<T: Decodable>(_ dict: [String: Any], as type: T.Type) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
    
    func loadWallpaperEngineConfig() {
        let basePath = (scriptsPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: (basePath as NSString).appendingPathComponent("wallpaper.json"))
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            
            if let arr = json["residentApps"] as? [[String: Any]] {
                self.residentApps = arr.compactMap { decodeDict($0, as: ResidentApp.self) }
            }
            if let arr = json["monitoredApps"] as? [[String: Any]] {
                self.monitoredApps = arr.compactMap { decodeDict($0, as: MonitoredApp.self) }
            }
            if let arr = json["mediaApps"] as? [[String: Any]] {
                self.mediaApps = arr.compactMap { decodeDict($0, as: MediaApp.self) }
            }
            
            if let configData = try? JSONSerialization.data(withJSONObject: json),
               let config = try? JSONDecoder().decode(WallpaperEngineConfig.self, from: configData) {
                self.wallpaperEngineConfig = config
                if let enabled = config.isEngineEnabled {
                    self.isWallpaperEngineEnabled = enabled
                }
            }
        } else {
            // Default config
            self.wallpaperEngineConfig = WallpaperEngineConfig(
                globalIntervalMinutes: 1440,
                enableAutoChange: true,
                screens: [:]
            )
            saveWallpaperEngineConfig()
        }
    }
    
    func saveWallpaperEngineConfig() {
        let basePath = (scriptsPath as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: (basePath as NSString).appendingPathComponent("wallpaper.json"))
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(wallpaperEngineConfig) {
            try? data.write(to: url)
        }
    }
    
    private func loadSettings() {
        if let data = UserDefaults.standard.data(forKey: "residentApps"),
           let apps = try? JSONDecoder().decode([ResidentApp].self, from: data) {
            residentApps = apps
        }
        
        if let data = UserDefaults.standard.data(forKey: "monitoredApps"),
           let apps = try? JSONDecoder().decode([MonitoredApp].self, from: data) {
            monitoredApps = apps
        } else {
            // 默认添加 Finder
            monitoredApps = [
                MonitoredApp(id: "com.apple.finder", name: "Finder", path: "/System/Library/CoreServices/Finder.app")
            ]
        }
        
        if let data = UserDefaults.standard.data(forKey: "floatingApps"),
           let apps = try? JSONDecoder().decode([FloatingApp].self, from: data) {
            floatingApps = apps
        }
        
        if let data = UserDefaults.standard.data(forKey: "mediaApps"),
           let apps = try? JSONDecoder().decode([MediaApp].self, from: data) {
            mediaApps = apps
        }
        
        if let data = UserDefaults.standard.data(forKey: "commonPaths"),
           let paths = try? JSONDecoder().decode([CommonPath].self, from: data) {
            commonPaths = paths
        }
        
        let port = UserDefaults.standard.integer(forKey: "httpPort")
        if port != 0 {
            httpPort = port
        }
        
        if let path = UserDefaults.standard.string(forKey: "scriptsPath") {
            scriptsPath = path
        }
        
        if let hsPath = UserDefaults.standard.string(forKey: "hsConfigPath") {
            hsConfigPath = hsPath
        }
        
        isFloatingFeatureEnabled = UserDefaults.standard.bool(forKey: "isFloatingFeatureEnabled")
        isTelescopeEnabled = UserDefaults.standard.bool(forKey: "isTelescopeEnabled")
        isAudioKeepAliveEnabled = UserDefaults.standard.bool(forKey: "isAudioKeepAliveEnabled")
        
        if let data = UserDefaults.standard.data(forKey: "hotkeyTogglePin"), let hk = try? JSONDecoder().decode(HotkeyConfig.self, from: data) { hotkeyTogglePin = hk }
        if let data = UserDefaults.standard.data(forKey: "hotkeyToggleAll"), let hk = try? JSONDecoder().decode(HotkeyConfig.self, from: data) { hotkeyToggleAll = hk }
        if let data = UserDefaults.standard.data(forKey: "hotkeyTelescope"), let hk = try? JSONDecoder().decode(HotkeyConfig.self, from: data) { hotkeyTelescope = hk }
        
        

        if let dir = UserDefaults.standard.string(forKey: "wallpaperSaveDir") { wallpaperSaveDir = dir }
        if let data = UserDefaults.standard.data(forKey: "wallpaperChannels"), let ch = try? JSONDecoder().decode([String: [String]].self, from: data) { wallpaperChannels = ch }
        if let data = UserDefaults.standard.data(forKey: "wallpaperHistory"), let hs = try? JSONDecoder().decode([String: [WallpaperHistoryEntry]].self, from: data) { wallpaperHistory = hs }
        
        syncFromHSConfig()
    }
    
    private func syncFromHSConfig() {
        let fileManager = FileManager.default
        let hsDir = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".hammerspoon")
        let configFile = hsDir.appendingPathComponent("taichi_env.lua")
        
        guard let content = try? String(contentsOf: configFile, encoding: .utf8) else {
            // 如果不存在配置文件，默认关闭
            isFloatingFeatureEnabled = false
            isTelescopeEnabled = false
            return
        }
        
        var floatingEnabled = false
        var telescopeEnabled = false
        
        func parseHotkey(for key: String) -> HotkeyConfig? {
            // Regex to match: togglePin = {{"ctrl", "cmd"}, "H"}
            let pattern = "\(key)\\s*=\\s*\\{\\{([^}]+)\\}\\s*,\\s*\"([^\"]+)\"\\}"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
            let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
            if let match = regex.firstMatch(in: content, options: [], range: nsRange) {
                let modsStr = (content as NSString).substring(with: match.range(at: 1))
                let keyStr = (content as NSString).substring(with: match.range(at: 2))
                
                let mods = modsStr.components(separatedBy: ",").map {
                    $0.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
                
                return HotkeyConfig(modifiers: mods, key: keyStr)
            }
            return nil
        }
        
        if let pinHK = parseHotkey(for: "togglePin") {
            hotkeyTogglePin = pinHK
            floatingEnabled = true
        }
        if let allHK = parseHotkey(for: "toggleAll") {
            hotkeyToggleAll = allHK
            floatingEnabled = true
        }
        
        if let inspectorHK = parseHotkey(for: "triggerInspector") {
            hotkeyTelescope = inspectorHK
            telescopeEnabled = true
        }
        
        // 只有当文件里明确存在相应的配置时才开启，否则按文件里的实际情况（如被手动置为 nil）关闭
        isFloatingFeatureEnabled = floatingEnabled
        isTelescopeEnabled = telescopeEnabled
    }
    
    private func saveResidentApps() {
        guard !isInitializing else { return }
        if let data = try? JSONEncoder().encode(residentApps) {
            UserDefaults.standard.set(data, forKey: "residentApps")
        }
    }

    private func saveMonitoredApps() {
        guard !isInitializing else { return }
        if let data = try? JSONEncoder().encode(monitoredApps) {
            UserDefaults.standard.set(data, forKey: "monitoredApps")
        }
    }
    
    private func saveMediaApps() {
        guard !isInitializing else { return }
        if let data = try? JSONEncoder().encode(mediaApps) {
            UserDefaults.standard.set(data, forKey: "mediaApps")
        }
    }
    
    private func saveFloatingApps() {
        guard !isInitializing else { return }
        if let data = try? JSONEncoder().encode(floatingApps) {
            UserDefaults.standard.set(data, forKey: "floatingApps")
        }
    }
    
    private func saveCommonPaths() {
        guard !isInitializing else { return }
        if let data = try? JSONEncoder().encode(commonPaths) {
            UserDefaults.standard.set(data, forKey: "commonPaths")
        }
    }
    
    private func saveHttpPort() {
        guard !isInitializing else { return }
        UserDefaults.standard.set(httpPort, forKey: "httpPort")
    }
    
    private func saveScriptsPath() {
        guard !isInitializing else { return }
        UserDefaults.standard.set(scriptsPath, forKey: "scriptsPath")
    }
    
    private func saveHSConfigPath() {
        guard !isInitializing else { return }
        UserDefaults.standard.set(hsConfigPath, forKey: "hsConfigPath")
    }
    
    private func saveHSFeatures() {
        guard !isInitializing else { return }
        UserDefaults.standard.set(isFloatingFeatureEnabled, forKey: "isFloatingFeatureEnabled")
        UserDefaults.standard.set(isTelescopeEnabled, forKey: "isTelescopeEnabled")
    }
    
    private func saveHotkeys() {
        guard !isInitializing else { return }
        if let d1 = try? JSONEncoder().encode(hotkeyTogglePin) { UserDefaults.standard.set(d1, forKey: "hotkeyTogglePin") }
        if let d2 = try? JSONEncoder().encode(hotkeyToggleAll) { UserDefaults.standard.set(d2, forKey: "hotkeyToggleAll") }
        if let d3 = try? JSONEncoder().encode(hotkeyTelescope) { UserDefaults.standard.set(d3, forKey: "hotkeyTelescope") }
    }
    
    private func saveWallpaperSettings() {
        guard !isInitializing else { return }
        UserDefaults.standard.set(wallpaperSaveDir, forKey: "wallpaperSaveDir")
        if let d = try? JSONEncoder().encode(wallpaperChannels) { UserDefaults.standard.set(d, forKey: "wallpaperChannels") }
        if let d = try? JSONEncoder().encode(wallpaperHistory) { UserDefaults.standard.set(d, forKey: "wallpaperHistory") }
    }
}
