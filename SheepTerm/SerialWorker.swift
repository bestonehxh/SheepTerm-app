import Darwin
import Foundation
import Synchronization

/// Runs one serial-port session (POSIX termios) on its own queue,
/// mirroring SSHWorker's thread-safe surface.
nonisolated final class SerialWorker: Sendable {
    private let queue = DispatchQueue(label: "sheepterm.serial.session")
    private struct State: Sendable {
        var pendingWrites: [UInt8] = []
        /// Set when input was discarded because the buffer is full; cleared
        /// by the next accepted write, so one stall produces one notice.
        var writeOverflowNotified = false
        /// True from start() until run() has completed all of its defers.
        /// Kept separate from `running`, which stop() clears immediately.
        var runActive = false
        var running = false
        /// Write end of the self-pipe; -1 when the loop isn't up.
        var wakeFD: Int32 = -1
        var onData: (@Sendable ([UInt8]) -> Void)?
        var onNotice: (@Sendable (String) -> Void)?
        /// Fired when a write was refused. A paced paste has to stop: the
        /// pacer counts lines it HANDED OVER, so without this the HUD
        /// reports a full send while the device got a config with holes.
        var onInputDiscarded: (@Sendable () -> Void)?
        var onStatus: (@Sendable (String) -> Void)?
        var onClosed: (@Sendable (String) -> Void)?
    }
    private let state = Mutex(State())
    /// Cap on buffered input — a wedged session must not grow it forever.
    ///
    /// Sized ABOVE the app's own paste limit on purpose. At 1 MB it was
    /// smaller than `SafePastePlan.maxBytes`, so a legal 2 MB paste — or any
    /// single-line clipboard over 1 MB, which bypasses Safe Paste entirely —
    /// was refused whole on a perfectly healthy session and reported as if
    /// the connection had stalled.
    private static let maxPendingWrites = SafePastePlan.maxBytes + 1024 * 1024

    var onData: (@Sendable ([UInt8]) -> Void)? {
        get { state.withLock { $0.onData } }
        set { state.withLock { $0.onData = newValue } }
    }
    var onNotice: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onNotice } }
        set { state.withLock { $0.onNotice = newValue } }
    }

    var onInputDiscarded: (@Sendable () -> Void)? {
        get { state.withLock { $0.onInputDiscarded } }
        set { state.withLock { $0.onInputDiscarded = newValue } }
    }
    var onStatus: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onStatus } }
        set { state.withLock { $0.onStatus = newValue } }
    }
    var onClosed: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onClosed } }
        set { state.withLock { $0.onClosed = newValue } }
    }

    func start(devicePath: String, baudRate: Int) {
        let accepted = state.withLock { state in
            // One file descriptor owns this worker queue at a time. Do not let
            // a new run overtake teardown after stop().
            guard !state.runActive else { return false }
            state.runActive = true
            state.running = true
            state.pendingWrites.removeAll(keepingCapacity: true)
            state.writeOverflowNotified = false
            return true
        }
        // A refusal must SAY so — see the matching note in SSHWorker.start.
        guard accepted else {
            onClosed?("the previous serial session is still closing — try again")
            return
        }
        queue.async { [weak self] in
            self?.run(devicePath: devicePath, baudRate: baudRate)
        }
    }

    func stop() {
        state.withLock { state in
            state.running = false
            // Wake the poll loop now. Holding the Mutex prevents a race with
            // teardown closing and invalidating (or reusing) the descriptor.
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
    }

    /// Returns false when the input was refused, so a paced paste can stop
    /// instead of reporting lines it never sent.
    @discardableResult
    func write(_ bytes: [UInt8]) -> Bool {
        // Fired outside the lock: onNotice hops to the main actor, and this
        // Mutex is not recursive.
        var notice: (@Sendable (String) -> Void)?
        var message = ""
        var accepted = false
        var discarded: (@Sendable () -> Void)?
        state.withLock { state in
            // A dead or wedged session must not buffer input forever — and
            // a paced paste has to hear about the refusal, exactly as it
            // does for a full buffer, or it keeps counting lines the port
            // never got.
            guard state.running else {
                discarded = state.onInputDiscarded
                return
            }
            // All-or-nothing, and on a console cable this is the case that
            // matters most: the old code appended `bytes.prefix(room)`, so a
            // paced paste into a 9600-baud port — which drains ~960 B/s while
            // the pacer feeds ~8 KB/s — would eventually send the FRONT of a
            // config line to a live switch and drop the rest.
            guard state.pendingWrites.count + bytes.count <= Self.maxPendingWrites else {
                discarded = state.onInputDiscarded
                if !state.writeOverflowNotified {
                    state.writeOverflowNotified = true
                    notice = state.onNotice
                    message = bytes.count > Self.maxPendingWrites
                        ? "that paste is larger than SheepTerm will send in one go — nothing was sent"
                        : "serial port is not draining — input is being discarded until it catches up"
                }
                return
            }
            state.writeOverflowNotified = false
            state.pendingWrites.append(contentsOf: bytes)
            accepted = true
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
        if let notice { notice(message) }
        discarded?()
        return accepted
    }

    private var isRunning: Bool {
        state.withLock { $0.running }
    }

    private func takeWrites() -> [UInt8] {
        state.withLock { state in
            let writes = state.pendingWrites
            state.pendingWrites.removeAll()
            return writes
        }
    }

    private func run(devicePath: String, baudRate: Int) {
        // Reset the public lifecycle on every exit path and drop input that
        // belongs to the dead device. Resource defers registered below run
        // first, then runActive is released for a possible later start().
        defer {
            state.withLock { state in
                state.running = false
                state.pendingWrites.removeAll(keepingCapacity: true)
                state.runActive = false
            }
        }
        var fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        // A reconnect reaches open() before the PREVIOUS session's defers
        // have run: stop() only pokes the self-pipe, so for a few
        // milliseconds the old descriptor still holds TIOCEXCL and the port
        // answers EBUSY. Retry briefly instead of failing the reconnect
        // outright (this also rides out another app letting go of the cable).
        if fd < 0, errno == EBUSY {
            let deadline = Date().addingTimeInterval(1.0)
            while fd < 0, isRunning, Date() < deadline {
                usleep(20_000)
                fd = open(devicePath, O_RDWR | O_NOCTTY | O_NONBLOCK)
                if fd < 0, errno != EBUSY { break }
            }
        }
        guard fd >= 0 else {
            onClosed?("cannot open \(devicePath): \(String(cString: strerror(errno)))")
            return
        }
        defer { close(fd) }

        // Self-pipe so write() can wake the poll loop immediately; lets the
        // idle timeout be a full second with zero added input latency.
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            onClosed?("pipe failed: \(String(cString: strerror(errno)))")
            return
        }
        let pipeRead = pipeFDs[0]
        let pipeWrite = pipeFDs[1]
        // Non-blocking so a full pipe can never stall the caller of write().
        _ = fcntl(pipeWrite, F_SETFL, O_NONBLOCK)
        state.withLock { $0.wakeFD = pipeWrite }
        defer {
            state.withLock { $0.wakeFD = -1 }
            close(pipeRead)
            close(pipeWrite)
        }

        // Exclusive access so two apps don't fight over the console cable.
        // Not fatal — some drivers reject it — so warn and carry on.
        if ioctl(fd, TIOCEXCL) != 0 {
            onNotice?("could not lock port exclusively — another app may have it open")
        }

        var tty = termios()
        guard tcgetattr(fd, &tty) == 0 else {
            onClosed?("tcgetattr failed: \(String(cString: strerror(errno)))")
            return
        }
        // Hand the port back the way we found it.
        var original = tty
        defer { tcsetattr(fd, TCSANOW, &original) }
        cfmakeraw(&tty)
        tty.c_cflag |= tcflag_t(CLOCAL | CREAD)
        // 8N1
        tty.c_cflag &= ~tcflag_t(PARENB)
        tty.c_cflag &= ~tcflag_t(CSTOPB)
        tty.c_cflag &= ~tcflag_t(CSIZE)
        tty.c_cflag |= tcflag_t(CS8)
        // No flow control
        tty.c_cflag &= ~tcflag_t(CRTSCTS)
        tty.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        guard cfsetspeed(&tty, speed_t(baudRate)) == 0,
              tcsetattr(fd, TCSANOW, &tty) == 0 else {
            onClosed?("cannot configure \(baudRate) baud: \(String(cString: strerror(errno)))")
            return
        }

        onStatus?("serial · \((devicePath as NSString).lastPathComponent) · \(baudRate) 8N1")

        var buffer = [UInt8](repeating: 0, count: 4096)
        while isRunning {
            let writes = takeWrites()
            if !writes.isEmpty {
                var offset = 0
                // Stall deadline, not a batch deadline: a 100 KB paste at
                // 9600 baud needs ~107 s of steady progress, which is fine
                // — only abort when the port makes NO progress for 60 s
                // (flow control wedged).
                var lastProgress = Date()
                while offset < writes.count {
                    // Bail out when the tab is closed instead of spinning
                    // forever on a stalled port.
                    guard isRunning else { return }
                    if Date().timeIntervalSince(lastProgress) > 60 {
                        onClosed?("write stalled for 60 s — is flow control stuck?")
                        return
                    }
                    let written = writes[offset...].withUnsafeBytes { raw in
                        Darwin.write(fd, raw.baseAddress, raw.count)
                    }
                    if written > 0 {
                        offset += written
                        lastProgress = Date()
                        // A long drain must not starve inbound data — the
                        // port is non-blocking, so check for input between
                        // write chunks.
                        let count = buffer.withUnsafeMutableBytes { raw in
                            Darwin.read(fd, raw.baseAddress, raw.count)
                        }
                        if count > 0 {
                            onData?(Array(buffer[0..<count]))
                        } else if count == 0 {
                            // EOF — device gone (cable unplugged).
                            onClosed?("serial device disconnected")
                            return
                        } else if errno != EAGAIN, errno != EINTR {
                            onClosed?("read failed: \(String(cString: strerror(errno)))")
                            return
                        }
                    } else if written < 0, errno == EINTR {
                        continue
                    } else if written < 0, errno != EAGAIN {
                        onClosed?("write failed: \(String(cString: strerror(errno)))")
                        return
                    } else {
                        // EAGAIN or a 0-byte write: output buffer full —
                        // sleep in the kernel until the port is writable
                        // instead of usleep-spinning.
                        var wfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&wfd, 1, 100)
                    }
                }
            }

            // Sleep in the kernel until bytes arrive or write() pokes the
            // self-pipe. The pipe wake covers pending writes, so the idle
            // timeout only needs to notice unplug (POLLHUP) and stop() —
            // 1 wakeup/sec, zero added input latency.
            var pfds = [
                pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: pipeRead, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&pfds, 2, 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                onClosed?("poll failed: \(String(cString: strerror(errno)))")
                return
            }
            if ready > 0 {
                // Drain the wake pipe; the queued bytes it announced are
                // picked up by takeWrites() at the top of the next pass.
                if Int32(pfds[1].revents) & Int32(POLLIN) != 0 {
                    var sink = [UInt8](repeating: 0, count: 256)
                    _ = sink.withUnsafeMutableBytes { raw in
                        Darwin.read(pipeRead, raw.baseAddress, raw.count)
                    }
                }
                let revents = Int32(pfds[0].revents)
                if revents & Int32(POLLIN) != 0 {
                    let count = buffer.withUnsafeMutableBytes { raw in
                        Darwin.read(fd, raw.baseAddress, raw.count)
                    }
                    if count > 0 {
                        onData?(Array(buffer[0..<count]))
                    } else if count == 0 {
                        // EOF — device gone (cable unplugged).
                        onClosed?("serial device disconnected")
                        return
                    } else if errno != EAGAIN && errno != EINTR {
                        onClosed?("read failed: \(String(cString: strerror(errno)))")
                        return
                    }
                }
                // Checked independently, NOT as an else of POLLIN: a hangup
                // arriving WITH pending data (POLLIN|POLLHUP) must still be
                // honored after the read — as an else-if, a read that hit
                // EAGAIN would leave the HUP unnoticed and the loop would
                // keep polling a dead port.
                if revents & Int32(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    onClosed?("serial device disconnected")
                    return
                }
            }
        }
        onClosed?("serial session closed")
    }

#if SHEEPTERM_TESTING
    /// Compiled only by the standalone worker regression harness.
    func _testLifecycleSnapshot() -> (
        running: Bool,
        runActive: Bool,
        pendingWriteCount: Int
    ) {
        state.withLock { ($0.running, $0.runActive, $0.pendingWrites.count) }
    }
#endif
}
