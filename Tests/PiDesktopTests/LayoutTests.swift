import XCTest
import AppKit
import SwiftUI
@testable import PiDesktop

/// Render the real native view hierarchy off screen at two supported window sizes.
/// Fixtures remain in memory and never create native Pi session files or provider requests.
@MainActor
final class LayoutTests: XCTestCase {
    func testNativeConversationFitsSupportedWindowSizes() async throws {
        let model = AppModel()
        let folder = Project(path: "/tmp/pi-desktop-layout-fixture")
        model.projects = [folder]; model.project = folder; model.connected = true
        model.sessionPath = "/tmp/pi-desktop-layout-fixture/session.jsonl"
        model.sessionName = "原生界面检查"
        model.sessions = [folder.id: [.init(path: model.sessionPath!, title: model.sessionName, date: Date())]]
        model.messages = [
            .from(["role":"user", "content":"请查看这个项目。"],index:0),
            .from(["role":"assistant", "model":"UI fixture", "content":[["type":"text","text":"我先查看主要入口文件。"],["type":"toolCall","name":"read","id":"fixture-tool","arguments":["path":"Package.swift"]]]],index:1),
            .from(["role":"toolResult","toolName":"read","toolCallId":"fixture-tool","content":[["type":"text","text":"// swift-tools-version: 5.10"]]],index:2),
            .from(["role":"assistant", "model":"UI fixture", "content":[["type":"text","text":"这是一个 SwiftUI + AppKit 项目。\n\n```swift\nlet interface = RootView()\n```\n\nPi 负责原生会话和 Agent 运行。\n\n| 步骤 | 状态 | 耗时 |\n|---|---|---|\n| read | ✅ 完成 | 0.2s |\n| bash | ✅ 完成 | 4.8s |\n\n表格后面的段落，**加粗**与 `代码` 应该继续生效。"]]],index:3)
        ]
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/test-artifacts")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name,scheme) in [("native-fixture-wide",ColorScheme.light),("native-fixture-dark",ColorScheme.dark)] {
            let size = NSSize(width:1280,height:800)
            let host = NSHostingView(rootView: RootView().environmentObject(model).environment(\.colorScheme, scheme))
            let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
            window.contentView = host
            host.frame = NSRect(origin:.zero,size:size)
            host.layoutSubtreeIfNeeded()
            // Allow SwiftUI's deferred native layout to settle without showing a window.
            try await Task.sleep(nanoseconds:300_000_000)
            host.layoutSubtreeIfNeeded(); host.display()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { return XCTFail("No native render") }
            host.cacheDisplay(in:host.bounds,to:bitmap)
            guard let png=bitmap.representation(using:.png,properties:[:]) else { return XCTFail("No PNG") }
            try png.write(to:out.appendingPathComponent(name+".png"))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertEqual(host.bounds.width,size.width,accuracy:1)
            window.contentView = nil
        }
        await model.shutdown()
    }
    func testSlashPaletteAtSupportedSizes() async throws {
        let model = AppModel()
        let folder = Project(path: "/tmp/pi-desktop-slash-fixture")
        model.project = folder; model.projects = [folder]; model.connected = true
        model.draft = "/"
        model.commands = (0..<16).map { PiCommand(name: $0 == 0 ? "code-review" : "command-\($0)", description: "检查代码改动与实现细节，描述较长时保持在单行内", source: "extension") }
        let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/test-artifacts")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func findInput(_ view: NSView) -> InputTextView? {
            if let input = view as? InputTextView { return input }
            return view.subviews.compactMap(findInput).first
        }
        for (name, size, dark, welcome) in [
            ("native-slash-light-wide", NSSize(width:1280,height:800), false, false),
            ("native-slash-dark-compact", NSSize(width:820,height:640), true, false),
            ("native-slash-welcome-compact", NSSize(width:820,height:640), false, true)
        ] {
            model.messages = welcome ? [] : [
                .from(["role":"user", "content":"检查启动流程和斜杠命令菜单。"],index:0),
                .from(["role":"assistant", "content":[["type":"text","text":"这是合成的原生布局测试。命令菜单应完整显示在输入框上方。"]]],index:1)
            ]
            let host = NSHostingView(rootView: RootView().environmentObject(model).environment(\.colorScheme,dark ? .dark : .light))
            let window = NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
            window.appearance = NSAppearance(named:dark ? .darkAqua : .aqua)
            window.contentView = host; host.frame = NSRect(origin:.zero,size:size)
            host.layoutSubtreeIfNeeded()
            let input = try XCTUnwrap(findInput(host))
            XCTAssertTrue(window.makeFirstResponder(input))
            try await Task.sleep(nanoseconds:200_000_000)
            host.layoutSubtreeIfNeeded(); host.display()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
            host.cacheDisplay(in:host.bounds,to:bitmap)
            let png = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
            try png.write(to:out.appendingPathComponent(name+".png"))
            window.contentView = nil
        }
        await model.shutdown()
    }

}
