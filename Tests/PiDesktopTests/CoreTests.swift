import XCTest
@testable import PiDesktop

final class CoreTests: XCTestCase {
    func testFramingPreservesUnicodeAndSplitUTF8() throws {
        let decoder = JSONLDecoder()
        let object: [String: Any] = ["type": "test", "text": "你好\u{2028}a\u{2029}b\nnext"]
        let bytes = try JSONSerialization.data(withJSONObject: object) + Data([13, 10])
        var records: [[String: Any]] = []
        for byte in bytes { records += decoder.append(Data([byte])) }
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0]["text"] as? String, object["text"] as? String)
        XCTAssertEqual(decoder.append(Data("{\"a\":1}\n{\"b\":2}\n".utf8)).count, 2)
    }
    func testNativeSessionMetadataAndCwdIsolation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = "/Users/test/A project"
        let header = "{\"type\":\"session\",\"version\":3,\"id\":\"a\",\"cwd\":\"\(project)\"}\n"
        let history = header + "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"First prompt\"}]}}\n{\"type\":\"session_info\",\"name\":\"Native name\"}\n{partial"
        let file = root.appendingPathComponent("session.jsonl")
        try Data(history.utf8).write(to: file)
        let before = try Data(contentsOf: file)
        let sessions = SessionIndex.list(project: project, environment: [:], override: root.path)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Native name")
        XCTAssertTrue(SessionIndex.list(project: "/other", environment: [:], override: root.path).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), before, "Index must never modify a Pi session")
    }
    func testDefaultAndEnvironmentSessionLocations() {
        let urls = SessionIndex.directories(project: "/Users/test/repo", environment: ["PI_CODING_AGENT_DIR": "/tmp/custom-agent"], override: "")
        XCTAssertEqual(urls[0].path, "/tmp/custom-agent/sessions/--Users-test-repo--")
        let env = SessionIndex.directories(project: "/Users/test/repo", environment: ["PI_CODING_AGENT_SESSION_DIR": "/tmp/explicit"], override: "")
        XCTAssertEqual(env[0].path, "/tmp/explicit")
    }
    func testDisplayMessageDoesNotLoseImagesOrThinking() {
        let message = DisplayMessage.from(["role": "assistant", "timestamp": 3, "content": [["type": "thinking", "thinking": "reason"], ["type": "text", "text": "answer"], ["type": "image", "data": "AA=="]]], index: 0)
        XCTAssertEqual(message.blocks.count, 3)
        XCTAssertEqual(message.text, "answer")
    }
}

@MainActor
final class ConnectionTests: XCTestCase {
    func testResponsesAreCorrelatedAndProcessOwnershipIsReleased() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("pi-fixture")
        let source = """
        #!/usr/bin/env python3
        import sys, json
        pending = []
        for line in sys.stdin.buffer:
            p = json.loads(line)
            if p['type'] == 'fail':
                print(json.dumps({'type':'response','id':p['id'],'success':False,'error':'fixture failure'}), flush=True)
                continue
            pending.append(p)
            if len(pending) == 2:
                for q in reversed(pending):
                    print(json.dumps({'type':'response','id':q['id'],'success':True,'data':{'echo':q['type']}}), flush=True)
                pending = []
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let connection = PiConnection()
        let environment = PiEnvironment(executable: script.path, variables: ProcessInfo.processInfo.environment)
        try connection.start(environment: environment, cwd: root.path, session: nil, continueRecent: false, sessionDirectory: "")
        async let first = connection.request("one")
        async let second = connection.request("two")
        let (a,b) = try await (first,second)
        XCTAssertEqual(a["echo"] as? String, "one")
        XCTAssertEqual(b["echo"] as? String, "two")
        do { _ = try await connection.request("fail"); XCTFail("Expected Pi error") }
        catch { XCTAssertEqual(error.localizedDescription, "fixture failure") }
        await connection.stop()
        XCTAssertFalse(connection.running)
        try connection.start(environment: environment, cwd: root.path, session: nil, continueRecent: false, sessionDirectory: "")
        await connection.stop()
        XCTAssertFalse(connection.running)
    }
}

@MainActor
final class SessionSwitchTests: XCTestCase {
    func testExtensionCancellationKeepsCurrentConversation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("pi-fixture")
        try """
        #!/usr/bin/env python3
        import sys,json
        for line in sys.stdin.buffer:
            p=json.loads(line)
            print(json.dumps({'type':'response','id':p['id'],'success':True,'data':{'cancelled':True}}),flush=True)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let model = AppModel()
        model.project = Project(path: root.path)
        model.connected = true
        model.sessionPath = "/native/current.jsonl"
        model.sessionName = "Current"
        model.messages = [.from(["role":"user","content":"Keep this history"],index:0)]
        try model.connection.start(environment: PiEnvironment(executable: script.path, variables: ProcessInfo.processInfo.environment), cwd: root.path, session: nil, continueRecent: false, sessionDirectory: "")
        await model.newSession()
        XCTAssertEqual(model.sessionName,"Current")
        XCTAssertEqual(model.messages.first?.text,"Keep this history")
        await model.switchSession(PiSession(path:"/native/other.jsonl",title:"Other",date:Date()),in:model.project!)
        XCTAssertEqual(model.sessionPath,"/native/current.jsonl")
        XCTAssertEqual(model.messages.first?.text,"Keep this history")
        await model.shutdown()
    }
}

@MainActor
final class DraftTests: XCTestCase {
    func testUnsentTextAndImagesSurviveSessionRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("pi-fixture")
        try """
        #!/usr/bin/env python3
        import sys,json
        current='/native/original.jsonl'
        for line in sys.stdin.buffer:
            p=json.loads(line); t=p['type']; data={}
            if t=='new_session': current='/native/new.jsonl'; data={'cancelled':False}
            elif t=='switch_session': current=p['sessionPath']; data={'cancelled':False}
            elif t=='get_state': data={'sessionFile':current,'sessionName':'Fixture','isStreaming':False}
            elif t=='get_messages': data={'messages':[]}
            elif t=='get_available_models': data={'models':[]}
            elif t=='get_commands': data={'commands':[]}
            elif t=='get_available_thinking_levels': data={'levels':['off']}
            print(json.dumps({'type':'response','id':p['id'],'success':True,'data':data}),flush=True)
        """.write(to:script,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        let model=AppModel(), folder=Project(path:root.path)
        model.projects=[folder]; model.project=folder; model.connected=true
        model.sessionPath="/native/original.jsonl"
        model.draft="Unsent work"
        let image=ImageAttachment(name:"fixture.png",data:Data([1,2,3]),mime:"image/png")
        model.attachments=[image]
        try model.connection.start(environment:PiEnvironment(executable:script.path,variables:ProcessInfo.processInfo.environment),cwd:root.path,session:nil,continueRecent:false,sessionDirectory:"")
        await model.newSession()
        XCTAssertTrue(model.draft.isEmpty)
        XCTAssertTrue(model.attachments.isEmpty)
        await model.switchSession(PiSession(path:"/native/original.jsonl",title:"Fixture",date:Date()),in:folder)
        XCTAssertEqual(model.draft,"Unsent work")
        XCTAssertEqual(model.attachments.first?.data,image.data)
        await model.shutdown()
    }
}
