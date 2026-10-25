import XCTest
import SwiftUI
import AppKit
@testable import PiDesktop

@MainActor
private final class PaletteSequence: ObservableObject {
    @Published var query = ""
    @Published var filter: CommandFilter = .all
    @Published var commands = [
        PiCommand(name:"skill:ae-depth-video",description:"After Effects 视频",source:"skill"),
        PiCommand(name:"skill:huashu-design",description:"界面设计",source:"skill"),
        PiCommand(name:"skill:neat-freak",description:"知识文档整理",source:"skill")
    ]
}
private struct PaletteSequenceView: View {
    @ObservedObject var state: PaletteSequence
    @State private var selected = 0
    var body: some View {
        SlashPalette(query:state.query,matches:CommandSearch.matches(state.commands,query:state.query,filter:state.filter),selected:$selected,filter:$state.filter,allCommands:state.commands,maxHeight:320,refresh:{},pick:{_ in})
            .frame(width:490,height:320,alignment:.top)
            .transaction { $0.disablesAnimations = true }
    }
}

@MainActor
final class CommandRenderingTests: XCTestCase {
    private func makeHost(_ state: PaletteSequence) -> (NSWindow,NSHostingView<PaletteSequenceView>) {
        let host=NSHostingView(rootView:PaletteSequenceView(state:state))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:490,height:320),styleMask:[.borderless],backing:.buffered,defer:false)
        window.appearance=NSAppearance(named:.darkAqua)
        window.contentView=host;host.layoutSubtreeIfNeeded()
        return (window,host)
    }
    private func capture(_ host:NSView, name:String) throws -> Data {
        host.layoutSubtreeIfNeeded();host.display()
        let bitmap=try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        let png=try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
        let out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/test-artifacts")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        try png.write(to:out.appendingPathComponent(name+".png"))
        return png
    }
    func testChangingQueryRendersSameRowsAsFreshMatchingList() async throws {
        let state=PaletteSequence()
        let (window,host)=makeHost(state)
        defer { window.contentView=nil }
        try await Task.sleep(nanoseconds:50_000_000)
        _ = try capture(host,name:"command-sequence-initial")
        for (i,query) in ["n","ne","neat","","ae","neat","zz-no-match","neat"].enumerated() {
            state.query=query
            try await Task.sleep(nanoseconds:40_000_000)
            let actual=try capture(host,name:"command-sequence-\(i)")
            let reference=PaletteSequence();reference.query=query
            let (expectedWindow,expectedHost)=makeHost(reference)
            try await Task.sleep(nanoseconds:40_000_000)
            let expected=try capture(expectedHost,name:"command-reference-\(i)")
            expectedWindow.contentView=nil
            XCTAssertEqual(actual,expected,"Visible rows after '\(query)' must match a fresh list; count alone is insufficient")
        }
    }
    func testRefreshAndCategorySwitchReplaceVisibleRows() async throws {
        let state=PaletteSequence();state.query="neat"
        let (window,host)=makeHost(state)
        defer { window.contentView=nil }
        try await Task.sleep(nanoseconds:40_000_000)
        _ = try capture(host,name:"command-refresh-before")
        for (index,filter) in [CommandFilter.skill,.extensions,.all].enumerated() {
            state.filter=filter
            state.commands[2].description="目录刷新后的真实描述 \(index)"
            state.commands.reverse()
            try await Task.sleep(nanoseconds:40_000_000)
            let actual=try capture(host,name:"command-refresh-\(index)")
            let reference=PaletteSequence();reference.query=state.query;reference.filter=filter;reference.commands=state.commands
            let (expectedWindow,expectedHost)=makeHost(reference)
            try await Task.sleep(nanoseconds:40_000_000)
            let expected=try capture(expectedHost,name:"command-refresh-reference-\(index)")
            expectedWindow.contentView=nil
            XCTAssertEqual(actual,expected,"Refresh/reorder/category changes must replace visible labels and keep the count consistent")
        }
    }

}
