import Foundation

struct Project: Identifiable, Codable, Equatable {
    var path: String
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct PiSession: Identifiable, Equatable {
    var path: String
    var title: String
    var date: Date
    var id: String { path }
}
struct PiModel: Identifiable, Equatable {
    var provider: String
    var modelID: String
    var name: String
    var id: String { provider + "/" + modelID }
    init(_ json: [String: Any]) {
        provider = json["provider"] as? String ?? ""
        modelID = json["id"] as? String ?? ""
        name = json["name"] as? String ?? modelID
    }
}
struct PiCommand: Identifiable {
    var name: String
    var description: String
    var source: String
    var sourcePath = ""
    var package = ""
    var id: String { source + ":" + name }
    var shortName: String { source == "skill" && name.hasPrefix("skill:") ? String(name.dropFirst(6)) : name }
    var sourceLabel: String {
        switch source { case "skill": return "Skill"; case "extension": return "扩展"; case "prompt": return "提示词"; default: return source }
    }
    var origin: String { [package == "auto" ? "" : package, sourcePath].filter { !$0.isEmpty }.joined(separator: "\n") }
    var originLabel: String { !package.isEmpty && package != "auto" ? package.replacingOccurrences(of: "npm:", with: "") : "本机" }
    init(name: String, description: String, source: String, sourcePath: String = "", package: String = "") {
        self.name = name; self.description = description; self.source = source; self.sourcePath = sourcePath; self.package = package
    }
    init?(_ raw: [String: Any]) {
        guard let name = raw["name"] as? String else { return nil }
        let info = raw["sourceInfo"] as? [String: Any] ?? [:]
        self.init(name: name, description: raw["description"] as? String ?? "", source: raw["source"] as? String ?? "", sourcePath: info["path"] as? String ?? "", package: info["source"] as? String ?? "")
    }
}
enum CommandFilter: String, CaseIterable {
    case all = "全部", skill = "Skills", extensions = "扩展", prompt = "提示词"
    func includes(_ command: PiCommand) -> Bool {
        switch self { case .all: return true; case .skill: return command.source == "skill"; case .extensions: return command.source == "extension"; case .prompt: return command.source == "prompt" }
    }
}
/// Normalize and order the real catalogue once; keystrokes only scan this index.
struct CommandSearchIndex {
    private struct Entry {
        let command: PiCommand
        let name: String
        let fullName: String
        let description: String
    }
    private let entries: [Entry]
    init(_ commands: [PiCommand]) {
        entries = commands.sorted {
            if $0.source != $1.source { return $0.source == "skill" || ($1.source != "skill" && $0.source < $1.source) }
            return $0.shortName.localizedStandardCompare($1.shortName) == .orderedAscending
        }.map { Entry(command: $0, name: $0.shortName.lowercased(), fullName: $0.name.lowercased(), description: $0.description.lowercased()) }
    }
    func matches(query: String, filter: CommandFilter = .all) -> [PiCommand] {
        var query = query.lowercased()
        if query.hasPrefix("/") { query.removeFirst() }
        let skillsOnly = query.hasPrefix("skill:")
        if skillsOnly { query = String(query.dropFirst(6)) }
        var ranked = [[PiCommand]](repeating: [], count: 4)
        for entry in entries {
            let command = entry.command
            guard filter.includes(command), !skillsOnly || command.source == "skill" else { continue }
            let rank: Int
            if query.isEmpty || entry.name == query { rank = 0 }
            else if entry.name.hasPrefix(query) { rank = 1 }
            else if entry.name.contains(query) || entry.fullName.contains(query) { rank = 2 }
            else if entry.description.contains(query) { rank = 3 }
            else { continue }
            ranked[rank].append(command)
        }
        return ranked.flatMap { $0 }
    }
}
enum CommandSearch {
    static func matches(_ commands: [PiCommand], query: String, filter: CommandFilter = .all) -> [PiCommand] {
        CommandSearchIndex(commands).matches(query: query, filter: filter)
    }
}
struct DisplayMessage: Identifiable {
    var id: String
    var raw: [String: Any]
    var role: String { raw["role"] as? String ?? "custom" }
    var blocks: [[String: Any]] {
        if let text = raw["content"] as? String { return [["type": "text", "text": text]] }
        return raw["content"] as? [[String: Any]] ?? []
    }
    var text: String { blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
    static func from(_ raw: [String: Any], index: Int) -> DisplayMessage {
        let stamp = raw["timestamp"].map { String(describing: $0) } ?? String(index)
        return DisplayMessage(id: "\(index)-\(stamp)", raw: raw)
    }
}
struct ImageAttachment: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
    let mime: String
    var wire: [String: Any] { ["type": "image", "data": data.base64EncodedString(), "mimeType": mime] }
}
struct ExtensionDialog: Identifiable {
    let id: String
    let method: String
    let title: String
    let message: String
    let options: [String]
    let placeholder: String
    let prefill: String
}

enum PiError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

/// Strict LF framing; UTF-8 and U+2028/U+2029 are preserved even across pipe chunks.
final class JSONLDecoder: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    func append(_ data: Data) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        // Search each incoming byte once. Rescanning the accumulated, multi-MB
        // response on every pipe read makes history loading quadratic.
        var records: [[String: Any]] = []
        var start = data.startIndex
        while let end = data[start...].firstIndex(of: 10) {
            buffer.append(contentsOf: data[start..<end])
            if let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any] {
                records.append(object)
            }
            buffer.removeAll(keepingCapacity: true)
            start = data.index(after: end)
        }
        buffer.append(contentsOf: data[start...])
        return records
    }
}

struct PiEnvironment {
    let executable: String
    let variables: [String: String]
    @MainActor private static var cache: [String: PiEnvironment] = [:]
    @MainActor static func invalidate(override: String) { cache.removeValue(forKey: override) }
    @MainActor static func resolve(override: String = "") async throws -> PiEnvironment {
        if let cached = cache[override] { return cached }
        let resolved: PiEnvironment = try await Task.detached {
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", "/usr/bin/env -0"]
            process.standardOutput = output
            process.standardError = errors
            // Drain stderr so shell startup cannot fill the pipe. Never log the environment.
            errors.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit(); timeout.cancel()
            errors.fileHandleForReading.readabilityHandler = nil
            var env = ProcessInfo.processInfo.environment
            for entry in data.split(separator: 0) {
                guard let text = String(data: entry, encoding: .utf8), let equal = text.firstIndex(of: "=") else { continue }
                let key = String(text[..<equal])
                if !key.contains("\n") { env[key] = String(text[text.index(after: equal)...]) }
            }
            let fm = FileManager.default
            let paths = (env["PATH"] ?? "").split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path]
            env["PATH"] = paths.joined(separator: ":")
            let expanded = NSString(string: override).expandingTildeInPath
            let candidate = override.isEmpty ? paths.map { $0 + "/pi" }.first { fm.isExecutableFile(atPath: $0) } : expanded
            guard let pi = candidate, fm.isExecutableFile(atPath: pi) else {
                throw PiError.message("未找到 Pi CLI。请先安装原版 Pi，或在设置中指定 pi 可执行文件。")
            }
            env["TERM"] = "xterm-256color"
            env["COLORTERM"] = "truecolor"
            let resolved = PiEnvironment(executable: pi, variables: env)
            return resolved
        }.value
        cache[override] = resolved
        return resolved
    }
}

struct SkillInvocation {
    let name:String
    let request:String
    let content:String
    static func parse(_ text:String)->SkillInvocation? {
        let text=text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard text.hasPrefix("<skill "),let start=text.range(of:"name=\""),let end=text[start.upperBound...].firstIndex(of:"\""),let close=text.range(of:"</skill>") else { return nil }
        return .init(name:String(text[start.upperBound..<end]),request:text[close.upperBound...].trimmingCharacters(in:.whitespacesAndNewlines),content:String(text[..<close.upperBound]))
    }
}

enum SessionTitle {
    static func fromPrompt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<skill "), let marker = trimmed.range(of: "name=\""),
              let end = trimmed[marker.upperBound...].firstIndex(of: "\"") else { return trimmed }
        let skill = String(trimmed[marker.upperBound..<end])
        guard let close = trimmed.range(of: "</skill>") else { return "/skill:" + skill }
        let request = trimmed[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return request.isEmpty ? "/skill:" + skill : request
    }
}

/// Only reads native Pi files to build sidebar metadata. Pi alone writes session history.
enum SessionIndex {
    static func directories(project: String, environment: [String: String], override: String) -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agentDir = environment["PI_CODING_AGENT_DIR"] ?? home + "/.pi/agent"
        let settingsPaths = [agentDir + "/settings.json", project + "/.pi/settings.json"]
        var configured: String?
        for path in settingsPaths {
            if let data = FileManager.default.contents(atPath: path),
               let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = settings["sessionDir"] as? String { configured = value }
        }
        if let fromEnvironment = environment["PI_CODING_AGENT_SESSION_DIR"] { configured = fromEnvironment }
        // Explicit app setting is forwarded verbatim as Pi's --session-dir.
        if !override.isEmpty { configured = override }
        if let configured {
            let expanded = NSString(string: configured).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : URL(fileURLWithPath: project).appendingPathComponent(expanded)
            return [url.standardizedFileURL]
        }
        let safe = "--" + project.dropFirst().replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "--"
        return [URL(fileURLWithPath: NSString(string: agentDir).expandingTildeInPath).appendingPathComponent("sessions").appendingPathComponent(safe)]
    }
    static func list(project: String, environment: [String: String], override: String) -> [PiSession] {
        let fm = FileManager.default
        var result: [PiSession] = []
        for directory in directories(project: project, environment: environment, override: override) {
            let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                let lines = data.split(separator: 10)
                guard let first = lines.first,
                      let header = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
                      header["type"] as? String == "session",
                      let cwd = header["cwd"] as? String,
                      URL(fileURLWithPath: cwd).standardizedFileURL.path == URL(fileURLWithPath: project).standardizedFileURL.path else { continue }
                var name: String?, firstMessage: String?
                for line in lines.dropFirst() {
                    guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                    if entry["type"] as? String == "session_info" { name = entry["name"] as? String }
                    if firstMessage == nil, let message = entry["message"] as? [String: Any], message["role"] as? String == "user" {
                        firstMessage = DisplayMessage.from(message, index: 0).text
                    }
                }
                let title = [name, firstMessage.map(SessionTitle.fromPrompt)].compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "未命名会话"
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                result.append(PiSession(path: file.path, title: String(title.prefix(100)), date: date))
            }
        }
        return result.sorted { $0.date > $1.date }
    }
}

/// Names from Pi 1.4's own built-in slash-command metadata; implementations stay in Pi.
/// Unknown slash-prefixed text (including absolute paths) must pass through untouched.
enum PiInteractiveCommands {
    static let names: Set<String> = [
        "/settings", "/model", "/tree", "/thinking", "/scoped-models", "/export", "/import",
        "/share", "/bug", "/copy", "/name", "/session", "/changelog", "/hotkeys", "/fork",
        "/clone", "/trust", "/login", "/logout", "/new", "/compact", "/resume", "/reload", "/quit"
    ]
}
