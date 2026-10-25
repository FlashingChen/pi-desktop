import XCTest
import Combine
import AppKit
import SwiftUI
@testable import PiDesktop

final class TurnGroupingTests: XCTestCase {
    func testOneGroupOneThoughtAndPairedToolForWholeUserTurn() {
        let messages: [DisplayMessage] = [
            .from(["role":"user","content":"Hi, where are you?"],index:0),
            .from(["role":"assistant","content":[["type":"thinking","thinking":"First reasoning"],["type":"toolCall","name":"bash","id":"call-1","arguments":["command":"pwd"]]]],index:1),
            .from(["role":"toolResult","toolCallId":"call-1","toolName":"bash","content":[["type":"text","text":"/native/project"]]],index:2),
            .from(["role":"assistant","content":[["type":"thinking","thinking":"Final reasoning"],["type":"text","text":"Here is the answer"]]],index:3)
        ]
        let rows = conversationRows(messages)
        XCTAssertEqual(rows.count,3)
        guard case .execution(let activity) = rows[1], case .message(let answer) = rows[2] else { return XCTFail("One activity group must precede the visible answer") }
        XCTAssertEqual(answer.text,"Here is the answer")
        let records = executionRecords(activity)
        XCTAssertEqual(records.map(\.label),["思考","bash"])
        guard case .thinking(let thoughts) = records[0].kind, case .tool(let call, let result) = records[1].kind else { return XCTFail("Expected one thought and one paired tool") }
        XCTAssertEqual(thoughts.count,2)
        XCTAssertEqual(call?["id"] as? String,"call-1")
        XCTAssertEqual(result?.text,"/native/project")
        XCTAssertEqual(executionRecords([messages[2]]).count,1,"A missing call must not hide an orphan result")
    }
    func testDistinctUserTurnsKeepDistinctExecutionGroups() {
        let messages = (0..<2).flatMap { turn in [
            DisplayMessage.from(["role":"user","content":"Question \(turn)"],index:turn*2),
            DisplayMessage.from(["role":"assistant","content":[["type":"thinking","thinking":"Reasoning"],["type":"text","text":"Answer"]]],index:turn*2+1)
        ] }
        XCTAssertEqual(conversationRows(messages).filter { if case .execution = $0 {return true};return false }.count,2)
    }
    func testTwoCallsOfSameToolStayDistinctByID() {
        let messages = [DisplayMessage.from(["role":"assistant","content":[["type":"toolCall","name":"read","id":"a"],["type":"toolCall","name":"read","id":"b"]]],index:0)]
        let records=executionRecords(messages)
        XCTAssertEqual(records.count,2)
        XCTAssertNotEqual(records[0].id,records[1].id)
    }
}

final class CommandCatalogueTests: XCTestCase {
    func testSkillsAreSearchableByShortAndCanonicalNameAndKeepTheirOrigin() throws {
        let neat=try XCTUnwrap(PiCommand(["name":"skill:neat-freak","description":"知识文档整理","source":"skill","sourceInfo":["path":"/native/skills/neat-freak/SKILL.md","source":"auto"]]))
        let foreign=PiCommand(name:"workflow",description:"A package command",source:"extension",sourcePath:"/native/package/workflow.ts",package:"npm:pi-dynamic-workflows")
        let commands=[foreign,neat]
        for query in ["neat","/neat-freak","/skill:neat","skill:neat-freak","知识"] {
            XCTAssertEqual(CommandSearch.matches(commands,query:query).first?.name,"skill:neat-freak")
        }
        XCTAssertEqual(CommandSearch.matches(commands,query:"",filter:.skill).map(\.name),["skill:neat-freak"])
        XCTAssertEqual(CommandSearch.matches(commands,query:"").first?.name,"skill:neat-freak")
        XCTAssertEqual(neat.sourcePath,"/native/skills/neat-freak/SKILL.md")
        XCTAssertEqual(foreign.originLabel,"pi-dynamic-workflows")
    }
    func testSourceIdentityDoesNotHideCollidingInvocationNames() {
        let a=PiCommand(name:"review",description:"",source:"extension")
        let b=PiCommand(name:"review",description:"",source:"prompt")
        XCTAssertNotEqual(a.id,b.id)
        XCTAssertEqual(CommandSearch.matches([a,b],query:"review").count,2)
    }
}

@MainActor
final class TypingIsolationTests: XCTestCase {
    func testTypingDoesNotPublishWholeConversationAndKeepsSendStateCurrent() async {
        let model=AppModel();model.connected=true
        var rootNotifications=0, editorNotifications=0
        let root=model.objectWillChange.sink { rootNotifications += 1 }
        let editor=model.draftBuffer.objectWillChange.sink { editorNotifications += 1 }
        for _ in 0..<100 { model.draft += "字" }
        XCTAssertEqual(rootNotifications,0,"Typing must not re-render history, regroup tools or parse Markdown")
        XCTAssertEqual(editorNotifications,100)
        XCTAssertTrue(model.canSend)
        model.draft=""
        XCTAssertFalse(model.canSend)
        withExtendedLifetime((root,editor)) {}
        await model.shutdown()
    }
}

final class CommandSearchLatencyTests: XCTestCase {
    func testIndexedSearchStaysSynchronousForLargeCatalogue() {
        var commands=(0..<1000).map { PiCommand(name:"skill:example-\($0)",description:String(repeating:"Long native skill description. ",count:25),source:"skill") }
        commands.append(PiCommand(name:"skill:neat-freak",description:"知识文档整理",source:"skill"))
        let index=CommandSearchIndex(commands)
        let queries=["", "n", "ne", "nea", "neat", "neat-", "neat-freak"]
        // Warm up allocation caches so the first samples do not dominate the percentile.
        for _ in 0..<3 { for query in queries { _ = index.matches(query:query) } }
        var samples=[Double]()
        for _ in 0..<20 {
            for query in queries {
                let start=Date()
                let matches=index.matches(query:query)
                samples.append(Date().timeIntervalSince(start)*1000)
                XCTAssertTrue(matches.contains { $0.name == "skill:neat-freak" })
            }
        }
        let sorted=samples.sorted(),p95=sorted[Int(Double(sorted.count)*0.95)]
        // 16 ms is one 60 Hz frame on the machine actually running the app. Shared CI
        // runners are virtualized and materially slower, so they only guard against
        // order-of-magnitude regressions rather than pretending to measure frame pacing.
        let budget = ProcessInfo.processInfo.environment["CI"] == nil ? 16.0 : 150.0
        print("COMMAND_SEARCH_LATENCY count=1001 samples=\(samples.count) p95_ms=\(p95) budget_ms=\(budget)")
        XCTAssertLessThan(p95,budget,"Local filtering must stay within the frame budget for the measured environment")
    }
}
