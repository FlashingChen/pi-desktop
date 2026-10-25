import XCTest
import AppKit
import SwiftUI
@testable import PiDesktop

@MainActor
final class StartupBenchTests: XCTestCase {
    func testOptInRealProjectStartup() async throws {
        guard ProcessInfo.processInfo.environment["PI_STARTUP_BENCH"] == "1" else { throw XCTSkip("Opt-in, reads local native sessions without provider calls") }
        let root = FileManager.default.currentDirectoryPath
        let model = AppModel()
        let folder = Project(path: root)
        model.projects = [folder]
        let host = NSHostingView(rootView: RootView().environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:1280,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = host
        host.frame = NSRect(x:0,y:0,width:1280,height:800)
        let start = Date()
        await model.selectProject(folder)
        let sync = Date().timeIntervalSince(start)
        host.layoutSubtreeIfNeeded(); host.display()
        let layout = Date().timeIntervalSince(start)
        print("STARTUP_BENCH sync_ms=\(Int(sync*1000)) layout_ms=\(Int(layout*1000)) messages=\(model.messages.count)")
        if let value = ProcessInfo.processInfo.environment["PI_STARTUP_MAX_MS"], let ceiling = Double(value) {
            XCTAssertLessThan(layout * 1000, ceiling, "Native startup exceeded its measured regression ceiling")
        }
        await model.shutdown()
        window.contentView = nil
    }
}
