import SwiftUI
import AppKit

/// 正文渲染：GFM 表格用原生 Grid 渲染，其余段落走 inline Markdown。
struct MarkdownBody: View {
    let text: String
    var segments: [(table: [[String]]?, lines: [String])] {
        var result: [( [[String]]?, [String] )] = []
        var buffer: [String] = []
        let lines = text.components(separatedBy: "\n")
        var index = 0
        func flush() {
            if !buffer.isEmpty { result.append((nil, buffer)); buffer = [] }
        }
        func isSeparator(_ row: [String]) -> Bool {
            // "|---|---|" 首尾切出空串，只检查非空单元格
            let meaningful = row.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return !meaningful.isEmpty && meaningful.allSatisfy { cell in
                cell.trimmingCharacters(in: .whitespaces).allSatisfy { "-: " .contains($0) }
            }
        }
        while index < lines.count {
            var candidate: [String] = []
            var cursor = index
            while cursor < lines.count, lines[cursor].contains("|") {
                candidate.append(lines[cursor]); cursor += 1
            }
            let cells = candidate.map { line -> [String] in
                var parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                // 首尾竖线切出的空串丢弃，保留中间的空单元格
                if parts.first?.isEmpty == true { parts.removeFirst() }
                if parts.last?.isEmpty == true { parts.removeLast() }
                return parts
            }
            if candidate.count >= 2, cells.count >= 2, isSeparator(cells[1]) {
                flush()
                var rows = cells
                rows.remove(at: 1) // 分隔行
                let width = rows.map(\.count).max() ?? 1
                let padded = rows.map { $0 + Array(repeating: "", count: max(0, width - $0.count)) }
                result.append((padded, []))
                index = cursor
            } else {
                buffer.append(lines[index])
                index += 1
            }
        }
        flush()
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if let rows = segment.table {
                    MarkdownTable(rows: rows)
                } else {
                    Text((try? AttributedString(markdown: segment.lines.joined(separator: "\n"), options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(segment.lines.joined(separator: "\n")))
                        .font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
                }
            }
        }
    }
}

struct MarkdownTable: View {
    let rows: [[String]]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let header = rows.first ?? []
            let body = Array(rows.dropFirst())
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 7)
                    }
                }
                Divider().overlay(Theme.line)
                ForEach(Array(body.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text((try? AttributedString(markdown: cell)) ?? AttributedString(cell))
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 7)
                        }
                    }
                    Divider().overlay(Theme.line)
                }
            }
        }
        .background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 0.75))
        .padding(.vertical, 2)
    }
}
/// toolResult / bashExecution 归入同一个默认收起的「执行过程」组，点开可回看全过程。
/// 折叠组的摘要行显示各步骤；运行中显示进度点，结束后显示步骤数与耗时（如有）。
struct ExecutionGroup: View {
    let messages: [DisplayMessage]
    let done: Bool
    @State private var expanded = false
    @State private var showAllSteps = false
    @State private var hovering = false
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(messages:[DisplayMessage],done:Bool,initiallyExpanded:Bool=false) {
        self.messages=messages;self.done=done;_expanded=State(initialValue:initiallyExpanded)
    }
    private var records: [ExecutionRecord] { executionRecords(messages) }
    private var labels: [String] { records.map(\.label) }
    private var visibleRecords:[ExecutionRecord] {
        guard !showAllSteps,records.count > 7 else { return records }
        let thought=records.filter { if case .thinking = $0.kind { return true };return false }
        let tools=records.filter { if case .thinking = $0.kind { return false };return true }
        return thought + tools.suffix(5)
    }
    var summary: String {
        var seen:Set<String>=[]
        let names=labels.filter { seen.insert($0).inserted }
        return names.prefix(3).joined(separator:" · ") + (names.count > 3 ? "…" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    if !done {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .modifier(PulseIfRunning())
                    }
                    Text(done ? "执行过程" : "正在执行")
                        .font(.system(size: 12, weight: .medium))
                    Text(summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text("\(labels.count) 步")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 12).frame(minHeight: 34).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PiButtonStyle(kind: .row, horizontalPadding: 0, verticalPadding: 0))
            .background(hovering ? Theme.controlHover : Theme.hover, in: RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
            .accessibilityLabel(done ? "执行过程，\(labels.count) 步" : "正在执行")
            .accessibilityHint("点按以展开或收起")
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleRecords) { record in
                        ExecutionRecordRow(record: record, done: done)
                    }
                    if records.count > 7 {
                        Button(showAllSteps ? "收起较早的操作" : "显示全部 \(records.count) 项（当前仅显示最近操作）") { showAllSteps.toggle() }
                            .font(.system(size:11)).foregroundStyle(Theme.secondary).buttonStyle(.plain).padding(.leading,21).padding(.vertical,7)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct PulseIfRunning: ViewModifier {
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(on ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct MarkdownText: View {
    let text: String
    struct Part: Identifiable { let id: Int; let text: String; let code: Bool; let language: String }
    var parts: [Part] {
        let chunks = text.components(separatedBy: "```")
        return chunks.enumerated().map { index, content in
            if index % 2 == 0 { return Part(id: index, text: content.trimmingCharacters(in: .newlines), code: false, language: "") }
            let split = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return Part(id: index, text: split.count > 1 ? String(split[1]).trimmingCharacters(in: .newlines) : content, code: true, language: String(split.first ?? ""))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(parts) { part in
                if part.code {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(part.language).foregroundStyle(Theme.secondary); Spacer(); CopyControl(text: part.text, help: "复制代码") }.font(.system(size: 11))
                        ScrollView(.horizontal) { Text(part.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: true, vertical: false).padding(.bottom, 2) }
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line, lineWidth: 0.75))
                } else if !part.text.isEmpty {
                    MarkdownBody(text: part.text)
                }
            }
        }
    }
}

/// Codex 式分组：把连续的执行类消息（assistant 含 thinking/toolCall、toolResult、bashExecution）
/// 合并成一个执行组，纯文本 assistant 与 user 消息单独成行。
enum ConversationRow: Identifiable {
    case message(DisplayMessage)
    case execution([DisplayMessage])
    var id: String {
        switch self {
        case .message(let m): return "m-\(m.id)"
        case .execution(let ms): return "e-" + (ms.first?.id ?? "empty")
        }
    }
}
func conversationRows(_ messages: [DisplayMessage]) -> [ConversationRow] {
    var rows: [ConversationRow] = [], turn: [DisplayMessage] = []
    func appendTurn() {
        guard !turn.isEmpty else { return }
        var execution: [DisplayMessage] = [], prose: [DisplayMessage] = []
        for message in turn {
            if message.role == "toolResult" || message.role == "bashExecution" {
                execution.append(message)
            } else if message.role == "assistant" {
                let activity = message.blocks.filter { $0["type"] as? String == "toolCall" || ($0["type"] as? String == "thinking" && !($0["thinking"] as? String ?? "").isEmpty) }
                if !activity.isEmpty {
                    var copy = message; copy.raw["content"] = activity; execution.append(copy)
                }
                let visible = message.blocks.filter { !["thinking", "toolCall"].contains($0["type"] as? String) }
                if !visible.isEmpty || message.raw["errorMessage"] != nil {
                    var copy = message; copy.raw["content"] = visible; prose.append(copy)
                }
            } else if message.role != "system" { prose.append(message) }
        }
        // One expandable activity summary per user turn, including the final
        // assistant's thinking. Never split it around visible answer text.
        if !execution.isEmpty { rows.append(.execution(execution)) }
        rows += prose.map(ConversationRow.message)
        turn.removeAll(keepingCapacity: true)
    }
    for message in messages {
        if message.role == "user" {
            appendTurn(); rows.append(.message(message))
        } else { turn.append(message) }
    }
    appendTurn()
    return rows
}
struct MessageRow: View {
    let message: DisplayMessage
    @EnvironmentObject var model: AppModel
    /// 折叠规则：assistant 消息若含 thinking/toolCall、或为 bashExecution，则归入执行组；
    /// 纯文本的 assistant 消息是结论，正常渲染。
    var isExecution: Bool {
        if message.role == "bashExecution" { return true }
        guard message.role == "assistant" || message.role == "toolResult" else { return false }
        return message.blocks.contains { ["thinking", "toolCall"].contains($0["type"] as? String) }
    }
    var body: some View {
        Group {
            if message.role == "user" {
                HStack(alignment: .top, spacing: 10) {
                    Spacer(minLength: 60)
                    VStack(alignment: .leading, spacing: 8) { content }
                        .padding(.horizontal, 16).padding(.vertical, 11)
                        .background(Theme.bubble, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line.opacity(0.7), lineWidth: 0.5))
                        .frame(maxWidth: 520, alignment: .trailing)
                }
            } else if isExecution {
                ExecutionGroup(messages: [message], done: !model.busy)
            } else if message.role == "system" {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        PiMark(size: 18)
                        Text(message.role == "assistant" ? "Pi" : (message.raw["customType"] as? String ?? message.role)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
                        if let name = message.raw["model"] as? String { Text(name).font(.system(size: 11)).foregroundStyle(Theme.secondary.opacity(0.8)).lineLimit(1) }
                        Spacer(minLength: 8)
                        if !message.text.isEmpty { CopyControl(text: message.text, help: "复制回复") }
                    }.padding(.bottom, 2).frame(maxWidth: .infinity, alignment: .leading)
                    content
                    if let error = message.raw["errorMessage"] as? String { Text(error).foregroundStyle(.red).font(.system(size: 12)).textSelection(.enabled) }
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder var content: some View {
        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
            switch block["type"] as? String ?? "" {
            case "text":
                if message.role == "user",let invocation=SkillInvocation.parse(block["text"] as? String ?? "") { SkillInvocationView(invocation:invocation) }
                else { MarkdownText(text: block["text"] as? String ?? "") }
            case "thinking": EmptyView()
            case "toolCall": EmptyView()
            case "image":
                if let data = block["data"] as? String, let bytes = Data(base64Encoded: data), let image = NSImage(data: bytes) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240).clipShape(RoundedRectangle(cornerRadius: 8))
                }
            default:
                Text(jsonString(block)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            }
        }
    }
    private func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return String(describing: value) }
        return text
    }
}

private struct SkillInvocationView:View {
    let invocation:SkillInvocation
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Label("/skill:" + invocation.name,systemImage:"doc.text").font(.system(size:12,weight:.medium)).foregroundStyle(Theme.secondary)
            if !invocation.request.isEmpty { MarkdownText(text:invocation.request) }
            DisclosureGroup {
                VStack(alignment:.leading,spacing:6) {
                    HStack { Text("Skill 原始内容").font(.system(size:11));Spacer();CopyControl(text:invocation.content,help:"复制完整 Skill 内容") }
                    Text(String(invocation.content.prefix(16000))).font(.system(size:11,design:.monospaced)).textSelection(.enabled)
                }
            } label: { Text("查看 Skill 内容").font(.system(size:11)) }
        }
    }
}
