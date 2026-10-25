import SwiftUI
import AppKit

@main
struct PiDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @AppStorage("appearance") private var appearance = "dark"
    private var colorScheme: ColorScheme? {
        appearance == "dark" ? .dark : appearance == "light" ? .light : nil
    }
    var body: some Scene {
        Window("Pi Desktop", id: "main") {
            RootView().environmentObject(model).preferredColorScheme(colorScheme)
                .onAppear { delegate.model = model; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
                .onOpenURL { model.openURL($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新会话") { Task { await model.newSession() } }.keyboardShortcut("n").disabled(!model.canSwitch || !model.connected)
                Button("打开项目…") { model.openProject() }.keyboardShortcut("o").disabled(!model.canSwitch)
                Button("打开原生会话…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "jsonl")!]
                    if panel.runModal() == .OK, let url = panel.url { model.openURL(url) }
                }.disabled(!model.canSwitch)
            }
            CommandGroup(replacing: .appSettings) { Button("设置…") { model.showSettings = true }.keyboardShortcut(",") }
            CommandMenu("会话") {
                Button("搜索会话") { NotificationCenter.default.post(name: .piSearch, object: nil) }.keyboardShortcut("k")
                Button("Pi 命令…") { model.showCommands = true }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!model.connected)
                Button("在应用内运行 Pi CLI") { Task { await model.openTerminal() } }.keyboardShortcut("t", modifiers: [.command, .shift]).disabled(!model.canSwitch || model.project == nil)
                Button("中止当前运行") { Task { await model.abort() } }.keyboardShortcut(".").disabled(!model.busy)
            }
        }
    }
}
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        Task { await model?.shutdown(); NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for file in filenames { model?.openURL(URL(fileURLWithPath: file)) }
    }
}
