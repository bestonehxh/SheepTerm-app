import AppKit
import SwiftUI

/// How the app's chrome (sidebar, tab bar) is painted. Stored under
/// "chromeStyle"; `glass` is the default.
///
/// This picks the MATERIAL only. The layout is the same either way: the
/// sidebar is a full-height column that owns the traffic-light row and the
/// tab bar sits over the detail pane alone. Classic just paints that same
/// layout with the flat `Theme.chrome` tile instead of glass.
enum ChromeStyle: String, CaseIterable, Identifiable {
    case glass
    case classic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .glass: return "Liquid Glass"
        case .classic: return "Solid Color"
        }
    }

    static let storageKey = "chromeStyle"

    /// For the non-SwiftUI readers (AppKit-side helpers) that cannot observe
    /// @AppStorage. SwiftUI views read the setting through @AppStorage so they
    /// re-render the moment it changes.
    static var current: ChromeStyle {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ChromeStyle.init) ?? .glass
    }
}

/// The chrome surfaces that can be painted. The status bar is deliberately
/// never glass: it is a dense strip of 11pt dim monospace, not a floating
/// control layer, and glass only costs it contrast.
enum ChromeZone {
    case sidebar, topBar, statusBar

    func isGlass(_ style: ChromeStyle) -> Bool {
        style == .glass && self != .statusBar
    }
}

/// Background for one chrome surface. Uses `.background { }` (the view builder
/// form) at every call site — unlike the ShapeStyle form it does not expand
/// into the titlebar safe area, so the `ignoresSafeAreaEdges: []` guard the
/// flat version needed is unnecessary here.
struct ChromeBackground: View {
    let zone: ChromeZone
    @AppStorage(ChromeStyle.storageKey) private var style = ChromeStyle.glass

    var body: some View {
        if zone.isGlass(style) {
            VisualEffectBackground(material: zone == .sidebar ? .sidebar : .headerView)
        } else {
            Theme.chrome
        }
    }
}

/// Fill for a control sitting ON a chrome surface (the sidebar search field,
/// the ⌘K palette's field). A translucent tint over glass reads muddy — the
/// glass shows through the control and it stops looking like a field — so on
/// a glass surface the fill goes opaque instead.
struct ControlFill: View {
    let zone: ChromeZone
    var cornerRadius: CGFloat = 7
    @AppStorage(ChromeStyle.storageKey) private var style = ChromeStyle.glass

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(zone.isGlass(style) ? Theme.controlFill : Color.primary.opacity(0.07))
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
