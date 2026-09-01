import AppKit
import Combine
import ImageIO
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class SessionTab: ObservableObject, Identifiable {
    enum Content {
        case local(LocalTerminalController)
        case ssh(SSHTerminalController)
        case serial(SerialTerminalController)
    }

    let id = UUID()
    let content: Content
    @Published var title: String
    @Published var statusInfo: String?
    @Published var highlightEnabled = false {
        didSet {
            switch content {
            case .ssh(let controller): controller.highlightEnabled = highlightEnabled
            case .serial(let controller): controller.highlightEnabled = highlightEnabled
            case .local: break
            }
        }
    }
    var wasConnected = false
    var autoReconnectAttempts = 0
    /// Guards the recent-host entry to exactly one write per connect:
    /// password auth notes it via rememberSessionPassword, key-only SSH
    /// and serial note it on the first success status.
    var didNoteRecent = false

    init(content: Content, title: String) {
        self.content = content
        self.title = title
    }
}

struct QuickConnectRequest: Identifiable {
    let id = UUID()
    let kind: ConnectionKind
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}


@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var tabs: [SessionTab] = []
    @Published var selectedID: UUID?
    // Launch clean like Terminal.app — the sidebar opens with ⌘0 or the
    // toolbar button when needed.
    @Published var sidebarShown = false
    // Persisted by the resize handle's drag .onEnded — writing UserDefaults
    // in a didSet here would hit disk on every drag frame.
    @Published var sidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: "sidebarWidth")
        return saved == 0 ? 232 : min(max(saved, 200), 320)
    }()
    @Published var quickConnect: QuickConnectRequest?
    @Published var showCredentials = false
    @Published var showReorderGroups = false
    @Published var sessionLogging: Bool {
        didSet {
            UserDefaults.standard.set(sessionLogging, forKey: "logSessions")
        }
    }
    @Published var autoReconnect = true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "autoReconnect") }
    }
    @Published var safePasteEnabled = true {
        didSet {
            UserDefaults.standard.set(safePasteEnabled, forKey: "safePasteEnabled")
            guard !safePasteEnabled else { return }
            for tab in tabs {
                switch tab.content {
                case .ssh(let controller):
                    (controller.terminalView as? SheepSSHTerminalView)?.cancelSafePaste(reason: .stopped)
                case .serial(let controller):
                    (controller.terminalView as? SheepSSHTerminalView)?.cancelSafePaste(reason: .stopped)
                case .local:
                    break
                }
            }
        }
    }
    @Published var appearanceMode: AppearanceMode = .system {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode")
            NSApp.appearance = appearanceMode.appearance
        }
    }
    @Published var showStatusBar = true {
        didSet { UserDefaults.standard.set(showStatusBar, forKey: "showStatusBar") }
    }
    @Published var statusShowSession = true {
        didSet { UserDefaults.standard.set(statusShowSession, forKey: "statusShowSession") }
    }
    @Published var statusShowHints = true {
        didSet { UserDefaults.standard.set(statusShowHints, forKey: "statusShowHints") }
    }
    @Published var statusShowIP = true {
        didSet { UserDefaults.standard.set(statusShowIP, forKey: "statusShowIP") }
    }
    @Published var statusShowClock = true {
        didSet { UserDefaults.standard.set(statusShowClock, forKey: "statusShowClock") }
    }
    @Published var terminalTheme = "sheepterm" {
        didSet {
            UserDefaults.standard.set(terminalTheme, forKey: "terminalTheme")
            for tab in tabs {
                switch tab.content {
                case .local(let controller): Theme.apply(to: controller.terminalView)
                case .ssh(let controller): Theme.apply(to: controller.terminalView)
                case .serial(let controller): Theme.apply(to: controller.terminalView)
                }
            }
        }
    }
    /// Default icon choice. "V2" is the 2026 wool-family artwork that also
    /// ships as the bundle's AppIcon; A/B/C are the original set and stay
    /// selectable in Settings.
    static let defaultAppIcon = "V2"

    @Published var appIcon: String = AppModel.defaultAppIcon {
        didSet {
            UserDefaults.standard.set(appIcon, forKey: "appIcon")
            applyDockIcon()
        }
    }

    /// Resolves the stored choice, running the one-time move off the retired
    /// defaults. "D" belonged to the removed SheepTermD variant and its image
    /// no longer ships. "B" was the old default: bumping the default alone
    /// would leave everyone who never opened Settings on the old artwork, so
    /// it is rewritten once — after that a deliberate pick of B sticks,
    /// because the flag is already set.
    private static func resolveStoredIcon(_ defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: "appIcon")
        if stored == "D" { return defaultAppIcon }
        guard let stored else { return defaultAppIcon }
        if stored == "B", !defaults.bool(forKey: "didMigrateIconToV2") {
            defaults.set(true, forKey: "didMigrateIconToV2")
            return defaultAppIcon
        }
        defaults.set(true, forKey: "didMigrateIconToV2")
        return stored
    }

    /// User-picked icon image (Settings → General → Browse…), 256px PNG.
    static let customIconURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("custom-icon.png")
    }()

    /// Replaces the Dock icon with the chosen artwork — and, on the default
    /// choice, deliberately does NOT.
    ///
    /// `applicationIconImage` is drawn by the Dock exactly as handed over: no
    /// mask, no shadow, and no icon-grid inset either. The bundle icon a
    /// normal app shows goes through Icon Services, whose rendering already
    /// contains that inset — measured on macOS 26, the opaque tile is
    /// 410/512 = 80% of the canvas for SheepTerm, Mail and Notes alike. So
    /// assigning that same rendering to `applicationIconImage` insets it a
    /// SECOND time: the Dock fits the whole 512-wide image (transparent
    /// margin included) into the slot, and the sheep ends up ~80% the size of
    /// every neighbour. That is the "icon looks smaller than the other apps"
    /// report, and no amount of re-baking the PNG fixes it cleanly.
    ///
    /// The default icon therefore hands the Dock back to the system (nil
    /// restores the bundle icon), which is the only way to be pixel-for-pixel
    /// identical to Mail and Notes — and it keeps Dock and Finder in sync by
    /// construction rather than by regenerating a PNG after every build.
    /// A/B/C and a user's own picture still have to be pushed, so their fully
    /// transparent border is trimmed first: what remains (artwork plus its
    /// baked shadow) then fills the slot the same way.
    func applyDockIcon() {
        guard appIcon != Self.defaultAppIcon else {
            NSApp.applicationIconImage = nil
            return
        }
        let image: NSImage?
        if appIcon == "Custom" {
            image = NSImage(contentsOf: Self.customIconURL)
        } else {
            image = NSImage(named: "SheepIcon\(appIcon)")
        }
        guard let image else { return }
        NSApp.applicationIconImage = Self.trimmingTransparentBorder(image) ?? image
    }

    /// Crops rows/columns that are entirely alpha 0. Only fully transparent
    /// pixels go — a soft cast shadow is part of the artwork and stays.
    /// Returns nil when there is nothing to trim (or nothing opaque at all),
    /// so the caller can just use the original.
    private static func trimmingTransparentBorder(_ image: NSImage) -> NSImage? {
        guard let source = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? NSBitmapImageRep(data: image.tiffRepresentation ?? Data()),
              let data = source.bitmapData, source.samplesPerPixel == 4 else { return nil }
        let width = source.pixelsWide, height = source.pixelsHigh
        let rowBytes = source.bytesPerRow, pixelBytes = source.bitsPerPixel / 8
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where data[y * rowBytes + x * pixelBytes + 3] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let box = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard box.width < CGFloat(width) || box.height < CGFloat(height),
              let cropped = source.cgImage?.cropping(to: box) else { return nil }
        return NSImage(cgImage: cropped, size: NSSize(width: box.width, height: box.height))
    }

    /// Imports an image file as the custom icon (scaled to 256px, aspect-fit)
    /// and selects it. Decode + scale run on a background queue — a
    /// multi-megabyte photo must not beach-ball the UI — and the result is
    /// delivered back on the main actor.
    func setCustomIcon(from url: URL, completion: @escaping @Sendable (Bool) -> Void) {
        let destination = Self.customIconURL
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.renderCustomIcon(from: url, to: destination)
            DispatchQueue.main.async {
                if ok { self.appIcon = "Custom" }
                completion(ok)
            }
        }
    }

    /// Compatibility shim for the old synchronous call site: kicks off the
    /// async import and reports only whether the file is readable at all.
    /// New callers should use setCustomIcon(from:completion:).
    @discardableResult
    func setCustomIcon(from url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return false }
        setCustomIcon(from: url) { _ in }
        return true
    }

    /// ImageIO thumbnail render: decodes at ≤256px instead of full size, so
    /// a huge source image never materializes in memory. Pure CoreGraphics —
    /// safe to run on a background queue (hence nonisolated).
    nonisolated private static func renderCustomIcon(from url: URL, to destination: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        let thumbOptions: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions as CFDictionary) else {
            return false
        }
        // Aspect-fit onto a square canvas, same as the old NSImage path.
        let side = 256
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        let scale = min(CGFloat(side) / CGFloat(max(thumb.width, 1)), CGFloat(side) / CGFloat(max(thumb.height, 1)))
        let drawSize = CGSize(width: CGFloat(thumb.width) * scale, height: CGFloat(thumb.height) * scale)
        let origin = CGPoint(x: (CGFloat(side) - drawSize.width) / 2, y: (CGFloat(side) - drawSize.height) / 2)
        context.draw(thumb, in: CGRect(origin: origin, size: drawSize))
        guard let output = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(dest, output, nil)
        return CGImageDestinationFinalize(dest)
    }

    let store = HostStore()
    let credentialStore = CredentialStore()
    /// Session-lifetime memory of passwords that worked (keyed
    /// user@host:port) so reconnects don't ask again. Never written to disk.
    private var passwordCache: [String: String] = [:]
    let highlightStore = HighlightStore()
    private var keyMonitor: Any?

    private init() {
        // Our tab strip replaces native window tabbing entirely.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Suppress the macOS input-source switch panel for this app: SwiftTerm
        // can't anchor the small caret badge, so the system would show the big
        // centered language panel on every switch. The menu-bar input icon
        // still shows the current language.
        UserDefaults.standard.set(false, forKey: "TSMLanguageIndicatorEnabled")
        sessionLogging = UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true
        autoReconnect = UserDefaults.standard.object(forKey: "autoReconnect") as? Bool ?? true
        safePasteEnabled = UserDefaults.standard.object(forKey: "safePasteEnabled") as? Bool ?? true
        appearanceMode = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: "appearanceMode") ?? ""
        ) ?? .system
        NSApp.appearance = appearanceMode.appearance
        appIcon = Self.resolveStoredIcon(.standard)
        terminalTheme = UserDefaults.standard.string(forKey: "terminalTheme") ?? "sheepterm"
        applyDockIcon()
        showStatusBar = UserDefaults.standard.object(forKey: "showStatusBar") as? Bool ?? true
        statusShowSession = UserDefaults.standard.object(forKey: "statusShowSession") as? Bool ?? true
        statusShowHints = UserDefaults.standard.object(forKey: "statusShowHints") as? Bool ?? true
        statusShowIP = UserDefaults.standard.object(forKey: "statusShowIP") as? Bool ?? true
        statusShowClock = UserDefaults.standard.object(forKey: "statusShowClock") as? Bool ?? true
        // Launched from Finder the cwd is "/"; start shells at home like Terminal.app.
        FileManager.default.changeCurrentDirectoryPath(NSHomeDirectory())
        purgeTeamShareLeftovers()
        newLocalTab()
        installKeyMonitor()
    }

    /// Pulls every setting and every store back in after BackupManager has
    /// written a restored configuration over the live files. The window
    /// stays put and open sessions keep running — only the configuration
    /// changes underneath them.
    func reloadAfterRestore() {
        let defaults = UserDefaults.standard
        sessionLogging = defaults.object(forKey: "logSessions") as? Bool ?? true
        autoReconnect = defaults.object(forKey: "autoReconnect") as? Bool ?? true
        safePasteEnabled = defaults.object(forKey: "safePasteEnabled") as? Bool ?? true
        appearanceMode = AppearanceMode(rawValue: defaults.string(forKey: "appearanceMode") ?? "") ?? .system
        appIcon = Self.resolveStoredIcon(defaults)
        terminalTheme = defaults.string(forKey: "terminalTheme") ?? "sheepterm"
        showStatusBar = defaults.object(forKey: "showStatusBar") as? Bool ?? true
        statusShowSession = defaults.object(forKey: "statusShowSession") as? Bool ?? true
        statusShowHints = defaults.object(forKey: "statusShowHints") as? Bool ?? true
        statusShowIP = defaults.object(forKey: "statusShowIP") as? Bool ?? true
        statusShowClock = defaults.object(forKey: "statusShowClock") as? Bool ?? true
        let width = defaults.double(forKey: "sidebarWidth")
        sidebarWidth = width == 0 ? 232 : min(max(width, 200), 320)
        applyDockIcon()
        store.reloadFromDisk()
        credentialStore.reloadFromDisk()
        highlightStore.reloadFromDisk()
    }

    /// Team Share (LAN sharing + vault + team passphrase) was removed after
    /// the round-3 review; purge its leftovers so old installs don't carry
    /// them forever: the vault path/skip defaults, the plaintext-passphrase
    /// and KDF-salt defaults orphaned by earlier builds, and the Keychain
    /// team-passphrase item. Host passwords (same Keychain service, UUID
    /// accounts) are NOT touched.
    private func purgeTeamShareLeftovers() {
        for key in ["teamVaultPath", "teamVaultSkippedFiles", "teamPassphrase", "teamKeySalt"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Bestchaan.SheepTerm",
            kSecAttrAccount as String: "team-passphrase",
        ] as CFDictionary)
    }

    func exportGroup(_ group: HostGroup) {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: "sheepterm") {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "\(group.name).sheepterm"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? ShareCodec.encode(group, sender: ShareCodec.deviceName) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Opening a .sheepterm file (Finder double-click, `open`, drag onto the
    /// Dock icon). Routed through the app delegate rather than SwiftUI's
    /// `.onOpenURL`, because WindowGroup answers an opened document by
    /// spawning a SECOND window — and two windows share AppModel.shared and
    /// the very same TerminalView instances, so the terminal blanks and
    /// reparents between them.
    func importFile(at url: URL) {
        guard url.pathExtension == "sheepterm",
              let data = try? Data(contentsOf: url),
              let payload = try? ShareCodec.decode(data) else { return }
        // Never import silently — same confirmation as the menu path.
        confirmImport(payload)
    }

    func importGroupViaPanel() {
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "sheepterm") {
            panel.allowedContentTypes = [type, .json]
        }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let payload = try? ShareCodec.decode(data) else { return }
        confirmImport(payload)
    }

    /// Shared guard for every .sheepterm import path (menu panel, Finder
    /// double-click): nothing is imported without an explicit accept, and
    /// duplicates are resolved by the user — never silently (spec 0.4).
    func confirmImport(_ payload: SharePayload) {
        var group = payload.group
        let sender = Self.sanitizedForDialog(payload.sender)
        // Control characters in a stored group name would break the
        // sidebar — strip them from the value itself, not just the dialog.
        group.name = Self.sanitizedForDialog(group.name)
        if group.name.isEmpty { group.name = "Imported Group" }

        guard let existing = store.existingGroup(matching: group) else {
            let alert = NSAlert()
            alert.messageText = "Import group?"
            alert.informativeText = "“\(group.name)” (\(group.hosts.count) hosts) from \(sender) will be added as a new group. Passwords are not included."
            alert.addButton(withTitle: "Import")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                _ = store.applyImport(group, action: .createNew, replace: [:])
            }
            return
        }

        // 0.4 (ก): duplicate group — three choices, both host counts shown.
        let alert = NSAlert()
        alert.messageText = "Group “\(existing.name)” already exists"
        alert.informativeText = """
        Your group has \(existing.hosts.count) hosts — the file from \(sender) contains \(group.hosts.count) hosts.

        Merge adds new hosts to your group and asks about each conflicting host. Create New Group imports it as a separate numbered group. Passwords are not included.
        """
        alert.addButton(withTitle: "Merge into Existing")
        alert.addButton(withTitle: "Create New Group")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            resolveImportConflicts(group, into: existing)
        case .alertSecondButtonReturn:
            _ = store.applyImport(group, action: .createNew, replace: [:])
        default:
            break
        }
    }

    /// 0.4 (ข): ask Replace/Keep for each conflicting host, showing what
    /// differs, with an apply-to-all checkbox. Nothing is written until
    /// every conflict has an answer — Cancel aborts the whole import.
    private func resolveImportConflicts(_ incoming: HostGroup, into existing: HostGroup) {
        let conflicts = store.conflictingHosts(incoming: incoming, existing: existing)
        var decisions: [UUID: Bool] = [:]
        var applyToAll: Bool?
        for (index, pair) in conflicts.enumerated() {
            if let applyToAll {
                decisions[pair.incoming.id] = applyToAll
                continue
            }
            let alert = NSAlert()
            alert.messageText = "Host “\(Self.sanitizedForDialog(pair.incoming.name))” exists in both"
            alert.informativeText = Self.importDiffDescription(incoming: pair.incoming, existing: pair.existing)
                + "\n\nReplace uses the file's version — your saved password reference is kept. Keep leaves your version untouched."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep")
            alert.addButton(withTitle: "Cancel Import")
            let remaining = conflicts.count - index - 1
            let checkbox = NSButton(
                checkboxWithTitle: "Apply to the remaining \(remaining) conflicting host(s)",
                target: nil, action: nil
            )
            alert.accessoryView = checkbox
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return } // abort — nothing written yet
            let replace = response == .alertFirstButtonReturn
            decisions[pair.incoming.id] = replace
            if checkbox.state == .on { applyToAll = replace }
        }
        _ = store.applyImport(incoming, action: .merge, replace: decisions)
    }

    /// 0.4 (ค)5: file-sourced text shown in a dialog is stripped of
    /// control characters and capped at 64 characters.
    private static func sanitizedForDialog(_ text: String) -> String {
        let noControls = text.components(separatedBy: .controlCharacters).joined()
        return String(noControls.prefix(64))
    }

    /// 0.4 (ข): shows exactly which fields differ between the two entries.
    private static func importDiffDescription(incoming: Host, existing: Host) -> String {
        var diffs: [String] = []
        if incoming.name != existing.name {
            diffs.append("name: \(sanitizedForDialog(existing.name)) → \(sanitizedForDialog(incoming.name))")
        }
        if incoming.address != existing.address {
            diffs.append("address: \(sanitizedForDialog(existing.address)) → \(sanitizedForDialog(incoming.address))")
        }
        if incoming.port != existing.port {
            diffs.append("port: \(existing.port) → \(incoming.port)")
        }
        if incoming.username != existing.username {
            diffs.append("username: \(sanitizedForDialog(existing.username)) → \(sanitizedForDialog(incoming.username))")
        }
        if incoming.cipherMode != existing.cipherMode {
            diffs.append("cipher: \(existing.cipherMode?.rawValue ?? "auto") → \(incoming.cipherMode?.rawValue ?? "auto")")
        }
        if (incoming.agentForward ?? false) != (existing.agentForward ?? false) {
            let label = { (on: Bool) in on ? "on" : "off" }
            diffs.append("agent forwarding: \(label(existing.agentForward ?? false)) → \(label(incoming.agentForward ?? false))")
        }
        return diffs.isEmpty
            ? "The two entries differ."
            : "Differences (yours → file):\n" + diffs.joined(separator: "\n")
    }

    var selectedTab: SessionTab? {
        tabs.first { $0.id == selectedID }
    }

    /// Keyboard focus belongs to the terminal, like Terminal.app — sidebar
    /// clicks must not strand it on the List (a non-text view leaves the
    /// input-source switcher HUD with no caret to anchor to, so macOS shows
    /// the big centered panel instead of the small caret badge).
    func focusActiveTerminal() {
        guard let tab = selectedTab else { return }
        let view: NSView
        switch tab.content {
        case .local(let controller): view = controller.terminalView
        case .ssh(let controller): view = controller.terminalView
        case .serial(let controller): view = controller.terminalView
        }
        view.window?.makeFirstResponder(view)
    }

    /// The selected tab's terminal view, whatever kind of session it is.
    /// LocalProcessTerminalView is a TerminalView subclass, so one accessor
    /// covers all three.
    var activeTerminalView: TerminalView? {
        guard let tab = selectedTab else { return nil }
        switch tab.content {
        case .local(let controller): return controller.terminalView
        case .ssh(let controller): return controller.terminalView
        case .serial(let controller): return controller.terminalView
        }
    }

    /// Find in scrollback. SwiftTerm already ships the search engine AND the
    /// find bar (`TerminalFindBarView`, anchored top-trailing inside the
    /// terminal view) wired to the standard `performTextFinderAction:`
    /// responder action — the menu items just have to reach it. The action is
    /// sent STRAIGHT to the terminal view rather than down the responder
    /// chain from nil: with the sidebar search field or the find bar's own
    /// field focused, chain dispatch would land somewhere else entirely.
    private func sendFinderAction(_ action: NSTextFinder.Action) {
        guard let view = activeTerminalView else { return }
        // SwiftTerm reads the requested action off the sender's tag, so the
        // sender has to be a tagged NSMenuItem.
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: view, from: sender)
    }

    func showFind() { sendFinderAction(.showFindInterface) }
    func findNextMatch() { sendFinderAction(.nextMatch) }
    func findPreviousMatch() { sendFinderAction(.previousMatch) }
    func useSelectionForFind() { sendFinderAction(.setSearchString) }

    /// Discards the lines that scrolled off the top; the visible screen and
    /// the shell's own state are left alone (same meaning as Terminal.app's
    /// Clear Scrollback, not a reset).
    func clearScrollback() {
        guard let view = activeTerminalView else { return }
        view.getTerminal().clearScrollback()
        view.setNeedsDisplay(view.bounds)
    }

    /// SSH/serial tabs that are still up — what a quit would actually cut.
    /// A tab with no status yet is mid-connect, which counts: killing it
    /// loses the session just the same.
    var liveRemoteSessions: [SessionTab] {
        tabs.filter { tab in
            switch tab.content {
            case .local: return false
            case .ssh, .serial:
                guard let status = tab.statusInfo else { return true }
                return !status.hasPrefix("disconnected")
            }
        }
    }

    func newLocalTab() {
        // Inherit the working directory of the active local tab (Terminal.app
        // behavior); shells report cwd via OSC 7.
        if let tab = selectedTab, case .local(let current) = tab.content,
           let directory = current.currentDirectoryPath {
            FileManager.default.changeCurrentDirectoryPath(directory)
        }
        let controller = LocalTerminalController()
        let shellName = (LocalTerminalController.userShell() as NSString).lastPathComponent
        let tab = SessionTab(content: .local(controller), title: "\(shellName) — This Mac")
        controller.onTitleChange = { [weak tab] title in
            guard let tab, !title.isEmpty else { return }
            tab.title = title
        }
        controller.onExit = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            self.close(tab: tab)
        }
        tabs.append(tab)
        selectedID = tab.id
        controller.start()
    }

    func open(host: Host, password overridePassword: String? = nil, serialLog: Bool? = nil, reusingLogger: SessionLogger? = nil) {
        switch host.kind {
        case .local:
            newLocalTab()
        case .ssh:
            var host = host
            // Recent/ad-hoc copies may lack settings made via Edit Host —
            // inherit credential/username/cipher from the saved host in groups.
            if host.credentialID == nil {
                let match = store.groups.flatMap(\.hosts).first {
                    $0.kind == .ssh && $0.address == host.address && $0.port == host.port
                        && (host.username.isEmpty || $0.username.isEmpty || $0.username == host.username)
                }
                if let match {
                    host.credentialID = match.credentialID
                    if host.username.isEmpty { host.username = match.username }
                    if host.cipherMode == nil { host.cipherMode = match.cipherMode }
                    if host.agentForward == nil { host.agentForward = match.agentForward }
                }
            }
            let credential = host.credentialID.flatMap { credentialStore.credential(for: $0) }
            if host.username.isEmpty, let credential {
                host.username = credential.username
            }
            let password = overridePassword
                ?? credential.flatMap { credentialStore.password(for: $0) }
                ?? passwordCache["\(host.username)@\(host.address):\(host.port)"]
            let controller = SSHTerminalController(host: host, password: password, reusingLogger: reusingLogger)
            let tab = SessionTab(content: .ssh(controller), title: host.name)
            tab.highlightEnabled = UserDefaults.standard.object(forKey: "highlightDefault") as? Bool ?? true
            controller.onStatus = { [weak tab, weak self] status in
                guard let tab else { return }
                tab.statusInfo = status
                if status.hasPrefix("ssh2") {
                    tab.wasConnected = true
                    // Note the recent only AFTER the connect succeeded —
                    // noting it at open() time recorded hosts that never
                    // connected. Password auth already noted it via
                    // rememberSessionPassword, so this covers key-only
                    // auth; didNoteRecent keeps it to one write per connect.
                    if !tab.didNoteRecent,
                       case .ssh(let sshController) = tab.content,
                       !sshController.didAuthenticateWithPassword {
                        tab.didNoteRecent = true
                        self?.store.noteRecent(host)
                    }
                    // "ssh2" means auth succeeded, but the device may still
                    // refuse the shell (VTY full) — resetting attempts here
                    // would loop a 2 s reconnect forever. Reset only if this
                    // session is still alive 30 s later (a dropped one shows
                    // "disconnected"; a reconnected one is a new tab id).
                    let tabID = tab.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        guard let current = self?.tabs.first(where: { $0.id == tabID }),
                              current.statusInfo?.hasPrefix("ssh2") == true else { return }
                        current.autoReconnectAttempts = 0
                    }
                } else if status == "disconnected" {
                    self?.scheduleAutoReconnect(for: tab)
                }
            }
            tabs.append(tab)
            selectedID = tab.id
            controller.start()
        case .serial:
            let controller = SerialTerminalController(host: host, reusingLogger: reusingLogger)
            controller.logOverride = serialLog
            let tab = SessionTab(content: .serial(controller), title: host.name)
            tab.highlightEnabled = UserDefaults.standard.object(forKey: "highlightDefault") as? Bool ?? true
            controller.onStatus = { [weak tab, weak self] status in
                guard let tab else { return }
                tab.statusInfo = status
                // The port is open only when this status arrives — note the
                // recent now, not at open() time; a failed open must not be
                // recorded (and must not be written twice).
                if status.hasPrefix("serial ·") {
                    tab.wasConnected = true
                    if !tab.didNoteRecent {
                        tab.didNoteRecent = true
                        self?.store.noteRecent(host)
                    }
                    // Same 30 s rule as SSH: a port that opens and dies right
                    // back (half-seated cable, switch rebooting) must not
                    // reset the attempt counter, or the retries never stop.
                    let tabID = tab.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                        guard let current = self?.tabs.first(where: { $0.id == tabID }),
                              current.statusInfo?.hasPrefix("serial ·") == true else { return }
                        current.autoReconnectAttempts = 0
                    }
                } else if status == "disconnected" {
                    // A console cable pulled mid-reboot is exactly what
                    // auto-reconnect is for; the EBUSY retry in SerialWorker
                    // covers the moment the old descriptor is still open.
                    self?.scheduleAutoReconnect(for: tab)
                }
            }
            tabs.append(tab)
            selectedID = tab.id
            controller.start()
        }
    }

    func rememberSessionPassword(_ password: String, forUser user: String, host: Host) {
        guard !password.isEmpty else { return }
        passwordCache["\(user)@\(host.address):\(host.port)"] = password
        var resolved = host
        resolved.username = user
        store.noteRecent(resolved)
    }

    func openQuickConnect(_ kind: ConnectionKind) {
        quickConnect = QuickConnectRequest(kind: kind)
    }

    /// Opens an ad-hoc connection; when `groupName` is given the session is
    /// also saved into that sidebar group (created if needed). A password
    /// typed in the form is used for this session even when not saved.
    func connectQuick(host: Host, saveTo groupName: String?, password: String? = nil, serialLog: Bool? = nil) {
        if let groupName {
            if let index = store.groups.firstIndex(where: { $0.name == groupName }) {
                let duplicate = store.groups[index].hosts.contains {
                    $0.address == host.address && $0.port == host.port && $0.username == host.username
                }
                if !duplicate {
                    store.groups[index].hosts.append(host)
                }
            } else {
                store.groups.append(HostGroup(name: groupName, hosts: [host]))
            }
            store.save()
        }
        open(host: host, password: password, serialLog: serialLog)
        collapseSidebar()
    }

    func close(tab: SessionTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        switch tab.content {
        case .local(let controller):
            controller.detach()
        case .ssh(let controller):
            controller.stop()
        case .serial(let controller):
            controller.stop()
        }
        tabs.remove(at: index)
        if selectedID == tab.id {
            selectedID = tabs.indices.contains(index) ? tabs[index].id : tabs.last?.id
        }
    }

    /// Auto-reconnect timestamps per host (user@address:port). Beyond the
    /// 3-attempts-per-drop limit, one host gets at most this many automatic
    /// reconnects per hour — a flapping link must not reconnect forever.
    private var reconnectHistory: [String: [Date]] = [:]
    private static let maxAutoReconnectsPerHour = 10

    private func reconnectBudgetAllows(for host: Host) -> Bool {
        let key = "\(host.username)@\(host.address):\(host.port)"
        let cutoff = Date().addingTimeInterval(-3600)
        let recent = (reconnectHistory[key] ?? []).filter { $0 > cutoff }
        reconnectHistory[key] = recent
        return recent.count < Self.maxAutoReconnectsPerHour
    }

    private func recordAutoReconnect(for host: Host) {
        let key = "\(host.username)@\(host.address):\(host.port)"
        reconnectHistory[key, default: []].append(Date())
    }

    /// A session that had connected successfully and then dropped gets up to
    /// three automatic reconnect attempts (2 s / 5 s / 10 s backoff). Serial
    /// counts too — a console cable on a rebooting switch drops exactly the
    /// same way an SSH session does.
    private func scheduleAutoReconnect(for tab: SessionTab) {
        guard autoReconnect else { return }
        let host: Host
        switch tab.content {
        case .ssh(let controller): host = controller.host
        case .serial(let controller): host = controller.host
        case .local: return
        }
        let attempts = tab.autoReconnectAttempts
        guard attempts < 3 else { return }
        // Never loop on a session that failed its very first connect
        // (wrong password / unreachable) — only revive proven sessions.
        guard tab.wasConnected || attempts > 0 else { return }
        // Overall cap on top of the per-drop limit: at most 10 automatic
        // reconnects per host per hour, across separate drops.
        guard reconnectBudgetAllows(for: host) else {
            tab.statusInfo = "disconnected — auto-reconnect limit reached"
            return
        }

        let delay = [2.0, 5.0, 10.0][attempts]
        let tabID = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self,
                  let current = self.tabs.first(where: { $0.id == tabID }),
                  current.statusInfo == "disconnected" else { return }
            let focusBefore = self.selectedID
            self.recordAutoReconnect(for: host)
            self.reconnect(tab: current)
            if let newTab = self.selectedTab {
                newTab.autoReconnectAttempts = attempts + 1
                newTab.wasConnected = true
                // Don't steal focus if the user was working in another tab.
                if focusBefore != tabID {
                    self.selectedID = focusBefore
                }
            }
        }
    }

    /// Tears down an SSH/serial tab and opens a fresh session to the same
    /// host, keeping the tab's position in the strip.
    func reconnect(tab: SessionTab) {
        let host: Host
        var serialLog: Bool?
        var handedLogger: SessionLogger?
        switch tab.content {
        case .ssh(let controller):
            host = controller.host
            // Keep the same log file across the reconnect — a fresh file
            // per attempt scatters one session over N logs.
            handedLogger = controller.handOverLogger()
        case .serial(let controller):
            host = controller.host
            // Carry the per-session logging choice into the new session.
            serialLog = controller.logOverride
            handedLogger = controller.handOverLogger()
        case .local: return
        }
        let index = tabs.firstIndex { $0.id == tab.id }
        close(tab: tab)
        open(host: host, serialLog: serialLog, reusingLogger: handedLogger)
        if let index, let newTab = tabs.last, tabs.count > 1, index < tabs.count - 1 {
            tabs.removeLast()
            tabs.insert(newTab, at: index)
        }
    }

    func closeCurrentTab() {
        if let tab = selectedTab {
            close(tab: tab)
        }
        if tabs.isEmpty {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func selectTab(number: Int) {
        let index = number - 1
        if tabs.indices.contains(index) {
            selectedID = tabs[index].id
            // ⌘1–9 must hand keyboard focus to the newly shown terminal.
            // The view attaches on the next SwiftUI pass, so focus one
            // runloop tick later — same pattern as the sidebar rows.
            DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
        }
    }

    func selectAdjacentTab(offset: Int) {
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == selectedID } ?? 0
        let next = (current + offset + tabs.count) % tabs.count
        selectedID = tabs[next].id
        DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
    }

    /// ⌘⇧H — flips display highlighting for the active SSH/serial session.
    func toggleHighlightCurrent() {
        guard let tab = selectedTab else { return }
        switch tab.content {
        case .ssh, .serial:
            tab.highlightEnabled.toggle()
            UserDefaults.standard.set(tab.highlightEnabled, forKey: "highlightDefault")
        case .local:
            break
        }
    }

    func toggleSidebar() {
        sidebarShown.toggle()
        // Closing the sidebar must hand keyboard focus back to the
        // terminal — a sidebar-less window with focus stranded on the
        // (now hidden) List leaves the input-source HUD with no caret.
        if !sidebarShown {
            DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
        }
    }

    @Published var showQuickSearch = false

    /// Sidebar auto-collapses once a session is opened from it,
    /// giving the terminal the full window (expand again with ⌘0).
    func collapseSidebar() {
        sidebarShown = false
        DispatchQueue.main.async { [weak self] in self?.focusActiveTerminal() }
    }

    private func installKeyMonitor() {
        // ⌘W closes the tab (not the window) and ⌘T always opens a local shell,
        // matching Terminal.app; the menu items keep the shortcuts discoverable.
        //
        // ⇧⌘H is here for a different reason: the application menu's Hide
        // (⌘H) wins the key-equivalent match against View → Toggle
        // Highlighting, so pressing ⇧⌘H HID THE APP instead of flipping the
        // colors. A local monitor sees the event before menu dispatch, which
        // is the only way to keep the documented shortcut.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command || flags == [.command, .shift] else { return event }
            // On non-Latin layouts (Thai) charactersIgnoringModifiers is the
            // native glyph ("ธ" for the T key), so matching it alone makes
            // ⌘T/⌘W/⇧⌘H dead whenever the input source is Thai. With ⌘ held,
            // `characters` carries the layout's Latin command plane — fall
            // back to it when the primary string isn't ASCII.
            var characters = event.charactersIgnoringModifiers?.lowercased()
            if characters?.allSatisfy(\.isASCII) != true {
                characters = event.characters?.lowercased()
            }
            guard let characters, characters.allSatisfy(\.isASCII) else { return event }
            // Only intercept in the main terminal window — never inside
            // sheets, auth panels, or the Settings window.
            let isMainWindow = MainActor.assumeIsolated {
                guard let key = NSApp?.keyWindow else { return false }
                return !key.isSheet && !(key is NSPanel)
                    && key.styleMask.contains(.fullSizeContentView)
            }
            guard isMainWindow else { return event }
            switch (flags, characters) {
            case (.command, "w"):
                MainActor.assumeIsolated { AppModel.shared.closeCurrentTab() }
                return nil
            case (.command, "t"):
                MainActor.assumeIsolated { AppModel.shared.newLocalTab() }
                return nil
            case ([.command, .shift], "h"):
                MainActor.assumeIsolated { AppModel.shared.toggleHighlightCurrent() }
                return nil
            default:
                return event
            }
        }
    }
}
