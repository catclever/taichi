import Foundation

struct WallpaperHistoryEntry: Codable, Equatable {
    var photoId: String
    var timestamp: Date
    var channelName: String?
    var title: String?
}

if let data = UserDefaults(suiteName: "com.kael.taichi")?.data(forKey: "wallpaperHistory") {
    print("Found data, size:", data.count)
    do {
        let hs = try JSONDecoder().decode([String: [WallpaperHistoryEntry]].self, from: data)
        print("Decoded history:", hs)
    } catch {
        print("Decode error:", error)
    }
} else {
    print("No data found")
}
