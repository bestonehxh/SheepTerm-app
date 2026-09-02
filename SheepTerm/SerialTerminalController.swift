import AppKit
import Foundation
import Synchronization
import SwiftTerm

/// Owns one serial console tab: SwiftTerm view + termios worker.
final class SerialTerminalController: NSObject {
    let terminalView: TerminalView
    private(set) var host: Host

    var onStatus: ((String) -> Void)?
    /// Fired once when the passive stream fingerprint names a device family
    /// for a tab that was still on `.auto`. Serial consoles carry no
    /// protocol-level vendor signal, but a login banner or `display version`
    /// header often does, so the same detector serves them.
    var onVendorDetected: ((Vendor) -> Void)?
    /// Pushed from the main actor and read from worker/highlight queues.
    /// Swift's Mutex expresses shared ownership without unsafe isolation.
    nonisolated private let highlightState = Mutex(false)
    nonisolated var highlightEnabled: Bool {
        get { highlightState.withLock { $0 } }
        set { highlightState.withLock { $0 = newValue } }
    }
    /// Per-session choice from the New Serial form; nil = follow app setting.
    var logOverride: Bool?
    /// Passive family detector. Active only until a vendor is locked in; see
    /// `vendorDetectionActive`.
    private var fingerprint = VendorFingerprint()
    /// Set once the user (or a saved host) has committed a vendor — including
    /// an explicit `.auto`. Passive detection must never override a decision.
    private var vendorChosenByUser = false

    /// Passive detection runs only while highlighting is on, the painter is
    /// present, no vendor has been chosen yet (`host.vendor == nil` covers a
    /// quick-connect and any already-detected/adopted family), and the user
    /// has not committed a choice of their own.
    private var vendorDetectionActive: Bool {
        // Effective family, NOT `host.vendor == nil`: adoptVendor(.auto) —
        // which the tab's highlightVendor didSet fires at open() time — sets
        // host.vendor to a non-nil `.auto`, so a nil check disarmed detection
        // before the first byte ever arrived. Detection runs while the family
        // in effect is still Auto and the user has not committed a choice.
        highlightEnabled && gridHighlighter != nil
            && host.highlightVendor == .auto && !vendorChosenByUser
    }

    /// Stops passive detection for good — the vendor is now the user's (or a
    /// saved host's) explicit choice.
    func suppressVendorDetection() { vendorChosenByUser = true }

    private let worker = SerialWorker()
    /// Shared by the main actor and worker callbacks. SessionLogger
    /// serializes file access; this Mutex protects ownership/reconnection.
    nonisolated private let loggerState: Mutex<SessionLogger?>
    nonisolated private var logger: SessionLogger? {
        get { loggerState.withLock { $0 } }
        set { loggerState.withLock { $0 = newValue } }
    }
    /// Set by handOverLogger(): stop()/onClosed must not close the file —
    /// the reconnecting successor keeps appending to it.
    private var loggerHandedOver = false
    /// Regex stripping + a blocking file write per chunk must not run on
    /// the worker's I/O queue — logging gets its own serial queue (serial
    /// so the log order matches arrival order).
    private let logQueue = DispatchQueue(label: "sheepterm.sessionlog")
    /// nil when SwiftTerm no longer behaves the way grid painting needs it
    /// to (see GridHighlighter.selfCheck) — the session then runs without
    /// colour, which is a complete and correct terminal, just a plainer one.
    private var gridHighlighter: GridHighlighter?
    /// One paint per runloop tick, not one per chunk. A burst of output
    /// queues many feeds on the main thread and each used to trigger its own
    /// full-screen paint — 107 chunks meant 107 paints where one would do,
    /// and that redundancy was most of the throughput cost under a flood.
    private var paintScheduled = false

    private func schedulePaint() {
        guard highlightEnabled, gridHighlighter != nil, !paintScheduled else { return }
        paintScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.paintScheduled = false
            guard self.highlightEnabled else { return }
            self.gridHighlighter?.paintVisible(in: self.terminalView)
        }
    }

    /// The user's per-tab toggle. Unlike the old stream highlighter, the
    /// grid one can act on what is ALREADY on screen: off takes our colour
    /// back off the whole buffer, on paints it back. Both are deliberate
    /// user actions, which is what makes a whole-buffer pass acceptable.
    func setHighlightEnabled(_ enabled: Bool) {
        guard enabled != highlightEnabled else { return }
        highlightEnabled = enabled
        guard let gridHighlighter else { return }
        if enabled {
            gridHighlighter.repaintAll(in: terminalView)
        } else {
            gridHighlighter.strip(in: terminalView)
        }
    }

    /// Live device-family switch. Updates `host` as well, because reconnect —
    /// manual and automatic — rebuilds the session from this snapshot, so
    /// writing only the painter meant a dropped cable silently reverted the
    /// pack the user had just corrected. Unlike the old stream highlighter,
    /// this also RE-colours what is already on screen.
    func adoptVendor(_ vendor: Vendor) {
        host.vendor = vendor
        gridHighlighter?.setVendor(vendor)
        // A session the user set to plain stays plain.
        if highlightEnabled { gridHighlighter?.repaintAll(in: terminalView) }
    }

    init(host: Host, reusingLogger: SessionLogger? = nil) {
        gridHighlighter = GridHighlighter(vendor: host.highlightVendor)
        self.host = host
        // A reconnect keeps appending to the previous session's log file
        // instead of starting a fresh one per attempt.
        loggerState = Mutex(reusingLogger)
        terminalView = SheepSSHTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        Theme.apply(to: terminalView)
        terminalView.terminalDelegate = self

        worker.onData = { [weak self] bytes in
            guard let self else { return }
            // The device's bytes go to the terminal untouched; colour is
            // written into the grid afterwards. Painting is bounded by the
            // SIZE OF THE SCREEN — rows that scroll past between frames are
            // never drawn, so they never need a colour — which is why it can
            // sit on the main thread next to the feed instead of needing a
            // queue and a carry buffer of its own.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.terminalView.feed(byteArray: bytes[...])
                self.schedulePaint()
                // Passive family detection, after the terminal has the bytes.
                // Bounded and one-shot — see VendorFingerprint. Once a family
                // is named, adopting it makes host.vendor non-nil, so this
                // stops on the next chunk without any extra flag.
                if self.vendorDetectionActive, let detected = self.fingerprint.consider(bytes) {
                    self.printNotice("auto-detected \(detected.label) — highlighting set")
                    self.onVendorDetected?(detected)
                }
            }
            // Logging (regex strip + blocking file write) must not stall
            // the worker's I/O loop — hand it to the log queue.
            let logger = self.logger
            self.logQueue.async { logger?.append(bytes) }
        }
        // Notices/status/closed hop via DispatchQueue.main.async — the same
        // queue feed() uses — so everything delivers in FIFO order (Task
        // scheduling does not guarantee it). MainActor isolation comes from
        // the default-actor build setting, so main-actor state is touched
        // directly inside.
        // A refused write means the device did NOT get that line, so a paced
        // paste must stop rather than keep counting.
        worker.onInputDiscarded = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                (self.terminalView as? SheepSSHTerminalView)?
                    .cancelSafePaste(reason: .inputDiscarded)
            }
        }
        worker.onNotice = { [weak self] message in
            DispatchQueue.main.async {
                self?.printNotice(message)
            }
        }
        worker.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.onStatus?(status)
            }
        }
        worker.onClosed = { [weak self] message in
            DispatchQueue.main.async {
                guard let self else { return }
                (self.terminalView as? SheepSSHTerminalView)?
                    .cancelSafePaste(reason: .sessionEnded)
                self.printNotice(message, error: true)
                // A prompt the user dismissed is a decision, not a drop. Plain
                // "disconnected" is what auto-reconnect keys on, and it would
                // put the same prompt straight back up — three times.
                self.onStatus?(message.hasPrefix("connection cancelled")
                               ? "disconnected — cancelled" : "disconnected")
                // The log is NOT closed here. Auto-reconnect hands this
                // logger to the successor 2–10 s from now, and a logger closed
                // in between dropped every byte of the reconnected session
                // while the successor printed "logging continues". stop()
                // (tab close) and shutdownForQuit() own the close.
            }
        }
    }

    func start() {
        printNotice("opening \(host.address) at \(host.port) baud…")
        if let logger {
            printNotice("logging continues to \(logger.url.path)")
        } else if logOverride ?? (UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true) {
            logger = SessionLogger(sessionName: host.name)
            if let logger {
                printNotice("logging to \(logger.url.path)")
            }
        }
        worker.start(devicePath: host.address, baudRate: host.port)
    }

    /// Transfers the open log to a reconnecting successor: the old worker
    /// stops but the file stays open, so the new session appends to the
    /// same log instead of starting a fresh file per attempt.
    func handOverLogger() -> SessionLogger? {
        loggerHandedOver = true
        return logger
    }

    /// Quit: stop the worker and close the log SYNCHRONOUSLY, behind any
    /// appends already queued. The async close in stop() never ran before
    /// the process exited, and the tail of every open log went with it.
    /// close() itself waits for the flush, bounded by the logger's backlog.
    func shutdownForQuit() {
        worker.stop()
        onStatus = nil
        let logger = self.logger
        logQueue.sync { logger?.close() }
    }

    func stop() {
        (terminalView as? SheepSSHTerminalView)?.cancelSafePaste(reason: .sessionEnded)
        worker.stop()
        // Queued behind the final appends for the same reason as onClosed.
        if !loggerHandedOver {
            let logger = self.logger
            logQueue.async { logger?.close() }
        }
        onStatus = nil
    }

    private func printNotice(_ message: String, error: Bool = false) {
        let color = error ? "\u{1b}[91m" : "\u{1b}[90m"
        terminalView.feed(text: "\r\n\(color)\(message)\u{1b}[0m\r\n")
    }
}

extension SerialTerminalController: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        (source as? SheepSSHTerminalView)?.prepareForOrdinaryUserInput()
        worker.write(Array(data))
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Reflow renumbers rows, so what the paint cache remembers about row
        // N no longer describes the line now at row N.
        MainActor.assumeIsolated {
            gridHighlighter?.invalidateCache()
            schedulePaint()
        }
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// Scrolling back reveals rows that were never painted: painting is
    /// bounded to what is on screen, and rows that scrolled past inside a
    /// single chunk were never on screen. Without this hook most of the
    /// scrollback stayed permanently plain.
    nonisolated func scrolled(source: TerminalView, position: Double) {
        MainActor.assumeIsolated { schedulePaint() }
    }

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
