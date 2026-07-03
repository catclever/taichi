import Foundation

let defaults = UserDefaults.standard
let dict = defaults.dictionaryRepresentation()
print("Defaults count: \(dict.count)")
let taichiKeys = dict.keys.filter { $0.lowercased().contains("taichi") || $0.lowercased().contains("wallpaper") }
for key in taichiKeys {
    print("\(key): \(dict[key]!)")
}
