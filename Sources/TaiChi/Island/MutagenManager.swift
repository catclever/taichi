import Foundation
import Combine

public struct MutagenChange: Codable, Equatable, Sendable {
    public let path: String?
    
    public init(path: String? = nil) {
        self.path = path
    }
}

public struct MutagenConflict: Codable, Equatable, Sendable, Identifiable {
    public let root: String?
    public let alphaChanges: [MutagenChange]?
    public let betaChanges: [MutagenChange]?
    
    public var id: String { root ?? UUID().uuidString }
    
    public init(
        root: String? = nil,
        alphaChanges: [MutagenChange]? = nil,
        betaChanges: [MutagenChange]? = nil
    ) {
        self.root = root
        self.alphaChanges = alphaChanges
        self.betaChanges = betaChanges
    }
}

public struct MutagenIgnore: Codable, Equatable, Sendable {
    public let paths: [String]?
    
    public init(paths: [String]? = nil) {
        self.paths = paths
    }
}

public struct MutagenEndpoint: Codable, Equatable, Sendable {
    public let url: String?
    public let connected: Bool?
    public let `protocol`: String?
    public let path: String?
    public let host: String?
    public let user: String?
    public let port: Int?
    
    public init(
        url: String? = nil,
        connected: Bool? = nil,
        protocol: String? = nil,
        path: String? = nil,
        host: String? = nil,
        user: String? = nil,
        port: Int? = nil
    ) {
        self.url = url
        self.connected = connected
        self.`protocol` = `protocol`
        self.path = path
        self.host = host
        self.user = user
        self.port = port
    }
    
    public var commandFormat: String {
        if let proto = `protocol`, proto != "local" {
            var prefix = ""
            if let user = user, !user.isEmpty {
                prefix += "\(user)@"
            }
            if let host = host, !host.isEmpty {
                prefix += host
            }
            if let port = port {
                prefix += ":\(port)"
            }
            let p = path ?? ""
            if !prefix.isEmpty {
                return "\(prefix):\(p)"
            }
        }
        return path ?? url ?? ""
    }
}

public enum SessionType: Equatable, Sendable {
    case normal
    case unlinkedProject(projectId: String)
    case linkedProject(projectId: String, configPath: String)
}

public struct MutagenSession: Codable, Identifiable, Equatable, Sendable {
    public let identifier: String
    public let name: String?
    public let labels: [String: String]?
    public let alpha: MutagenEndpoint?
    public let beta: MutagenEndpoint?
    public let status: String?
    public let paused: Bool?
    public let mode: String?
    public let ignore: MutagenIgnore?
    public let conflicts: [MutagenConflict]?
    
    public var id: String { identifier }
    public var projectId: String? { labels?["io.mutagen.project"] }
    public var hasConflicts: Bool { !(conflicts?.isEmpty ?? true) }
    public var conflictCount: Int { conflicts?.count ?? 0 }
    
    public init(
        identifier: String,
        name: String? = nil,
        labels: [String: String]? = nil,
        alpha: MutagenEndpoint? = nil,
        beta: MutagenEndpoint? = nil,
        status: String? = nil,
        paused: Bool? = nil,
        mode: String? = nil,
        ignore: MutagenIgnore? = nil,
        conflicts: [MutagenConflict]? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.labels = labels
        self.alpha = alpha
        self.beta = beta
        self.status = status
        self.paused = paused
        self.mode = mode
        self.ignore = ignore
        self.conflicts = conflicts
    }
    
    public func generateCreateCommand(newIgnores: [String]) -> String {
        var cmd = "mutagen sync create"
        
        if let name = name, !name.isEmpty {
            cmd += " --name=\"\(name)\""
        }
        
        let syncMode = mode ?? "two-way-safe"
        cmd += " -m \(syncMode)"
        
        for ig in newIgnores {
            cmd += " -i \"\(ig)\""
        }
        
        let alphaStr = alpha?.commandFormat ?? ""
        let betaStr = beta?.commandFormat ?? ""
        
        cmd += " \"\(alphaStr)\" \"\(betaStr)\""
        
        return cmd
    }
}

public enum MutagenError: LocalizedError, Sendable {
    case fileNotFound(String)
    case syncSectionNotFound
    case sessionNotFoundInConfig(String)
    case commandFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "配置文件未找到: \(path)"
        case .syncSectionNotFound:
            return "在配置文件中未找到 'sync' 部分"
        case .sessionNotFoundInConfig(let name):
            return "在配置文件中未找到对应的任务: \(name)"
        case .commandFailed(let msg):
            return "命令执行失败: \(msg)"
        }
    }
}

@MainActor
public class MutagenManager: ObservableObject {
    public static let shared = MutagenManager()
    
    @Published public var sessions: [MutagenSession] = []
    @Published public var archivedSessions: [MutagenSession] = []
    @Published public var projectMappings: [String: String] = [:]
    @Published public var pendingSelectionId: String? = nil
    
    public var mappingsFileURL: URL {
        URL(fileURLWithPath: (TaiChiSettings.shared.scriptsPath as NSString).expandingTildeInPath)
            .appendingPathComponent("mutagen_projects.json")
    }
    
    public var archivedSessionsFileURL: URL {
        URL(fileURLWithPath: (TaiChiSettings.shared.scriptsPath as NSString).expandingTildeInPath)
            .appendingPathComponent("mutagen_archived_sessions.json")
    }
    
    private init() {
        loadMappings()
        loadArchivedSessions()
    }
    
    // MARK: - Mappings Persistence
    
    public func loadMappings() {
        let url = mappingsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.projectMappings = [:]
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([String: String].self, from: data)
            self.projectMappings = decoded
        } catch {
            print("MutagenManager loadMappings error: \(error)")
            self.projectMappings = [:]
        }
    }
    
    public func saveMappings() {
        let url = mappingsFileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(projectMappings)
            let dir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            print("MutagenManager saveMappings error: \(error)")
        }
    }
    
    public func bind(projectId: String, path: String) {
        let standardized = (path as NSString).expandingTildeInPath
        projectMappings[projectId] = standardized
        saveMappings()
    }
    
    public func unbind(projectId: String) {
        projectMappings.removeValue(forKey: projectId)
        saveMappings()
    }
    
    public func sessionType(for session: MutagenSession) -> SessionType {
        guard let projectId = session.projectId, !projectId.isEmpty else {
            return .normal
        }
        if let configPath = projectMappings[projectId],
           !configPath.isEmpty,
           FileManager.default.fileExists(atPath: configPath) {
            return .linkedProject(projectId: projectId, configPath: configPath)
        }
        return .unlinkedProject(projectId: projectId)
    }
    
    // MARK: - Mutagen CLI Status & Sessions
    
    public func checkInstallStatus() -> Bool {
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; which mutagen"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return task.terminationStatus == 0 && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } catch {
            return false
        }
    }
    
    public func fetchSessions() {
        Task.detached {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; mutagen sync list --template '{{json .}}'"]
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            do {
                try task.run()
                task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                
                var loadedSessions: [MutagenSession] = []
                
                if let decoded = try? JSONDecoder().decode([MutagenSession].self, from: data) {
                    loadedSessions = decoded
                } else if let single = try? JSONDecoder().decode(MutagenSession.self, from: data) {
                    loadedSessions = [single]
                } else {
                    let str = String(data: data, encoding: .utf8) ?? ""
                    let lines = str.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    var parsedSessions = [MutagenSession]()
                    for line in lines {
                        if let d = line.data(using: .utf8), let s = try? JSONDecoder().decode(MutagenSession.self, from: d) {
                            parsedSessions.append(s)
                        }
                    }
                    if !parsedSessions.isEmpty {
                        loadedSessions = parsedSessions
                    } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let list = dict["sessions"] as? [[String: Any]],
                              let listData = try? JSONSerialization.data(withJSONObject: list),
                              let arr = try? JSONDecoder().decode([MutagenSession].self, from: listData) {
                        loadedSessions = arr
                    }
                }
                
                await MainActor.run {
                    self.sessions = loadedSessions
                }
            } catch {
                print("Mutagen fetch error: \(error)")
            }
        }
    }
    
    // MARK: - YAML Ignore Updating
    
    private static func leadingSpaces(of line: String) -> Int {
        var count = 0
        for ch in line {
            if ch == " " { count += 1 }
            else if ch == "\t" { count += 2 }
            else { break }
        }
        return count
    }
    
    public func updateYamlIgnorePaths(yamlContent: String, sessionName: String?, newIgnores: [String]) throws -> String {
        let isCRLF = yamlContent.contains("\r\n")
        let newlineSeparator = isCRLF ? "\r\n" : "\n"
        var lines = yamlContent.components(separatedBy: newlineSeparator)
        
        // 1. Find sync: section
        var syncLineIndex: Int?
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("sync:") || trimmed == "sync" {
                syncLineIndex = i
                break
            }
        }
        
        guard let syncIdx = syncLineIndex else {
            throw MutagenError.syncSectionNotFound
        }
        let syncIndent = Self.leadingSpaces(of: lines[syncIdx])
        
        // 2. Find target session under sync:
        var sessionLineIndex: Int?
        var sessionIndent: Int?
        var defaultSessionLineIndex: Int?
        var defaultSessionIndent: Int?
        
        var i = syncIdx + 1
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            
            let indent = Self.leadingSpaces(of: line)
            if indent <= syncIndent {
                break
            }
            
            if sessionIndent == nil {
                sessionIndent = indent
            }
            
            if indent == sessionIndent {
                let keyPart = trimmed.components(separatedBy: ":").first?.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"'"))) ?? ""
                if let sessionName = sessionName, !sessionName.isEmpty {
                    if keyPart == sessionName {
                        sessionLineIndex = i
                        break
                    }
                }
                if keyPart != "defaults" && defaultSessionLineIndex == nil {
                    defaultSessionLineIndex = i
                    defaultSessionIndent = indent
                }
            }
            i += 1
        }
        
        let targetSessionIdx: Int
        let targetSessionIndent: Int
        if let foundIdx = sessionLineIndex, let foundIndent = sessionIndent {
            targetSessionIdx = foundIdx
            targetSessionIndent = foundIndent
        } else if let defIdx = defaultSessionLineIndex, let defIndent = defaultSessionIndent {
            targetSessionIdx = defIdx
            targetSessionIndent = defIndent
        } else {
            throw MutagenError.sessionNotFoundInConfig(sessionName ?? "默认任务")
        }
        
        // 3. Find bounds of this session
        var sessionEndIdx = lines.count
        for j in (targetSessionIdx + 1)..<lines.count {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }
            let indent = Self.leadingSpaces(of: line)
            if indent <= targetSessionIndent {
                sessionEndIdx = j
                break
            }
        }
        
        // Detect session indentation step
        var indentStep = 2
        for j in (targetSessionIdx + 1)..<sessionEndIdx {
            let indent = Self.leadingSpaces(of: lines[j])
            if indent > targetSessionIndent {
                indentStep = max(2, indent - targetSessionIndent)
                break
            }
        }
        
        // Look inside session block for configuration: and ignore:
        var configLineIdx: Int?
        var configIndent: Int?
        var ignoreLineIdx: Int?
        var ignoreIndent: Int?
        var pathsLineIdx: Int?
        var pathsIndent: Int?
        
        for j in (targetSessionIdx + 1)..<sessionEndIdx {
            let line = lines[j]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = Self.leadingSpaces(of: line)
            
            if trimmed.hasPrefix("configuration:") || trimmed == "configuration" {
                configLineIdx = j
                configIndent = indent
            } else if trimmed.hasPrefix("ignore:") || trimmed == "ignore" {
                ignoreLineIdx = j
                ignoreIndent = indent
            } else if trimmed.hasPrefix("paths:") || trimmed == "paths" || trimmed.hasPrefix("paths :") {
                if let igIndent = ignoreIndent, indent > igIndent {
                    pathsLineIdx = j
                    pathsIndent = indent
                }
            }
        }
        
        if let pIdx = pathsLineIdx, let pIndent = pathsIndent {
            var itemsEndIdx = pIdx + 1
            while itemsEndIdx < sessionEndIdx {
                let line = lines[itemsEndIdx]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    itemsEndIdx += 1
                    continue
                }
                let indent = Self.leadingSpaces(of: line)
                if indent > pIndent && (trimmed.hasPrefix("-") || trimmed.hasPrefix("#")) {
                    itemsEndIdx += 1
                } else {
                    break
                }
            }
            
            let listIndentStr = String(repeating: " ", count: pIndent + indentStep)
            var replacementLines: [String] = []
            if newIgnores.isEmpty {
                replacementLines.append("\(String(repeating: " ", count: pIndent))paths: []")
            } else {
                replacementLines.append("\(String(repeating: " ", count: pIndent))paths:")
                for ig in newIgnores {
                    replacementLines.append("\(listIndentStr)- \"\(ig)\"")
                }
            }
            lines.replaceSubrange(pIdx..<itemsEndIdx, with: replacementLines)
            
        } else if let igIdx = ignoreLineIdx, let igIndent = ignoreIndent {
            let pIndent = igIndent + indentStep
            let listIndentStr = String(repeating: " ", count: pIndent + indentStep)
            var toInsert: [String] = []
            if newIgnores.isEmpty {
                toInsert.append("\(String(repeating: " ", count: pIndent))paths: []")
            } else {
                toInsert.append("\(String(repeating: " ", count: pIndent))paths:")
                for ig in newIgnores {
                    toInsert.append("\(listIndentStr)- \"\(ig)\"")
                }
            }
            lines.insert(contentsOf: toInsert, at: igIdx + 1)
            
        } else if let cIdx = configLineIdx, let cIndent = configIndent {
            let igIndent = cIndent + indentStep
            let pIndent = igIndent + indentStep
            let listIndentStr = String(repeating: " ", count: pIndent + indentStep)
            var toInsert: [String] = []
            toInsert.append("\(String(repeating: " ", count: igIndent))ignore:")
            if newIgnores.isEmpty {
                toInsert.append("\(String(repeating: " ", count: pIndent))paths: []")
            } else {
                toInsert.append("\(String(repeating: " ", count: pIndent))paths:")
                for ig in newIgnores {
                    toInsert.append("\(listIndentStr)- \"\(ig)\"")
                }
            }
            lines.insert(contentsOf: toInsert, at: cIdx + 1)
            
        } else {
            let igIndent = targetSessionIndent + indentStep
            let pIndent = igIndent + indentStep
            let listIndentStr = String(repeating: " ", count: pIndent + indentStep)
            var toInsert: [String] = []
            toInsert.append("\(String(repeating: " ", count: igIndent))ignore:")
            if newIgnores.isEmpty {
                toInsert.append("\(String(repeating: " ", count: pIndent))paths: []")
            } else {
                toInsert.append("\(String(repeating: " ", count: pIndent))paths:")
                for ig in newIgnores {
                    toInsert.append("\(listIndentStr)- \"\(ig)\"")
                }
            }
            lines.insert(contentsOf: toInsert, at: targetSessionIdx + 1)
        }
        
        return lines.joined(separator: newlineSeparator)
    }
    
    // MARK: - Project Reload & Hot Restart
    
    public func updateProjectIgnoreAndReload(session: MutagenSession, configPath: String, newIgnores: [String]) async throws {
        let configURL = URL(fileURLWithPath: configPath)
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw MutagenError.fileNotFound(configPath)
        }
        
        // 1. 备份为 .bak
        let bakURL = URL(fileURLWithPath: configPath + ".bak")
        if FileManager.default.fileExists(atPath: bakURL.path) {
            try? FileManager.default.removeItem(at: bakURL)
        }
        try FileManager.default.copyItem(at: configURL, to: bakURL)
        
        // 2. 修改 YAML ignore.paths
        let content = try String(contentsOf: configURL, encoding: .utf8)
        let updatedContent = try updateYamlIgnorePaths(yamlContent: content, sessionName: session.name, newIgnores: newIgnores)
        try updatedContent.write(to: configURL, atomically: true, encoding: .utf8)
        
        // 3. 执行重启
        try await reloadProject(configPath: configPath)
    }
    
    public func reloadProject(configPath: String) async throws {
        // mutagen project terminate -f <path>
        let termTask = Process()
        termTask.launchPath = "/bin/sh"
        termTask.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; mutagen project terminate -f \"\(configPath)\""]
        try? termTask.run()
        termTask.waitUntilExit()
        
        // mutagen project start -f <path>
        let startTask = Process()
        startTask.launchPath = "/bin/sh"
        startTask.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; mutagen project start -f \"\(configPath)\""]
        let pipe = Pipe()
        startTask.standardOutput = pipe
        startTask.standardError = pipe
        try startTask.run()
        startTask.waitUntilExit()
        
        if startTask.terminationStatus != 0 {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MutagenError.commandFailed("mutagen project start 失败: \(errMsg)")
        }
        
        fetchSessions()
    }
    
    public func hotRestartNormal(session: MutagenSession, newIgnores: [String]) async throws {
        let createCmd = session.generateCreateCommand(newIgnores: newIgnores)
        
        let termTask = Process()
        termTask.launchPath = "/bin/sh"
        termTask.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; mutagen sync terminate \(session.id)"]
        try? termTask.run()
        termTask.waitUntilExit()
        
        let createTask = Process()
        createTask.launchPath = "/bin/sh"
        createTask.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; \(createCmd)"]
        let pipe = Pipe()
        createTask.standardOutput = pipe
        createTask.standardError = pipe
        try createTask.run()
        createTask.waitUntilExit()
        
        if createTask.terminationStatus != 0 {
            let errData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MutagenError.commandFailed("mutagen sync create 失败: \(errMsg)")
        }
        
        fetchSessions()
    }
    
    // MARK: - Batch Control
    
    public func pauseAll() {
        Task.detached {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; mutagen sync pause --all"]
            try? task.run()
            task.waitUntilExit()
            await self.fetchSessions()
        }
    }
    
    public func resumeAll() {
        Task.detached {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; mutagen sync resume --all"]
            try? task.run()
            task.waitUntilExit()
            await self.fetchSessions()
        }
    }
    
    // MARK: - Archived Sessions
    
    public func loadArchivedSessions() {
        let url = archivedSessionsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            self.archivedSessions = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode([MutagenSession].self, from: data)
            self.archivedSessions = decoded
        } catch {
            print("MutagenManager loadArchivedSessions error: \(error)")
            self.archivedSessions = []
        }
    }
    
    public func saveArchivedSessions() {
        let url = archivedSessionsFileURL
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(archivedSessions)
            let dir = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            print("MutagenManager saveArchivedSessions error: \(error)")
        }
    }
    
    public func togglePause(session: MutagenSession) {
        let isPaused = session.paused ?? false
        let action = isPaused ? "resume" : "pause"
        Task.detached {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; mutagen sync \(action) \(session.id)"]
            try? task.run()
            task.waitUntilExit()
            await self.fetchSessions()
        }
    }
    
    public func terminateAndArchive(session: MutagenSession) {
        if !archivedSessions.contains(where: { $0.id == session.id }) {
            archivedSessions.append(session)
            saveArchivedSessions()
        }
        
        Task.detached {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; mutagen sync terminate \(session.id)"]
            try? task.run()
            task.waitUntilExit()
            await self.fetchSessions()
        }
    }
    
    public func resumeArchivedSession(id: String) {
        guard let index = archivedSessions.firstIndex(where: { $0.id == id }) else { return }
        let session = archivedSessions[index]
        
        Task.detached {
            let sessionType = await self.sessionType(for: session)
            var cmd = ""
            
            if case .linkedProject(_, let configPath) = sessionType {
                cmd = "mutagen project start -f \"\(configPath)\""
            } else {
                cmd = session.generateCreateCommand(newIgnores: session.ignore?.paths ?? [])
            }
            
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "export PATH=/usr/local/bin:/opt/homebrew/bin:$PATH; \(cmd)"]
            try? task.run()
            task.waitUntilExit()
            
            await MainActor.run {
                if task.terminationStatus == 0 {
                    self.archivedSessions.removeAll { $0.id == id }
                    self.saveArchivedSessions()
                }
            }
            await self.fetchSessions()
        }
    }
    
    public func deleteArchivedSession(id: String) {
        archivedSessions.removeAll { $0.id == id }
        saveArchivedSessions()
    }
}
