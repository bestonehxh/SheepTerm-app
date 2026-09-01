import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Glassy macOS-style modal used for SSH username/password prompts.
/// Runs a modal session so the SSH worker thread can block on the answer.
enum AuthPrompt {
    @MainActor
    static func ask(prompt: String, secure: Bool) -> String? {
        final class Box {
            var value: String?
        }
        let box = Box()

        // Credentials are ASCII — force-switch the keyboard to an
        // English-capable layout so Thai input never gets in the way.
        forceASCIIKeyboard()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 280),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }

        let root = AuthPromptView(prompt: prompt, secure: secure) { value in
            box.value = value
            NSApp.stopModal()
        }
        let hosting = NSHostingView(rootView: root)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)
        panel.center()

        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return box.value
    }

    @MainActor
    static func forceASCIIKeyboard() {
        if let source = TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue() {
            TISSelectInputSource(source)
        }
    }
}

struct AuthPromptView: View {
    let prompt: String
    let secure: Bool
    let completion: (String?) -> Void

    @State private var text = ""
    @State private var revealed = false
    /// Revealing swaps SecureField for TextField — two different views, so
    /// they cannot share one focus binding: the focus set on the old field
    /// dies with it and the caret vanishes (you type into nothing). Each
    /// field claims its own value instead, and the eye button re-aims the
    /// focus at whichever one is about to exist.
    private enum Field: Hashable {
        case secure, plain
    }
    @FocusState private var focusedField: Field?
    private var focused: Bool { focusedField != nil }
    /// Which field the current mode renders — the focus target.
    private var activeField: Field { secure && !revealed ? .secure : .plain }

    /// Recomputed from the current value — clears itself once the text is
    /// clean again, nothing latches.
    private var hasNonASCII: Bool {
        text.contains { !$0.isASCII }
    }

    var body: some View {
        VStack(spacing: 18) {
            SheepLockBadge()

            VStack(spacing: 4) {
                Text("SSH Authentication")
                    .font(.system(size: 15, weight: .semibold))
                Text(prompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 9) {
                Image(systemName: secure ? "key.fill" : "person.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(focused ? Theme.accent : Color.secondary)
                    .frame(width: 18)
                Group {
                    if secure && !revealed {
                        SecureField("Password", text: $text)
                            .focused($focusedField, equals: .secure)
                    } else {
                        TextField(secure ? "Password" : "Username", text: $text)
                            .focused($focusedField, equals: .plain)
                    }
                }
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit { completion(text) }
                if secure {
                    Button {
                        revealed.toggle()
                        // Aim at the field that is about to exist; it isn't
                        // installed yet in this runloop pass.
                        let target: Field = revealed ? .plain : .secure
                        DispatchQueue.main.async {
                            focusedField = target
                            moveCaretToEndOfFocusedField()
                        }
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(revealed ? "Hide password" : "Show password")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        focused ? Theme.accent.opacity(0.8) : Color.primary.opacity(0.14),
                        lineWidth: focused ? 1.5 : 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: focused)

            if hasNonASCII {
                // Same policy as RevealableSecureField: keep the pasted value
                // intact, just flag it — a silently mangled paste is
                // undebuggable.
                Text("Contains non-ASCII characters (passwords are ASCII only)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Button("Cancel") { completion(nil) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                Button(secure ? "Connect" : "Continue") { completion(text) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 350)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.06)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                )
        )
        .padding(10)
        .onAppear {
            AuthPrompt.forceASCIIKeyboard()
            let target = activeField
            DispatchQueue.main.async { focusedField = target }
        }
    }
}

/// Moves the caret to the END of the field that just took focus.
///
/// A field becoming first responder selects all of its text (standard
/// AppKit), so revealing a password and then typing one more character
/// wiped everything the user had entered. There is no SwiftUI API for the
/// selection, so reach for the field editor once the focus has actually
/// landed — two hops: one for SwiftUI to install the new field, one for
/// AppKit to make it first responder.
@MainActor
func moveCaretToEndOfFocusedField() {
    DispatchQueue.main.async {
        guard let editor = NSApp?.keyWindow?.firstResponder as? NSTextView else { return }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }
}
