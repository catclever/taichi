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
}
