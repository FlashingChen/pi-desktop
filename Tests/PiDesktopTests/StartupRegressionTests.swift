import XCTest
import AppKit
import SwiftUI
@testable import PiDesktop

final class HistoryRegressionTests: XCTestCase {
    func testMultiMegabyteHistoryIsLinearAcrossPipeChunks() throws {
        let text = String(repeating: "中文🧪 abcdefgh\n", count: 220_000)
        let bytes = try JSONSerialization.data(withJSONObject: ["type":"response", "id":"large", "data":["text":text]]) + Data([10])
        let decoder = JSONLDecoder()
        var records: [[String: Any]] = []
        let start = Date()
        for offset in stride(from: 0, to: bytes.count, by: 8192) {
            records += decoder.append(bytes.subdata(in: offset..<min(offset + 8192, bytes.count)))
        }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual((records[0]["data"] as? [String: Any])?["text"] as? String, text)
        // A generous ceiling, roughly an order of magnitude over normal local runs.
        // The old accumulated-buffer scan takes seconds on this exact workload.
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }
    func testMixedAssistantMessageKeepsProseOutsideExecution() {
        let message = DisplayMessage.from(["role":"assistant", "content":[
            ["type":"thinking", "thinking":"private reasoning"],
            ["type":"text", "text":"I will inspect the entry point."],
            ["type":"toolCall", "name":"read", "id":"tool", "arguments":["path":"main.swift"]]
        ]], index: 0)
        let rows = conversationRows([message])
        XCTAssertEqual(rows.count, 2)
        guard case .execution(let execution) = rows[0], case .message(let prose) = rows[1] else { return XCTFail("Expected visible prose and a separate execution group") }
        XCTAssertEqual(prose.text, "I will inspect the entry point.")
        XCTAssertEqual(prose.blocks.count, 1)
        XCTAssertEqual(executionRecords(execution).map(\.label), ["思考", "read"])
    }
}

@MainActor
final class StartupRegressionTests: XCTestCase {
    func testDraftSurvivesConnectionAndOptionalDiscoveryFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("pi-fixture")
        try """
        #!/usr/bin/env python3
        import sys,json,time
        for line in sys.stdin.buffer:
            p=json.loads(line); kind=p['type']; data={}
            if kind=='get_state':
                time.sleep(.2)
                data={'sessionFile':'/native/fixture.jsonl','sessionName':'Fixture'}
            elif kind=='get_messages': data={'messages':[{'role':'user','content':'Stored native history'}]}
            elif kind=='get_available_models':
                print(json.dumps({'type':'response','id':p['id'],'success':False,'error':'Unavailable optional discovery'}),flush=True)
                continue
            elif kind=='get_commands': data={'commands':[{'name':'example','description':'Fixture command'}]}
            print(json.dumps({'type':'response','id':p['id'],'success':True,'data':data}),flush=True)
        """.write(to:script,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        let model = AppModel()
        model.executableOverride = script.path
        let task = Task { await model.selectProject(Project(path:root.path)) }
        try await Task.sleep(nanoseconds:50_000_000)
        XCTAssertNotNil(model.project, "Project and editor must be available before Pi responds")
        XCTAssertTrue(model.connecting)
        model.draft = "Typed while Pi connects"
        await task.value
        XCTAssertTrue(model.connected)
        XCTAssertTrue(model.canSend)
        XCTAssertEqual(model.draft, "Typed while Pi connects")
        XCTAssertEqual(model.messages.first?.text, "Stored native history")
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertNil(model.error, "Optional model discovery cannot fail a ready session")
        XCTAssertEqual(model.commands.first?.name, "example")
        await model.shutdown()
    }

    func testNativeInputReceivesCompletionKeys() async throws {
        var sent = 0, keys = [UInt16]()
        let host = NSHostingView(rootView: MessageInput(text:.constant("/"),focused:.constant(false),onSend:{sent += 1},onSlashKey:{keys.append($0.keyCode);return true}))
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:100),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func input(in view: NSView) -> InputTextView? {
            if let input = view as? InputTextView { return input }
            return view.subviews.compactMap { input(in:$0) }.first
        }
        let text = try XCTUnwrap(input(in:host))
        for code: UInt16 in [125,126,48,36,53] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:code))
            text.keyDown(with:event)
        }
        XCTAssertEqual(keys,[125,126,48,36,53])
        XCTAssertEqual(sent,0,"Return must complete a command before sending")
        window.contentView = nil
    }
}
