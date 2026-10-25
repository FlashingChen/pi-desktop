import Foundation

@MainActor
final class PiConnection {
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private let writer = DispatchQueue(label: "PiDesktop.stdin")
    private var generation = UUID()
    private(set) var diagnostics = ""
    var onEvent: (([String: Any]) -> Void)?
    var onExit: ((String?) -> Void)?
    var running: Bool { process?.isRunning == true }
    var processIdentifier: Int32? { process?.processIdentifier }

    func start(environment: PiEnvironment, cwd: String, session: String?, continueRecent: Bool, sessionDirectory: String) throws {
        guard process == nil else { throw PiError.message("Pi 进程尚未退出。") }
        let child = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe(), decoder = JSONLDecoder()
        let token = UUID(); generation = token; diagnostics = ""
        child.qualityOfService = .userInitiated
        child.executableURL = URL(fileURLWithPath: environment.executable)
        var args = ["--mode", "rpc"]
        if let session { args += ["--session", session] } else if continueRecent { args += ["--continue"] }
        if !sessionDirectory.isEmpty { args += ["--session-dir", NSString(string: sessionDirectory).expandingTildeInPath] }
        child.arguments = args
        child.environment = environment.variables
        child.currentDirectoryURL = URL(fileURLWithPath: cwd)
        child.standardInput = stdin; child.standardOutput = stdout; child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let records = decoder.append(data)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                for record in records { self.receive(record) }
            }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.diagnostics = String((self.diagnostics + String(decoding: data, as: UTF8.self)).suffix(12000))
            }
        }
        child.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.failPending("Pi CLI 已退出（\(proc.terminationStatus)）。")
                self.onExit?(proc.terminationStatus == 0 ? nil : self.diagnostics)
            }
        }
        do { try child.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        process = child; input = stdin.fileHandleForWriting
    }
    func request(_ type: String, _ fields: [String: Any] = [:], timeout: Double = 30) async throws -> [String: Any] {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            var payload = fields; payload["type"] = type; payload["id"] = id
            do { try send(payload) } catch { pending.removeValue(forKey: id)?.resume(throwing: error); return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.pending.removeValue(forKey: id)?.resume(throwing: PiError.message("Pi 的 \(type) 请求超时。可重连后查看原生会话。"))
            }
        }
    }
    func send(_ payload: [String: Any]) throws {
        guard running, let input else { throw PiError.message("Pi CLI 未连接。") }
        let data = try JSONSerialization.data(withJSONObject: payload) + Data([10])
        writer.async { [weak self] in
            do { try input.write(contentsOf: data) } catch {
                Task { @MainActor [weak self] in self?.failPending("无法向 Pi CLI 写入命令：\(error.localizedDescription)") }
            }
        }
    }
    private func receive(_ record: [String: Any]) {
        if record["type"] as? String == "response", let id = record["id"] as? String, let callback = pending.removeValue(forKey: id) {
            if record["success"] as? Bool == true { callback.resume(returning: record["data"] as? [String: Any] ?? [:]) }
            else { callback.resume(throwing: PiError.message(record["error"] as? String ?? "Pi 命令失败。")) }
        } else { onEvent?(record) }
    }
    private func failPending(_ message: String) {
        let callbacks = pending; pending.removeAll()
        for callback in callbacks.values { callback.resume(throwing: PiError.message(message)) }
    }
    /// Wait for the old writer to close before another interface may own this session.
    func stop() async {
        guard let child = process else { return }
        generation = UUID()
        child.terminationHandler = nil
        let handle = input; input = nil
        writer.async { try? handle?.close() }
        failPending("Pi 连接已关闭。")
        for _ in 0..<100 {
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning { child.terminate() }
        for _ in 0..<30 {
            if !child.isRunning { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        // Do not release ownership until waitpid confirms child exit.
        await Task.detached { child.waitUntilExit() }.value
        (child.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (child.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
    }
}
