import AppKit
import SwiftTerm
import SwiftUI

/// Hosts any SwiftTerm TerminalView (local pty or SSH) and keeps it focused
/// while its tab is active.
struct TerminalViewRepresentable: NSViewRepresentable {
    let terminalView: TerminalView
    let isActive: Bool

    func makeNSView(context: Context) -> TerminalView {
        terminalView
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        if isActive {
            DispatchQueue.main.async {
                guard let window = view.window, window.firstResponder !== view else { return }
                // A focused text field (sidebar search, sheets) owns an
                // NSTextView field editor — never yank its focus away just
                // because a @Published change re-ran this update.
                guard !(window.firstResponder is NSTextView) else { return }
                // Same for the sidebar outline. It handles Return-to-connect,
                // which was unreachable in practice: any @Published change —
                // and selecting a row causes several — stole focus back here
                // before the key could arrive.
                guard !(window.firstResponder is NSOutlineView) else { return }
                window.makeFirstResponder(view)
            }
        }
    }
}
