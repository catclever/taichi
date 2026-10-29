import Foundation
import SwiftUI

private final class WebSocketDelegateForwarder: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (@Sendable () -> Void)?
    var onClose: (@Sendable (URLSessionWebSocketTask.CloseCode, String?) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonStr = reason.flatMap { String(data: $0, encoding: .utf8) }
        onClose?(closeCode, reasonStr)
    }
}

/// WebSocket Client for connecting to Descartes Hub (`descartes-hub`)
/// Declares local tools (`list_dir`, `read_file`, `write_file`, `save_manifest`),
/// executes them when requested by Hub, returns `tool_result`, and streams thoughts/logs.
@MainActor
public class DescartesHubClient: ObservableObject {
    @Published public var isConnected: Bool = false
    @Published public var lastThought: String = ""
    @Published public var lastLog: String = ""

    private var session: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var delegateForwarder: WebSocketDelegateForwarder?
    private var hasCompleted: Bool = false
    private var currentDirURL: URL?

    private var onThoughtHandler: ((String) -> Void)?
    private var onLogHandler: ((String) -> Void)?
    private var completionHandler: ((Result<String, Error>) -> Void)?

    public init() {}

    /// Onboard a system service directory via Descartes Hub WebSocket protocol
    public func onboardService(
        serviceDirURL: URL,
        hubURL: URL,
        llmProfile: String = "default",
        onThought: @escaping (String) -> Void,
        onLog: @escaping (String) -> Void,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        disconnect()

        self.hasCompleted = false
        self.currentDirURL = serviceDirURL
        self.onThoughtHandler = onThought
        self.onLogHandler = onLog
        self.completionHandler = completion

        log("[Descartes] Connecting to Descartes Hub at \(hubURL.absoluteString)...")

        let config = URLSessionConfiguration.default
        let forwarder = WebSocketDelegateForwarder()
        forwarder.onOpen = { [weak self] in
            Task { @MainActor in
                self?.isConnected = true
                self?.log("[Descartes] WebSocket connected to Hub")
            }
        }
        forwarder.onClose = { [weak self] closeCode, reasonStr in
            Task { @MainActor in
                self?.isConnected = false
                self?.log("[Descartes] WebSocket closed (code: \(closeCode.rawValue), reason: \(reasonStr ?? "none"))")
            }
        }
        self.delegateForwarder = forwarder

        let urlSession = URLSession(configuration: config, delegate: forwarder, delegateQueue: nil)
        self.session = urlSession

        let task = urlSession.webSocketTask(with: hubURL)
        self.webSocketTask = task
        task.resume()

        self.isConnected = true

        // Send 'init' payload declaring service directory and available tools
        sendInitPayload(serviceDirURL: serviceDirURL, llmProfile: llmProfile)

        // Begin listening for messages
        receiveNextMessage()
    }

    /// Disconnect WebSocket connection and cancel session
    public func disconnect() {
        isConnected = false
        if let task = webSocketTask {
            task.cancel(with: .normalClosure, reason: nil)
            webSocketTask = nil
        }
        if let session = session {
            session.invalidateAndCancel()
            self.session = nil
        }
        delegateForwarder = nil
    }

    // MARK: - Protocol Message Sending

    private func sendInitPayload(serviceDirURL: URL, llmProfile: String) {
        let tools: [[String: Any]] = [
            [
                "name": "list_dir",
                "description": "Lists non-hidden files in the service directory or subpath. Automatically filters out .venv, .git, __pycache__, node_modules.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "subpath": [
                            "type": "string",
                            "description": "Relative subdirectory path inside service folder (default is root)"
                        ]
                    ]
                ]
            ],
            [
                "name": "read_file",
                "description": "Safely reads UTF-8 text file content relative to the service directory.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Relative path of the target file"
                        ]
                    ],
                    "required": ["path"]
                ]
            ],
            [
                "name": "write_file",
                "description": "Writes text content to a file relative to the service directory. Automatically creates a .bak backup file if the original exists and no backup has been made yet.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Relative path of the file to write"
                        ],
                        "content": [
                            "type": "string",
                            "description": "Text content to write into the file"
                        ]
                    ],
                    "required": ["path", "content"]
                ]
            ],
            [
                "name": "save_manifest",
                "description": "Saves the declarative taichi-service.json manifest in the service root directory.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "manifest": [
                            "type": "object",
                            "description": "JSON object conforming to TaiChiServiceManifest"
                        ]
                    ],
                    "required": ["manifest"]
                ]
            ]
        ]

        let serviceName = serviceDirURL.lastPathComponent
        let safeId = serviceName.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        let prompt = """
        Your goal is to inspect the service directory '\(serviceDirURL.path)' (service: '\(serviceName)') and generate 'taichi-service.json'.

        Mandatory Step-by-Step Procedure:
        Step 1: Use 'list_dir' to see the files.
        Step 2: Use 'read_file' on entrypoints or configuration files (such as main.py, config.json, etc.).
        Step 3: Call 'save_manifest' to write the 'taichi-service.json' file:
          {
            "id": "\(safeId)",
            "name": "\(serviceName)",
            "description": "Short description of what the service does",
            "category": "web",
            "start_cmd": "python3 main.py",
            "default_port": 8000,
            "has_web_ui": true,
            "web_path": "/"
          }
        Step 4: Only AFTER calling 'save_manifest', call 'send_message' with key: "result" and value: "Onboarding completed successfully".

        CRITICAL: You MUST call 'save_manifest' to save the manifest before exiting via 'send_message'.
        """

        let systemPrompt = """
        You are Descartes AI Service Architect for TaiChi Launcher.
        Your job is to inspect unmanaged local services in ~/Library/Services/ and write a standardized declarative 'taichi-service.json' manifest using the 'save_manifest' tool.
        Always inspect files before saving the manifest.
        You MUST invoke 'save_manifest' before calling 'send_message'.
        """

        let initPayload: [String: Any] = [
            "type": "init",
            "action": "init",
            "task_name": "onboard_\(serviceName)",
            "prompt": prompt,
            "system_prompt": systemPrompt,
            "service_dir": serviceDirURL.path,
            "service_name": serviceName,
            "llm_profile": llmProfile,
            "tools": tools
        ]

        sendJson(initPayload)
        log("[Descartes] Sent init handshake declaring 4 local tools (list_dir, read_file, write_file, save_manifest)")
    }

    private func sendToolResult(callId: String, status: String, output: String) {
        let payload: [String: Any] = [
            "type": "tool_result",
            "call_id": callId,
            "status": status,
            "output": output
        ]
        sendJson(payload)
        log("[Descartes] Sent tool_result [\(callId)]: \(status)")
    }

    private func sendJson(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            log("[Descartes] Error: Failed to serialize JSON message")
            return
        }

        log("[Descartes -> Hub] \(str)")
        webSocketTask?.send(.string(str)) { [weak self] error in
            if let error = error {
                Task { @MainActor in
                    self?.log("[Descartes] Send error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Message Loop

    private func receiveNextMessage() {
        guard let task = webSocketTask, !hasCompleted else { return }

        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self, !self.hasCompleted else { return }

                switch result {
                case .failure(let error):
                    self.finishWithError(error)

                case .success(let message):
                    self.handleIncomingMessage(message)
                    self.receiveNextMessage()
                }
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) {
        let rawData: Data?
        switch message {
        case .string(let text):
            log("[Hub -> Descartes] \(text)")
            rawData = text.data(using: .utf8)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                log("[Hub -> Descartes] \(text)")
            }
            rawData = data
        @unknown default:
            rawData = nil
        }

        guard let data = rawData,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        let type = (json["type"] as? String) ?? (json["action"] as? String) ?? (json["event"] as? String) ?? ""

        switch type {
        case "stream_event":
            handleStreamEvent(json)

        case "execute_tool":
            handleExecuteTool(json)

        case "finished", "finish", "done", "completed":
            let summary = (json["result"] as? String)
                ?? (json["summary"] as? String)
                ?? (json["message"] as? String)
                ?? "Service onboarding completed successfully."
            finishWithSuccess(summary)

        case "error":
            let errMsg = (json["error"] as? String)
                ?? (json["message"] as? String)
                ?? "Unknown Descartes Hub error"
            finishWithError(NSError(domain: "DescartesHub", code: -1, userInfo: [NSLocalizedDescriptionKey: errMsg]))

        default:
            // Check for inline stream events or thoughts
            if let thought = json["thought"] as? String, !thought.isEmpty {
                recordThought(thought)
            } else if let logMsg = json["log"] as? String ?? json["message"] as? String {
                log("[Descartes] \(logMsg)")
            }
        }
    }

    // MARK: - Stream Event Handling

    private func handleStreamEvent(_ json: [String: Any]) {
        let event = json["event"] as? String

        // Parse streaming thoughts
        var thoughtText: String? = json["thought"] as? String
        if thoughtText == nil, event == "thought" {
            thoughtText = json["data"] as? String
        }
        if thoughtText == nil, let dataDict = json["data"] as? [String: Any] {
            thoughtText = dataDict["thought"] as? String ?? dataDict["content"] as? String
        }
        if thoughtText == nil, let payloadDict = json["payload"] as? [String: Any] {
            thoughtText = payloadDict["thought"] as? String ?? payloadDict["content"] as? String
        }
        if thoughtText == nil, let deltaDict = json["delta"] as? [String: Any] {
            thoughtText = deltaDict["thought"] as? String ?? deltaDict["content"] as? String
        }

        if let thought = thoughtText, !thought.isEmpty {
            recordThought(thought)
        }

        // Parse tool call starts or ends
        if event == "tool_call_start" {
            let dataDict = json["data"] as? [String: Any]
            let toolName = (json["tool"] as? String)
                ?? (dataDict?["tool"] as? String)
                ?? (json["name"] as? String)
                ?? ""
            log("[Descartes AI] ⚙️ Executing tool: \(toolName)")
        } else if event == "tool_call_end" {
            let dataDict = json["data"] as? [String: Any]
            let toolName = (json["tool"] as? String)
                ?? (dataDict?["tool"] as? String)
                ?? ""
            log("[Descartes AI] 🏁 Finished tool: \(toolName)")
        } else if let content = json["content"] as? String, thoughtText == nil {
            log("[Descartes] \(content)")
        } else if let message = json["message"] as? String {
            log("[Descartes] \(message)")
        }
    }

    // MARK: - Tool Execution

    private func handleExecuteTool(_ json: [String: Any]) {
        let callId = (json["call_id"] as? String)
            ?? (json["id"] as? String)
            ?? (json["tool_call_id"] as? String)
            ?? UUID().uuidString
        let toolName = (json["tool"] as? String)
            ?? (json["name"] as? String)
            ?? (json["tool_name"] as? String)
            ?? ""

        var args: [String: Any] = [:]
        if let dictArgs = (json["args"] as? [String: Any]) ?? (json["arguments"] as? [String: Any]) {
            args = dictArgs
        } else if let strArgs = json["arguments"] as? String,
                  let data = strArgs.data(using: .utf8),
                  let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            args = parsed
        }

        guard let serviceDir = currentDirURL else {
            sendToolResult(callId: callId, status: "error", output: "Service directory URL not set")
            return
        }

        log("[Descartes] Hub requested tool '\(toolName)' with call_id: \(callId)")

        let (status, output) = runLocalTool(name: toolName, args: args, serviceDir: serviceDir)
        sendToolResult(callId: callId, status: status, output: output)
    }

    private func runLocalTool(name: String, args: [String: Any], serviceDir: URL) -> (status: String, output: String) {
        switch name {
        case "list_dir":
            return executeListDir(args: args, serviceDir: serviceDir)
        case "read_file":
            return executeReadFile(args: args, serviceDir: serviceDir)
        case "write_file":
            return executeWriteFile(args: args, serviceDir: serviceDir)
        case "save_manifest":
            return executeSaveManifest(args: args, serviceDir: serviceDir)
        default:
            return ("error", "Unsupported tool: \(name)")
        }
    }

    // MARK: - Local Tool Implementations

    private func executeListDir(args: [String: Any], serviceDir: URL) -> (status: String, output: String) {
        let subpath = (args["subpath"] as? String) ?? (args["path"] as? String) ?? ""
        let targetURL = subpath.isEmpty ? serviceDir : serviceDir.appendingPathComponent(subpath).standardizedFileURL

        // Security check: ensure targetURL is within serviceDir
        let canonicalServiceDir = serviceDir.resolvingSymlinksInPath().standardized.path
        let canonicalTarget = targetURL.resolvingSymlinksInPath().standardized.path
        guard canonicalTarget == canonicalServiceDir || canonicalTarget.hasPrefix(canonicalServiceDir + "/") else {
            return ("error", "Access denied: target path escapes service directory (\(subpath))")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalTarget, isDirectory: &isDir), isDir.boolValue else {
            return ("error", "Directory not found: \(subpath)")
        }

        do {
            let items = try FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                options: []
            )

            let ignoreSet: Set<String> = [".venv", "venv", ".git", "__pycache__", "node_modules", ".DS_Store", "DerivedData"]
            var results: [String] = []

            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = item.lastPathComponent
                if name == ".venv" || name == "venv" {
                    results.append("[ENV]  \(name)/ (Python virtual environment exists - prefer \(name)/bin/python)")
                    continue
                }
                if name.hasPrefix(".") && !ignoreSet.contains(name) {
                    continue // filter hidden files
                }
                if ignoreSet.contains(name) {
                    continue // filter vendor / environment directories
                }

                let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let size = (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

                let relPath = item.path.replacingOccurrences(of: canonicalServiceDir + "/", with: "")
                if isDirectory {
                    results.append("[DIR]  \(relPath)/")
                } else {
                    results.append("[FILE] \(relPath) (\(size) bytes)")
                }
            }

            let output = results.isEmpty ? "(Directory is empty)" : results.joined(separator: "\n")
            return ("ok", output)
        } catch {
            return ("error", "Failed to list directory: \(error.localizedDescription)")
        }
    }

    private func executeReadFile(args: [String: Any], serviceDir: URL) -> (status: String, output: String) {
        guard let relPath = args["path"] as? String, !relPath.isEmpty else {
            return ("error", "Missing required argument 'path'")
        }

        let targetURL = serviceDir.appendingPathComponent(relPath).standardizedFileURL

        // Security check
        let canonicalServiceDir = serviceDir.resolvingSymlinksInPath().standardized.path
        let canonicalTarget = targetURL.resolvingSymlinksInPath().standardized.path
        guard canonicalTarget == canonicalServiceDir || canonicalTarget.hasPrefix(canonicalServiceDir + "/") else {
            return ("error", "Access denied: target path escapes service directory (\(relPath))")
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalTarget, isDirectory: &isDir), !isDir.boolValue else {
            return ("error", "File not found or is a directory: \(relPath)")
        }

        do {
            let data = try Data(contentsOf: targetURL)
            // Guard against massive files (> 2 MB)
            if data.count > 2 * 1024 * 1024 {
                return ("error", "File too large to read safely (\(data.count) bytes)")
            }
            guard let content = String(data: data, encoding: .utf8) else {
                return ("error", "File is binary or not valid UTF-8 text")
            }
            return ("ok", content)
        } catch {
            return ("error", "Failed to read file: \(error.localizedDescription)")
        }
    }

    private func executeWriteFile(args: [String: Any], serviceDir: URL) -> (status: String, output: String) {
        guard let relPath = args["path"] as? String, !relPath.isEmpty else {
            return ("error", "Missing required argument 'path'")
        }
        let content = (args["content"] as? String) ?? ""

        let targetURL = serviceDir.appendingPathComponent(relPath).standardizedFileURL

        // Security check
        let canonicalServiceDir = serviceDir.resolvingSymlinksInPath().standardized.path
        let canonicalTarget = targetURL.resolvingSymlinksInPath().standardized.path
        guard canonicalTarget == canonicalServiceDir || canonicalTarget.hasPrefix(canonicalServiceDir + "/") else {
            return ("error", "Access denied: target path escapes service directory (\(relPath))")
        }

        do {
            let parentDir = targetURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Backup logic: creates .bak file if original exists and backup doesn't
            var backupNote = ""
            let backupURL = URL(fileURLWithPath: targetURL.path + ".bak")
            if FileManager.default.fileExists(atPath: targetURL.path) && !FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.copyItem(at: targetURL, to: backupURL)
                backupNote = " (created backup \(backupURL.lastPathComponent))"
            }

            try content.write(to: targetURL, atomically: true, encoding: .utf8)
            return ("ok", "File written successfully: \(relPath)\(backupNote)")
        } catch {
            return ("error", "Failed to write file: \(error.localizedDescription)")
        }
    }

    private func executeSaveManifest(args: [String: Any], serviceDir: URL) -> (status: String, output: String) {
        let manifestObj = args["manifest"] ?? args
        let manifestURL = serviceDir.appendingPathComponent("taichi-service.json")

        do {
            let jsonData: Data
            if let dict = manifestObj as? [String: Any] {
                jsonData = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
            } else if let str = manifestObj as? String, let data = str.data(using: .utf8) {
                if let jsonObj = try? JSONSerialization.jsonObject(with: data) {
                    jsonData = try JSONSerialization.data(withJSONObject: jsonObj, options: [.prettyPrinted, .sortedKeys])
                } else {
                    jsonData = data
                }
            } else {
                return ("error", "Invalid manifest parameter format")
            }

            // Validate against TaiChiServiceManifest
            let decoded = try JSONDecoder().decode(TaiChiServiceManifest.self, from: jsonData)

            try jsonData.write(to: manifestURL, options: .atomic)
            log("[Descartes] Successfully saved taichi-service.json manifest for '\(decoded.name)' (id: \(decoded.id))")
            return ("ok", "Saved taichi-service.json successfully for '\(decoded.name)'. Please call 'send_message' to finish onboarding.")
        } catch {
            return ("error", "Failed to validate or save taichi-service.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Lifecycle & Completions

    private func recordThought(_ thought: String) {
        lastThought = thought
        onThoughtHandler?(thought)
    }

    private func log(_ message: String) {
        lastLog = message
        onLogHandler?(message)

        let logLine = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        let logURL = URL(fileURLWithPath: "/tmp/taichi_descartes_onboard.log")
        if let data = logLine.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    private func finishWithSuccess(_ result: String) {
        guard !hasCompleted else { return }
        hasCompleted = true
        log("[Descartes] Finished successfully: \(result)")
        completionHandler?(.success(result))
        cleanup()
    }

    private func finishWithError(_ error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        log("[Descartes] Terminated with error: \(error.localizedDescription)")
        completionHandler?(.failure(error))
        cleanup()
    }

    private func cleanup() {
        disconnect()
        currentDirURL = nil
        onThoughtHandler = nil
        onLogHandler = nil
        completionHandler = nil
    }
}
