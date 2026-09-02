import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    /// Last color painted on the window — skips redundant writes during resize.
    private static var lastBackgroundColor: NSColor?

    /// The sidebar is a full-height column that owns the traffic-light row;
    /// the tab bar spans only the detail pane. (Before 2.3 (12) the tab bar
    /// ran the whole window width with the sidebar strictly below it — see
    /// ARCHITECTURE.md; the rule that survived is the one that matters: the
    /// sidebar's scroll content must still be clipped to its own slot.)
    private var mainLayout: some View {
        HStack(spacing: 0) {
            if model.sidebarShown {
                SidebarView(store: model.store)
                    .frame(width: model.sidebarWidth)
                    // Clip to the sidebar's own slot. The outer
                    // .ignoresSafeArea(.top) lets the outline's scroll content
                    // draw upward into the titlebar row — with a short window
                    // you could scroll rows straight over the traffic lights.
                    // The search field is the hard edge.
                    .clipped()
                SidebarResizeHandle()
            }
            VStack(spacing: 0) {
                TopBarView()
                Rectangle()
                    .fill(Theme.chromeLine)
                    .frame(height: 1)
                DetailPane()
            }
        }
    }

    var body: some View {
        // Custom split layout (no NavigationSplitView): the top bar always
        // spans the full window width, and the sidebar lives strictly BELOW
        // it — it can never reach the traffic-light row, and showing/hiding
        // it is a plain subview swap with no hidden column animation.
        mainLayout
        .background(Theme.chrome)
        .frame(minWidth: 760, minHeight: 460)
        // Grab the actual hosting window and re-sync on every event that can
        // accompany a fullscreen change — including aborted restores that
        // never fire the will*/did* pair. Self-healing: the state is always
        // re-derived from the window's real styleMask.
        .background(WindowSyncAccessor { window in
            syncFullscreen(window)
        })
        // Pull the top bar into the titlebar row so the traffic lights and
        // session tabs share one line. Outermost on purpose: a .frame applied
        // after ignoresSafeArea mis-positions the expanded content. Only works
        // together with an empty NSToolbar in an earlier build. That toolbar
        // is gone and the trick still holds on its own — do not go looking
        // for code that no longer exists —
        // without a toolbar the titlebar backdrop covers content in this row.
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { note in
            syncFullscreen(note.object as? NSWindow)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { note in
            syncFullscreen(note.object as? NSWindow)
        }
        // The did* pair matters: styleMask only reflects the final state after
        // the transition ends (an aborted restore never fires will* cleanly).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { note in
            syncFullscreen(note.object as? NSWindow)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { note in
            syncFullscreen(note.object as? NSWindow)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            syncFullscreen(note.object as? NSWindow)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            syncFullscreen(note.object as? NSWindow)
        }
    }

    private func syncFullscreen(_ window: NSWindow?) {
        guard let window, isMainTerminalWindow(window) else { return }
        // didResize fires per frame — write only when the value differs.
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        // Fullscreen keeps a thin reserved strip above the content (the
        // titlebar reveal area) — paint it chrome instead of black so it
        // blends with the tab bar. Hover reveal briefly overlaying the tab
        // bar is standard macOS behavior (Chrome/VS Code do the same);
        // titlebar-accessory mirrors don't render in hiddenTitleBar windows.
        // didResize fires per frame during a resize — skip redundant writes.
        let color = NSColor(Theme.chrome)
        if color != Self.lastBackgroundColor {
            Self.lastBackgroundColor = color
            window.backgroundColor = color
        }
    }
}

/// Hands the hosting NSWindow to SwiftUI as soon as the view lands in one.
/// For syncFullscreen only (titlebar transparency + background colour, both
/// harmless on a sheet). The traffic-light spacer must NOT be keyed on this:
/// a SwiftUI sheet also carries fullSizeContentView and on macOS 26 is
/// neither an NSSheet nor an NSPanel — TopBarView keys on window identity.
func isMainTerminalWindow(_ window: NSWindow) -> Bool {
    window.styleMask.contains(.fullSizeContentView)
        && !window.isSheet && window.sheetParent == nil && !(window is NSPanel)
}

private struct WindowSyncAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> GrabberView {
        let view = GrabberView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: GrabberView, context: Context) {}

    final class GrabberView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                onWindow?(window)
            }
        }
    }
}

/// Thin draggable divider between sidebar and terminal pane.
struct SidebarResizeHandle: View {
    @EnvironmentObject var model: AppModel
    @State private var dragStartWidth: CGFloat?
    /// Tracks the pushed resize cursor so pop only runs when we pushed —
    /// if the sidebar collapses (⌘0) mid-hover the exit callback never fires.
    @State private var cursorPushed = false
    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        Rectangle()
            .fill(Theme.chromeLine)
            .frame(width: 1)
            .overlay(
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                dragging = true
                                let base = dragStartWidth ?? model.sidebarWidth
                                if dragStartWidth == nil { dragStartWidth = base }
                                model.sidebarWidth = min(max(base + value.translation.width, 200), 320)
                            }
                            .onEnded { _ in
                                dragging = false
                                dragStartWidth = nil
                                // The hover-exit was suppressed mid-drag — if
                                // the pointer ended outside the strip, pop now.
                                if !hovering, cursorPushed {
                                    NSCursor.pop()
                                    cursorPushed = false
                                }
                                // Persist once per drag — the sidebarWidth
                                // didSet would hit UserDefaults every frame.
                                UserDefaults.standard.set(model.sidebarWidth, forKey: "sidebarWidth")
                            }
                    )
                    .onHover { inside in
                        hovering = inside
                        // Push/pop must pair up exactly — an unbalanced pop
                        // would steal another view's cursor. Mid-drag the
                        // pointer can outrun the 9pt strip — keep the cursor
                        // until the drag ends instead of pop/push flicker.
                        if inside, !cursorPushed {
                            NSCursor.resizeLeftRight.push()
                            cursorPushed = true
                        } else if !inside, cursorPushed, !dragging {
                            NSCursor.pop()
                            cursorPushed = false
                        }
                    }
                    // If the sidebar collapses (⌘0) mid-hover the hover-exit
                    // never fires — pop here or the cursor sticks app-wide.
                    .onDisappear {
                        dragging = false
                        if cursorPushed {
                            NSCursor.pop()
                            cursorPushed = false
                        }
                    }
            )
    }
}

struct DetailPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.termBackground
                // Only the selected tab's terminal view is attached; hidden
                // tabs keep their scrollback in the Terminal model but hold
                // no full-size backing store and skip all drawing.
                if let tab = model.selectedTab {
                    SessionContentView(tab: tab, isActive: true)
                        .padding(.leading, 10)
                        .padding(.trailing, 4)
                        .padding(.top, 6)
                        .id(tab.id)
                } else {
                    EmptyPaneView()
                }
            }
            if model.showStatusBar
                && (model.statusShowSession || model.statusShowHints
                    || model.statusShowIP || model.statusShowClock) {
                StatusBarView()
            }
        }
        // ignoresSafeAreaEdges: [] is load-bearing — the default background
        // auto-expands into the (ignored) titlebar safe area and would paint
        // chrome OVER the tab bar living in that row.
        .background(Theme.chrome, ignoresSafeAreaEdges: [])
        .sheet(item: $model.quickConnect) { request in
            QuickConnectSheet(kind: request.kind)
        }
        .sheet(isPresented: $model.showCredentials) {
            CredentialsSheet()
        }
        // Here and not on SidebarView: the sidebar is removed from the
        // hierarchy when hidden, and View → Reorder Groups… then set a flag
        // nobody was presenting — nothing happened, and the sheet popped up
        // unbidden the next time the sidebar was shown.
        .sheet(isPresented: $model.showReorderGroups) {
            ReorderGroupsSheet(store: model.store)
        }
    }
}

/// Custom top bar replacing the system toolbar: our tab chips on the left,
/// the + menu pinned to the far right, full control over right-click menus.
struct TopBarView: View {
    @EnvironmentObject var model: AppModel
    @State private var isFullScreen = false
    /// The window this bar lives in. Fullscreen state is read from THIS
    /// window and healed only from ITS notifications: any test by styleMask
    /// or class let a SwiftUI sheet (which also carries fullSizeContentView
    /// and, on macOS 26, is neither an NSSheet nor an NSPanel) pass as the
    /// main window while it was key, and its styleMask — never .fullScreen —
    /// put the 64 pt traffic-light spacer back in the middle of fullscreen.
    @State private var hostWindow: NSWindow?

    var body: some View {
        HStack(spacing: 8) {
            // Room for the traffic lights sharing this row — hidden in
            // fullscreen, so no gap there. Switched on the will* notifications
            // below so the icons move DURING the system transition; a switch
            // on did* pops visibly after the animation settles.
            // The traffic lights sit over the SIDEBAR now, so the tab bar
            // only needs its own gap when the sidebar is closed.
            Spacer()
                .frame(width: (isFullScreen || model.sidebarShown) ? 0 : 64)
                .animation(.easeOut(duration: 0.18), value: isFullScreen)

            // Grouped: snug hit boxes with a small gap between them.
            HStack(spacing: 10) {
                Button {
                    model.toggleSidebar()
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 13))
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.dimText)
                .help("Toggle sidebar (⌘0)")

                Button {
                    model.showQuickSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .frame(width: 20, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.dimText)
                .help("Quick Connect (⌘K)")
            }
            .popover(isPresented: $model.showQuickSearch, arrowEdge: .bottom) {
                QuickSearchView()
                    .environmentObject(model)
            }

            TabStripView(compensateWindowBorder: !isFullScreen)

            Spacer(minLength: 8)

            Menu {
                Button("New Terminal Tab") { model.newLocalTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("New SSH Connection…") { model.openQuickConnect(.ssh) }
                Button("New Serial Console…") { model.openQuickConnect(.serial) }
                Divider()
                Button("Credentials…") { model.showCredentials = true }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.dimText)
                    .frame(width: 38, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("New session")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background {
            ChromeBackground(zone: .topBar).gesture(WindowDragGesture())
        }
        // Ground truth on attach: a restore straight into fullscreen may skip
        // the will/did notifications below (§2), and at onAppear the window
        // is not key yet — so read the styleMask of the window we land in.
        .background(WindowSyncAccessor { window in
            DispatchQueue.main.async {
                hostWindow = window
                let actual = window.styleMask.contains(.fullScreen)
                if actual != isFullScreen { isFullScreen = actual }
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            healFullScreen(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { note in
            healFullScreen(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        // Safety net for aborted/restored transitions that skip the will* pair.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
    }
}

extension TopBarView {
    /// The spacer for the traffic lights must match what the window IS, not
    /// what the last notification said. A restore into fullscreen used to
    /// leave a 64 pt gap with no buttons behind it until the next toggle.
    /// Only OUR window counts — see `hostWindow`.
    private func healFullScreen(from note: Notification) {
        guard let window = note.object as? NSWindow, let hostWindow, window === hostWindow else { return }
        let actual = window.styleMask.contains(.fullScreen)
        // didResize fires per frame — write only when it differs.
        if actual != isFullScreen { isFullScreen = actual }
    }
}

struct SessionContentView: View {
    @ObservedObject var tab: SessionTab
    let isActive: Bool

    var body: some View {
        switch tab.content {
        case .local(let controller):
            TerminalViewRepresentable(terminalView: controller.terminalView, isActive: isActive)
        case .ssh(let controller):
            TerminalViewRepresentable(terminalView: controller.terminalView, isActive: isActive)
        case .serial(let controller):
            TerminalViewRepresentable(terminalView: controller.terminalView, isActive: isActive)
        }
    }
}

/// Line-art sheep in the icon-D style: scalloped wool ring with the ❯_ face,
/// strokes only — no background tile.
struct SheepLineMark: View {
    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let shading = GraphicsContext.Shading.color(Theme.accent)

            // Wool ring: cloud bumps around a circle, each its own subpath.
            let bumps = 12
            let ringRadius = s * 0.355
            let bumpRadius = ringRadius * .pi / CGFloat(bumps) * 1.2
            let halfSpan: CGFloat = 1.85
            var wool = Path()
            for i in 0..<bumps {
                let angle = CGFloat(i) / CGFloat(bumps) * 2 * .pi
                let bumpCenter = CGPoint(
                    x: center.x + cos(angle) * ringRadius,
                    y: center.y + sin(angle) * ringRadius
                )
                let startAngle = angle - halfSpan
                wool.move(to: CGPoint(
                    x: bumpCenter.x + cos(startAngle) * bumpRadius,
                    y: bumpCenter.y + sin(startAngle) * bumpRadius
                ))
                wool.addArc(
                    center: bumpCenter, radius: bumpRadius,
                    startAngle: .radians(Double(startAngle)),
                    endAngle: .radians(Double(angle + halfSpan)),
                    clockwise: false
                )
            }
            context.stroke(wool, with: shading, style: StrokeStyle(
                lineWidth: s * 0.04, lineCap: .round, lineJoin: .round))

            // Face: ❯ eye and _ mouth.
            func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: center.x + x * s, y: center.y + y * s)
            }
            var face = Path()
            face.move(to: pt(-0.15, -0.11))
            face.addLine(to: pt(-0.04, -0.02))
            face.addLine(to: pt(-0.15, 0.07))
            face.move(to: pt(0.03, 0.07))
            face.addLine(to: pt(0.16, 0.07))
            context.stroke(face, with: shading, style: StrokeStyle(
                lineWidth: s * 0.055, lineCap: .round, lineJoin: .round))
        }
    }
}

struct EmptyPaneView: View {
    @EnvironmentObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 14) {
            // Line art extracted from icon D itself — identical strokes,
            // transparent background.
            Group {
                if let sheep = NSImage(named: "SheepLineD") {
                    Image(nsImage: sheep)
                        .resizable()
                        .interpolation(.high)
                } else {
                    SheepLineMark()
                }
            }
            .frame(width: 84, height: 84)
            .opacity(hovering ? 1.0 : 0.75)
            Text("⌘T or click to open a new terminal")
                .font(.system(size: 13, design: .monospaced))
        }
        .foregroundStyle(hovering ? Theme.tabText : Theme.dimText)
        // Click target = the sheep + caption block only, with a little
        // breathing room — not the entire empty pane.
        .padding(20)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onTapGesture {
            model.newLocalTab()
        }
        .onHover { inside in
            hovering = inside
        }
    }
}
