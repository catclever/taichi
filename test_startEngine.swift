import Foundation

let url = URL(fileURLWithPath: ("/Users/kael/Library/Services/taichi/wallpaper.json" as NSString).expandingTildeInPath)
let configData = try! Data(contentsOf: url)

if let str = String(data: configData, encoding: .utf8) {
    print(str)
}
