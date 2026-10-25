import SwiftUI
import AppKit

/// One state system for quiet toolbar controls, sidebar rows and primary actions.
/// The native Button still owns activation, shortcuts, accessibility and disabled semantics.
struct PiButtonStyle: ButtonStyle {
    enum Kind { case quiet, row, accent }
    var kind: Kind = .quiet
    var selected = false
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 6

    func makeBody(configuration: Configuration) -> some View {
        ButtonSurface(configuration: configuration, kind: kind, selected: selected,
                      horizontalPadding: horizontalPadding, verticalPadding: verticalPadding)
    }
    private struct ButtonSurface: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let selected: Bool
        let horizontalPadding: CGFloat
        let verticalPadding: CGFloat
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false
        private var background: Color {
            if kind == .accent {
                if !enabled { return Theme.accent.opacity(0.32) }
                return configuration.isPressed ? Theme.accentPressed : hovering ? Theme.accentHover : Theme.accent
            }
            if configuration.isPressed && enabled { return Theme.controlPressed }
            if selected { return hovering && enabled ? Theme.selectionHover : Theme.selection }
            return hovering && enabled ? Theme.controlHover : .clear
        }
        var body: some View {
            configuration.label
                .padding(.horizontal, horizontalPadding).padding(.vertical, verticalPadding)
                .foregroundStyle(kind == .accent ? Theme.onAccent : enabled ? Theme.text : Theme.secondary)
                .background(background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused && enabled ? Theme.focus : .clear, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .opacity(enabled || kind == .accent ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && enabled && !reduceMotion && kind != .row ? 0.97 : 1)
                .nativeHover { hovering = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// Menus keep the native macOS implementation while gaining the same hover surface.
private struct ControlHover: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering && enabled ? Theme.controlHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .nativeHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
    }
}
/// AppKit tracking keeps hover reliable in nested native views and during drag entry.
/// The tracking view never participates in hit testing, so it cannot consume clicks.
struct NativeHoverArea: NSViewRepresentable {
    var onChange: (Bool) -> Void
    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView(); view.onChange = onChange; return view
    }
    func updateNSView(_ view: HoverTrackingView, context: Context) { view.onChange = onChange }
}
final class HoverTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag], owner: self)
        addTrackingArea(area!)
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}
extension View {
    func nativeHover(_ onChange: @escaping (Bool) -> Void) -> some View {
        background(NativeHoverArea(onChange: onChange))
    }
    func controlHover() -> some View { modifier(ControlHover()) }
}

struct PiDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label
                    Spacer(minLength: 0)
                }.padding(.horizontal, 7).frame(minHeight: 29).frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(PiButtonStyle(kind: .row, horizontalPadding: 0, verticalPadding: 0))
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已折叠")
            if configuration.isExpanded {
                configuration.content.padding(.leading, 24).padding(.top, 7).padding(.bottom, 5)
            }
        }
    }
}

struct CopyControl: View {
    let text: String
    let help: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11)).frame(width: 16, height: 16)
                .foregroundStyle(copied ? Theme.success : Theme.secondary)
        }
        .buttonStyle(PiButtonStyle(horizontalPadding: 5, verticalPadding: 5))
        .help(copied ? "已复制" : help)
        .accessibilityLabel(copied ? "已复制" : help)
    }
}
