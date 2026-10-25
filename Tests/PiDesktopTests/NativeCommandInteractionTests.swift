import XCTest
import AppKit
import SwiftUI
@testable import PiDesktop

@MainActor
final class NativeCommandInteractionTests: XCTestCase {
    private func input(in view: NSView) -> InputTextView? {
        if let input = view as? InputTextView { return input }
        return view.subviews.compactMap { input(in:$0) }.first
    }
    func testCompletionActuallyInsertsCanonicalSkillAndMovesCaretToEnd() async throws {
        let model=AppModel(), project=Project(path:"/tmp/pi-command-interaction-fixture")
        model.projects=[project];model.project=project;model.connected=true
        model.commands=[PiCommand(name:"skill:neat-freak",description:"知识文档整理",source:"skill",sourcePath:"/native/skills/neat-freak/SKILL.md")]
        model.draft="/neat"
        let host=NSHostingView(rootView:RootView().environmentObject(model))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=host;host.layoutSubtreeIfNeeded()
        let editor=try XCTUnwrap(input(in:host))
        XCTAssertTrue(window.makeFirstResponder(editor))
        try await Task.sleep(nanoseconds:100_000_000)
        let tab=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\t",charactersIgnoringModifiers:"\t",isARepeat:false,keyCode:48))
        editor.keyDown(with:tab)
        try await Task.sleep(nanoseconds:100_000_000)
        XCTAssertEqual(model.draft,"/skill:neat-freak ")
        XCTAssertEqual(editor.string,model.draft)
        XCTAssertEqual(editor.selectedRange().location,(model.draft as NSString).length)
        XCTAssertFalse(model.busy,"Completing a Skill never sends a model prompt")
        model.draft="/neat"
        try await Task.sleep(nanoseconds:50_000_000)
        let escape=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:53))
        editor.keyDown(with:escape)
        XCTAssertEqual(model.draft,"/neat")
        window.orderOut(nil);window.contentView=nil;await model.shutdown()
    }

    func testOptInLivePiCatalogueMatchesGUIAndFindsNeatFreak() async throws {
        guard ProcessInfo.processInfo.environment["PI_NATIVE_CATALOGUE_AUDIT"] == "1" else { throw XCTSkip("Opt-in installed Pi audit, no provider requests") }
        let model=AppModel(), project=Project(path:FileManager.default.currentDirectoryPath)
        model.projects=[project]
        await model.selectProject(project)
        XCTAssertTrue(model.connected)
        await model.refreshCommands()
        let response=try await model.connection.request("get_commands")
        let actual=(response["commands"] as? [[String:Any]] ?? []).compactMap(PiCommand.init)
        XCTAssertEqual(model.commands.map(\.id).sorted(),actual.map(\.id).sorted(),"GUI must show the actual RPC catalogue without mock entries or dropped Skills")
        let neat=try XCTUnwrap(CommandSearch.matches(model.commands,query:"/neat").first)
        XCTAssertEqual(neat.name,"skill:neat-freak")
        XCTAssertEqual(neat.source,"skill")
        XCTAssertTrue(neat.sourcePath.hasSuffix("neat-freak/SKILL.md"))
        print("LIVE_CATALOGUE commands=\(actual.count) skills=\(actual.filter{$0.source == "skill"}.count) neat=\(neat.name) source=\(neat.sourcePath)")
        var timings=[Double]()
        for _ in 0..<20 {
            for query in ["", "n", "ne", "nea", "neat", "neat-", "neat-freak"] {
                let started=Date()
                _ = model.commandIndex.matches(query:query)
                timings.append(Date().timeIntervalSince(started)*1000)
            }
        }
        let p95=timings.sorted()[Int(Double(timings.count)*0.95)]
        print("LIVE_SEARCH_LATENCY samples=\(timings.count) p95_ms=\(p95)")
        XCTAssertLessThan(p95,16)

        model.draft="/neat"
        let host=NSHostingView(rootView:RootView().environmentObject(model).environment(\.colorScheme,.dark))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:800),styleMask:[.borderless],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:.darkAqua)
        window.contentView=host;host.layoutSubtreeIfNeeded()
        window.makeFirstResponder(try XCTUnwrap(input(in:host)))
        try await Task.sleep(nanoseconds:200_000_000)
        host.layoutSubtreeIfNeeded();host.display()
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/test-artifacts/native-live-neat-completion.png")
        try png.write(to:out)
        window.orderOut(nil);window.contentView=nil;await model.shutdown()
    }
}
