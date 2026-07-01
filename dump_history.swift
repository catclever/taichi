import Foundation
if let dict = UserDefaults(suiteName: "TaiChi")?.dictionaryRepresentation() {
    print("Found dict")
}
let data = UserDefaults.standard.persistentDomain(forName: "TaiChi")?["wallpaperHistory"] as? Data
if let data = data {
    print(String(data: data, encoding: .utf8) ?? "err")
}
