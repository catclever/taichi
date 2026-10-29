import Foundation
import SwiftUI
import AppKit

/// Central manager for declarative TaiChi system services and Descartes Hub onboarding
@MainActor
public class SystemServiceManager: ObservableObject, @unchecked Sendable {
    public static let shared = SystemServiceManager()

    @Published public var managedServices: [TaiChiServiceItem] = []
    @Published public var unmanagedDirectories: [URL] = []
    @Published public var isScanning: Bool = false
    @Published public var activeOnboardingDir: URL? = nil

    private var descartesClient: DescartesHubClient?
    private var serviceLogBuffers: [String: [String]] = [:]

    private init() {
        scanServices()

        // Safely terminate child processes on application exit
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stopAllServices()
            }
        }
    }

    // MARK: - Declarative Service Discovery

    /// Scans the configured services directory (defaults to `~/Library/Services/`)
    /// Identifies managed services containing `taichi-service.json` and unmanaged directories
    public func scanServices() {
        isScanning = true
        defer { isScanning = false }

        let rawPath = TaiChiSettings.shared.servicesDirectoryPath
        let servicesPath = (rawPath as NSString).expandingTildeInPath
        let servicesDirURL = URL(fileURLWithPath: servicesPath)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: servicesDirURL.path, isDirectory: &isDir), isDir.boolValue else {
            self.unmanagedDirectories = []
            return
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: servicesDirURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            self.unmanagedDirectories = []
            return
        }

        // 1. Read global ~/Library/Services/.taichiignore if present
        let globalIgnoreURL = servicesDirURL.appendingPathComponent(".taichiignore")
        var ignoredNames: Set<String> = []
        if let content = try? String(contentsOf: globalIgnoreURL, encoding: .utf8) {
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                    ignoredNames.insert(trimmed)
                }
            }
        }

        var newManaged: [TaiChiServiceItem] = []
        var newUnmanaged: [URL] = []

        for entry in entries {
            let name = entry.lastPathComponent

            // Skip hidden items or directories starting with underscore (e.g. _archived)
            if name.hasPrefix(".") || name.hasPrefix("_") {
                continue
            }

            // Must be a directory
            var entryIsDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &entryIsDir), entryIsDir.boolValue else {
                continue
            }

            // Exclude macOS Automator workflows (.workflow bundles)
            if entry.pathExtension.lowercased() == "workflow" || name.hasSuffix(".workflow") {
                continue
            }

            // Skip if listed in global .taichiignore
            if ignoredNames.contains(name) {
                continue
            }

            // Skip if directory contains a local .taichiignore or .taichi-ignore marker
            let localIgnore1 = entry.appendingPathComponent(".taichiignore")
            let localIgnore2 = entry.appendingPathComponent(".taichi-ignore")
            if FileManager.default.fileExists(atPath: localIgnore1.path) || FileManager.default.fileExists(atPath: localIgnore2.path) {
                continue
            }

            let manifestURL = entry.appendingPathComponent("taichi-service.json")
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                do {
                    let data = try Data(contentsOf: manifestURL)
                    let manifest = try JSONDecoder().decode(TaiChiServiceManifest.self, from: data)

                    // Skip services explicitly disabled in manifest
                    if manifest.disabled == true {
                        continue
                    }

                    // Retain state and process for previously registered services
                    if let existing = managedServices.first(where: { $0.id == manifest.id }) {
                        existing.manifest = manifest
                        existing.dirURL = entry
                        if let customPort = TaiChiSettings.shared.customServicePorts[manifest.id] {
                            existing.assignedPort = customPort
                        } else if existing.assignedPort == 0, let def = manifest.defaultPort {
                            existing.assignedPort = def
                        }
                        newManaged.append(existing)
                    } else {
                        let port = TaiChiSettings.shared.customServicePorts[manifest.id] ?? manifest.defaultPort ?? 0
                        let item = TaiChiServiceItem(manifest: manifest, dirURL: entry, assignedPort: port)
                        newManaged.append(item)
                    }
                } catch {
                    print("⚠️ [SystemServiceManager] Error parsing taichi-service.json in \(entry.path): \(error)")
                    newUnmanaged.append(entry)
                }
            } else {
                newUnmanaged.append(entry)
            }
        }

        self.managedServices = newManaged.sorted {
            $0.manifest.name.localizedCompare($1.manifest.name) == .orderedAscending
        }
        self.unmanagedDirectories = newUnmanaged.sorted {
            $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    // MARK: - Process Lifecycle Management

    /// Starts a managed service process with injected PORT environment variable
    public func startService(serviceId: String) {
        guard let service = managedServices.first(where: { $0.id == serviceId }) else {
            print("⚠️ [SystemServiceManager] Service not found: \(serviceId)")
            return
        }

        if service.state.isRunning || service.state.isStarting {
            print("ℹ️ [SystemServiceManager] Service \(serviceId) is already running or starting")
            return
        }

        service.state = .starting

        // Resolve working directory
        var workDirURL = service.dirURL
        if let customWorkDir = service.manifest.workDir, !customWorkDir.isEmpty {
            if customWorkDir.hasPrefix("/") {
                workDirURL = URL(fileURLWithPath: customWorkDir)
            } else {
                workDirURL = service.dirURL.appendingPathComponent(customWorkDir)
            }
        }

        // Determine port
        let portToUse = service.assignedPort > 0 ? service.assignedPort : (service.manifest.defaultPort ?? 8000)
        service.assignedPort = portToUse

        let process = Process()
        let shellURL = FileManager.default.fileExists(atPath: "/bin/zsh")
            ? URL(fileURLWithPath: "/bin/zsh")
            : URL(fileURLWithPath: "/bin/bash")
        process.executableURL = shellURL
        process.arguments = ["-l", "-c", service.manifest.startCmd]
        process.currentDirectoryURL = workDirURL

        // Inject environment variables
        var env = ProcessInfo.processInfo.environment
        env["PORT"] = "\(portToUse)"
        env["SERVICE_ID"] = service.manifest.id
        env["SERVICE_NAME"] = service.manifest.name
        env["SERVICE_DIR"] = service.dirURL.path
        process.environment = env

        // Setup pipes
        let inPipe = Pipe()
        process.standardInput = inPipe

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = outPipe

        self.serviceLogBuffers[serviceId] = []

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let outputStr = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.appendServiceLog(serviceId: serviceId, text: outputStr)
                }
            }
        }

        process.terminationHandler = { [weak service] proc in
            Task { @MainActor in
                guard let service = service else { return }
                service.pid = nil
                service.process = nil
                if proc.terminationStatus == 0 {
                    service.state = .stopped
                    print("🛑 [SystemServiceManager] Service \(serviceId) stopped normally")
                } else {
                    service.state = .error("Exited with status \(proc.terminationStatus)")
                    print("⚠️ [SystemServiceManager] Service \(serviceId) exited with code \(proc.terminationStatus)")
                }
            }
        }

        do {
            try process.run()
            service.process = process
            service.pid = process.processIdentifier
            service.state = .running
            print("🚀 [SystemServiceManager] Started service '\(service.manifest.name)' [PID \(process.processIdentifier)] on port \(portToUse)")
        } catch {
            service.state = .error("Launch failed: \(error.localizedDescription)")
            print("❌ [SystemServiceManager] Failed to launch service \(serviceId): \(error)")
        }
    }

    /// Stops a managed service gracefully via stop_cmd or SIGTERM
    public func stopService(serviceId: String) {
        guard let service = managedServices.first(where: { $0.id == serviceId }) else { return }

        // Execute custom stopCmd if provided
        if let stopCmd = service.manifest.stopCmd, !stopCmd.isEmpty {
            let stopProc = Process()
            let shellURL = FileManager.default.fileExists(atPath: "/bin/zsh")
                ? URL(fileURLWithPath: "/bin/zsh")
                : URL(fileURLWithPath: "/bin/bash")
            stopProc.executableURL = shellURL
            stopProc.arguments = ["-l", "-c", stopCmd]

            var workDirURL = service.dirURL
            if let customWorkDir = service.manifest.workDir, !customWorkDir.isEmpty {
                workDirURL = customWorkDir.hasPrefix("/")
                    ? URL(fileURLWithPath: customWorkDir)
                    : service.dirURL.appendingPathComponent(customWorkDir)
            }
            stopProc.currentDirectoryURL = workDirURL

            var env = ProcessInfo.processInfo.environment
            env["PORT"] = "\(service.assignedPort)"
            env["SERVICE_ID"] = service.manifest.id
            env["SERVICE_DIR"] = service.dirURL.path
            stopProc.environment = env

            try? stopProc.run()
            stopProc.waitUntilExit()
        }

        // Terminate spawned process
        if let proc = service.process, proc.isRunning {
            proc.terminate()
        } else if let pid = service.pid {
            kill(pid, SIGTERM)
        }

        service.process = nil
        service.pid = nil
        service.state = .stopped
        print("🛑 [SystemServiceManager] Stopped service '\(service.manifest.name)' (\(serviceId))")
    }

    /// Stops all running managed services
    public func stopAllServices() {
        for service in managedServices where service.state.isRunning || service.state.isStarting {
            stopService(serviceId: service.id)
        }
    }

    /// Sets custom port for a service and persists it to settings
    public func setServicePort(serviceId: String, port: Int) {
        if let service = managedServices.first(where: { $0.id == serviceId }) {
            service.assignedPort = port
        }
        TaiChiSettings.shared.customServicePorts[serviceId] = port
    }

    // MARK: - Descartes Hub AI Onboarding

    /// Onboards an unmanaged service directory via Descartes Hub WebSocket integration
    public func onboardService(
        dirURL: URL,
        onThought: @escaping (String) -> Void,
        onLog: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let hubURL = URL(string: TaiChiSettings.shared.descartesHubURL) else {
            completion(.failure(NSError(
                domain: "SystemServiceManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Descartes Hub URL: \(TaiChiSettings.shared.descartesHubURL)"]
            )))
            return
        }

        self.activeOnboardingDir = dirURL
        let client = DescartesHubClient()
        self.descartesClient = client

        client.onboardService(
            serviceDirURL: dirURL,
            hubURL: hubURL,
            llmProfile: "default",
            onThought: onThought,
            onLog: onLog
        ) { [weak self] result in
            Task { @MainActor in
                self?.activeOnboardingDir = nil
                self?.descartesClient = nil
                if case .success = result {
                    self?.scanServices()
                }
                completion(result)
            }
        }
    }

    /// Cancels any active onboarding session
    public func cancelOnboarding() {
        descartesClient?.disconnect()
        descartesClient = nil
        activeOnboardingDir = nil
    }

    // MARK: - Internal Logging

    private func appendServiceLog(serviceId: String, text: String) {
        var logs = serviceLogBuffers[serviceId] ?? []
        let lines = text.components(separatedBy: .newlines)
        for line in lines where !line.isEmpty {
            logs.append(line)
        }
        if logs.count > 500 {
            logs.removeFirst(logs.count - 500)
        }
        serviceLogBuffers[serviceId] = logs
    }

    public func getRecentLogs(serviceId: String) -> [String] {
        return serviceLogBuffers[serviceId] ?? []
    }

    // MARK: - Service Ignore Action

    /// Ignores a service or directory by writing a local .taichiignore marker and rescanning
    public func ignoreService(identifier: String) {
        let rawPath = TaiChiSettings.shared.servicesDirectoryPath
        let servicesPath = (rawPath as NSString).expandingTildeInPath
        let servicesDirURL = URL(fileURLWithPath: servicesPath)

        var targetName = identifier
        var targetURL: URL? = nil

        if let svc = managedServices.first(where: { $0.id == identifier || $0.dirURL.lastPathComponent == identifier }) {
            targetName = svc.manifest.name
            targetURL = svc.dirURL
        } else {
            let candidate = servicesDirURL.appendingPathComponent(identifier)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                targetURL = candidate
            }
        }

        if let target = targetURL {
            let ignoreFile = target.appendingPathComponent(".taichiignore")
            try? "".write(to: ignoreFile, atomically: true, encoding: .utf8)
            print("🚫 [SystemServiceManager] Created .taichiignore in \(target.path)")
            scanServices()
            showNotification(title: "TaiChi 服务已忽略", body: "\(targetName) 已标记忽略，不再出现在启动器中")
        }
    }

    private func showNotification(title: String, body: String) {
        let script = "display notification \"\(body)\" with title \"\(title)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }
}
