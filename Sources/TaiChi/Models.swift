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

@MainActor
class TaiChiSettings: ObservableObject {
    static let shared = TaiChiSettings()
    
    @Published var residentApps: [ResidentApp] = [] {
        didSet { saveResidentApps() }
    }
    
    @Published var monitoredApps: [MonitoredApp] = [] {
        didSet { saveMonitoredApps() }
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
    
    init() {
        loadSettings()
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
    }
    
    private func saveResidentApps() {
        if let data = try? JSONEncoder().encode(residentApps) {
            UserDefaults.standard.set(data, forKey: "residentApps")
        }
    }
    
    private func saveMonitoredApps() {
        if let data = try? JSONEncoder().encode(monitoredApps) {
            UserDefaults.standard.set(data, forKey: "monitoredApps")
        }
    }
    
    private func saveCommonPaths() {
        if let data = try? JSONEncoder().encode(commonPaths) {
            UserDefaults.standard.set(data, forKey: "commonPaths")
        }
    }
    
    private func saveHttpPort() {
        UserDefaults.standard.set(httpPort, forKey: "httpPort")
    }
    
    private func saveScriptsPath() {
        UserDefaults.standard.set(scriptsPath, forKey: "scriptsPath")
    }
}
