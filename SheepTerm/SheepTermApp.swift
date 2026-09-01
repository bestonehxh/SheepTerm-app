import Combine
import SwiftUI

/// Handles opened .sheepterm files at the APPLICATION level.
///
/// SwiftUI's `.onOpenURL` inside a WindowGroup made macOS treat the file as
/// a document and open a second window for it — and SheepTerm is
/// single-window on purpose (two windows share AppModel.shared and the same
/// TerminalView instances, so terminals blank and reparent between them).
/// An app delegate that implements `application(_:open:)` consumes the
/// event before that happens.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        // Hop to the next runloop turn before doing anything: the import
        // asks for confirmation with NSAlert.runModal(), and a modal started
        // INSIDE this Apple Event callback does not run at all when the app
        // is already up — runModal returns the default button immediately,
        // so the file was imported with no dialog ever shown. Nothing may be
        // imported without an explicit accept (spec 0.4).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp?.activate(ignoringOtherApps: true)
                for url in urls {
                    AppModel.shared.importFile(at: url)
                }
            }
        }
    }

    /// Clicking the Dock icon with the window closed reopens it rather than
    /// creating a second one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }

    /// ⌘Q (and closing the last window, which terminates the app) must not
    /// silently drop live sessions — a half-finished configuration on a
    /// console port is exactly the thing you cannot get back. Local shells
    /// don't count: those are cheap to reopen and Terminal.app doesn't ask
    /// about them either.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let live = AppModel.shared.liveRemoteSessions
        guard !live.isEmpty else { return .terminateNow }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = live.count == 1
            ? "Quit SheepTerm? One session is still open."
            : "Quit SheepTerm? \(live.count) sessions are still open."
        let names = live.prefix(8).map { "• \($0.title)" }.joined(separator: "\n")
        let more = live.count > 8 ? "\n• and \(live.count - 8) more" : ""
        alert.informativeText = "Quitting closes \(live.count == 1 ? "it" : "them") right away.\n\n\(names)\(more)"
        let quit = alert.addButton(withTitle: "Quit")
        let cancel = alert.addButton(withTitle: "Cancel")
        // Cancel is the default: Return must never be the key that drops a
        // live session, and Escape maps to it as well.
        quit.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct SheepTermApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1100, height: 680)
        .windowStyle(.hiddenTitleBar)
        // The app delegate handles opened .sheepterm files; without this the
        // WindowGroup ALSO answers the open request by spawning a second
        // window for the "document" — and SheepTerm is single-window on
        // purpose. An empty match set means this scene handles no external
        // events, so no extra window is ever created for one.
        .handlesExternalEvents(matching: [])
        .commands {
            SheepTermCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Tracks whether the app's main window (fullSizeContentView) is key, and
/// whether anything of the app is on screen at all.
/// Window-scoped commands (Close Tab) disable themselves while Settings or
/// a panel is key, the status-bar sheep pause their animation while the
/// window isn't key, and the clock stops ticking while nothing is visible.
@MainActor
final class MainWindowKeyMonitor: NSObject, ObservableObject {
    static let shared = MainWindowKeyMonitor()
    @Published private(set) var isKey = true
    /// False while every window is occluded (hidden, minimized, fully
    /// covered). Unlike `isKey` this stays true for a visible-but-inactive
    /// window — a clock the user can still see must keep the right time;
    /// one nobody can see must not wake the app once a second.
    @Published private(set) var isVisible = true

    private override init() {
        super.init()
        isVisible = NSApp?.occlusionState.contains(.visible) ?? true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationOcclusionDidChange(_:)),
            name: NSApplication.didChangeOcclusionStateNotification,
            object: nil
        )
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowKeyStateDidChange(_:)),
                name: name,
                object: nil
            )
        }
    }

    /// AppKit posts application/window lifecycle notifications on the main
    /// thread. Selector observation keeps the Objective-C boundary at the
    /// framework edge instead of transferring a non-Sendable Notification
    /// through a @Sendable closure.
    @objc private func applicationOcclusionDidChange(_ note: Notification) {
        isVisible = NSApp?.occlusionState.contains(.visible) ?? true
    }

    @objc private func windowKeyStateDidChange(_ note: Notification) {
        guard let window = note.object as? NSWindow,
              window.styleMask.contains(.fullSizeContentView) else { return }
        isKey = note.name == NSWindow.didBecomeKeyNotification
    }
}

/// All menu commands live here so checkmarks (Appearance, logging, …)
/// update live — the struct observes AppModel.
struct SheepTermCommands: Commands {
    @ObservedObject private var model = AppModel.shared
    @ObservedObject private var mainWindowKey = MainWindowKeyMonitor.shared
    // The supported way to open the SwiftUI Settings scene from a command —
    // responder-chain showSettingsWindow: silently does nothing when no
    // Settings window has ever been created.
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        // One window only: a second window would share AppModel.shared and
        // the same TerminalView instances, blanking/reparenting views
        // between windows. Remove the default File → New Window (⌘N).
        CommandGroup(replacing: .newItem) { }

        CommandGroup(after: .newItem) {
            Button("Quick Connect…") { model.showQuickSearch = true }
                .keyboardShortcut("k", modifiers: .command)
            Button("New Terminal Tab") { model.newLocalTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New SSH Connection…") { model.openQuickConnect(.ssh) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("New Serial Console…") { model.openQuickConnect(.serial) }
            // Main window only — while Settings is key, ⌘⇧W must not close
            // a terminal tab in the background.
            Button("Close Tab") { model.closeCurrentTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(!mainWindowKey.isKey)
            Divider()
            Button("Credentials…") { model.showCredentials = true }
            Divider()
            Toggle("Log SSH Sessions", isOn: $model.sessionLogging)
            Button("Open Logs Folder") {
                NSWorkspace.shared.open(SessionLogger.logsDirectory)
            }
            Divider()
            Button("Import Group…") { model.importGroupViaPanel() }
            Divider()
            Button("Back Up Configuration…") { BackupManager.backUp() }
            Button("Restore Configuration…") { BackupManager.restore() }
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Toggle("Safe Multi-line Paste", isOn: $model.safePasteEnabled)
            Divider()
            // Search in the scrollback. SwiftTerm owns the engine and the
            // find bar itself — these items only forward the standard
            // NSTextFinder actions to the active terminal view (see
            // AppModel.sendFinderAction).
            Button("Find…") { model.showFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(model.selectedTab == nil)
            Button("Find Next") { model.findNextMatch() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(model.selectedTab == nil)
            Button("Find Previous") { model.findPreviousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(model.selectedTab == nil)
            Button("Use Selection for Find") { model.useSelectionForFind() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedTab == nil)
        }

        CommandGroup(after: .sidebar) {
            Button {
                model.toggleSidebar()
            } label: {
                Label("Toggle Sidebar", systemImage: "sidebar.leading")
            }
            .keyboardShortcut("0", modifiers: .command)
            Button {
                model.showReorderGroups = true
            } label: {
                Label("Reorder Groups…", systemImage: "arrow.up.arrow.down")
            }
            Button {
                model.toggleHighlightCurrent()
            } label: {
                Label("Toggle Highlighting", systemImage: "highlighter")
            }
            .keyboardShortcut("h", modifiers: [.command, .shift])
            Button {
                // Aim the Settings window at the Highlight tab, then open it
                // via the environment action — works even when no Settings
                // window exists yet.
                SettingsTabSelection.shared.tab = .highlight
                openSettings()
            } label: {
                Label("Highlight Rules…", systemImage: "slider.horizontal.3")
            }
            Button {
                model.clearScrollback()
            } label: {
                Label("Clear Scrollback", systemImage: "eraser")
            }
            // ⌘K already belongs to Quick Connect here, so this takes ⌘L.
            // Only the history above the screen goes — the visible screen and
            // the remote session are untouched.
            .keyboardShortcut("l", modifiers: .command)
            .disabled(model.selectedTab == nil)
            Divider()
            Toggle(isOn: $model.showStatusBar) {
                Label("Show Bottom Bar", systemImage: "rectangle.bottomthird.inset.filled")
            }
            Menu {
                Toggle("Session Info", isOn: $model.statusShowSession)
                Toggle("Shortcut Hints", isOn: $model.statusShowHints)
                Toggle("This Mac IP", isOn: $model.statusShowIP)
                Toggle("Clock", isOn: $model.statusShowClock)
            } label: {
                Label("Bottom Bar Items", systemImage: "checklist")
            }
            Divider()
            Menu {
                ForEach(Theme.terminalThemes) { theme in
                    Toggle(theme.name, isOn: Binding(
                        get: { model.terminalTheme == theme.id },
                        set: { _ in model.terminalTheme = theme.id }
                    ))
                }
            } label: {
                Label("Terminal Theme", systemImage: "paintpalette")
            }
            Menu {
                ForEach(AppearanceMode.allCases) { mode in
                    Toggle(mode.label, isOn: Binding(
                        get: { model.appearanceMode == mode },
                        set: { _ in model.appearanceMode = mode }
                    ))
                }
            } label: {
                Label("Appearance", systemImage: "circle.lefthalf.filled")
            }
        }

        CommandMenu("Tabs") {
            Button("Next Tab") { model.selectAdjacentTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { model.selectAdjacentTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10, id: \.self) { number in
                Button("Tab \(number)") { model.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command)
            }
        }
    }
}
