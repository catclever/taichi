import Foundation

let url = URL(fileURLWithPath: "Sources/TaiChi/Resources/MediaRemoteAdapter/mediaremote-adapter.pl")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
process.arguments = [
    url.path,
    URL(fileURLWithPath: "Sources/TaiChi/Resources/MediaRemoteAdapter/MediaRemoteAdapter.framework").path,
    "get"
]

let pipe = Pipe()
process.standardOutput = pipe
try! process.run()
let data = pipe.fileHandleForReading.readDataToEndOfFile()
print(String(data: data, encoding: .utf8)!)
