import AppKit
import Foundation
import Synchronization
import SwiftTerm

/// Owns one local shell session: the SwiftTerm view plus the pty-backed process.
/// The view is created once and kept alive for the lifetime of its tab so the
/// scrollback and running programs survive tab switches.
final class LocalTerminalController: NSObject {
    let terminalView: LocalProcessTerminalView

    var onTitleChange: ((String) -> Void)?
    var onExit: ((Int32?) -> Void)?
    private(set) var currentDirectory: String?

    /// OSC 7 reports arrive as file:// URLs; expose a plain path.
    var currentDirectoryPath: String? {
        guard let directory = currentDirectory else { return nil }
        if directory.hasPrefix("file://"), let url = URL(string: directory) {
            return url.path
        }
        return directory.hasPrefix("/") ? directory : nil
    }

    override init() {
        terminalView = SheepLocalTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        Theme.apply(to: terminalView)
        terminalView.processDelegate = self
    }

    func start() {
        let shell = Self.userShell()
        let shellName = (shell as NSString).lastPathComponent

        var environment: [String] = []
        var seen = Set<String>()
        for (key, value) in ProcessInfo.processInfo.environment {
            if key == "TERM" || key == "COLORTERM" || key == "TERM_PROGRAM" { continue }
            environment.append("\(key)=\(value)")
            seen.insert(key)
        }
        environment.append("TERM=xterm-256color")
        environment.append("COLORTERM=truecolor")
        // Makes the stock /etc/zshrc emit OSC 7 cwd reports (same hook
        // Terminal.app uses), so new tabs can inherit the directory.
        environment.append("TERM_PROGRAM=Apple_Terminal")
        environment.append("TERM_PROGRAM_VERSION=453")
        if !seen.contains("LANG") { environment.append("LANG=en_US.UTF-8") }

        // Leading dash marks the shell as a login shell, same as Terminal.app.
        terminalView.startProcess(
            executable: shell,
            args: [],
            environment: environment,
            execName: "-\(shellName)"
        )
    }

    func detach() {
        // Read the pid BEFORE terminate(): SwiftTerm's terminate() cancels
        // its own exit monitor (childStopped), so nothing would ever reap
        // the SIGTERMed shell — it stayed a zombie until app quit.
        let pid = terminalView.process?.shellPid ?? 0
        // Kill the shell first — closing a tab must not leave an orphaned
        // process holding a pty and eating CPU in the background.
        //
        // Only register a reaper when we ACTUALLY terminated something. On
        // the ordinary path the shell has already exited and SwiftTerm's
        // monitor has already waitpid'ed it, but `shellPid` is still set — so
        // registering anyway attached a DispatchSourceProcess to a pid that
        // no longer exists. Its exit event never fires, so the source and its
        // dictionary entry lived in `reapers` for the life of the app, once
        // per closed local tab.
        let terminated = terminalView.process.running
        if terminated {
            terminalView.terminate()
        }
        if terminated, pid > 0 {
            Self.reapAfterTerminate(pid)
        }
        terminalView.processDelegate = nil
        onTitleChange = nil
        onExit = nil
    }

    /// Reapers for shells killed at tab close, kept until the exit event
    /// fires — the source must stay referenced or GCD cancels it.
    private static let reapers = Mutex<[pid_t: DispatchSourceProcess]>([:])

    /// Reaps a terminated shell off the main thread. When the shell exited
    /// normally SwiftTerm's own monitor already waitpid'ed it — our
    /// waitpid then just gets ECHILD, which is fine.
    private static func reapAfterTerminate(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            reapers.withLock { $0[pid] = nil }
        }
        reapers.withLock { $0[pid] = source }
        source.activate()
    }

    static func userShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}

extension LocalTerminalController: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    // All UI hops use DispatchQueue.main.async — the same queue feed()
    // uses — so callbacks deliver in FIFO order (Task scheduling does not
    // guarantee it). MainActor isolation comes from the default-actor
    // build setting, so main-actor state can be touched directly.
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async {
            self.onTitleChange?(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async {
            self.currentDirectory = directory
        }
    }

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.onExit?(exitCode)
        }
    }
}
