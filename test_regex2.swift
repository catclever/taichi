import Foundation
let content = """
return {
  taichi_port = 9216,
  hs_port = 9999,
  security_token = "FDF893jKDS",
  wallpaperSaveDir = "/Users/kael/Pictures",
}
"""
let pattern = "security_token = \"([^\"]+)\""
if let range = content.range(of: pattern, options: .regularExpression) {
    let match = String(content[range])
    let components = match.components(separatedBy: "\"")
    if components.count >= 3 {
        print("Token: \(components[1])")
    } else {
        print("Components failed")
    }
} else {
    print("Regex failed")
}
