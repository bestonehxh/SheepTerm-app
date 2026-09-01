import AppKit
import SwiftUI

/// Password field with an eye button to reveal/hide what's typed.
struct RevealableSecureField: View {
    let title: String
    @Binding var text: String
    @State private var revealed = false
    /// Same reason as AuthPromptView: SecureField and TextField are two
    /// different views, so one shared focus binding is lost the moment the
    /// eye button swaps them. Each claims its own value.
    private enum Field: Hashable {
        case secure, plain
    }
    @FocusState private var focusedField: Field?

    /// Recomputed from the current value, so the warning clears itself as
    /// soon as the text is clean again — nothing latches.
    private var hasNonASCII: Bool {
        text.contains { !$0.isASCII }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Group {
                    if revealed {
                        TextField(title, text: $text)
                            .focused($focusedField, equals: .plain)
                    } else {
                        SecureField(title, text: $text)
                            .focused($focusedField, equals: .secure)
                    }
                }
                .onChange(of: focusedField) {
                    if focusedField != nil {
                        AuthPrompt.forceASCIIKeyboard()
                    }
                }
                Button {
                    revealed.toggle()
                    let target: Field = revealed ? .plain : .secure
                    DispatchQueue.main.async {
                        focusedField = target
                        moveCaretToEndOfFocusedField()
                    }
                } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(revealed ? "Hide password" : "Show password")
            }
            if hasNonASCII {
                // The value is kept as pasted — only warned about, never
                // silently mangled.
                Text("Contains non-ASCII characters (passwords are ASCII only)")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// The auth dialog badge: SheepTerm's sheep face guarded by a little lock.
struct SheepLockBadge: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0.9), Theme.accent.opacity(0.45)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 60, height: 60)
                .shadow(color: Theme.accent.opacity(0.35), radius: 10, y: 4)

            // mini sheep face (same DNA as the app icon)
            ZStack {
                Circle()
                    .fill(Color(red: 0.96, green: 0.95, blue: 0.92))
                    .frame(width: 42, height: 42)
                Ellipse()
                    .fill(Color(red: 0.97, green: 0.91, blue: 0.83))
                    .frame(width: 30, height: 26)
                    .offset(y: 1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .black))
                    .foregroundStyle(Color(red: 0.16, green: 0.15, blue: 0.13))
                    .offset(x: -5, y: 0)
                Capsule()
                    .fill(Color(red: 0.16, green: 0.15, blue: 0.13))
                    .frame(width: 9, height: 2.5)
                    .offset(x: 1, y: 8)
            }

            // lock badge
            ZStack {
                Circle()
                    .fill(Color(red: 0.11, green: 0.12, blue: 0.16))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                Image(systemName: "lock.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(red: 0.99, green: 0.85, blue: 0.45))
            }
            .offset(x: 21, y: 21)
        }
    }
}
