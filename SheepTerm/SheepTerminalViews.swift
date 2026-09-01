import AppKit
import SwiftTerm

// SwiftTerm's Mac view implements NSTextInputClient but exposes no text
// accessibility. The macOS input-source switcher anchors its small caret
// badge via the ACCESSIBILITY text protocol (AXTextArea + AXSelectedTextRange
// + parameterized AXBoundsForRange) — without the full set the system falls
// back to the big centered language panel. These subclasses expose the
// visible terminal text and its line/range mapping for VoiceOver while also
// providing enough geometry for the badge to anchor.

private func axCols(_ terminal: Terminal) -> Int { max(terminal.cols, 1) }

/// A VoiceOver snapshot of the visible terminal. Newlines make rows audible
/// as separate lines; per-cell UTF-16 accounting keeps the insertion point
/// correct for Thai, emoji, combining characters, and wide glyphs.
private struct TerminalAXSnapshot {
    let value: NSString
    let lineRanges: [NSRange]
    let cursorRange: NSRange
    let cursorLine: Int
}

/// Memo for the snapshot above. Building one walks the whole visible grid,
/// O(rows × cols) — and a screen reader asks LINE BY LINE, so an uncached
/// build turns one traversal of a fullscreen window into O(rows² × cols).
/// The entry is keyed on a cheap identity (which terminal, its size, the
/// cursor, the scroll offset) plus a short TTL: a burst of AX queries about
/// one unchanged screen now builds exactly once, any cursor or viewport move
/// invalidates immediately, and text rewritten in place under a still cursor
/// is stale for at most `maxAge` — far below what a reader can consume.
/// One entry is enough: only the selected tab's terminal is in the window.
private enum TerminalAXCache {
    struct Key: Equatable {
        let terminal: ObjectIdentifier
        let rows: Int
        let cols: Int
        let cursorX: Int
        let cursorY: Int
        let topRow: Int
    }

    static let maxAge: TimeInterval = 0.1
    static var key: Key?
    static var snapshot: TerminalAXSnapshot?
    static var builtAt = Date.distantPast

    static func key(for terminal: Terminal) -> Key {
        let cursor = terminal.getCursorLocation()
        return Key(
            terminal: ObjectIdentifier(terminal),
            rows: terminal.rows,
            cols: terminal.cols,
            cursorX: cursor.x,
            cursorY: cursor.y,
            topRow: terminal.getTopVisibleRow()
        )
    }
}

private func terminalAXSnapshot(_ terminal: Terminal) -> TerminalAXSnapshot {
    let key = TerminalAXCache.key(for: terminal)
    if let cached = TerminalAXCache.snapshot, TerminalAXCache.key == key,
       Date().timeIntervalSince(TerminalAXCache.builtAt) < TerminalAXCache.maxAge {
        return cached
    }
    let snapshot = buildTerminalAXSnapshot(terminal)
    TerminalAXCache.key = key
    TerminalAXCache.snapshot = snapshot
    TerminalAXCache.builtAt = Date()
    return snapshot
}

private func buildTerminalAXSnapshot(_ terminal: Terminal) -> TerminalAXSnapshot {
    let rows = max(terminal.rows, 1)
    let cols = axCols(terminal)
    let cursor = terminal.getCursorLocation()
    let cursorLine = min(max(cursor.y, 0), rows - 1)
    let cursorColumn = min(max(cursor.x, 0), cols)
    var text = ""
    var lineRanges: [NSRange] = []
    var utf16Location = 0
    var cursorLocation = 0

    for row in 0..<rows {
        var line = ""
        var lineUTF16Length = 0
        var cursorColumnOffset = 0
        for col in 0..<cols {
            let raw = terminal.getCharacter(col: col, row: row) ?? " "
            // SwiftTerm uses code point zero for empty and wide-character
            // continuation cells. NUL is not useful spoken text; a space
            // preserves the grid position without exposing a control byte.
            let character: Character = raw == "\0" ? " " : raw
            if row == cursorLine, col < cursorColumn {
                cursorColumnOffset += String(character).utf16.count
            }
            line.append(character)
            lineUTF16Length += String(character).utf16.count
        }
        lineRanges.append(NSRange(location: utf16Location, length: lineUTF16Length))
        if row == cursorLine {
            cursorLocation = utf16Location + cursorColumnOffset
        }
        text.append(line)
        utf16Location += lineUTF16Length
        if row + 1 < rows {
            text.append("\n")
            utf16Location += 1
        }
    }
    return TerminalAXSnapshot(
        value: text as NSString,
        lineRanges: lineRanges,
        cursorRange: NSRange(location: cursorLocation, length: 0),
        cursorLine: cursorLine
    )
}

private func terminalAXString(_ terminal: Terminal, for range: NSRange) -> String? {
    let snapshot = terminalAXSnapshot(terminal)
    guard range.location != NSNotFound, range.location <= snapshot.value.length else { return nil }
    let clamped = NSRange(
        location: range.location,
        length: min(max(range.length, 0), snapshot.value.length - range.location)
    )
    return snapshot.value.substring(with: clamped)
}

private func terminalAXLine(_ terminal: Terminal, for index: Int) -> Int {
    let snapshot = terminalAXSnapshot(terminal)
    guard !snapshot.lineRanges.isEmpty else { return 0 }
    let clamped = min(max(index, 0), snapshot.value.length)
    return snapshot.lineRanges.firstIndex { clamped <= NSMaxRange($0) }
        ?? (snapshot.lineRanges.count - 1)
}

private func terminalAXRange(_ terminal: Terminal, forLine line: Int) -> NSRange {
    let ranges = terminalAXSnapshot(terminal).lineRanges
    guard ranges.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
    return ranges[line]
}

/// Auto-hiding scrollbar: invisible at rest, appears while scrolling and
/// fades back out (modern macOS overlay behavior — SwiftTerm's scroller is
/// always-visible legacy style). Alpha only, so the terminal never reflows.
@MainActor
final class ScrollerFader {
    private weak var scroller: NSScroller?
    private weak var view: NSView?
    private var lastFlash = Date.distantPast
    private var fadePending = false

    /// One app-level scroll monitor fans out to every attached fader —
    /// N tabs would otherwise stack N local monitors on each scroll event.
    private static let registry = NSHashTable<ScrollerFader>.weakObjects()
    private static var monitor: Any?

    func attach(in view: NSView) {
        guard scroller == nil else { return }
        scroller = view.subviews.compactMap { $0 as? NSScroller }.first
        scroller?.alphaValue = 0
        self.view = view
        Self.registry.add(self)
        Self.installMonitorIfNeeded()
    }

    private static func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        // SwiftTerm's scrollWheel isn't open for overriding — watch scroll
        // events and forward to the fader whose view is under the pointer.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                for fader in registry.allObjects {
                    guard let view = fader.view, event.window === view.window,
                          view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                    else { continue }
                    fader.flash()
                    break
                }
            }
            return event
        }
    }

    // No explicit unregister in deinit: the weak registry drops deallocated
    // faders on its own, and the shared monitor lives for the app's lifetime.

    func flash() {
        guard let scroller else { return }
        lastFlash = Date()
        scroller.alphaValue = 1
        // At most one pending fade block — a scroll storm would otherwise
        // queue an asyncAfter closure per event.
        guard !fadePending else { return }
        fadePending = true
        scheduleFade()
    }

    private func scheduleFade() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak scroller] in
            guard let self else { return }
            // Scrolled again during the wait — re-arm instead of fading.
            if Date().timeIntervalSince(self.lastFlash) < 1.0 {
                self.scheduleFade()
                return
            }
            self.fadePending = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.4
                scroller?.animator().alphaValue = 0
            }
        }
    }
}

final class SheepSSHTerminalView: TerminalView {
    private let scrollerFader = ScrollerFader()
    private let pastePacer = SafePastePacer()
    private var pastePromptPresented = false
    private var pasteHUD: NSVisualEffectView?
    private var pasteProgressLabel: NSTextField?
    private var sendingPacedLine = false

    private static let pasteDelayKey = "safePasteDelayMilliseconds"
    private static let pasteDelayChoices = [50, 100, 200, 300, 500, 1_000]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            scrollerFader.attach(in: self)
        } else {
            // Only the selected terminal is attached to the window. Continuing
            // an invisible configuration paste after a tab switch is unsafe.
            cancelSafePaste(reason: .sessionEnded)
        }
    }

    @objc override func paste(_ sender: Any) {
        guard AppModel.shared.safePasteEnabled else {
            super.paste(sender)
            return
        }
        guard !pastePromptPresented,
              let text = NSPasteboard.general.string(forType: .string)
        else {
            NSSound.beep()
            return
        }

        let plan: SafePastePlan
        do {
            plan = try SafePastePlan.parse(text)
        } catch SafePastePlan.ParseError.singleLine {
            super.paste(sender)
            return
        } catch SafePastePlan.ParseError.tooManyBytes {
            showPasteLimitAlert("The clipboard is larger than 5 MB.")
            return
        } catch SafePastePlan.ParseError.tooManyLines {
            showPasteLimitAlert("The clipboard contains more than 10,000 lines.")
            return
        } catch {
            NSSound.beep()
            return
        }

        if pastePacer.isActive {
            cancelSafePaste(reason: .replaced)
        }
        presentSafePasteConfirmation(plan: plan, originalText: text)
    }

    func cancelSafePaste(reason: SafePastePacer.EndReason = .sessionEnded) {
        pastePacer.stop(reason: reason)
        hidePasteHUD()
    }

    /// TerminalViewDelegate.send is declared nonisolated because transports
    /// may implement it off-main, although SwiftTerm's macOS input contract
    /// calls it on the view/main thread. Keep the synchronization explicit so
    /// ordinary typing cancels a running paste before its bytes are queued.
    nonisolated func prepareForOrdinaryUserInput() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                if !sendingPacedLine, pastePacer.isActive {
                    cancelSafePaste(reason: .keyboardInput)
                }
            }
        } else {
            DispatchQueue.main.sync {
                if !self.sendingPacedLine, self.pastePacer.isActive {
                    self.cancelSafePaste(reason: .keyboardInput)
                }
            }
        }
    }

    private func presentSafePasteConfirmation(plan: SafePastePlan, originalText: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Safe Multi-line Paste"
        alert.informativeText = "Review all \(plan.lines.count) lines (\(Self.byteCountText(plan.sourceByteCount))) before sending."
        alert.addButton(withTitle: "Send Line by Line")
        alert.addButton(withTitle: "Paste Immediately")
        alert.addButton(withTitle: "Cancel")

        let reviewLabel = NSTextField(labelWithString: "Commands to send:")
        reviewLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)

        let previewScrollView = NSScrollView(frame: .zero)
        previewScrollView.borderType = .bezelBorder
        previewScrollView.hasVerticalScroller = true
        previewScrollView.hasHorizontalScroller = true
        previewScrollView.autohidesScrollers = false
        previewScrollView.verticalScrollElasticity = .automatic
        previewScrollView.horizontalScrollElasticity = .automatic

        let previewTextView = NSTextView(frame: .zero)
        previewTextView.string = plan.lines.joined(separator: "\n")
        previewTextView.isEditable = false
        previewTextView.isSelectable = true
        previewTextView.isRichText = false
        previewTextView.allowsUndo = false
        previewTextView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        previewTextView.textColor = .labelColor
        previewTextView.backgroundColor = .textBackgroundColor
        previewTextView.textContainerInset = NSSize(width: 6, height: 6)
        previewTextView.isVerticallyResizable = true
        previewTextView.isHorizontallyResizable = true
        previewTextView.minSize = .zero
        previewTextView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        previewTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        previewTextView.textContainer?.widthTracksTextView = false
        previewScrollView.documentView = previewTextView

        let delayLabel = NSTextField(labelWithString: "Delay between lines:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for milliseconds in Self.pasteDelayChoices {
            popup.addItem(withTitle: Self.delayTitle(milliseconds))
            popup.lastItem?.representedObject = milliseconds
        }
        let saved = UserDefaults.standard.integer(forKey: Self.pasteDelayKey)
        let selected = Self.pasteDelayChoices.contains(saved) ? saved : 200
        if let index = Self.pasteDelayChoices.firstIndex(of: selected) {
            popup.selectItem(at: index)
        }
        popup.toolTip = "Time allowed for the device CLI to process each command"

        let delayControls = NSStackView(views: [delayLabel, popup])
        delayControls.orientation = .horizontal
        delayControls.alignment = .centerY
        delayControls.spacing = 10

        let accessory = NSStackView(views: [reviewLabel, previewScrollView, delayControls])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 620, height: 330)
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewScrollView.widthAnchor.constraint(equalToConstant: 620),
            previewScrollView.heightAnchor.constraint(equalToConstant: 285),
        ])
        alert.accessoryView = accessory

        pastePromptPresented = true
        let handleResponse = { [weak self, weak popup] (response: NSApplication.ModalResponse) in
            guard let self else { return }
            self.pastePromptPresented = false
            switch response {
            case .alertFirstButtonReturn:
                let delay = popup?.selectedItem?.representedObject as? Int ?? 200
                UserDefaults.standard.set(delay, forKey: Self.pasteDelayKey)
                self.startSafePaste(plan: plan, delayMilliseconds: delay)
            case .alertSecondButtonReturn:
                self.sendImmediatePaste(originalText)
            default:
                break
            }
        }

        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: handleResponse)
        } else {
            handleResponse(alert.runModal())
        }
    }

    private func startSafePaste(plan: SafePastePlan, delayMilliseconds: Int) {
        showPasteHUD(sent: 0, total: plan.lines.count, delayMilliseconds: delayMilliseconds)
        pastePacer.start(
            plan: plan,
            delayMilliseconds: delayMilliseconds,
            send: { [weak self] bytes in
                guard let self else { return }
                self.sendingPacedLine = true
                self.send(data: bytes[...])
                self.sendingPacedLine = false
            },
            progress: { [weak self] sent, total in
                self?.showPasteHUD(sent: sent, total: total, delayMilliseconds: delayMilliseconds)
            },
            completion: { [weak self] _, _ in
                self?.hidePasteHUD()
            }
        )
    }

    /// Bracketed-paste markers: `ESC [ 200 ~` / `ESC [ 201 ~`.
    /// SwiftTerm's `EscapeSequences` exposes these as mutable `static var`s,
    /// which Swift 6 concurrency rejects as shared mutable state — the bytes
    /// are protocol constants, so we keep immutable copies here.
    private static let bracketedPasteStart: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e]
    private static let bracketedPasteEnd: [UInt8] = [0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e]

    private func sendImmediatePaste(_ text: String) {
        if terminal.bracketedPasteMode {
            send(data: Self.bracketedPasteStart[...])
        }
        send(txt: text)
        if terminal.bracketedPasteMode {
            send(data: Self.bracketedPasteEnd[...])
        }
    }

    private func showPasteLimitAlert(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Safe Paste Limit"
        alert.informativeText = detail + " Split it into smaller sections before sending."
        alert.addButton(withTitle: "OK")
        if let window, window.attachedSheet == nil {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func showPasteHUD(sent: Int, total: Int, delayMilliseconds: Int) {
        if pasteHUD == nil {
            let hud = NSVisualEffectView()
            hud.material = .hudWindow
            hud.state = .active
            hud.blendingMode = .withinWindow
            hud.wantsLayer = true
            hud.layer?.cornerRadius = 7
            hud.translatesAutoresizingMaskIntoConstraints = false

            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .labelColor
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            pasteProgressLabel = label

            let stop = NSButton(title: "Stop", target: self, action: #selector(stopSafePasteFromHUD))
            stop.bezelStyle = .rounded
            stop.controlSize = .small
            stop.toolTip = "Stop before sending the next line"

            let stack = NSStackView(views: [label, stop])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            hud.addSubview(stack)
            addSubview(hud)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: hud.leadingAnchor, constant: 10),
                stack.trailingAnchor.constraint(equalTo: hud.trailingAnchor, constant: -8),
                stack.topAnchor.constraint(equalTo: hud.topAnchor, constant: 6),
                stack.bottomAnchor.constraint(equalTo: hud.bottomAnchor, constant: -6),
                hud.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                hud.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                hud.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            ])
            pasteHUD = hud
        }
        pasteProgressLabel?.stringValue = "Safe Paste \(sent)/\(total) · \(Self.delayTitle(delayMilliseconds))"
        pasteHUD?.isHidden = false
    }

    private func hidePasteHUD() {
        pasteHUD?.isHidden = true
    }

    @objc private func stopSafePasteFromHUD() {
        cancelSafePaste(reason: .stopped)
    }

    private static func delayTitle(_ milliseconds: Int) -> String {
        milliseconds >= 1_000 ? "\(milliseconds / 1_000) s" : "\(milliseconds) ms"
    }

    private static func byteCountText(_ count: Int) -> String {
        if count < 1_024 { return "\(count) bytes" }
        return String(format: "%.1f KB", Double(count) / 1_024)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilitySelectedTextRange() -> NSRange {
        terminalAXSnapshot(terminal).cursorRange
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        terminalAXSnapshot(terminal).cursorLine
    }

    override func accessibilityNumberOfCharacters() -> Int {
        terminalAXSnapshot(terminal).value.length
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        let length = terminalAXSnapshot(terminal).value.length
        return NSRange(location: 0, length: length)
    }

    override func accessibilityValue() -> Any? {
        terminalAXSnapshot(terminal).value as String
    }

    override func accessibilityString(for range: NSRange) -> String? {
        terminalAXString(terminal, for: range)
    }

    override func accessibilityLine(for index: Int) -> Int {
        terminalAXLine(terminal, for: index)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        terminalAXRange(terminal, forLine: line)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        firstRect(forCharacterRange: range, actualRange: nil)
    }
}

final class SheepLocalTerminalView: LocalProcessTerminalView {
    private let scrollerFader = ScrollerFader()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollerFader.attach(in: self)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilitySelectedTextRange() -> NSRange {
        terminalAXSnapshot(terminal).cursorRange
    }

    override func accessibilityInsertionPointLineNumber() -> Int {
        terminalAXSnapshot(terminal).cursorLine
    }

    override func accessibilityNumberOfCharacters() -> Int {
        terminalAXSnapshot(terminal).value.length
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        let length = terminalAXSnapshot(terminal).value.length
        return NSRange(location: 0, length: length)
    }

    override func accessibilityValue() -> Any? {
        terminalAXSnapshot(terminal).value as String
    }

    override func accessibilityString(for range: NSRange) -> String? {
        terminalAXString(terminal, for: range)
    }

    override func accessibilityLine(for index: Int) -> Int {
        terminalAXLine(terminal, for: index)
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        terminalAXRange(terminal, forLine: line)
    }

    override func accessibilityFrame(for range: NSRange) -> NSRect {
        firstRect(forCharacterRange: range, actualRange: nil)
    }
}
