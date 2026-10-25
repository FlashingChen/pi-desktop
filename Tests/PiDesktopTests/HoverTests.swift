import XCTest
import SwiftUI
import AppKit
@testable import PiDesktop

@MainActor
final class HoverTests: XCTestCase {
    /// Use AppKit's public pointer-enter/exit entry points on the real hosted tracking
    /// view. Offscreen windows do not receive the WindowServer's global mouse moves.
    func testPointerEntryRendersHoverAndExitRestoresSurface() async throws {
        try await verifyHover(enabled:true)
    }
    func testDisabledButtonDoesNotHighlightOnPointerEntry() async throws {
        try await verifyHover(enabled:false)
    }
    private func verifyHover(enabled:Bool) async throws {
        var activations=0
        let view=NSHostingView(rootView:Button("Hover target") { activations += 1 }
            .buttonStyle(PiButtonStyle()).disabled(!enabled)
            .frame(width:180,height:70).background(Theme.canvas))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:180,height:70),styleMask:[.borderless],backing:.buffered,defer:false)
        window.contentView=view; view.frame=NSRect(x:0,y:0,width:180,height:70)
        view.layoutSubtreeIfNeeded(); view.display()
        try await Task.sleep(nanoseconds:150_000_000)
        func trackers(_ root:NSView) -> [HoverTrackingView] {
            (root as? HoverTrackingView).map { [$0] } ?? root.subviews.flatMap(trackers)
        }
        let tracking=try XCTUnwrap(trackers(view).first,"The actual control needs a native tracking region")
        XCTAssertNil(tracking.hitTest(.zero),"Hover tracking must not consume clicks")
        func capture() -> Data {
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            return bitmap.representation(using:.png,properties:[:])!
        }
        func event(_ type:NSEvent.EventType) -> NSEvent {
            NSEvent.enterExitEvent(with:type,location:NSPoint(x:90,y:35),modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,trackingNumber:0,userData:nil)!
        }
        let before=capture()
        tracking.mouseEntered(with:event(.mouseEntered))
        try await Task.sleep(nanoseconds:250_000_000)
        let hovered=capture()
        if enabled { XCTAssertNotEqual(before,hovered,"Pointer entry must visibly highlight enabled controls") }
        else { XCTAssertEqual(before,hovered,"Disabled controls must not pretend to be interactive") }
        tracking.mouseExited(with:event(.mouseExited))
        try await Task.sleep(nanoseconds:250_000_000)
        XCTAssertEqual(before,capture(),"Pointer exit must restore the resting surface")
        XCTAssertEqual(activations,0,"Hover must never activate a button")
        let out=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/test-artifacts")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        if enabled {
            try before.write(to:out.appendingPathComponent("hover-control-rest.png"))
            try hovered.write(to:out.appendingPathComponent("hover-control-active.png"))
        }
        window.contentView=nil
    }
}
