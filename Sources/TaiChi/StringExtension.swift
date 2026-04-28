import Foundation

extension String {
    func append(to url: URL) throws {
        let data = self.data(using: .utf8)!
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            defer { fileHandle.closeFile() }
            fileHandle.seekToEndOfFile()
            fileHandle.write(data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }
}
