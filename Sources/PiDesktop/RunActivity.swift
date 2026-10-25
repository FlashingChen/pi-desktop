import Foundation

/// Keep user-started Pi work responsive even while another window owns focus.
@MainActor
final class RunActivity {
    private var token: NSObjectProtocol?
    var active: Bool { token != nil }
    func update(running: Bool) {
        if running, token == nil {
            token = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Pi Agent 正在运行")
        } else if !running, let current = token {
            ProcessInfo.processInfo.endActivity(current); token = nil
        }
    }
}
