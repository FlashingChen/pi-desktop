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
        switch record.kind {
        case .thinking(let messages):
            DisclosureGroup {
                MarkdownText(text: messages.flatMap { $0.blocks }.compactMap { $0["thinking"] as? String }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
                    .padding(.top, 6)
            } label: { Text("思考过程").font(.system(size: 12, weight: .medium)) }
                .padding(.horizontal, 12).padding(.vertical, 5)
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
                    Text(record.label).font(.system(size: 12, design: .monospaced))
                    if result == nil { Text(done ? "未记录结果" : "运行中").font(.system(size: 11)).foregroundStyle(Theme.secondary) }
                }
            }.padding(.horizontal, 12).padding(.vertical, 5)
        case .bash(let message):
            DisclosureGroup {
                executionText(message.raw["output"] as? String ?? "", title: "输出")
            } label: {
                Label(message.raw["command"] as? String ?? "Bash", systemImage: "terminal")
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1)
            }.padding(.horizontal, 12).padding(.vertical, 5)
        }
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
