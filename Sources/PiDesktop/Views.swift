import SwiftUI
import AppKit

/// Direction C: graphite reading canvas, cool neutral chrome and one blue-gray accent.
enum Theme {
    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255)/255, green: Double((hex >> 8) & 255)/255, blue: Double(hex & 255)/255, alpha: 1)
        })
    }
    static let canvas = adaptive(0xfcfcfc, 0x23272d)
    static let sidebar = adaptive(0xf0f2f4, 0x20242a)
    static let surface = adaptive(0xffffff, 0x2b3037)
    static let text = adaptive(0x242628, 0xe5e9ed)
    static let secondary = adaptive(0x60666b, 0xa4adb7)
    static let bubble = adaptive(0xeff1f2, 0x30363e)
    static let code = adaptive(0xf3f4f5, 0x292f37)
    static let line = adaptive(0xe3e5e7, 0x3a424b)
    static let hover = adaptive(0xeceef0, 0x303740)
    static let controlHover = adaptive(0xe4e8ec, 0x363e47)
    static let controlPressed = adaptive(0xd6dde4, 0x424d59)
    static let selection = adaptive(0xdce5ec, 0x3c4856)
    static let selectionHover = adaptive(0xd0dce7, 0x455568)
    static let accent = adaptive(0x476781, 0x9eb5c8)
    static let onAccent = adaptive(0xffffff, 0x1d252b)
    static let accentHover = adaptive(0x3d5b74, 0xb4c7d7)
    static let accentPressed = adaptive(0x324c63, 0x8ea6bb)
    static let focus = adaptive(0x597d9a, 0x9eb5c8)
    static let success = adaptive(0x367350, 0x8ac3a0)
    static let composerHoverLine = adaptive(0xb9c4ce, 0x566371)

}
struct PiMark: View {
    var size: CGFloat = 25
    var body: some View { Text("π").font(.custom("Georgia-Italic", size: size)).foregroundStyle(Theme.accent).accessibilityHidden(true) }
}
struct RootView: View {
    @EnvironmentObject var model: AppModel
    @State private var sidebarVisible = false
    @State private var sidebarSection = "sessions"
    @State private var filePreview:FilePreviewRequest?
    @State private var expanded: Set<String> = []
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @State private var atBottom = true
    @State private var viewportHeight: CGFloat = 0
    @State private var contentBottom: CGFloat = 0
    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar.frame(width: 238).background(Theme.sidebar)
                Rectangle().fill(Theme.line).frame(width: 0.5)
            }
            mainCard.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.canvas)
        .foregroundStyle(Theme.text).frame(minWidth: 820, minHeight: 640)
        .disclosureGroupStyle(PiDisclosureStyle())
        .ignoresSafeArea()
        .task { expanded = Set(model.projects.map(\.id)); await model.boot() }
        .onChange(of: model.project) { _, project in if let project { expanded.insert(project.id) } }
        .sheet(isPresented: $model.showSettings) { SettingsView().environmentObject(model) }
        .sheet(item: $model.renameTarget) { _ in RenameSessionView().environmentObject(model) }
        .sheet(item: $filePreview) { WorkspaceFilePreview(url:$0.url) }
        .sheet(isPresented: $model.showCommands) { CommandsView().environmentObject(model) }
        .sheet(isPresented: $model.forkSheetVisible) { ForkPickerView().environmentObject(model) }
        .sheet(isPresented: $model.showCompactSheet) { CompactView().environmentObject(model) }
        .sheet(item: Binding(get: { model.dialogs.first }, set: { if $0 == nil, let dialog = model.dialogs.first { model.replyDialog(dialog) } })) { dialog in
            ExtensionDialogView(dialog: dialog).environmentObject(model).interactiveDismissDisabled()
        }
        .onReceive(NotificationCenter.default.publisher(for: .piSearch)) { _ in focusSearch() }
    }
    private func focusSearch() {
        sidebarVisible = true; sidebarSection = "sessions"; searchVisible = true
        DispatchQueue.main.async { searchFocused = true }
    }
    private var mainCard: some View {
        VStack(spacing: 0) {
            toolbar
            if let terminal = model.terminal {
                VStack(spacing: 0) {
                    HStack {
                        Label("原版 Pi CLI", systemImage: "terminal").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("在 Pi CLI 中退出后，自动返回最近会话").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }.padding(.horizontal, 24).padding(.bottom, 12)
                    PiTerminalView(session: terminal).padding(12).background(Color(white: 0.08))
                }
            } else {
                if let error = model.error { errorBanner(error) }
                if model.project == nil { noProject }
                else if model.messages.isEmpty { welcome }
                else { conversation }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) { PiMark(size: 23); Text("Pi").font(.system(size: 17, weight: .semibold)) }.padding(.horizontal, 20).padding(.top, 54).padding(.bottom, 20)
            Picker("侧栏",selection:$sidebarSection) {
                Text("会话").tag("sessions")
                Text("文件").tag("files")
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal,14).padding(.bottom,13)
            if sidebarSection == "sessions" {
            navButton("新会话", icon: "square.and.pencil", shortcut: "⌘ N") { Task { await model.newSession() } }
            navButton("搜索会话", icon: "magnifyingglass", shortcut: "⌘ K") { focusSearch() }
            if searchVisible { TextField("搜索会话…", text: $model.search).focused($searchFocused).onExitCommand { model.search = ""; searchVisible = false }.textFieldStyle(.roundedBorder).font(.system(size: 12)).padding(.horizontal, 17).padding(.top, 7) }
            HStack { Text("项目"); Spacer(); Button { model.openProject() } label: { Image(systemName: "plus") }.buttonStyle(PiButtonStyle()).help("打开项目") }.font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.horizontal, 21).padding(.top, 30).padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.projects) { project in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 7) {
                                Button { Task { await model.selectProject(project) } } label: { Label(project.name, systemImage: "folder").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 7).frame(height: 30) }.buttonStyle(PiButtonStyle(kind: .row, horizontalPadding: 0, verticalPadding: 0))
                                Button { if expanded.contains(project.id) { expanded.remove(project.id) } else { expanded.insert(project.id) } } label: { Image(systemName: "chevron.right").font(.system(size: 8)).rotationEffect(.degrees(expanded.contains(project.id) ? 90 : 0)).frame(width: 16, height: 25) }.buttonStyle(PiButtonStyle(horizontalPadding: 4, verticalPadding: 0)).accessibilityLabel("展开或收起 \(project.name)")
                            }.font(.system(size: 12, weight: .medium)).padding(.horizontal, 2).frame(height: 30)
                                .contextMenu {
                                    Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) }
                                    Button("从侧栏移除") { model.removeProject(project) }
                                }
                            if expanded.contains(project.id) || !model.search.isEmpty {
                                VStack(spacing: 1) {
                                    ForEach((model.sessions[project.id] ?? []).filter { model.search.isEmpty || $0.title.localizedCaseInsensitiveContains(model.search) }) { session in
                                        Button { Task { await model.switchSession(session, in: project) } } label: {
                                            HStack(spacing: 5) {
                                                if model.busy && model.sessionPath == session.path { Circle().fill(Theme.accent).frame(width: 4, height: 4) }
                                                Text(session.title).lineLimit(1).truncationMode(.tail)
                                                Spacer(minLength: 0)
                                            }.font(.system(size: 12)).foregroundStyle(model.sessionPath == session.path ? Theme.text : Theme.secondary).padding(.horizontal, 9).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                        }.buttonStyle(PiButtonStyle(kind: .row, selected: model.sessionPath == session.path, horizontalPadding: 0, verticalPadding: 0)).help(session.title)
                                            .contextMenu {
                                                Button("重命名…") { Task { await model.requestRename(session,in:project) } }
                                                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:session.path)]) }
                                            }
                                    }
                                    if (model.sessions[project.id] ?? []).isEmpty {
                                        Text("还没有会话").font(.system(size: 11)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 7)
                                    }
                                }.padding(.leading, 20).padding(.bottom, 10)
                            }
                        }
                    }
                }.padding(.horizontal, 11)
            }
            } else if let project=model.project {
                WorkspaceFileBrowser(root:URL(fileURLWithPath:project.path),preview:{ filePreview=FilePreviewRequest(url:$0) })
            } else {
                Text("先打开一个项目").font(.system(size:12)).foregroundStyle(Theme.secondary).padding(18)
            }
            Spacer(minLength: 10)
            Rectangle().fill(Theme.line).frame(height: 0.5).padding(.horizontal, 10)
            navButton("打开项目…", icon: "folder", shortcut: nil) { model.openProject() }.padding(.top, 10)
            navButton("设置", icon: "slider.horizontal.3", shortcut: "⌘ ,") { model.showSettings = true }.padding(.bottom, 15)
        }
    }
    private func navButton(_ title: String, icon: String, shortcut: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) { Image(systemName: icon).frame(width: 16); Text(title); Spacer(); if let shortcut { Text(shortcut).font(.system(size: 11)).foregroundStyle(Theme.secondary) } }.font(.system(size: 12)).padding(.horizontal, 10).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(PiButtonStyle(kind: .row, horizontalPadding: 0, verticalPadding: 0)).padding(.horizontal, 10)
    }
    private var toolbar: some View {
        HStack(spacing: 10) {
            // macOS traffic lights occupy the leading 78pt when the sidebar is closed.
            if !sidebarVisible { Spacer().frame(width: 62) }
            PiMark(size: 23)
            Button { sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left").frame(width: 24, height: 28)
            }.buttonStyle(PiButtonStyle(horizontalPadding: 3, verticalPadding: 0))
                .help(sidebarVisible ? "收起会话列表" : "显示会话列表 · ⌘ K 搜索")
                .accessibilityLabel("切换会话列表")
            projectTabs
            Button { sidebarVisible=true;sidebarSection="files" } label: {
                Image(systemName:"folder").frame(width:24,height:28)
            }.buttonStyle(PiButtonStyle(horizontalPadding:3,verticalPadding:0)).help("项目文件").accessibilityLabel("项目文件")
            if model.connecting { ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16) }
            Button { Task { await model.newSession() } } label: {
                Image(systemName: "square.and.pencil").frame(width: 24, height: 28)
            }.buttonStyle(PiButtonStyle(horizontalPadding: 3, verticalPadding: 0))
                .disabled(!model.canSwitch || !model.connected).help("新会话 · ⌘ N").accessibilityLabel("新会话")
            Button { Task { await model.openTerminal() } } label: {
                Label("Pi CLI", systemImage: "terminal").font(.system(size: 11))
            }.buttonStyle(PiButtonStyle()).disabled(!model.canSwitch || model.project == nil)
                .help("运行原版 Pi，使用所有交互式命令和 TUI 扩展")
            Menu {
                Button("重命名会话…") { model.renameSession() }.disabled(!model.connected)
                Button("模型配置…") { model.openModelSettings() }
                Divider()
                Button("从历史消息创建分支…") { model.showForkPicker() }.disabled(!model.connected)
                Button("克隆为新会话") { Task { await model.cloneSession() } }.disabled(!model.connected)
                Button("压缩上下文…") { model.showCompactSheet = true }.disabled(!model.connected || model.busy)
                Divider()
                Button("导出为 HTML") { Task { await model.exportSession() } }.disabled(!model.connected)
                if let path = model.sessionPath { Button("显示原生会话文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }
                Divider()
                Button("自动压缩：\(model.autoCompaction ? "开" : "关")") { Task { await model.toggleAutoCompaction() } }
                Button("自动重试：\(model.autoRetry ? "开" : "关")") { Task { await model.toggleAutoRetry() } }
                Divider()
                Button("刷新会话列表") { Task { await model.refreshSessions() } }
                Button("重连 Pi CLI") { Task { await model.reconnect() } }
                Divider()
                Button("搜索会话…") { focusSearch() }
                Button("设置…") { model.showSettings = true }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().controlHover().help("会话操作")
        }.font(.system(size: 12)).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 16).frame(height: 53)
            .background(Theme.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
    private var projectTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(model.projects) { item in
                        let selected = model.project == item
                        Button {
                            if !selected { Task { await model.selectProject(item) } }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "folder").font(.system(size: 11))
                                Text(item.name).font(.system(size: 12, weight: selected ? .medium : .regular))
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            .foregroundStyle(selected ? Theme.text : Theme.secondary)
                            .padding(.horizontal, 13).frame(height: 52)
                            .frame(maxWidth: 200)
                            .contentShape(Rectangle())
                            .overlay(alignment: .bottom) {
                                if selected { Rectangle().fill(Theme.accent).frame(height: 2) }
                            }
                        }
                        .buttonStyle(PiButtonStyle(horizontalPadding: 0, verticalPadding: 0))
                        .disabled(model.terminal != nil || model.busy)
                        .id(item.id).help(item.path).accessibilityValue(selected ? "当前项目" : "")
                        .contextMenu {
                            Button("在 Finder 中显示") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.path) }
                            Button("从列表移除") { model.removeProject(item) }
                        }
                    }
                    Button { model.openProject() } label: {
                        Image(systemName: "plus").frame(width: 28, height: 30)
                    }.buttonStyle(PiButtonStyle(horizontalPadding: 2, verticalPadding: 0))
                        .disabled(!model.canSwitch).help("打开项目…").accessibilityLabel("打开项目")
                }
            }
            .onChange(of: model.project?.id) { _, id in if let id { proxy.scrollTo(id) } }
            .onAppear { if let id = model.project?.id { proxy.scrollTo(id) } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
            Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if !model.connected { Button("重连") { Task { await model.reconnect() } } }
            Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(PiButtonStyle())
        }.font(.system(size: 12)).foregroundStyle(Theme.text).padding(12).background(Theme.hover).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 24).padding(.bottom, 8)
    }
    private var noProject: some View {
        VStack(spacing: 18) {
            Spacer()
            PiMark(size: 44)
            Text("从一个项目开始").font(.system(size: 27, weight: .regular))
            Text("选择文件夹，继续你的 Pi 会话。").font(.system(size: 13.5)).foregroundStyle(Theme.secondary)
            Button("打开项目…") { model.openProject() }.buttonStyle(PiButtonStyle(kind: .accent, horizontalPadding: 18, verticalPadding: 10)).keyboardShortcut("o")
            Spacer()
        }.frame(maxWidth: .infinity)
    }
    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(alignment: .leading, spacing: 34) {
                HStack(alignment: .firstTextBaseline, spacing: 14) { PiMark(size: 40); Text("今天，想做点什么？").font(.system(size: 28, weight: .medium)).tracking(-0.6) }
                HStack(spacing: 7) { Image(systemName: "folder"); Text(model.project?.name ?? ""); Text(shortPath(model.project?.path ?? "")).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle) }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }.frame(maxWidth: 740, alignment: .leading).padding(.horizontal, 40).padding(.bottom, 36)
            Composer().environmentObject(model)
            Spacer()
            Label("与 Pi CLI 共用会话", systemImage: "link").font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.bottom, 28)
        }
    }
    private var conversation: some View {
        VStack(spacing: 0) {
            GeometryReader { viewport in
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 32) {
                            ForEach(model.conversationItems) { row in
                                switch row {
                                case .message(let message):
                                    MessageRow(message: message).environmentObject(model)
                                case .execution(let messages):
                                    ExecutionGroup(messages: messages, done: !model.busy || messages.last?.id != model.messages.last?.id)
                                }
                            }
                            Color.clear.frame(height: 1).id("bottom").background(GeometryReader { geo in
                                Color.clear.preference(key: BottomPreference.self, value: geo.frame(in: .named("conversation")).maxY)
                            })
                        }.frame(maxWidth: 740).padding(.horizontal, 40).padding(.top, 32).padding(.bottom, 20).frame(maxWidth: .infinity)
                    }.coordinateSpace(name: "conversation")
                        .onPreferenceChange(BottomPreference.self) { bottom in
                            contentBottom = bottom; atBottom = bottom <= viewport.size.height + 60
                        }
                        .onChange(of: model.messages.count) { _, _ in if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                        .onChange(of: model.messages.last?.text) { _, _ in if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
                        .onChange(of: model.sessionPath) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                        .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
                        .overlay(alignment: .bottom) {
                            if !atBottom { Button { proxy.scrollTo("bottom", anchor: .bottom) } label: { Image(systemName: "arrow.down").padding(8) }.buttonStyle(PiButtonStyle()).background(Theme.surface, in: Circle()).overlay(Circle().stroke(Theme.line)).padding(8).help("跳到最新消息") }
                        }
                }
            }
            Composer().environmentObject(model).padding(.top, 12).padding(.bottom, 22)
        }
    }
    private func shortPath(_ path: String) -> String {
        path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
    }
}
private struct BottomPreference: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
extension Notification.Name { static let piSearch = Notification.Name("PiDesktop.search") }

/// 从历史用户消息选择一条创建分支（对应 CLI 的 /fork）。
struct ForkPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("从历史消息创建分支").font(.system(size: 17, weight: .semibold))
            Text("会话将从所选用户消息处分出一条新分支，之后的对话不再影响当前分支。对应 Pi 的 /fork。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if model.forkPoints.isEmpty {
                Text("当前会话还没有可分支的用户消息。").foregroundStyle(Theme.secondary).padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.forkPoints.reversed()) { point in
                            Button { Task { await model.forkFrom(point) }; dismiss() } label: {
                                Text(point.display).font(.system(size: 12)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                            }.buttonStyle(PiButtonStyle(kind: .row, horizontalPadding: 0, verticalPadding: 0))
                        }
                    }
                }.frame(height: 300)
            }
            HStack { Spacer(); Button("取消") { dismiss() } }
        }.padding(22).frame(width: 520)
    }
}

/// 手动压缩上下文（对应 CLI 的 /compact），可附自定义指令。
struct CompactView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var instructions = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("压缩上下文").font(.system(size: 17, weight: .semibold))
            Text("用一份摘要替换较早的对话来释放上下文窗口，效果与 Pi 的 /compact 相同。")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            TextField("可选：给摘要的指令，如「保留所有 API 改动细节」", text: $instructions).textFieldStyle(.roundedBorder)
            HStack {
                Button("自动压缩设置") { Task { await model.toggleAutoCompaction() } }
                    .help("切换 Pi 的自动压缩开关")
                Spacer()
                Button("取消") { dismiss() }
                Button("开始压缩") { Task { await model.compactContext(instructions: instructions) }; dismiss() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).disabled(!model.connected)
            }
        }.padding(22).frame(width: 480)
    }
}

struct SettingsView: View {
    @AppStorage("appearance") private var appearance = "dark"
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var executable=""
    @State private var directory=""
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Text("设置").font(.system(size:20,weight:.semibold));Spacer()
                if model.busy { Label("Agent 正在后台运行",systemImage:"circle.fill").font(.system(size:11)).foregroundStyle(Theme.secondary) }
                Button("关闭") { dismiss() }
            }
            Picker("设置分类",selection:$model.settingsSection) {
                Text("通用").tag("general");Text("模型").tag("models")
            }.pickerStyle(.segmented).labelsHidden()
            if !model.dialogs.isEmpty {
                HStack {
                    Text("Pi 正在等待你的确认或输入").font(.system(size:12)).foregroundStyle(Theme.secondary)
                    Spacer();Button("返回处理") { model.showSettings=false }
                }
            }
            if model.settingsSection == "models" {
                ScrollView { ModelConfigurationView().environmentObject(model).padding(.trailing,5) }.frame(height:470)
            } else {
                VStack(alignment:.leading,spacing:20) {
                    HStack {
                        Text("外观").font(.system(size:12,weight:.medium));Spacer()
                        Picker("外观",selection:$appearance) {
                            Text("深色").tag("dark");Text("浅色").tag("light");Text("跟随系统").tag("system")
                        }.labelsHidden().pickerStyle(.segmented).frame(width:260)
                    }
                    VStack(alignment:.leading,spacing:7) {
                        Text("Pi CLI 可执行文件").font(.system(size:12,weight:.medium))
                        TextField("自动从登录 Shell 的 PATH 查找",text:$executable).textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment:.leading,spacing:7) {
                        Text("自定义会话目录（可选）").font(.system(size:12,weight:.medium))
                        TextField("留空以遵循 Pi 的配置",text:$directory).textFieldStyle(.roundedBorder)
                    }
                    Text("连接配置在下次连接时生效。打开或保存设置不会中断当前任务。")
                        .font(.system(size:12)).foregroundStyle(Theme.secondary)
                    HStack {
                        Button("打开 Pi 配置目录") { NSWorkspace.shared.open(model.agentDirectory) }
                        Spacer()
                        Button("保存") {
                            model.executableOverride=executable;model.sessionDirectory=directory
                            Task { await model.saveSettings() }
                        }.buttonStyle(PiButtonStyle(kind:.accent))
                    }
                }.padding(.vertical,6)
            }
        }.padding(24).frame(width:640)
            .onAppear { executable=model.executableOverride;directory=model.sessionDirectory }
    }
}

struct RenameSessionView:View {
    @EnvironmentObject var model:AppModel
    @State private var name=""
    @State private var error:String?
    @State private var saving=false
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("重命名会话").font(.system(size:18,weight:.semibold))
            TextField("会话名称",text:$name).textFieldStyle(.roundedBorder).onSubmit { save() }
            if let error { Text(error).font(.system(size:12)).foregroundStyle(.red) }
            HStack {
                Spacer();Button("取消") { model.renameTarget=nil }.disabled(saving)
                Button("保存") { save() }.buttonStyle(PiButtonStyle(kind:.accent)).disabled(saving || name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width:400).onAppear { name=model.renameTarget?.title ?? model.sessionName }
    }
    private func save() {
        guard !saving else { return };saving=true
        Task {
            do { try await model.saveSessionName(name) }
            catch { self.error=error.localizedDescription }
            saving=false
        }
    }
}
struct CommandsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var query = ""
    @State private var filter: CommandFilter = .all
    private var matches: [PiCommand] { model.commandIndex.matches(query: query, filter: filter) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Pi 命令").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button { Task { await model.refreshCommands() } } label: { Label("刷新", systemImage: "arrow.clockwise") }.disabled(model.commandsLoading)
                Button("关闭") { dismiss() }
            }
            Text("来自当前 Pi 会话，选择后填入原生命令。悬停可查看来源路径。")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            TextField("搜索名称或描述，例如 neat", text: $query).textFieldStyle(.roundedBorder)
            CommandFilterStrip(filter: $filter, commands: model.commands)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(matches) { command in
                        Button { model.draft = "/" + command.name + " "; dismiss() } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("/" + command.name).font(.system(size: 12, weight: .medium))
                                    Spacer()
                                    Text(command.sourceLabel).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                                }
                                Text(command.description).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(2)
                                Text(command.originLabel).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1)
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(PiButtonStyle(kind: .row, horizontalPadding: 0, verticalPadding: 0)).help(command.origin)
                    }
                    if matches.isEmpty {
                        Text(model.commandsError ?? (model.commandsLoading ? "正在读取 Pi 命令…" : "没有匹配的命令"))
                            .foregroundStyle(Theme.secondary).padding()
                    }
                }
            }.frame(height: 300)
            Text("\(matches.count) 项 · /settings、/login、/tree 等交互命令在 Pi CLI 中使用。")
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }.padding(22).frame(width: 540).task { await model.refreshCommands() }
    }
}
struct ExtensionDialogView: View {
    @EnvironmentObject var model: AppModel
    let dialog: ExtensionDialog
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(dialog.title).font(.system(size: 17, weight: .semibold))
            if !dialog.message.isEmpty { Text(dialog.message).font(.system(size: 13.5)).textSelection(.enabled) }
            if dialog.method == "select" {
                ScrollView { VStack(alignment: .leading, spacing: 6) { ForEach(Array(dialog.options.enumerated()), id: \.offset) { _, option in Button(option) { model.replyDialog(dialog, value: option) }.buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading) } } }.frame(maxHeight: 300)
            } else if dialog.method == "input" { TextField(dialog.placeholder, text: $text).textFieldStyle(.roundedBorder) }
            else if dialog.method == "editor" { TextEditor(text: $text).font(.system(size: 13.5, design: .monospaced)).frame(height: 220).border(Theme.line) }
            HStack {
                Button("取消") { model.replyDialog(dialog) }; Spacer()
                if dialog.method == "confirm" {
                    Button("否") { model.replyDialog(dialog, confirmed: false) }
                    Button("是") { model.replyDialog(dialog, confirmed: true) }.buttonStyle(.borderedProminent)
                } else if dialog.method != "select" { Button("确定") { model.replyDialog(dialog, value: text) }.buttonStyle(.borderedProminent) }
            }
        }.padding(24).frame(width: 440).onAppear { text = dialog.prefill }
    }
}
