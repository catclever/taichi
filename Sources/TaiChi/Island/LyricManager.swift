import Foundation
import Combine

struct NeteaseSearchResponse: Decodable {
    struct Result: Decodable {
        struct Song: Decodable {
            let id: Int
            let name: String
            let artists: [Artist]?
        }
        struct Artist: Decodable {
            let name: String
        }
        let songs: [Song]?
    }
    let result: Result?
}

struct NeteaseLyricResponse: Decodable {
    struct Lrc: Decodable {
        let lyric: String?
    }
    let lrc: Lrc?
}

struct LyricLine: Equatable, Hashable {
    let time: TimeInterval
    let text: String
}

class LyricManager: ObservableObject, @unchecked Sendable {
    static let shared = LyricManager()
    
    @Published var currentLyrics: [LyricLine] = []
    
    private var currentSongQuery: String = ""
    private var cancellables = Set<AnyCancellable>()
    private var lastPushTime: Date = Date.distantPast
    private var hasPushedForCurrentSong: Bool = false
    
    func pushLyrics(title: String, artist: String, lrc: String) {
        let query = "\(title) \(artist)"
        
        DispatchQueue.main.async {
            if self.currentSongQuery != query {
                self.currentLyrics = []
                self.currentSongQuery = query
                self.hasPushedForCurrentSong = false
            }
            
            // If this is the first push for this song, clear any existing NetEase lyrics
            if !self.hasPushedForCurrentSong {
                self.currentLyrics = []
                self.hasPushedForCurrentSong = true
            }
            
            self.lastPushTime = Date()
            self.cancellables.removeAll()
            
            let lines = lrc.components(separatedBy: .newlines)
            let regex = try! NSRegularExpression(pattern: "\\[(\\d{1,2}):(\\d{1,2})(?:\\.(\\d{1,3}))?\\](.*)")
            
            for line in lines {
                if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let mStr = (line as NSString).substring(with: match.range(at: 1))
                    let sStr = (line as NSString).substring(with: match.range(at: 2))
                    let msRange = match.range(at: 3)
                    let msStr = msRange.location != NSNotFound ? (line as NSString).substring(with: msRange) : "0"
                    let text = (line as NSString).substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                    
                    if text.isEmpty { continue }
                    
                    let m = Double(mStr) ?? 0
                    let s = Double(sStr) ?? 0
                    let ms = Double(msStr) ?? 0
                    let msDivisor = msStr.count == 3 ? 1000.0 : (msStr.count == 2 ? 100.0 : 10.0)
                    
                    let time = m * 60 + s + (ms / msDivisor)
                    self.currentLyrics.append(LyricLine(time: time, text: text))
                }
            }
        }
    }
    
    func fetchLyrics(title: String, artist: String, isFallback: Bool = false) {
        // 如果 10 秒内有过推送歌词，且不是降级触发，就不要去网易云查了，防止覆盖推送过来的歌词
        if !isFallback && Date().timeIntervalSince(lastPushTime) < 10.0 {
            return
        }
        
        let query = "\(title) \(artist)"
        guard query != currentSongQuery else { return }
        self.currentSongQuery = query
        
        DispatchQueue.main.async {
            self.currentLyrics = []
        }
        
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://music.163.com/api/search/get/web?csrf_token=hlpretag=&hlposttag=&s=\(encodedQuery)&type=1&offset=0&total=true&limit=1") else {
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTaskPublisher(for: request)
            .map { $0.data }
            .decode(type: NeteaseSearchResponse.self, decoder: JSONDecoder())
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] response in
                guard let songId = response.result?.songs?.first?.id else { return }
                self?.fetchLyric(for: songId)
            })
            .store(in: &cancellables)
    }
    
    private func fetchLyric(for songId: Int) {
        guard let url = URL(string: "https://music.163.com/api/song/lyric?id=\(songId)&lv=1&kv=1&tv=-1") else { return }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
        
        URLSession.shared.dataTaskPublisher(for: request)
            .map { $0.data }
            .decode(type: NeteaseLyricResponse.self, decoder: JSONDecoder())
            .sink(receiveCompletion: { _ in }, receiveValue: { [weak self] response in
                guard let lrcString = response.lrc?.lyric else { return }
                self?.parseLyric(lrcString)
            })
            .store(in: &cancellables)
    }
    
    private func parseLyric(_ lrc: String) {
        let lines = lrc.components(separatedBy: .newlines)
        var parsedLines: [LyricLine] = []
        
        let regex = try! NSRegularExpression(pattern: "\\[(\\d{2}):(\\d{2})\\.(\\d{2,3})\\](.*)")
        
        for line in lines {
            if let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                let mStr = (line as NSString).substring(with: match.range(at: 1))
                let sStr = (line as NSString).substring(with: match.range(at: 2))
                let msStr = (line as NSString).substring(with: match.range(at: 3))
                let text = (line as NSString).substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)
                
                if text.isEmpty { continue }
                
                let m = Double(mStr) ?? 0
                let s = Double(sStr) ?? 0
                let ms = Double(msStr) ?? 0
                let msDivisor = msStr.count == 3 ? 1000.0 : 100.0
                
                let time = m * 60 + s + (ms / msDivisor)
                parsedLines.append(LyricLine(time: time, text: text))
            }
        }
        
        DispatchQueue.main.async {
            self.currentLyrics = parsedLines.sorted(by: { $0.time < $1.time })
        }
    }
}
