import Foundation

struct WallpaperHistoryEntry: Codable {
    var photoId: String
    var timestamp: Date
}

struct ScreenInfo: Codable {
    var uuid: String
    var name: String
}

if let data = UserDefaults(suiteName: "com.kael.taichi")?.data(forKey: "wallpaperHistory") {
    let hs = try! JSONDecoder().decode([String: [WallpaperHistoryEntry]].self, from: data)
    for (k, v) in hs {
        print("History for \(k): \(v.count) entries, last: \(v.last?.timestamp)")
    }
}

if let data = UserDefaults(suiteName: "com.kael.taichi")?.data(forKey: "connectedScreens") {
    let sc = try! JSONDecoder().decode([ScreenInfo].self, from: data)
    for s in sc {
        print("Connected screen: \(s.name) (\(s.uuid))")
    }
}
