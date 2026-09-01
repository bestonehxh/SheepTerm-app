import AppKit
import SwiftUI
import SwiftTerm

/// A complete terminal color scheme: background, default text, ANSI 16.
struct TerminalTheme: Identifiable {
    let id: String
    let name: String
    let background: UInt32
    let foreground: UInt32
    let ansi: [UInt32]
}

enum Theme {
    // MARK: Terminal themes

    static let terminalThemes: [TerminalTheme] = [
        TerminalTheme(
            id: "sheepterm", name: "SheepTerm",
            background: 0x15171C, foreground: 0xD6DAE2,
            ansi: [0x1C1F26, 0xED7A7A, 0x7DD98C, 0xE8D06B, 0x6CA9E0, 0xE08BC7, 0x6CD1E0, 0xD6DAE2,
                   0x565D6B, 0xF29B9B, 0x9BE8A8, 0xF2E29B, 0x93C4F0, 0xF0AEDC, 0x9BE4F0, 0xF2F4F8]
        ),
        TerminalTheme(
            id: "dracula", name: "Dracula",
            background: 0x282A36, foreground: 0xF8F8F2,
            ansi: [0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                   0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF]
        ),
        TerminalTheme(
            id: "nord", name: "Nord",
            background: 0x2E3440, foreground: 0xD8DEE9,
            ansi: [0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
                   0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4]
        ),
        TerminalTheme(
            id: "onedark", name: "One Dark",
            background: 0x282C34, foreground: 0xABB2BF,
            ansi: [0x282C34, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
                   0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF]
        ),
        TerminalTheme(
            id: "solarized", name: "Solarized Dark",
            background: 0x002B36, foreground: 0x839496,
            ansi: [0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                   0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3]
        ),
        TerminalTheme(
            id: "gruvbox", name: "Gruvbox Dark",
            background: 0x282828, foreground: 0xEBDBB2,
            ansi: [0x282828, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                   0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2]
        ),
    ]

    static var currentTerminalTheme: TerminalTheme {
        let id = UserDefaults.standard.string(forKey: "terminalTheme") ?? "sheepterm"
        return terminalThemes.first { $0.id == id } ?? terminalThemes[0]
    }

    static var termBackgroundNS: NSColor { nsColor(currentTerminalTheme.background) }
    static var termForegroundNS: NSColor { nsColor(currentTerminalTheme.foreground) }
    static var termBackground: SwiftUI.Color { SwiftUI.Color(nsColor: termBackgroundNS) }

    // MARK: Chrome — the terminal follows its theme; the chrome (top bar,
    // sidebar, status bar) follows the app's Light/Dark appearance.

    static let chrome = dynamicColor(light: 0xE9EBEF, dark: 0x1C1F26)
    static let chromeLine = dynamicColor(light: 0xD3D7DD, dark: 0x2E323B)
    /// Opaque fill for controls that sit on a glass chrome surface.
    static let controlFill = dynamicColor(light: 0xFDFDFE, dark: 0x30343D)
    static let tabActive = dynamicColor(light: 0xFFFFFF, dark: 0x15171C)
    static let tabText = dynamicColor(light: 0x1B1E24, dark: 0xFFFFFF)
    static let dimText = dynamicColor(light: 0x5B6472, dark: 0x7D8492)
    static let accent = dynamicColor(light: 0x2C7FB8, dark: 0x5AA5D6)
    static let ok = dynamicColor(light: 0x2B7A46, dark: 0x7DD98C)
    static let warn = dynamicColor(light: 0x9A6A00, dark: 0xFEBC2E)

    private static func dynamicColor(light: UInt32, dark: UInt32) -> SwiftUI.Color {
        SwiftUI.Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(isDark ? dark : light)
        })
    }

    static func apply(to terminalView: TerminalView) {
        let theme = currentTerminalTheme
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = nsColor(theme.background)
        terminalView.nativeForegroundColor = nsColor(theme.foreground)
        terminalView.installColors(theme.ansi.map(termColor))
        // Selection: neutral mid-tone blended from the theme's own colors
        // (SwiftTerm's default is a hard dark teal that fights every theme).
        terminalView.selectedTextBackgroundColor =
            nsColor(theme.background).blended(withFraction: 0.35, of: nsColor(theme.foreground))
            ?? NSColor.selectedTextBackgroundColor

        // Right-click menu: SwiftTerm implements copy:/paste:/selectAll: as
        // responder actions; target nil routes them to the clicked view.
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Copy", action: NSSelectorFromString("copy:"), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Paste", action: NSSelectorFromString("paste:"), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Select All", action: NSSelectorFromString("selectAll:"), keyEquivalent: ""))
        terminalView.menu = menu

        // Cap SwiftTerm's kitty image cache (default 320 MB per tab): a hostile
        // or buggy host could otherwise inflate RAM for every open tab.
        terminalView.getTerminal().options.kittyImageCacheLimitBytes = 32 * 1024 * 1024
    }

    private static func nsColor(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }

    /// Pure conversion — safe to call from anywhere, so say so (installColors
    /// maps over it from a nonisolated context).
    nonisolated private static func termColor(_ hex: UInt32) -> SwiftTerm.Color {
        SwiftTerm.Color(
            red: UInt16((hex >> 16) & 0xFF) * 257,
            green: UInt16((hex >> 8) & 0xFF) * 257,
            blue: UInt16(hex & 0xFF) * 257
        )
    }
}
