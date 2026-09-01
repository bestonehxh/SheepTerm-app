import AppKit
import Foundation
import Synchronization
import SwiftTerm

/// Owns one SSH session tab: the SwiftTerm view plus the libssh worker.
final class SSHTerminalController: NSObject {
    let terminalView: TerminalView
    private(set) var host: Host

    var onTitleChange: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    /// Pushed from the main actor and read from worker/highlight queues.
    /// Swift's Mutex expresses shared ownership without unsafe isolation.
    nonisolated private let highlightState = Mutex(false)
    nonisolated var highlightEnabled: Bool {
        get { highlightState.withLock { $0 } }
        set { highlightState.withLock { $0 = newValue } }
    }

    private let worker = SSHWorker()
    private let password: String?
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
    /// Set when password/keyboard-interactive auth succeeded — AppModel
    /// uses it to note the recent-host entry exactly once per connect
    /// (password path notes it via rememberSessionPassword; key-only auth
    /// is noted when the status first reaches "ssh2").
    private(set) var didAuthenticateWithPassword = false
    /// Regex stripping + a blocking file write per chunk must not run on
    /// the worker's I/O queue — logging gets its own serial queue (serial
    /// so the log order matches arrival order).
    private let logQueue = DispatchQueue(label: "sheepterm.sessionlog")
    private let hlBuffer = HighlightBuffer()

    init(host: Host, password: String?, reusingLogger: SessionLogger? = nil) {
        self.host = host
        self.password = password
        // A reconnect keeps appending to the previous session's log file
        // instead of starting a fresh one per attempt.
        loggerState = Mutex(reusingLogger)
        terminalView = SheepSSHTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        Theme.apply(to: terminalView)
        terminalView.terminalDelegate = self

        worker.onData = { [weak self] bytes in
            guard let self else { return }
            // Highlighting runs on the highlight queue; only the SwiftTerm
            // feed hops to the main thread.
            let enabled = self.highlightEnabled
            // [weak self] belongs on the OUTER closure too: HighlightBuffer
            // retains this closure in flushWork, so a strong capture here is
            // a controller -> hlBuffer -> flushWork -> closure -> controller
            // cycle that leaks the whole tab (view + scrollback) on close.
            self.hlBuffer.append(bytes, enabled: enabled) { [weak self] processed in
                DispatchQueue.main.async {
                    self?.terminalView.feed(byteArray: processed)
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
                self.onStatus?("disconnected")
                // Close on the log queue, BEHIND any appends still queued —
                // closing inline here lets close() win the lock ahead of the
                // final chunks, which then hit `closed` and are dropped: the
                // tail of the session (the part you most want) never lands.
                if !self.loggerHandedOver {
                    let logger = self.logger
                    self.logQueue.async { logger?.close() }
                }
            }
        }
        worker.passwordPrompt = { prompt in
            Self.askOnMainActor(prompt: prompt, secure: true)
        }
        worker.challengePrompt = { prompt, secure in
            Self.askOnMainActor(prompt: prompt, secure: secure)
        }
        worker.onPasswordWorked = { [weak self] user, password in
            DispatchQueue.main.async {
                guard let self else { return }
                self.didAuthenticateWithPassword = true
                self.host.username = user
                AppModel.shared.rememberSessionPassword(password, forUser: user, host: self.host)
            }
        }
        worker.usernamePrompt = { prompt in
            Self.askOnMainActor(prompt: prompt, secure: false)
        }
    }

    /// libssh asks for credentials synchronously on its dedicated blocking
    /// queue, while AppKit must present the prompt on the main actor. Keep
    /// that bridge in one place and avoid sync-dispatching to the main queue
    /// if a future caller is already there.
    nonisolated private static func askOnMainActor(prompt: String, secure: Bool) -> String? {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                AuthPrompt.ask(prompt: prompt, secure: secure)
            }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                AuthPrompt.ask(prompt: prompt, secure: secure)
            }
        }
    }

    func start() {
        let terminal = terminalView.getTerminal()
        printNotice("connecting to \(host.address):\(host.port)…")
        if let logger {
            printNotice("logging continues to \(logger.url.path)")
        } else if UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true {
            logger = SessionLogger(sessionName: host.name)
            if let logger {
                printNotice("logging to \(logger.url.path)")
            }
        }
        worker.start(SSHConfig(
            host: host.address,
            port: host.port,
            username: host.username,
            password: password,
            mode: host.cipherMode ?? .auto,
            initialCols: terminal.cols,
            initialRows: terminal.rows,
            agentForward: host.agentForward ?? false
        ))
    }

    /// Transfers the open log to a reconnecting successor: the old worker
    /// stops but the file stays open, so the new session appends to the
    /// same log instead of starting a fresh file per attempt.
    func handOverLogger() -> SessionLogger? {
        loggerHandedOver = true
        return logger
    }

    func stop() {
        (terminalView as? SheepSSHTerminalView)?.cancelSafePaste(reason: .sessionEnded)
        worker.stop()
        // Queued behind the final appends for the same reason as onClosed.
        if !loggerHandedOver {
            let logger = self.logger
            logQueue.async { logger?.close() }
        }
        onTitleChange = nil
        onStatus = nil
    }

    private func printNotice(_ message: String, error: Bool = false) {
        let color = error ? "\u{1b}[91m" : "\u{1b}[90m"
        terminalView.feed(text: "\r\n\(color)\(message)\u{1b}[0m\r\n")
    }

}

extension SSHTerminalController: TerminalViewDelegate {
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        (source as? SheepSSHTerminalView)?.prepareForOrdinaryUserInput()
        worker.write(Array(data))
    }

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        worker.resize(cols: newCols, rows: newRows)
    }

    nonisolated func setTerminalTitle(source: TerminalView, title: String) {
        DispatchQueue.main.async {
            self.onTitleChange?(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func scrolled(source: TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
