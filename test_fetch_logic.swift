import Foundation

struct WallpaperHistoryEntry: Codable {
    var photoId: String
    var timestamp: Date
}
struct WallpaperEngineConfig: Codable {
    var globalIntervalMinutes: Int?
    var enableAutoChange: Bool?
    var autoTimeConfig: AutoTimeConfig?
    struct AutoTimeConfig: Codable {
        var times: [String]?
        var screens: [String]?
        var checkThresholdSeconds: Int?
    }
}

let historyData = UserDefaults(suiteName: "com.kael.taichi")?.data(forKey: "wallpaperHistory")
let historyMap = (try? JSONDecoder().decode([String: [WallpaperHistoryEntry]].self, from: historyData ?? Data())) ?? [:]

let url = URL(fileURLWithPath: ("/Users/kael/Library/Services/taichi/wallpaper.json" as NSString).expandingTildeInPath)
let configData = try! Data(contentsOf: url)
let config = try! JSONDecoder().decode(WallpaperEngineConfig.self, from: configData)

let intervalMinutes = config.globalIntervalMinutes ?? 1440
let intervalSeconds = max(60, intervalMinutes * 60)
let now = Date()

let screens = [
    ("37D8832A-2D66-02CA-B9F7-8F30A301B230", "2490W1"),
    ("CB2C571C-A6A7-47EA-B930-764C9503DAA4", "Built-in Retina Display"),
    ("UNKNOWN_UUID", "小面板")
]

for screen in screens {
    let history = historyMap[screen.0] ?? []
    let lastTimestamp = history.last?.timestamp ?? Date.distantPast
    let elapsed = now.timeIntervalSince(lastTimestamp)
    
    var shouldFetch = false
    print("Screen \(screen.1): elapsed \(elapsed) seconds, interval \(intervalSeconds)")
    
    if elapsed >= Double(intervalSeconds) {
        shouldFetch = true
        print("- Global interval passed.")
    }
    
    if let autoConfig = config.autoTimeConfig, 
       let times = autoConfig.times,
       let threshold = autoConfig.checkThresholdSeconds {
        let calendar = Calendar.current
        var timeMatched = false
        for timeStr in times {
            let components = timeStr.split(separator: ":")
            if components.count == 2, let hour = Int(components[0]), let minute = Int(components[1]) {
                if let targetDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) {
                    if now >= targetDate && lastTimestamp < targetDate {
                        timeMatched = true
                        print("- Time matched: \(timeStr), targetDate: \(targetDate), lastTimestamp: \(lastTimestamp)")
                        break
                    }
                }
            }
        }
        if timeMatched && elapsed >= Double(threshold) {
            print("- Time matched and threshold passed.")
            shouldFetch = true
        }
    }
    print("- shouldFetch: \(shouldFetch)\n")
}
