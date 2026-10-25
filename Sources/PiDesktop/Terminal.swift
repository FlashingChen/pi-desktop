import AppKit
import SwiftUI
import SwiftTerm

@MainActor
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    private let environment: PiEnvironment
    private let cwd: String
    private let session: String?
    private let sessionDirectory: String
    private var started = false
    @Published var exited = false
    var onExit: (() -> Void)?
    init(environment: PiEnvironment, cwd: String, session: String?, sessionDirectory: String) {
        self.environment = environment; self.cwd = cwd; self.session = session; self.sessionDirectory = sessionDirectory
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 960, height: 650))
        super.init()
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.90, alpha: 1)
        view.processDelegate = self
    }
    func startIfNeeded() {
        guard !started else { return }; started = true
        var args: [String] = []
        if let session { args += ["--session", session] }
        if !sessionDirectory.isEmpty { args += ["--session-dir", NSString(string: sessionDirectory).expandingTildeInPath] }
        view.startProcess(executable: environment.executable, args: args,
                          environment: environment.variables.map { "\($0.key)=\($0.value)" }, currentDirectory: cwd)
        view.window?.makeFirstResponder(view)
        // forkpty failures do not always invoke the process delegate.
        if !view.process.running { exited = true; onExit?() }
    }
    func stop() async {
        onExit = nil
        guard started, view.process.running else { return }
        view.terminate()
        for _ in 0..<50 {
            if !view.process.running { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if view.process.running { Darwin.kill(view.process.shellPid, SIGKILL) }
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in guard let self else { return }; self.exited = true; self.onExit?() }
    }
}
struct PiTerminalView: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> LocalProcessTerminalView { session.view }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        DispatchQueue.main.async { session.startIfNeeded() }
    }
}
