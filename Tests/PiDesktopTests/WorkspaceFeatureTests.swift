import XCTest
import SwiftUI
import AppKit
@testable import PiDesktop

final class WorkspaceDataTests:XCTestCase {
    func testModelEditingPreservesCredentialsUnknownFieldsAndOtherModels() throws {
        let original:[String:Any] = ["unknown-root":"keep","providers":["custom":["api":"anthropic-messages","apiKey":"$EXISTING_KEY","headers":["X-Custom":"keep"],"models":[["id":"one","cost":["input":1,"output":2,"cacheRead":0,"cacheWrite":0],"compat":["supportsStore":false]],["id":"two","name":"Keep me"]]]]]
        let draft=ModelConfigurationDraft(provider:"custom",baseURL:"http://localhost",modelID:"one",name:"Updated model")
        let changed=try NativeModelConfiguration.saving(draft,into:original)
        let providers=try XCTUnwrap(changed["providers"] as? [String:[String:Any]])
        let provider=try XCTUnwrap(providers["custom"])
        XCTAssertEqual(provider["apiKey"] as? String,"$EXISTING_KEY")
        XCTAssertEqual(provider["api"] as? String,"anthropic-messages","Editing one model's API must not change the sibling models' inherited API")
        XCTAssertEqual((provider["headers"] as? [String:String])?["X-Custom"],"keep")
        let models=try XCTUnwrap(provider["models"] as? [[String:Any]])
        XCTAssertEqual(models.count,2);XCTAssertNotNil(models[0]["cost"]);XCTAssertNotNil(models[0]["compat"])
        XCTAssertEqual(models[1]["name"] as? String,"Keep me")
        XCTAssertEqual(changed["unknown-root"] as? String,"keep")
        XCTAssertTrue(NativeModelConfiguration.models(in:changed).allSatisfy { $0.apiKey.isEmpty },"Stored secrets must not be put into visible editor state")
    }
    func testModelFileWriteDetectsExternalChangesAndKeepsPrivatePermissions() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("models.json")
        let draft=ModelConfigurationDraft(provider:"local",baseURL:"http://localhost",apiKey:"$TEST_KEY",modelID:"fixture")
        try NativeModelConfiguration.write(draft,to:file,expected:nil)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        let snapshot=try Data(contentsOf:file)
        try Data("{\"changed\":true}".utf8).write(to:file)
        XCTAssertThrowsError(try NativeModelConfiguration.write(draft,to:file,expected:snapshot))
        XCTAssertEqual(String(decoding:try Data(contentsOf:file),as:UTF8.self),"{\"changed\":true}")
    }
    func testFileBrowserIsSortedHiddenAwareAndPreviewHandlesUnicodeBoundary() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("folder"),withIntermediateDirectories:true)
        try Data("hidden".utf8).write(to:root.appendingPathComponent(".hidden"))
        let file=root.appendingPathComponent("sample.txt")
        try Data(String(repeating:"中文🧪",count:40_000).utf8).write(to:file)
        let entries=try WorkspaceDirectory.list(root,hidden:false)
        XCTAssertEqual(entries.map(\.name),["folder","sample.txt"])
        XCTAssertEqual(try WorkspaceDirectory.list(root,hidden:true).count,3)
        let preview=try FilePreviewContents.read(file)
        XCTAssertTrue(preview.truncated);XCTAssertFalse(preview.text.isEmpty)
        XCTAssertTrue(preview.text.hasPrefix("中文🧪"))
    }
    func testSkillPromptTitlesDoNotExposeExpandedMarkup() {
        XCTAssertEqual(SessionTitle.fromPrompt("<skill name=\"neat-freak\" file=\"/tmp/SKILL.md\">\nlong content\n</skill>"),"/skill:neat-freak")
        XCTAssertEqual(SessionTitle.fromPrompt("<skill name=\"neat-freak\">content</skill>\n\n整理当前项目文档"),"整理当前项目文档")
        XCTAssertEqual(SessionTitle.fromPrompt("普通问题"),"普通问题")
    }
    func testExecutionRowShowsActualCommand() {
        let item=ExecutionRecord(id:"tool",kind:.tool(call:["name":"bash","arguments":["command":"swift test\necho done"]],result:nil))
        XCTAssertEqual(item.summary,"swift test")
    }
}

@MainActor
final class BackgroundRunTests:XCTestCase {
    func testSettingsAndFocusChangesKeepSameProcessStreamingAndDoNotAbort() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let oldExecutable=UserDefaults.standard.object(forKey:"piExecutable"),oldDirectory=UserDefaults.standard.object(forKey:"sessionDirectory")
        defer {
            try? FileManager.default.removeItem(at:root)
            UserDefaults.standard.set(oldExecutable,forKey:"piExecutable");UserDefaults.standard.set(oldDirectory,forKey:"sessionDirectory")
        }
        let script=root.appendingPathComponent("stream-fixture"),log=root.appendingPathComponent("requests.log")
        try """
        #!/usr/bin/env python3
        import sys,json,time,threading
        lock=threading.Lock();running=False;text=''
        def emit(p):
            with lock: print(json.dumps(p),flush=True)
        def run(p):
            global running,text
            running=True;emit({'type':'agent_start'})
            emit({'type':'message_start','message':{'role':'assistant','content':[]}})
            for i in range(25):
                text+='tick '
                emit({'type':'message_update','assistantMessageEvent':{'type':'text_delta','contentIndex':0,'delta':'tick '}})
                time.sleep(.04)
            running=False
            emit({'type':'agent_settled'})
            emit({'type':'response','id':p['id'],'success':True,'data':{}})
        for line in sys.stdin:
            p=json.loads(line);kind=p['type']
            with open('requests.log','a') as f: f.write(kind+'\\n')
            if kind=='prompt': threading.Thread(target=run,args=(p,),daemon=True).start();continue
            data={}
            if kind=='get_state': data={'isStreaming':running,'sessionFile':'/fixture/current.jsonl'}
            if kind=='get_messages': data={'messages':[{'role':'assistant','content':[{'type':'text','text':text}]}]}
            emit({'type':'response','id':p['id'],'success':True,'data':data})
        """.write(to:script,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
        let model=AppModel();model.project=Project(path:root.path);model.connected=true;model.sessionPath="/fixture/current.jsonl"
        try model.connection.start(environment:PiEnvironment(executable:script.path,variables:ProcessInfo.processInfo.environment),cwd:root.path,session:nil,continueRecent:false,sessionDirectory:"")
        let process=model.connection.processIdentifier
        let host=NSHostingView(rootView:RootView().environmentObject(model))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=host;host.layoutSubtreeIfNeeded()
        model.draft="fixture-only prompt"
        let sending=Task { await model.send() }
        try await Task.sleep(nanoseconds:160_000_000)
        XCTAssertTrue(model.busy);XCTAssertTrue(model.runActivity.active)
        let before=model.messages.last?.text.count ?? 0
        model.showSettings=true
        NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:NSApp)
        NotificationCenter.default.post(name:NSWindow.didResignKeyNotification,object:window)
        try await Task.sleep(nanoseconds:240_000_000)
        XCTAssertGreaterThan(model.messages.last?.text.count ?? 0,before,"Output must continue while settings are shown and focus is elsewhere")
        await model.saveSettings()
        model.renameSession()
        try await model.saveSessionName("后台任务会话")
        XCTAssertEqual(model.sessionName,"后台任务会话")
        await model.reconnect()
        await model.newSession()
        XCTAssertEqual(model.connection.processIdentifier,process)
        XCTAssertTrue(model.busy);XCTAssertTrue(model.runActivity.active)
        await sending.value
        try await Task.sleep(nanoseconds:120_000_000)
        XCTAssertFalse(model.busy);XCTAssertFalse(model.runActivity.active)
        let requests=try String(contentsOf:log,encoding:.utf8)
        XCTAssertFalse(requests.contains("abort"));XCTAssertFalse(requests.contains("new_session"))
        window.contentView=nil;await model.shutdown()
    }
}
