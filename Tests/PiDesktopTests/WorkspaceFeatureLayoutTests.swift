import XCTest
import SwiftUI
import AppKit
@testable import PiDesktop

@MainActor
final class WorkspaceFeatureLayoutTests:XCTestCase {
    private func snapshot<V:View>(_ view:V,size:NSSize,name:String) async throws {
        let host=NSHostingView(rootView:view.environment(\.colorScheme,.dark))
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:.darkAqua);window.contentView=host
        host.frame=NSRect(origin:.zero,size:size);host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds:200_000_000)
        host.layoutSubtreeIfNeeded();host.display()
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".impeccable/review")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        try png.write(to:out.appendingPathComponent(name+".png"))
        XCTAssertGreaterThan(png.count,2000)
        window.contentView=nil
    }
    func testNewWorkspaceSurfacesFitNativeWindows() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("pi-layout-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root.appendingPathComponent("Sources"),withIntermediateDirectories:true)
        try Data("# Native fixture\n".utf8).write(to:root.appendingPathComponent("README.md"))
        let models=root.appendingPathComponent("models.json")
        try NativeModelConfiguration.write(.init(provider:"local",baseURL:"http://localhost",modelID:"fixture-model",name:"本地模型"),to:models,expected:nil)
        let model=AppModel();model.project=Project(path:root.path)
        model.sessionName="整理项目文档";model.renameTarget=PiSession(path:"/fixture/session.jsonl",title:model.sessionName,date:Date())
        try await snapshot(ModelConfigurationView(configurationURL:models).environmentObject(model).padding(24).background(Theme.canvas),size:NSSize(width:640,height:650),name:"native-model-configuration-fixture")
        try await snapshot(WorkspaceFileBrowser(root:root,preview:{_ in}).background(Theme.sidebar),size:NSSize(width:238,height:640),name:"native-file-browser-fixture")
        try await snapshot(RenameSessionView().environmentObject(model).background(Theme.canvas),size:NSSize(width:450,height:180),name:"native-rename-fixture")
        let messages=(0..<12).flatMap { index in [
            DisplayMessage.from(["role":"assistant","content":[["type":"toolCall","id":"call-\(index)","name":"bash","arguments":["command":["swift test --filter CoreTests","rg SessionIndex Sources","git diff --check"][index % 3]]]]],index:index*2),
            DisplayMessage.from(["role":"toolResult","toolCallId":"call-\(index)","toolName":"bash","content":[["type":"text","text":"Fixture output"]]],index:index*2+1)
        ] }
        try await snapshot(ExecutionGroup(messages:messages,done:true,initiallyExpanded:true).environmentObject(model).padding(24).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading).background(Theme.canvas),size:NSSize(width:820,height:460),name:"native-compact-execution-fixture")
        await model.shutdown()
    }
}
