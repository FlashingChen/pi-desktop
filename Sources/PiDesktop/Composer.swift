import SwiftUI
import AppKit

final class InputTextView: NSTextView {
    var onSend: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// 斜杠面板交互：↑↓ 选择、Tab 补全；返回值表示已消费按键。
    var slashKeys: ((NSEvent) -> Bool)?
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.onFocusChange?(true) } }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { DispatchQueue.main.async { [weak self] in self?.onFocusChange?(false) } }
        return result
    }
    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)), !hasMarkedText(),
           NSApp.currentEvent?.modifierFlags.contains(.shift) != true {
            onSend?(); return
        }
        super.doCommand(by: selector)
    }
    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty, slashKeys?(event) == true { return }
        super.keyDown(with: event)
    }
}
struct MessageInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    var editable = true
    var focusRequest = 0
    var onSend: () -> Void
    var onSlashKey: ((NSEvent) -> Bool)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        let input = InputTextView()
        input.isRichText = false; input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false; input.isAutomaticTextReplacementEnabled = false
        input.font = .systemFont(ofSize: 14); input.drawsBackground = false
        input.textColor = .labelColor; input.insertionPointColor = NSColor(Theme.accent)
        input.textContainerInset = NSSize(width: 1, height: 4)
        input.isVerticallyResizable = true; input.isHorizontallyResizable = false
        input.autoresizingMask = [.width]
        input.textContainer?.widthTracksTextView = true
        input.delegate = context.coordinator; input.onSend = { context.coordinator.parent.onSend() }
        input.onFocusChange = { context.coordinator.parent.focused = $0 }
        input.slashKeys = { context.coordinator.parent.onSlashKey?($0) ?? false }
        input.isEditable = editable
        input.setAccessibilityLabel("给 Pi 发消息")
        scroll.documentView = input
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? InputTextView else { return }
        input.isEditable = editable
        if input.string != text, !input.hasMarkedText() {
            input.string = text
            input.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            input.scrollRangeToVisible(input.selectedRange())
        }
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async { scroll.window?.makeFirstResponder(input) }
        }
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MessageInput
        var lastFocusRequest = 0
        init(_ parent: MessageInput) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let input = notification.object as? NSTextView { parent.text = input.string }
        }
    }
}
struct Composer: View {
    @EnvironmentObject private var model: AppModel
    var body: some View { ComposerContent(model: model, editor: model.draftBuffer) }
}

private struct ComposerContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var editor: DraftBuffer
    @State private var modelPicker = false
    @State private var inputFocused = false
    @State private var inputHovered = false
    @State private var slashSelected = 0
    @State private var slashDismissed = false
    @State private var paletteHeight: CGFloat = 320
    @State private var commandFilter: CommandFilter = .all
    @State private var inputFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Claude Code 式：输入以 / 开头时，在输入框上方内联列出候补命令。
    private var slashQuery: String? {
        guard !slashDismissed, model.draft.hasPrefix("/"), !model.draft.contains(where: { $0.isWhitespace }) else { return nil }
        return String(model.draft.dropFirst())
    }
    private var slashMatches: [PiCommand] {
        guard let query = slashQuery else { return [] }
        return model.commandIndex.matches(query: query, filter: commandFilter)
    }
    private func complete(_ command: PiCommand) {
        model.draft = "/" + command.name + " "
        inputFocusRequest += 1
    }

    var body: some View {
        let matches = slashMatches
        VStack(spacing: 10) {
            if model.pendingCount > 0 {
                HStack { Text("Pi 队列中有 \(model.pendingCount) 条消息"); Spacer() }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            if !model.widgets.isEmpty {
                ForEach(model.widgets.keys.sorted(), id: \.self) { key in
                    Text((model.widgets[key] ?? []).joined(separator: "\n")).font(.system(size: 12, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            VStack(spacing: 9) {
                if !model.attachments.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(model.attachments) { image in
                                HStack(spacing: 5) {
                                    Image(systemName: "photo")
                                    Text(image.name).lineLimit(1)
                                    Button { model.attachments.removeAll { $0.id == image.id } } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(PiButtonStyle(horizontalPadding: 4, verticalPadding: 4)).help("移除图片 \(image.name)").accessibilityLabel("移除图片 \(image.name)")
                                }.font(.system(size: 11)).padding(7).background(Theme.hover, in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }.frame(height: 34)
                }
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty { Text(model.project == nil ? "先打开一个项目" : "给 Pi 发消息…").font(.system(size: 14)).foregroundStyle(Theme.secondary).padding(.top, 4).padding(.leading, 5).allowsHitTesting(false) }
                    MessageInput(text: $editor.text, focused: $inputFocused, editable: model.project != nil && (!model.connecting || !model.connected), focusRequest: inputFocusRequest, onSend: { Task { await model.send() } }, onSlashKey: { event in
                        // Ordinary typing must go straight to NSTextView, without
                        // calculating the previous query before inserting each letter.
                        guard [125, 126, 36, 76, 48, 53].contains(event.keyCode), !event.modifierFlags.contains(.shift), slashQuery != nil else { return false }
                        let matches = slashMatches
                        guard !matches.isEmpty else { return false }
                        switch event.keyCode {
                        case 125: // down
                            slashSelected = min(slashSelected + 1, matches.count - 1); return true
                        case 126: // up
                            slashSelected = max(0, slashSelected - 1); return true
                        case 36, 76, 48: // Return, keypad Enter, Tab: complete before sending
                            let command = matches[min(slashSelected, matches.count - 1)]
                            if event.keyCode != 48, model.draft == "/" + command.name { return false }
                            complete(command); return true
                        case 53: // esc
                            slashDismissed = true; return true
                        default: return false
                        }
                    })
                        .frame(height: model.messages.isEmpty ? 66 : 54)
                }
                .onChange(of: editor.text) { _, _ in slashSelected = 0; slashDismissed = false }
                .onChange(of: commandFilter) { _, _ in slashSelected = 0 }
                .onChange(of: slashQuery != nil) { _, open in
                    if open { Task { await model.refreshCommands() } }
                }
                HStack(spacing: 7) {
                    Button { model.attachImages() } label: { Image(systemName: "plus").frame(width: 24, height: 26) }.buttonStyle(PiButtonStyle(horizontalPadding: 0, verticalPadding: 0)).help("添加图片").disabled(!model.connected)
                    Button {
                        if model.draft.isEmpty { model.draft = "/" }
                        if slashQuery != nil { slashDismissed = false; inputFocusRequest += 1 }
                        else { model.showCommands = true }
                    } label: { Text("/").font(.system(size: 15)).frame(width: 24, height: 26) }.buttonStyle(PiButtonStyle(horizontalPadding: 0, verticalPadding: 0)).help("Pi Skills、提示词和扩展命令").disabled(!model.connected)
                    Spacer(minLength: 5)
                    if model.busy {
                        Menu {
                            Button("Steer · 在下次模型调用前发送") { model.queueBehavior = "steer" }
                            Button("Follow-up · 当前运行结束后发送") { model.queueBehavior = "followUp" }
                        } label: { Text(model.queueBehavior == "steer" ? "Steer" : "Follow-up").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize().controlHover()
                    }
                    Button { modelPicker.toggle() } label: {
                        HStack(spacing: 5) { Text(model.selectedModel?.name ?? "选择模型").lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 8)) }
                    }.buttonStyle(PiButtonStyle(horizontalPadding: 6, verticalPadding: 3)).disabled(!model.connected || model.busy).popover(isPresented: $modelPicker) { ModelPicker().environmentObject(model) }
                    if model.thinkingLevels.count > 1 {
                        Menu {
                            ForEach(model.thinkingLevels, id: \.self) { level in Button(level.capitalized) { Task { await model.setThinking(level) } } }
                        } label: { Text("思考 · \(model.thinking.capitalized)").font(.system(size: 11)) }.menuStyle(.borderlessButton).fixedSize().controlHover().disabled(model.busy || !model.connected)
                    }
                    if model.busy {
                        Button { Task { await model.abort() } } label: { Image(systemName: "stop.fill").font(.system(size: 11)).frame(width: 27, height: 27) }.buttonStyle(PiButtonStyle(horizontalPadding: 0, verticalPadding: 0)).help("中止当前运行")
                    }
                    Button { Task { await model.send() } } label: { Image(systemName: "arrow.up").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.onAccent).frame(width: 28, height: 28) }
                        .buttonStyle(PiButtonStyle(kind: .accent, horizontalPadding: 0, verticalPadding: 0)).disabled(!model.canSend).help("发送消息")
                }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            .padding(15).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(inputFocused ? Theme.focus.opacity(0.7) : inputHovered && model.connected ? Theme.composerHoverLine : Theme.line, lineWidth: inputFocused ? 1.25 : 0.75))
            .shadow(color: .black.opacity(inputFocused ? 0.055 : inputHovered ? 0.04 : 0.025), radius: 10, x: 0, y: 4)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { paletteHeight = max(120, min(320, geometry.frame(in: .global).minY - 76)) }
                    .onChange(of: geometry.frame(in: .global).minY) { _, top in paletteHeight = max(120, min(320, top - 76)) }
            })
            .overlay(alignment: .topLeading) {
                if inputFocused, let query = slashQuery {
                    SlashPalette(query: query, matches: matches, selected: $slashSelected, filter: $commandFilter, allCommands: model.commands, loading: model.commandsLoading, error: model.commandsError, maxHeight: paletteHeight, refresh: { Task { await model.refreshCommands() } }, pick: complete)
                    .frame(maxWidth: 490)
                    .offset(y: -CommandPaletteLayout.height(count: matches.count, limit: paletteHeight) - 8)
                    .transition(.opacity)
                }
            }
            .zIndex(10)
            .nativeHover { inputHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: inputFocused)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: inputHovered)
            HStack {
                Text(model.status.isEmpty ? "Enter 发送，Shift + Enter 换行" : model.status).lineLimit(1)
                Spacer()
                Text(model.statistics)
            }.font(.system(size: 11)).foregroundStyle(Theme.secondary)
            if !model.extensionStatus.isEmpty {
                Text(model.extensionStatus.keys.sorted().compactMap { model.extensionStatus[$0] }.joined(separator: " · ")).font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: 740).padding(.horizontal, 40).zIndex(10)
    }
}
struct ModelPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State var query = ""
    var filtered: [PiModel] { model.models.filter { query.isEmpty || ($0.name + $0.provider + $0.modelID).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("搜索 Pi 已配置的模型", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { item in
                        Button {
                            Task { await model.setModel(item) }; dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) { Text(item.name).font(.system(size: 12)); Text(item.provider + " / " + item.modelID).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer(); if model.selectedModel?.id == item.id { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(PiButtonStyle(kind: .row, selected: model.selectedModel?.id == item.id, horizontalPadding: 0, verticalPadding: 0))
                    }
                    if filtered.isEmpty { Text("没有匹配的模型。可在 Pi CLI 中配置提供商。 ").font(.system(size: 12)).foregroundStyle(.secondary).padding() }
                }
            }.frame(maxHeight: 360)
        }.padding(12).frame(width: 340)
    }
}

enum CommandPaletteLayout {
    static func listHeight(count: Int, limit: CGFloat) -> CGFloat { min(CGFloat(max(1, count) * 50 + 6), max(28, limit - 96)) }
    static func height(count: Int, limit: CGFloat) -> CGFloat { listHeight(count: count, limit: limit) + 96 }
}

struct CommandFilterStrip: View {
    @Binding var filter: CommandFilter
    let commands: [PiCommand]
    var body: some View {
        HStack(spacing: 4) {
            ForEach(CommandFilter.allCases, id: \.self) { option in
                Button { filter = option } label: {
                    HStack(spacing: 4) {
                        Text(option.rawValue)
                        Text("\(commands.filter(option.includes).count)").monospacedDigit().foregroundStyle(Theme.secondary)
                    }.font(.system(size: 11)).padding(.horizontal, 7).frame(height: 26)
                }.buttonStyle(PiButtonStyle(kind: .row, selected: filter == option, horizontalPadding: 0, verticalPadding: 0)).focusable(false)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Real Pi RPC catalogue, searchable independently of the conversation renderer.
struct SlashPalette: View {
    let query: String
    let matches: [PiCommand]
    @Binding var selected: Int
    @Binding var filter: CommandFilter
    let allCommands: [PiCommand]
    var loading = false
    var error: String?
    var maxHeight: CGFloat = 320
    let refresh: () -> Void
    let pick: (PiCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Pi 命令").font(.system(size: 11, weight: .medium))
                if loading { ProgressView().controlSize(.mini).frame(width: 12) }
                if let error { Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange).help(error + "；保留上次目录，点击刷新重试") }
                Spacer()
                Text("\(matches.count) 项").font(.system(size: 11)).monospacedDigit()
                Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.system(size: 11)).frame(width: 22, height: 24) }
                    .buttonStyle(PiButtonStyle(horizontalPadding: 0, verticalPadding: 0)).disabled(loading).focusable(false).help("从当前 Pi 会话刷新命令")
            }.foregroundStyle(Theme.secondary).padding(.horizontal, 12).frame(height: 30)
            CommandFilterStrip(filter: $filter, commands: allCommands).padding(.horizontal, 7).frame(height: 36)
            ScrollViewReader { proxy in
                ScrollView {
                    // A filtered catalogue must never reuse a row by its old
                    // position. Eager rows keep label and action on the same data.
                    VStack(spacing: 2) {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                            Button { pick(command) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 10) {
                                        Text("/" + command.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(command.sourceLabel + " · " + command.originLabel).font(.system(size: 10)).foregroundStyle(Theme.secondary).lineLimit(1).frame(maxWidth: 160, alignment: .trailing)
                                    }
                                    Text(command.description.isEmpty ? "选择以填入输入框" : command.description)
                                        .font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                                .padding(.horizontal, 10).frame(height: 48).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PiButtonStyle(kind: .row, selected: index == selected, horizontalPadding: 0, verticalPadding: 0))
                            .focusable(false).help(command.origin.isEmpty ? command.description : command.origin)
                            .accessibilityLabel("/" + command.name).accessibilityValue(index == selected ? "已选中" : "")
                            // Hover styles are visual only: scrolling under a stationary
                            // pointer must never reset keyboard selection.
                        }
                        if matches.isEmpty {
                            Text(error ?? (loading ? "正在读取 Pi 命令…" : "没有匹配项，试试名称或描述"))
                                .font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.horizontal, 5).padding(.vertical, 3)
                }
                .frame(height: CommandPaletteLayout.listHeight(count: matches.count, limit: maxHeight))
                .onChange(of: selected) { _, value in
                    if matches.indices.contains(value) { proxy.scrollTo(matches[value].id) }
                }
                .onChange(of: matches.map(\.id)) { _, ids in
                    if let first = ids.first { proxy.scrollTo(first, anchor: .top) }
                }
            }
            HStack(spacing: 12) {
                Text("↑↓ 选择")
                Text("↵ / Tab 填入")
                Spacer()
                Text("Esc 关闭")
            }.font(.system(size: 10)).foregroundStyle(Theme.secondary).padding(.horizontal, 12).frame(height: 30)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.composerHoverLine, lineWidth: 0.75))
        .shadow(color: .black.opacity(0.16), radius: 14, x: 0, y: 5)
        .accessibilityLabel("Pi 命令候补")
    }
}
