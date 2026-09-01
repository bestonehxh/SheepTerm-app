import CLibSSH
import Foundation
import Synchronization

struct SSHConfig: Sendable {
    var host: String
    var port: Int
    var username: String
    var password: String?
    var mode: CipherMode
    var initialCols: Int
    var initialRows: Int
    /// ForwardAgent: let the remote host reach the local ssh-agent so a
    /// hop from there can use our keys. Off unless the host asks for it —
    /// anyone with root on the far end can use the socket while we sit there.
    var agentForward: Bool = false
}

/// Runs one libssh session on its own serial queue. libssh sessions are not
/// thread-safe, so every ssh_* call happens on that queue; the UI talks to
/// this class only through the locked buffers and the callback closures.
nonisolated final class SSHWorker: Sendable {
    private let queue = DispatchQueue(label: "sheepterm.ssh.session")
    private struct State: Sendable {
        var pendingWrites: [UInt8] = []
        var pendingResize: (cols: Int, rows: Int)?
        /// True from start() until run() has completed all of its defers.
        /// Kept separate from `running`, which stop() clears immediately.
        var runActive = false
        var running = false
        var lastError: String?
        /// Write end of the self-pipe; -1 when the loop isn't up.
        var wakeFD: Int32 = -1
        var onData: (@Sendable ([UInt8]) -> Void)?
        var onNotice: (@Sendable (String) -> Void)?
        var onStatus: (@Sendable (String) -> Void)?
        var onClosed: (@Sendable (String) -> Void)?
        var passwordPrompt: (@Sendable (String) -> String?)?
        var challengePrompt: (@Sendable (_ prompt: String, _ secure: Bool) -> String?)?
        var usernamePrompt: (@Sendable (String) -> String?)?
        var onPasswordWorked: (@Sendable (String, String) -> Void)?
    }
    private let state = Mutex(State())
    /// Cap on buffered input — a wedged session must not grow it forever.
    private static let maxPendingWrites = 1024 * 1024

    var onData: (@Sendable ([UInt8]) -> Void)? {
        get { state.withLock { $0.onData } }
        set { state.withLock { $0.onData = newValue } }
    }
    var onNotice: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onNotice } }
        set { state.withLock { $0.onNotice = newValue } }
    }
    var onStatus: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onStatus } }
        set { state.withLock { $0.onStatus = newValue } }
    }
    var onClosed: (@Sendable (String) -> Void)? {
        get { state.withLock { $0.onClosed } }
        set { state.withLock { $0.onClosed = newValue } }
    }
    /// Asks the UI for a password; returns nil when the user cancels.
    var passwordPrompt: (@Sendable (String) -> String?)? {
        get { state.withLock { $0.passwordPrompt } }
        set { state.withLock { $0.passwordPrompt = newValue } }
    }
    /// Asks the UI for a keyboard-interactive challenge. `secure` mirrors
    /// libssh's echo flag (password/OTP prompts normally request no echo).
    var challengePrompt: (@Sendable (_ prompt: String, _ secure: Bool) -> String?)? {
        get { state.withLock { $0.challengePrompt } }
        set { state.withLock { $0.challengePrompt = newValue } }
    }
    /// Asks the UI for a username when the host has none configured.
    var usernamePrompt: (@Sendable (String) -> String?)? {
        get { state.withLock { $0.usernamePrompt } }
        set { state.withLock { $0.usernamePrompt = newValue } }
    }
    /// Reports the (username, password) that actually authenticated, so the
    /// app can remember it for reconnects.
    var onPasswordWorked: (@Sendable (String, String) -> Void)? {
        get { state.withLock { $0.onPasswordWorked } }
        set { state.withLock { $0.onPasswordWorked = newValue } }
    }

    private var lastError: String? {
        get { state.withLock { $0.lastError } }
        set { state.withLock { $0.lastError = newValue } }
    }

    // Legacy lists append old algorithms after the modern ones, so new gear
    // still negotiates the best available while 15-year-old switches connect.
    private static let legacyKex = "curve25519-sha256,curve25519-sha256@libssh.org,ecdh-sha2-nistp521,ecdh-sha2-nistp384,ecdh-sha2-nistp256,diffie-hellman-group-exchange-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512,diffie-hellman-group14-sha256,diffie-hellman-group14-sha1,diffie-hellman-group1-sha1,diffie-hellman-group-exchange-sha1"
    private static let legacyCiphers = "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr,aes256-cbc,aes192-cbc,aes128-cbc,3des-cbc"
    private static let legacyHostKeys = "ssh-ed25519,ecdsa-sha2-nistp521,ecdsa-sha2-nistp384,ecdsa-sha2-nistp256,rsa-sha2-512,rsa-sha2-256,ssh-rsa,ssh-dss"
    private static let legacyMacs = "hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com,hmac-sha2-256,hmac-sha2-512,hmac-sha1,hmac-md5"

    // MARK: Thread-safe surface

    func start(_ config: SSHConfig) {
        let accepted = state.withLock { state in
            // One libssh session owns this worker queue at a time. In
            // particular, do not let start() race teardown after stop().
            guard !state.runActive else { return false }
            state.runActive = true
            state.running = true
            state.pendingWrites.removeAll(keepingCapacity: true)
            state.pendingResize = nil
            state.lastError = nil
            return true
        }
        // A refusal must SAY so. Every caller today builds a fresh worker, so
        // this cannot fire; a future in-place reconnect that rejected here in
        // silence would leave the tab on "connecting…" with nothing to show.
        guard accepted else {
            onClosed?("a session is still shutting down on this connection — try again")
            return
        }
        queue.async { [weak self] in
            self?.run(config)
        }
    }

    func stop() {
        state.withLock { state in
            state.running = false
            // Holding the Mutex prevents a race with teardown closing and
            // invalidating (or reusing) the descriptor.
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
    }

    func write(_ bytes: [UInt8]) {
        state.withLock { state in
            guard state.running else { return }
            let room = Self.maxPendingWrites - state.pendingWrites.count
            guard room > 0 else { return }
            state.pendingWrites.append(contentsOf: bytes.prefix(room))
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        state.withLock { state in
            guard state.running else { return }
            state.pendingResize = (cols, rows)
            if state.wakeFD >= 0 {
                var byte: UInt8 = 0
                _ = Darwin.write(state.wakeFD, &byte, 1)
            }
        }
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

    /// Puts unwritten bytes back at the FRONT of the queue so a failed or
    /// stalled write doesn't silently swallow keystrokes.
    private func requeueWrites(_ bytes: ArraySlice<UInt8>) {
        state.withLock { state in
            guard state.running else { return }
            state.pendingWrites.insert(contentsOf: bytes, at: 0)
        }
    }

    /// Puts an unapplied resize back so an SSH_AGAIN doesn't drop it; a
    /// newer resize queued in the meantime still wins.
    private func requeueResize(_ resize: (cols: Int, rows: Int)) {
        state.withLock { state in
            guard state.running else { return }
            if state.pendingResize == nil { state.pendingResize = resize }
        }
    }

    private func takeResize() -> (cols: Int, rows: Int)? {
        state.withLock { state in
            let resize = state.pendingResize
            state.pendingResize = nil
            return resize
        }
    }

    // MARK: Session lifecycle (everything below runs on `queue`)

    private func run(_ initialConfig: SSHConfig) {
        // Every return path — prompt cancellation, connection/authentication
        // failure, remote EOF, local stop, or I/O error — must make the public
        // surface reject further input and discard bytes belonging to the dead
        // session. This defer was registered first so the resource defers below
        // run before runActive is released for a possible later start().
        defer {
            state.withLock { state in
                state.running = false
                state.pendingWrites.removeAll(keepingCapacity: true)
                state.pendingResize = nil
                state.runActive = false
            }
        }
        var config = initialConfig
        if config.username.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let user = usernamePrompt?("Username for \(config.host)")?
                .trimmingCharacters(in: .whitespaces), !user.isEmpty else {
                onClosed?("connection cancelled — no username given")
                return
            }
            config.username = user
        }

        // libssh keeps the pointer we hand ssh_set_callbacks, so the
        // storage has to outlive the session. Allocated before the session
        // exists on purpose: its defer then runs AFTER the ssh_free below.
        let callbacks = UnsafeMutablePointer<ssh_callbacks_struct>.allocate(capacity: 1)
        callbacks.initialize(to: ssh_callbacks_struct())
        defer {
            callbacks.deinitialize(count: 1)
            callbacks.deallocate()
        }

        var usedLegacy = config.mode == .legacy
        var session = makeConnectedSession(config, legacy: usedLegacy)

        if session == nil, config.mode == .auto,
           let error = lastError?.lowercased(),
           error.contains("no match") || error.contains("kex") {
            onNotice?("modern negotiation failed — retrying with legacy algorithms…")
            usedLegacy = true
            session = makeConnectedSession(config, legacy: true)
        }

        guard let session else {
            onClosed?(lastError ?? "connection failed")
            return
        }
        defer {
            ssh_disconnect(session)
            ssh_free(session)
        }

        // The tab may have been closed while the (blocking) connect ran.
        guard isRunning else { return }
        guard verifyHostKey(session) else { return }
        guard authenticate(session, config) else {
            // Only a live session reports failure — a tab closed mid-auth
            // must not print a fake "authentication failed".
            if isRunning { onClosed?("authentication failed") }
            return
        }

        // Agent forwarding: the far end asks for our keys by opening an
        // "auth-agent@openssh.com" channel, which libssh only accepts when
        // this callback is installed.
        var forwarder: SSHAgentForwarder?
        if config.agentForward {
            if let path = SSHAgentForwarder.agentSocketPath() {
                let created = SSHAgentForwarder(socketPath: path)
                created.onNotice = { [weak self] message in self?.onNotice?(message) }
                forwarder = created
                callbacks.pointee.size = MemoryLayout<ssh_callbacks_struct>.size
                callbacks.pointee.userdata = Unmanaged.passUnretained(created).toOpaque()
                callbacks.pointee.channel_open_request_auth_agent_function = { session, userdata in
                    guard let session, let userdata else { return nil }
                    return Unmanaged<SSHAgentForwarder>.fromOpaque(userdata)
                        .takeUnretainedValue()
                        .accept(session: session)
                }
                _ = ssh_set_callbacks(session, callbacks)
            } else {
                onNotice?("agent forwarding: SSH_AUTH_SOCK is not set — no ssh-agent to forward")
            }
        }
        // Runs before the session teardown above (defers unwind in reverse),
        // which is required: the channels are freed against a live session.
        defer { forwarder?.closeAll() }

        guard let channel = ssh_channel_new(session) else {
            onClosed?("could not allocate channel")
            return
        }
        defer { ssh_channel_free(channel) }

        guard ssh_channel_open_session(channel) == 0 else {
            onClosed?("channel open failed: \(errorString(session))")
            return
        }
        _ = "xterm-256color".withCString {
            ssh_channel_request_pty_size(channel, $0, Int32(config.initialCols), Int32(config.initialRows))
        }
        if forwarder != nil, ssh_channel_request_auth_agent(channel) != SSH_OK {
            // Not fatal — the shell is still perfectly usable without it.
            onNotice?("agent forwarding refused by the server: \(errorString(session))")
            // Drop the callback too — `forwarder` is about to be released
            // and libssh would otherwise hold a dangling userdata pointer.
            callbacks.pointee.channel_open_request_auth_agent_function = nil
            forwarder?.closeAll()
            forwarder = nil
        }
        guard ssh_channel_request_shell(channel) == 0 else {
            onClosed?("shell request failed: \(errorString(session))")
            return
        }

        // The interactive phase runs non-blocking: libssh gives blocking
        // writes no timeout, so a wedged network would hang this queue
        // (and tab close) forever. Connect/auth above stay blocking on
        // purpose — they have their own connect timeout.
        ssh_set_blocking(session, 0)

        // Self-pipe so write()/resize()/stop() wake the poll loop
        // immediately — same trick as SerialWorker; the pipe write end is
        // non-blocking so a full pipe can never stall a caller.
        var pipeFDs: [Int32] = [0, 0]
        guard pipe(&pipeFDs) == 0 else {
            onClosed?("pipe failed: \(String(cString: strerror(errno)))")
            return
        }
        let pipeRead = pipeFDs[0]
        let pipeWrite = pipeFDs[1]
        _ = fcntl(pipeWrite, F_SETFL, O_NONBLOCK)
        state.withLock { $0.wakeFD = pipeWrite }
        defer {
            state.withLock { $0.wakeFD = -1 }
            close(pipeRead)
            close(pipeWrite)
        }

        // Only now is the session actually usable — reporting "Connected"
        // before the shell is granted would lie on VTY-full devices.
        let kex = ssh_get_kex_algo(session).map { String(cString: $0) } ?? "?"
        let cipher = ssh_get_cipher_out(session).map { String(cString: $0) } ?? "?"
        var status = "ssh2 · \(cipher) · \(kex) · \(config.host):\(config.port) · \(config.username)"
        if usedLegacy { status += " · LEGACY" }
        if forwarder != nil { status += " · agent" }
        onStatus?(status)

        let failure = ioLoop(session: session, channel: channel, pipeRead: pipeRead,
                             forwarder: forwarder)

        ssh_channel_send_eof(channel)
        ssh_channel_close(channel)
        if let failure {
            onClosed?(failure)
        } else {
            onClosed?("Connection to \(config.host) closed.")
        }
    }

#if SHEEPTERM_TESTING
    /// Compiled only by the standalone worker regression harness.
    func _testLifecycleSnapshot() -> (
        running: Bool,
        runActive: Bool,
        pendingWriteCount: Int,
        hasPendingResize: Bool
    ) {
        state.withLock {
            ($0.running, $0.runActive, $0.pendingWrites.count, $0.pendingResize != nil)
        }
    }
#endif

    /// Returns an error message when the session died from a local failure
    /// (e.g. a failed write), nil for a normal/remote close.
    ///
    /// Runs with the session in non-blocking mode: waiting happens in
    /// poll() on the raw socket plus the self-pipe (ssh_channel_poll_timeout
    /// can't see the pipe), so typing has zero added latency while idle
    /// wakeups stay at 1/sec.
    private func ioLoop(session: ssh_session, channel: ssh_channel, pipeRead: Int32,
                        forwarder: SSHAgentForwarder?) -> String? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        // ContinuousClock, not Date: these are internal deadlines, not
        // anything shown to the user, and a wall clock can jump — an NTP
        // correction, a timezone change, or (the common case on a laptop)
        // closing the lid and reopening it later — which would fire the
        // keepalive/stall checks early or suppress them entirely.
        // ContinuousClock keeps ticking across sleep, so the interval is
        // measured in real elapsed time regardless of what the wall clock does.
        let clock = ContinuousClock()
        var lastKeepalive = clock.now
        let socketFD = ssh_get_fd(session)

        while isRunning {
            // Keepalive so idle sessions survive device exec-timeouts.
            // Best-effort: in non-blocking mode SSH_AGAIN just means "not
            // right now", and a dropped keepalive is retried a minute later.
            if lastKeepalive.duration(to: clock.now) > .seconds(60) {
                _ = "keepalive@sheepterm".withCString { ssh_send_ignore(session, $0) }
                lastKeepalive = clock.now
            }

            let writes = takeWrites()
            if !writes.isEmpty {
                var offset = 0
                // Stall deadline, not a batch deadline (same rule as
                // serial): a big paste on a slow link needs steady
                // progress, which is fine — only abort when the session
                // makes NO progress for 60 s (network wedged).
                var lastProgress = clock.now
                while offset < writes.count {
                    // Bail out when the tab is closed instead of spinning
                    // forever on a wedged session.
                    guard isRunning else { return nil }
                    // A remote EOF mid-write leaves ssh_channel_write
                    // returning 0 forever (window full, peer gone) — the
                    // outer EOF check never runs while writes are pending,
                    // so without this the loop spins to the 60 s stall
                    // deadline, reports the wrong cause, and burns 100% CPU
                    // when the peer's FIN keeps poll() readable. Drain the
                    // output that arrived with the EOF, then close normally.
                    if ssh_channel_is_eof(channel) != 0 || ssh_channel_is_closed(channel) != 0 {
                        var delivered = false
                        repeat {
                            delivered = false
                            if readAvailable(session: session, channel: channel, buffer: &buffer, delivered: &delivered) != nil { break }
                        } while delivered
                        return nil
                    }
                    if lastProgress.duration(to: clock.now) > .seconds(60) {
                        requeueWrites(writes[offset...])
                        return "write stalled for 60 s — connection wedged?"
                    }
                    let written = writes[offset...].withUnsafeBytes { raw -> Int32 in
                        ssh_channel_write(channel, raw.baseAddress, UInt32(raw.count))
                    }
                    if written > 0 {
                        offset += Int(written)
                        lastProgress = clock.now
                    } else if written == 0 || written == SSH_AGAIN {
                        // Channel window full (remote not reading) or the
                        // socket is busy. Window updates arrive INBOUND, so
                        // wait for readability — not POLLOUT, which is
                        // almost always signaled on TCP and would spin —
                        // and let libssh consume packets before retrying.
                        var wfds = [
                            pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0),
                            pollfd(fd: pipeRead, events: Int16(POLLIN), revents: 0),
                        ]
                        let ready = poll(&wfds, 2, 1000)
                        if ready < 0, errno != EINTR {
                            requeueWrites(writes[offset...])
                            return "poll failed: \(String(cString: strerror(errno)))"
                        }
                        if ready > 0 {
                            if Int32(wfds[1].revents) & Int32(POLLIN) != 0 {
                                drainWakePipe(pipeRead)
                            }
                            var delivered = false
                            if Int32(wfds[0].revents) & Int32(POLLIN) != 0,
                               let failure = readAvailable(session: session, channel: channel, buffer: &buffer, delivered: &delivered) {
                                requeueWrites(writes[offset...])
                                return failure
                            }
                            if Int32(wfds[0].revents) & Int32(POLLHUP | POLLERR | POLLNVAL) != 0 {
                                requeueWrites(writes[offset...])
                                return "connection lost: \(errorString(session))"
                            }
                            forwarder?.pump()
                        }
                    } else {
                        // Report the real error instead of pretending the
                        // session closed normally with the input lost — and
                        // re-queue the remainder so it isn't lost either.
                        requeueWrites(writes[offset...])
                        return "write failed: \(errorString(session))"
                    }
                }
            }

            if let resize = takeResize() {
                // SSH_AGAIN is not an error — retry the same resize on the
                // next pass instead of dropping it.
                if ssh_channel_change_pty_size(channel, Int32(resize.cols), Int32(resize.rows)) == SSH_AGAIN {
                    requeueResize(resize)
                }
            }

            // Drain whatever libssh already has buffered BEFORE sleeping on
            // the raw socket — poll() can't see channel-buffered data, so
            // going to sleep with a non-empty buffer would stall output for
            // a whole poll timeout. A pass that delivered data may have
            // more waiting in the channel buffer: skip the sleep entirely
            // (writes are still serviced at the top of every pass).
            var delivered = false
            if let failure = readAvailable(session: session, channel: channel, buffer: &buffer, delivered: &delivered) {
                return failure
            }
            // Agent traffic rides the same session: move whatever the read
            // above handed the agent channels before deciding to sleep.
            forwarder?.pump()
            if ssh_channel_is_eof(channel) != 0 || ssh_channel_is_closed(channel) != 0 {
                return nil
            }
            if delivered { continue }

            // Sleep in the kernel until output arrives or write()/resize()/
            // stop() pokes the self-pipe. The pipe covers all pending work,
            // so the idle timeout only bounds keepalive cadence and dead-
            // socket detection — 1 wakeup/sec, zero added input latency.
            var pfds = [
                pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: pipeRead, events: Int16(POLLIN), revents: 0),
            ]
            // Agent sockets join the sleep so an agent reply is forwarded at
            // once instead of waiting out the idle timeout. Which fd woke us
            // doesn't matter — pump() reads them all non-blocking.
            let agentFDs = forwarder?.pollFDs ?? []
            pfds.append(contentsOf: agentFDs.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) })
            let ready = poll(&pfds, nfds_t(pfds.count), 1000)
            if ready < 0 {
                if errno == EINTR { continue }
                return "poll failed: \(String(cString: strerror(errno)))"
            }
            if ready > 0 {
                // Drain the wake pipe; the work it announced is picked up
                // by takeWrites()/takeResize() at the top of the next pass.
                if Int32(pfds[1].revents) & Int32(POLLIN) != 0 {
                    drainWakePipe(pipeRead)
                }
                let revents = Int32(pfds[0].revents)
                if revents & Int32(POLLIN) != 0,
                   let failure = readAvailable(session: session, channel: channel, buffer: &buffer, delivered: &delivered) {
                    return failure
                }
                // HUP/ERR is checked independently of POLLIN: a hangup
                // arriving WITH final data must still be honored after the
                // read, and a bare hangup must not spin the loop.
                if revents & Int32(POLLHUP | POLLERR | POLLNVAL) != 0 {
                    if ssh_channel_is_eof(channel) != 0 || ssh_channel_is_closed(channel) != 0 {
                        return nil
                    }
                    return "connection lost: \(errorString(session))"
                }
            }
            forwarder?.pump()

            if ssh_channel_is_eof(channel) != 0 || ssh_channel_is_closed(channel) != 0 {
                return nil
            }
        }
        return nil
    }

    /// Delivers one chunk per stream that libssh can hand out right now,
    /// setting `delivered` when any bytes came in. Returns an error
    /// message on a hard read failure, nil otherwise. 0 and SSH_AGAIN
    /// both mean "nothing at the moment" — the channel buffer is empty,
    /// so sleeping on the raw socket is safe.
    private func readAvailable(session: ssh_session, channel: ssh_channel, buffer: inout [UInt8], delivered: inout Bool) -> String? {
        for isStderr: Int32 in [0, 1] {
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                ssh_channel_read_nonblocking(channel, raw.baseAddress, UInt32(raw.count), isStderr)
            }
            if count > 0 {
                onData?(Array(buffer[0..<Int(count)]))
                delivered = true
            } else if count == SSH_ERROR {
                // A read error is not a clean close — say so.
                return "read failed: \(errorString(session))"
            }
        }
        return nil
    }

    /// Drains the wake pipe; the work it announced is picked up by
    /// takeWrites()/takeResize() at the top of the pass.
    private func drainWakePipe(_ pipeRead: Int32) {
        var sink = [UInt8](repeating: 0, count: 256)
        _ = sink.withUnsafeMutableBytes { raw in
            Darwin.read(pipeRead, raw.baseAddress, raw.count)
        }
    }

    private func makeConnectedSession(_ config: SSHConfig, legacy: Bool) -> ssh_session? {
        guard let session = ssh_new() else {
            lastError = "ssh_new failed"
            return nil
        }
        setOption(session, SSH_OPTIONS_HOST, config.host)
        // config.port is an unvalidated Int — reject anything libssh
        // can't represent instead of trapping on UInt32 truncation.
        guard let portValue = UInt32(exactly: config.port), (1...65535).contains(config.port) else {
            lastError = "invalid port \(config.port) — must be between 1 and 65535"
            ssh_free(session)
            return nil
        }
        var port = portValue
        _ = ssh_options_set(session, SSH_OPTIONS_PORT, &port)
        if !config.username.isEmpty {
            setOption(session, SSH_OPTIONS_USER, config.username)
        }
        var timeout = 15
        _ = ssh_options_set(session, SSH_OPTIONS_TIMEOUT, &timeout)
        // Disable Nagle: an interactive terminal wants keystrokes on the wire
        // immediately, not after a 40 ms buffering delay.
        var nodelay: Int32 = 1
        _ = ssh_options_set(session, SSH_OPTIONS_NODELAY, &nodelay)

        if legacy {
            setOption(session, SSH_OPTIONS_KEY_EXCHANGE, Self.legacyKex)
            setOption(session, SSH_OPTIONS_CIPHERS_C_S, Self.legacyCiphers)
            setOption(session, SSH_OPTIONS_CIPHERS_S_C, Self.legacyCiphers)
            setOption(session, SSH_OPTIONS_HOSTKEYS, Self.legacyHostKeys)
            setOption(session, SSH_OPTIONS_HMAC_C_S, Self.legacyMacs)
            setOption(session, SSH_OPTIONS_HMAC_S_C, Self.legacyMacs)
            setOption(session, SSH_OPTIONS_PUBLICKEY_ACCEPTED_TYPES, Self.legacyHostKeys)
        }

        guard ssh_connect(session) == 0 else {
            lastError = errorString(session)
            ssh_free(session)
            return nil
        }
        return session
    }

    private func verifyHostKey(_ session: ssh_session) -> Bool {
        let state = ssh_session_is_known_server(session)
        // Fail closed: an unreadable/corrupt known_hosts must never look
        // like "first connection" — that would silently disable MITM
        // protection and overwrite the stored key.
        if state == SSH_KNOWN_HOSTS_ERROR {
            onClosed?("cannot read ~/.ssh/known_hosts — refusing to trust any host key. Fix or remove the file, then reconnect.")
            return false
        }
        if state == SSH_KNOWN_HOSTS_OK {
            return true
        }
        if state == SSH_KNOWN_HOSTS_CHANGED {
            onClosed?("⚠️ HOST KEY CHANGED — possible man-in-the-middle. If the device was reinstalled, remove its entry from ~/.ssh/known_hosts and reconnect.")
            return false
        }
        if state == SSH_KNOWN_HOSTS_OTHER {
            onNotice?("host key type changed for this server; saving the new key")
        } else {
            onNotice?("first connection — host key saved to known_hosts")
        }
        if ssh_session_update_known_hosts(session) != 0 {
            // A failed save must not be silent — the user would otherwise
            // believe the key is pinned when it isn't.
            onNotice?("host key could NOT be saved to known_hosts: \(errorString(session))")
        }
        return true
    }

    private func authenticate(_ session: ssh_session, _ config: SSHConfig) -> Bool {
        let AUTH_SUCCESS: Int32 = 0
        let AUTH_INFO: Int32 = 3

        // Stop before each blocking attempt when the tab was closed.
        guard isRunning else { return false }
        if ssh_userauth_none(session, nil) == AUTH_SUCCESS {
            return true
        }
        guard isRunning else { return false }
        if ssh_userauth_publickey_auto(session, nil, nil) == AUTH_SUCCESS {
            onNotice?("authenticated with public key")
            return true
        }

        var password = config.password
        for _ in 0..<3 {
            // Stop prompting when the tab was closed mid-authentication.
            guard isRunning else { return false }
            if password == nil || password?.isEmpty == true {
                password = passwordPrompt?("Password for \(config.username)@\(config.host)")
                guard let entered = password, !entered.isEmpty else { return false }
            }
            guard let currentPassword = password else { return false }

            let passwordResult = currentPassword.withCString {
                ssh_userauth_password(session, nil, $0)
            }
            if passwordResult == AUTH_SUCCESS {
                onPasswordWorked?(config.username, currentPassword)
                return true
            }

            // Old network gear + TACACS very often use keyboard-interactive.
            var interactive = ssh_userauth_kbdint(session, nil, nil)
            while interactive == AUTH_INFO {
                // The tab may have closed while prompts were answered.
                guard isRunning else { return false }
                let prompts = ssh_userauth_kbdint_getnprompts(session)
                guard prompts >= 0 else {
                    onNotice?("keyboard-interactive prompt error: \(errorString(session))")
                    return false
                }
                for index in 0..<prompts {
                    var echo: CChar = 0
                    guard let rawPrompt = ssh_userauth_kbdint_getprompt(session, UInt32(index), &echo) else {
                        onNotice?("keyboard-interactive prompt error: \(errorString(session))")
                        return false
                    }
                    let prompt = String(cString: rawPrompt)
                    let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let asksAdditionalFactor = ["otp", "token", "verification", "code"].contains {
                        normalized.contains($0)
                    }
                    let canReusePassword = echo == 0
                        && (normalized.contains("password") || (prompts == 1 && normalized.isEmpty))
                        && !asksAdditionalFactor
                    let answer: String
                    if canReusePassword {
                        answer = currentPassword
                    } else {
                        let display = prompt.isEmpty
                            ? "Authentication challenge for \(config.username)@\(config.host)"
                            : prompt
                        guard let entered = challengePrompt?(display, echo == 0) else { return false }
                        answer = entered
                    }
                    let answerResult = answer.withCString {
                        ssh_userauth_kbdint_setanswer(session, UInt32(index), $0)
                    }
                    guard answerResult >= 0 else {
                        onNotice?("keyboard-interactive answer error: \(errorString(session))")
                        return false
                    }
                }
                interactive = ssh_userauth_kbdint(session, nil, nil)
            }
            if interactive == AUTH_SUCCESS {
                onPasswordWorked?(config.username, currentPassword)
                return true
            }

            onNotice?("authentication failed — try again")
            password = nil
        }
        return false
    }

    private func setOption(_ session: ssh_session?, _ option: ssh_options_e, _ value: String) {
        value.withCString {
            _ = ssh_options_set(session, option, $0)
        }
    }

    private func errorString(_ session: ssh_session?) -> String {
        guard let session else { return "unknown error" }
        return String(cString: ssh_get_error(UnsafeMutableRawPointer(session)))
    }
}

/// Client side of `ForwardAgent`: the server opens an
/// "auth-agent@openssh.com" channel per agent request, and every one of them
/// is glued to a fresh connection to the local ssh-agent (`SSH_AUTH_SOCK`).
///
/// Every method runs on the owning SSHWorker's session queue — the libssh
/// callback that creates channels fires inside packet processing on that
/// same queue — so nothing here needs a lock.
nonisolated final class SSHAgentForwarder {
    /// One forwarded channel plus the agent socket it is spliced to.
    private final class Tunnel {
        let channel: ssh_channel
        let fd: Int32
        /// Bytes read off the channel, not yet written to the agent.
        var toSocket: [UInt8] = []
        /// Bytes read off the agent, not yet written to the channel.
        var toChannel: [UInt8] = []
        /// The agent hung up (EOF on the socket) — nothing more will come
        /// back this way.
        var socketEOF = false
        /// The remote half-closed its side; the socket has been shut down
        /// for writing and only the reply direction is still live.
        var channelEOFSeen = false
        /// Torn down; dropped from the list on the next pass.
        var finished = false

        init(channel: ssh_channel, fd: Int32) {
            self.channel = channel
            self.fd = fd
        }
    }

    let socketPath: String
    private var tunnels: [Tunnel] = []
    var onNotice: (@Sendable (String) -> Void)?

    /// A stuck peer must not grow a buffer without bound; agent messages are
    /// a few KB at most, so anything past this is a broken far end.
    private static let maxBuffer = 256 * 1024
    /// Concurrent agent channels. One per agent request in practice, and
    /// short-lived, so this is headroom rather than a working limit — but a
    /// server opening hundreds of them is not doing agent auth.
    private static let maxTunnels = 32

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    /// The agent socket macOS hands every process in the login session, or
    /// nil when no agent is reachable.
    static func agentSocketPath() -> String? {
        guard let path = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
              !path.isEmpty else { return nil }
        return path
    }

    /// libssh callback body: accept the server's agent channel by handing
    /// back a fresh channel, or nil to refuse it (which libssh turns into a
    /// channel-open failure the far end reports as "agent refused").
    func accept(session: ssh_session) -> ssh_channel? {
        guard tunnels.count < Self.maxTunnels else {
            onNotice?("agent forwarding: too many open agent channels — refusing")
            return nil
        }
        guard let fd = connectToAgent() else {
            onNotice?("agent forwarding: cannot reach ssh-agent at \(socketPath) — refusing")
            return nil
        }
        guard let channel = ssh_channel_new(session) else {
            close(fd)
            return nil
        }
        tunnels.append(Tunnel(channel: channel, fd: fd))
        return channel
    }

    /// Agent sockets to add to the session's poll set, so a reply from the
    /// agent wakes the I/O loop instead of waiting out its idle timeout.
    var pollFDs: [Int32] {
        tunnels.filter { !$0.finished }.map(\.fd)
    }

    /// Moves whatever is ready in either direction. Everything is
    /// non-blocking, so this is a handful of syscalls when idle.
    func pump() {
        guard !tunnels.isEmpty else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        for tunnel in tunnels where !tunnel.finished {
            // Re-checked between every step: finish() closes the fd and
            // frees the channel, so one failing step must stop the rest
            // from touching either.
            readChannel(tunnel, into: &buffer)
            if !tunnel.finished { writeSocket(tunnel) }
            if !tunnel.finished { readSocket(tunnel, into: &buffer) }
            if !tunnel.finished { writeChannel(tunnel) }
            guard !tunnel.finished else { continue }

            // Half-close is passed through in each direction rather than
            // ending the tunnel: a peer that shuts down its write side is
            // still owed the reply travelling the other way.
            if ssh_channel_is_closed(tunnel.channel) != 0 {
                finish(tunnel)
                continue
            }
            if !tunnel.channelEOFSeen, ssh_channel_is_eof(tunnel.channel) != 0,
               tunnel.toSocket.isEmpty {
                tunnel.channelEOFSeen = true
                shutdown(tunnel.fd, SHUT_WR)
            }
            if tunnel.socketEOF, tunnel.toChannel.isEmpty {
                ssh_channel_send_eof(tunnel.channel)
                // Both directions are drained — nothing is owed either way.
                if tunnel.channelEOFSeen { finish(tunnel) }
            }
        }
        tunnels.removeAll { $0.finished }
    }

    /// Tears every tunnel down; called before the session goes away, since
    /// the channels are ours to free.
    func closeAll() {
        for tunnel in tunnels { finish(tunnel) }
        tunnels.removeAll()
    }

    // MARK: One direction at a time

    private func readChannel(_ tunnel: Tunnel, into buffer: inout [UInt8]) {
        guard !tunnel.channelEOFSeen else { return }
        while tunnel.toSocket.count < Self.maxBuffer {
            let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
                ssh_channel_read_nonblocking(tunnel.channel, raw.baseAddress, UInt32(raw.count), 0)
            }
            if count > 0 {
                tunnel.toSocket.append(contentsOf: buffer[0..<Int(count)])
            } else {
                if count == SSH_ERROR { finish(tunnel) }
                return
            }
        }
        onNotice?("agent forwarding: agent is not draining — closing this agent channel")
        finish(tunnel)
    }

    private func writeSocket(_ tunnel: Tunnel) {
        while !tunnel.toSocket.isEmpty {
            let written = tunnel.toSocket.withUnsafeBytes { raw -> Int in
                Darwin.write(tunnel.fd, raw.baseAddress, raw.count)
            }
            if written > 0 {
                tunnel.toSocket.removeFirst(written)
            } else {
                // EAGAIN just means "later"; anything else is a dead agent.
                if written < 0, errno != EAGAIN, errno != EINTR { finish(tunnel) }
                return
            }
        }
    }

    private func readSocket(_ tunnel: Tunnel, into buffer: inout [UInt8]) {
        guard !tunnel.socketEOF else { return }
        while tunnel.toChannel.count < Self.maxBuffer {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(tunnel.fd, raw.baseAddress, raw.count)
            }
            if count > 0 {
                tunnel.toChannel.append(contentsOf: buffer[0..<count])
            } else if count == 0 {
                tunnel.socketEOF = true
                return
            } else {
                if errno != EAGAIN, errno != EINTR { finish(tunnel) }
                return
            }
        }
        onNotice?("agent forwarding: remote is not draining — closing this agent channel")
        finish(tunnel)
    }

    private func writeChannel(_ tunnel: Tunnel) {
        while !tunnel.toChannel.isEmpty {
            let written = tunnel.toChannel.withUnsafeBytes { raw -> Int32 in
                ssh_channel_write(tunnel.channel, raw.baseAddress, UInt32(raw.count))
            }
            if written > 0 {
                tunnel.toChannel.removeFirst(Int(written))
            } else {
                // 0 = channel window full, SSH_AGAIN = socket busy: both are
                // "retry next pass" and must not drop the buffered reply.
                if written == SSH_ERROR { finish(tunnel) }
                return
            }
        }
    }

    private func finish(_ tunnel: Tunnel) {
        guard !tunnel.finished else { return }
        tunnel.finished = true
        ssh_channel_send_eof(tunnel.channel)
        ssh_channel_close(tunnel.channel)
        ssh_channel_free(tunnel.channel)
        close(tunnel.fd)
    }

    /// Fresh connection to the agent, non-blocking and SIGPIPE-proof.
    private func connectToAgent() -> Int32? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        // sun_path is 104 bytes on Darwin — a longer path cannot be
        // connected to at all, so say so instead of truncating into a
        // connection to some other socket.
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        // The agent can vanish mid-write; a SIGPIPE would kill the app.
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        return fd
    }
}
