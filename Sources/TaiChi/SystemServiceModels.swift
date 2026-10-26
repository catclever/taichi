import Foundation
import SwiftUI

// MARK: - TaiChi Declarative Service Manifest
public struct TaiChiServiceManifest: Codable, Sendable, Equatable, Hashable {
    public var schema: String?
    public var id: String
    public var name: String
    public var description: String?
    public var category: String? // web, api, daemon, mount
    public var workDir: String?
    public var entrypoint: String?
    public var startCmd: String
    public var stopCmd: String?
    public var defaultPort: Int?
    public var hasWebUI: Bool?
    public var webPath: String?
    public var icon: String?
    public var refactoredFiles: [String]?

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case id
        case name
        case description
        case category
        case workDir = "work_dir"
        case workDirAlt = "workDir"
        case entrypoint
        case startCmd = "start_cmd"
        case stopCmd = "stop_cmd"
        case defaultPort = "default_port"
        case hasWebUI = "has_web_ui"
        case webPath = "web_path"
        case icon
        case refactoredFiles = "refactored_files"
    }

    public init(
        schema: String? = nil,
        id: String,
        name: String,
        description: String? = nil,
        category: String? = nil,
        workDir: String? = nil,
        entrypoint: String? = nil,
        startCmd: String,
        stopCmd: String? = nil,
        defaultPort: Int? = nil,
        hasWebUI: Bool? = nil,
        webPath: String? = nil,
        icon: String? = nil,
        refactoredFiles: [String]? = nil
    ) {
        self.schema = schema
        self.id = id
        self.name = name
        self.description = description
        self.category = category
        self.workDir = workDir
        self.entrypoint = entrypoint
        self.startCmd = startCmd
        self.stopCmd = stopCmd
        self.defaultPort = defaultPort
        self.hasWebUI = hasWebUI
        self.webPath = webPath
        self.icon = icon
        self.refactoredFiles = refactoredFiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decodeIfPresent(String.self, forKey: .schema)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.category = try container.decodeIfPresent(String.self, forKey: .category)
        self.workDir = (try? container.decodeIfPresent(String.self, forKey: .workDir))
            ?? (try? container.decodeIfPresent(String.self, forKey: .workDirAlt))
        self.entrypoint = try container.decodeIfPresent(String.self, forKey: .entrypoint)
        self.startCmd = try container.decode(String.self, forKey: .startCmd)
        self.stopCmd = try container.decodeIfPresent(String.self, forKey: .stopCmd)
        self.defaultPort = try container.decodeIfPresent(Int.self, forKey: .defaultPort)
        self.hasWebUI = try container.decodeIfPresent(Bool.self, forKey: .hasWebUI)
        self.webPath = try container.decodeIfPresent(String.self, forKey: .webPath)
        self.icon = try container.decodeIfPresent(String.self, forKey: .icon)
        self.refactoredFiles = try container.decodeIfPresent([String].self, forKey: .refactoredFiles)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(schema, forKey: .schema)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(category, forKey: .category)
        try container.encodeIfPresent(workDir, forKey: .workDir)
        try container.encodeIfPresent(entrypoint, forKey: .entrypoint)
        try container.encode(startCmd, forKey: .startCmd)
        try container.encodeIfPresent(stopCmd, forKey: .stopCmd)
        try container.encodeIfPresent(defaultPort, forKey: .defaultPort)
        try container.encodeIfPresent(hasWebUI, forKey: .hasWebUI)
        try container.encodeIfPresent(webPath, forKey: .webPath)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(refactoredFiles, forKey: .refactoredFiles)
    }
}

// MARK: - Service Runtime State
public enum ServiceState: Equatable, Sendable {
    case stopped
    case starting
    case running
    case error(String)

    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    public var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }

    public var displayText: String {
        switch self {
        case .stopped:
            return "已停止"
        case .starting:
            return "启动中..."
        case .running:
            return "运行中"
        case .error(let message):
            return "异常: \(message)"
        }
    }
}

// MARK: - TaiChi Service Item
public class TaiChiServiceItem: Identifiable, ObservableObject, @unchecked Sendable {
    public let id: String
    @Published public var manifest: TaiChiServiceManifest
    public var dirURL: URL
    @Published public var state: ServiceState
    @Published public var assignedPort: Int
    @Published public var pid: pid_t?
    public var process: Process?

    public init(
        manifest: TaiChiServiceManifest,
        dirURL: URL,
        state: ServiceState = .stopped,
        assignedPort: Int? = nil,
        pid: pid_t? = nil,
        process: Process? = nil
    ) {
        self.id = manifest.id
        self.manifest = manifest
        self.dirURL = dirURL
        self.state = state
        self.assignedPort = assignedPort ?? manifest.defaultPort ?? 0
        self.pid = pid
        self.process = process
    }

    public var isWebAccessible: Bool {
        return (manifest.hasWebUI == true) || (manifest.category == "web") || (assignedPort > 0 && manifest.webPath != nil)
    }

    public var webURL: URL? {
        guard assignedPort > 0 else { return nil }
        let rawPath = manifest.webPath ?? "/"
        let cleanPath = rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"
        return URL(string: "http://127.0.0.1:\(assignedPort)\(cleanPath)")
    }
}
