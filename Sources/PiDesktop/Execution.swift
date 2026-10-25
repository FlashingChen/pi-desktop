import SwiftUI

/// A UI projection only: native Pi messages and tool IDs remain authoritative.
struct ExecutionRecord: Identifiable {
    enum Kind {
        case thinking([DisplayMessage])
        case tool(call: [String: Any]?, result: DisplayMessage?)
        case bash(DisplayMessage)
    }
    let id: String
    let kind: Kind
    var label: String {
        switch kind {
        case .thinking: return "思考"
        case .tool(let call, let result): return call?["name"] as? String ?? result?.raw["toolName"] as? String ?? "工具"
        case .bash: return "bash"
        }
    }
    var summary: String {
        switch kind {
        case .tool(let call, _):
            let args=call?["arguments"] as? [String:Any] ?? [:]
            let value=(args["command"] as? String) ?? (args["path"] as? String) ?? (args["file_path"] as? String) ?? (args["filePath"] as? String) ?? ""
            return String((value.split(separator:"\n",maxSplits:1,omittingEmptySubsequences:true).first ?? "").prefix(180)).trimmingCharacters(in:.whitespaces)
        case .bash(let message): return String((message.raw["command"] as? String ?? "").split(separator:"\n").first ?? "")
        case .thinking: return ""
        }
    }

}

func executionRecords(_ messages: [DisplayMessage]) -> [ExecutionRecord] {
    var results: [String: DisplayMessage] = [:]
    var callIDs: Set<String> = []
    var thoughts: [DisplayMessage] = []
    for message in messages {
        if message.role == "toolResult", let id = message.raw["toolCallId"] as? String { results[id] = message }
        if message.blocks.contains(where: { $0["type"] as? String == "thinking" }) { thoughts.append(message) }
        for block in message.blocks where block["type"] as? String == "toolCall" {
            if let id = block["id"] as? String { callIDs.insert(id) }
        }
    }
    var records: [ExecutionRecord] = [], seen: Set<String> = []
    for message in messages {
        for (index, block) in message.blocks.enumerated() {
            switch block["type"] as? String {
            case "thinking":
                if seen.insert("thinking").inserted { records.append(.init(id: "thinking", kind: .thinking(thoughts))) }
            case "toolCall":
                let id = block["id"] as? String ?? "\(message.id)-\(index)"
                if seen.insert("tool-" + id).inserted { records.append(.init(id: "tool-" + id, kind: .tool(call: block, result: results[id]))) }
            default: break
            }
        }
        if message.role == "toolResult" {
            let id = message.raw["toolCallId"] as? String
            // Preserve orphan results, but don't count a matched result as another operation.
            if id.map({ !callIDs.contains($0) }) ?? true {
                let key = "result-" + (id ?? message.id)
                if seen.insert(key).inserted { records.append(.init(id: key, kind: .tool(call: nil, result: message))) }
            }
        } else if message.role == "bashExecution" {
            records.append(.init(id: "bash-" + message.id, kind: .bash(message)))
        }
    }
    return records
}

struct ExecutionRecordRow: View {
    let record: ExecutionRecord
    let done: Bool
    var body: some View {
        Group {
        switch record.kind {
        case .thinking(let messages):
            DisclosureGroup {
                MarkdownText(text: messages.flatMap { $0.blocks }.compactMap { $0["thinking"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
                    .padding(.top, 6)
            } label: { Text("思考过程").font(.system(size: 12, weight: .medium)) }
                .padding(.horizontal, 5).padding(.vertical, 2)
        case .tool(let call, let result):
            DisclosureGroup {
                if let arguments = call?["arguments"], let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) {
                    executionText(text, title: "参数")
                }
                if let result { executionText(result.text, title: "输出") }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: result == nil ? "circle.dotted" : result?.raw["isError"] as? Bool == true ? "exclamationmark.circle" : "checkmark")
                        .font(.system(size: 11)).foregroundStyle(result?.raw["isError"] as? Bool == true ? Color.red : result == nil ? Theme.secondary : Theme.success)
                    Text(record.label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary).frame(minWidth:32,alignment:.leading)
                    if !record.summary.isEmpty { Text(record.summary).font(.system(size:12)).lineLimit(1).truncationMode(.middle) }
                    if result == nil { Text(done ? "未记录结果" : "运行中").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                }
            }.padding(.horizontal, 5).padding(.vertical, 2)
        case .bash(let message):
            DisclosureGroup {
                executionText(message.raw["output"] as? String ?? "", title: "输出")
            } label: {
                Label(message.raw["command"] as? String ?? "Bash", systemImage: "terminal")
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1)
            }.padding(.horizontal, 5).padding(.vertical, 2)
        }
        }.disclosureGroupStyle(ExecutionDisclosureStyle())
    }
    private func executionText(_ text: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                Spacer()
                CopyControl(text: text, help: "复制完整\(title)")
            }
            // Large tool output stays bounded on screen; copying retains every byte.
            Text(String(text.prefix(16_000))).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            if text.count > 16_000 { Text("仅预览前 16,000 字符，可复制完整\(title)").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
        }.padding(.vertical, 5)
    }
}

private struct ExecutionDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration:Configuration)->some View {
        VStack(alignment:.leading,spacing:3) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing:8) {
                    Image(systemName:"chevron.right").font(.system(size:8)).rotationEffect(.degrees(configuration.isExpanded ? 90 : 0)).foregroundStyle(Theme.secondary)
                    configuration.label
                    Spacer(minLength:0)
                }.frame(minHeight:28).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
            if configuration.isExpanded { configuration.content.padding(.leading,18) }
        }
    }
}
