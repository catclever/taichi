import Foundation
let content = """
hotkeys = {
    togglePin = {{"ctrl"}, "H"},
    toggleAll = {{"cmd", "ctrl"}, "H"},
    triggerInspector = nil
  }
"""
let pattern = "togglePin\\s*=\\s*\\{\\{([^}]+)\\}\\s*,\\s*\"([^\"]+)\"\\}"
if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
    let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
    if let match = regex.firstMatch(in: content, options: [], range: nsRange) {
        print("Match successful!")
    } else {
        print("Match failed!")
    }
}
