import Foundation
import Synchronization

/// Writes a plain-text log of everything a session receives, with ANSI
/// escape sequences stripped so the file reads like the on-screen output.
/// Files land in ~/Documents/SheepTerm Logs/.
///
/// `append` is called from a per-session log queue while `close` can run on
/// the main actor. Two different primitives now split the job on purpose:
/// the Mutex guards only cheap bookkeeping (closed/carry/written/truncated —
/// no I/O ever happens while it's held), and `ioQueue`, a serial dispatch
/// queue private to this logger, is the sole place `handle` is touched.
///
/// That used to not be true: `append` held the Mutex across a blocking
/// `FileHandle.write`, and `close` (called from the main actor when a tab
/// closes) took that same Mutex. Since `state` is a per-instance property,
/// this was never cross-session contention — a tab could only ever be
/// blocked behind *its own* logger's in-flight write, never another
/// session's. But that was still a real, visible UI freeze: `~/Documents`
/// is iCloud-synced on many Macs, where a single `write(contentsOf:)` can
/// be held up well past local-disk latency by the file-provider layer, and
/// closing a tab mid-stream landed you on exactly that write.
///
/// The fix moves the write itself off the calling thread and onto
/// `ioQueue`, with two things preserved deliberately:
///
/// 1. **Bounded backlog, not unbounded.** Simply making `append` fire off
///    an unawaited `ioQueue.async` for every chunk would trade a bounded
///    wait (one write) for an *unbounded* one: a session streaming fast
///    against a stalled file provider would queue `Data` forever, and
///    `close()` — which still has to wait for its own tail write to land,
///    see below — would end up waiting for that entire backlog to drain
///    instead of one write. That's worse than the bug it fixes. So, same
///    pattern as `HighlightBuffer`'s `pendingBytes`: a separate counter
///    (guarded by `pendingCondition`, deliberately not `state`'s Mutex —
///    see its doc comment) tracks bytes handed to `ioQueue` but not yet
///    written, and `append` blocks the *calling* thread — the per-session
///    log queue, never the main actor — once that backlog crosses
///    `maxPendingBytes`. Blocking that thread is fine: it is exactly the
///    natural backpressure the old synchronous design gave for free, and
///    unlike dropping bytes, no log data is lost.
/// 2. **FIFO order across two producers.** `append`/`close` run on
///    different threads, so submission order to `ioQueue` has to be
///    decided somewhere both agree on: the Mutex. The submit-to-`ioQueue`
///    call for both happens *inside* the Mutex critical section
///    (submission is a fast, non-blocking call — not the write itself).
///    Whichever of `append`/`close` wins the Mutex race enqueues its work
///    first, and once `close` sets `closed = true` under the lock, no
///    later `append` can enqueue anything at all — it returns at its own
///    `guard !state.closed`, still under the Mutex, before ever reaching
///    `ioQueue`.
///
/// `close()` still makes one synchronous wait, and it is now bounded by
/// `maxPendingBytes` worth of backlog instead of being unbounded: callers
/// (including `Tests/tests/main.swift`'s write-then-read-back check) rely
/// on "closed means fully flushed and the fd is released" the instant
/// `close()` returns.
///
/// (`Mutex` is itself unconditionally `@unchecked Sendable` — that's what
/// let it wrap a non-Sendable payload before. `handle` is Sendable on its
/// own now, but Sendable only certifies "safe to hand off between queues,"
/// not "safe to use from two queues at once" — `ioQueue` being the single
/// place it's ever called from is what actually keeps access exclusive,
/// standing in for the Mutex's old role.)
nonisolated final class SessionLogger: Sendable {
    let url: URL
    /// Every actual disk write/close lives here, off the caller's thread —
    /// see the class doc comment for why this exists.
    private let ioQueue = DispatchQueue(label: "SheepTerm.SessionLogger.io")
    /// Touched only from `ioQueue` — never under `state`'s Mutex, and never
    /// synchronously from `append`'s or `close`'s caller thread. (FileHandle
    /// is itself Sendable, so no `nonisolated(unsafe)` is needed here — but
    /// Sendable only means "safe to hand off," not "safe to use from two
    /// queues at once": exclusivity still comes from `ioQueue` being the
    /// only place this is ever called from.)
    private let handle: FileHandle
    private struct State {
        var closed = false
        /// Tail that can't be logged yet — a split UTF-8 character or an
        /// unterminated escape sequence — prepended to the next append.
        var carry: [UInt8] = []
        /// Bytes handed to `ioQueue` so far — incremented at *enqueue* time,
        /// not when the physical write completes. That's deliberate, not an
        /// oversight: incrementing here happens under the same Mutex as the
        /// cap check below, so the next `append` call sees an up-to-date
        /// total immediately, regardless of how far behind the actual disk
        /// write is. Incrementing only after the write completes would mean
        /// crossing back into this Mutex from the `ioQueue` closure, and
        /// would let the cap check under-count work that's already been
        /// committed to — i.e. a slow disk could let far more than 100 MB
        /// get queued up before the truncation notice ever fires.
        var written = 0
        var truncated = false
    }
    private let state: Mutex<State>

    /// Beyond this the log stops growing — a runaway session must not
    /// fill the disk.
    private static let maxSize = 100 * 1024 * 1024
    /// An escape run longer than this is garbage, not a sequence — log it
    /// rather than hold it in `carry` forever.
    private static let maxEscapeHold = 1024 * 1024

    /// Bytes submitted to `ioQueue` but not yet physically written — the
    /// backpressure counterpart to `HighlightBuffer.pendingBytes`, and for
    /// the same reason: it must not share `state`'s Mutex, or `append`
    /// couldn't keep enqueueing (thus growing this count) while `ioQueue` is
    /// mid-write (thus shrinking it) — the two need to be visible to each
    /// other independent of whoever holds `state` at the moment.
    /// `NSCondition`, not another `Mutex`, because backpressure needs a
    /// blocking thread to be woken *by* the drain, not just to read a
    /// number: a `Mutex` has no wait/signal.
    private let pendingCondition = NSCondition()
    /// `nonisolated(unsafe)`: mutated only while `pendingCondition`'s own
    /// lock is held (in `waitForRoom`/`addPending`/`removePending`) — an
    /// external synchronization primitive the compiler can't see, the same
    /// justification the class doc comment gives for `Mutex` itself.
    nonisolated(unsafe) private var pendingBytes = 0
    /// Cap on outstanding (enqueued-but-not-yet-written) bytes. Past this,
    /// `append` blocks its caller — the per-session log queue, never the
    /// main actor — until `ioQueue` drains below it again. This bounds two
    /// things at once: worst-case RAM held by queued `Data`, and — more to
    /// the point — `close()`'s one unavoidable wait, which is for this same
    /// backlog to finish draining. 4 MB is a few hundred KB of typical
    /// terminal output either side of the cap (comfortably more than one
    /// write ever needs in the common fast-disk case, so this essentially
    /// never engages), while still bounding a stalled-disk close() wait to
    /// "flush 4 MB" instead of "flush however much a runaway session
    /// produced before someone closed the tab."
    private static let maxPendingBytes = 4 * 1024 * 1024

    static var logsDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init?(sessionName: String) {
        let formatter = DateFormatter()
        // Pin the locale: the device calendar can be Buddhist-era, which
        // would put a 543-year offset into the filename.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let safeName = sessionName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        // Same-second sessions must never clobber each other's log.
        let unique = UUID().uuidString.prefix(4)
        url = Self.logsDirectory
            .appendingPathComponent("\(safeName) \(formatter.string(from: Date()))-\(unique).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = handle
        state = Mutex(State())
    }

    /// Blocks the caller — always the per-session log queue, never the main
    /// actor — while the outstanding write backlog is at or above the cap.
    /// The `pendingBytes > 0` half of the condition matters: a single chunk
    /// larger than the cap must still go through once nothing else is
    /// in flight, or a chunk bigger than `maxPendingBytes` would deadlock
    /// forever waiting for room that can never appear.
    private func waitForRoom() {
        pendingCondition.lock()
        while pendingBytes >= Self.maxPendingBytes && pendingBytes > 0 {
            pendingCondition.wait()
        }
        pendingCondition.unlock()
    }

    private func addPending(_ count: Int) {
        guard count > 0 else { return }
        pendingCondition.lock()
        pendingBytes += count
        pendingCondition.unlock()
    }

    /// Called from `ioQueue` once a write completes. `signal()`, not
    /// `broadcast()`, is enough — at most one thread (the single per-session
    /// log queue) ever waits on this logger at a time.
    private func removePending(_ count: Int) {
        guard count > 0 else { return }
        pendingCondition.lock()
        pendingBytes -= count
        pendingCondition.signal()
        pendingCondition.unlock()
    }

    func append(_ bytes: [UInt8]) {
        // Backpressure gate, deliberately outside `state`'s Mutex: if this
        // blocks, `close()` must still be free to run (it needs `state`,
        // not `pendingCondition`) and mark the logger closed while we wait
        // — this call will simply no-op once it wakes and sees `closed`.
        waitForRoom()

        // Computed under the Mutex (cheap: bookkeeping + byte scanning, no
        // I/O); the write itself is submitted to `ioQueue` before the lock
        // is released (see class doc comment) and runs after we return.
        state.withLock { state in
            guard !state.closed else { return }

            // Cap checked BEFORE any work: past 100 MB nothing is written,
            // so scanning the chunk is pure waste on runaway sessions.
            if state.written >= Self.maxSize {
                state.carry = []
                if !state.truncated {
                    state.truncated = true
                    let notice = Data("\n--- log truncated at 100 MB ---\n".utf8)
                    addPending(notice.count)
                    ioQueue.async { [self] in
                        try? handle.write(contentsOf: notice)
                        removePending(notice.count)
                    }
                }
                return
            }

            var data: [UInt8]
            if state.carry.isEmpty {
                // [UInt8] is copy-on-write: the common no-carry path borrows
                // incoming storage instead of allocating carry + bytes.
                data = bytes
            } else {
                data = state.carry
                data.append(contentsOf: bytes)
                state.carry = []
            }

            // One cut index for both holds, taking the minimum so neither
            // hold loses the other's bytes.
            var cut = data.count
            if let utf8Cut = Self.incompleteUTF8Tail(data) {
                cut = utf8Cut
            }
            cut = min(cut, Self.incompleteEscapeTail(data) ?? data.count)
            if cut < data.count {
                state.carry = Array(data[cut...])
                data = Array(data[..<cut])
            }

            guard let chunk = Self.encodedLogChunk(data) else { return }
            state.written += chunk.count
            addPending(chunk.count)
            ioQueue.async { [self] in
                try? handle.write(contentsOf: chunk)
                removePending(chunk.count)
            }
        }
    }

    func close() {
        // Whichever of append/close wins the Mutex first enqueues its
        // ioQueue work first, so FIFO order on ioQueue matches call order
        // even though the two run on different threads (log queue vs.
        // main actor). Once `closed` flips to true here, no later append()
        // can reach `ioQueue` at all — it returns at its own `guard` above,
        // still under this same Mutex.
        let flushed = DispatchSemaphore(value: 0)
        var alreadyClosed = false
        state.withLock { state in
            guard !state.closed else { alreadyClosed = true; return }
            // Flush what is still held — the tail of a session is the part
            // you most want in the log. Only an unfinished fragment drops.
            var finalChunk: Data?
            if !state.carry.isEmpty, state.written < Self.maxSize {
                var cut = state.carry.count
                if let utf8Cut = Self.incompleteUTF8Tail(state.carry) {
                    cut = utf8Cut
                }
                cut = min(cut, Self.incompleteEscapeTail(state.carry) ?? state.carry.count)
                if let chunk = Self.encodedLogChunk(Array(state.carry[..<cut])) {
                    state.written += chunk.count
                    finalChunk = chunk
                }
            }
            state.carry = []
            state.closed = true
            // Snapshot to an immutable local: `finalChunk` above is a `var`
            // only so the `if` block can assign it, but the async closure
            // needs a fixed value, not a reference to a box that could
            // (in principle) be mutated again after capture.
            let chunkToFlush = finalChunk
            ioQueue.async { [handle] in
                if let chunkToFlush { try? handle.write(contentsOf: chunkToFlush) }
                try? handle.close()
                flushed.signal()
            }
        }
        guard !alreadyClosed else { return }
        // The one synchronous wait left in this class: callers rely on
        // "closed means fully flushed and the fd is released" the instant
        // close() returns (the test harness reads the file back right
        // after this call). The Mutex is already free by this point.
        //
        // What this waits for, precisely: `ioQueue` is FIFO, so this is the
        // tail write plus whatever this session's own backlog of prior
        // `append` writes hadn't finished yet — bounded by `maxPendingBytes`
        // (append() blocks its own caller once that cap is hit, so the
        // backlog can never exceed it). Contrast with the old bug: there,
        // `close` and `append` shared one Mutex per session, so `close`
        // could be blocked for as long as whichever single write `append`
        // happened to be inside when the lock was requested — never another
        // session's, `state` is per-instance, but still an unbounded stall
        // if that one write was slow (e.g. an iCloud-synced file provider).
        // Now `append` never holds a lock across I/O at all, so the only
        // thing left to wait for is this bounded backlog actually landing.
        flushed.wait()
    }

    /// Index of a trailing incomplete UTF-8 sequence — a lead byte whose
    /// continuation bytes haven't all arrived yet — or nil when the buffer
    /// ends on a character boundary (or on invalid bytes, which are passed
    /// through rather than held forever).
    private static func incompleteUTF8Tail(_ bytes: [UInt8]) -> Int? {
        var index = bytes.count
        var continuation = 0
        while index > 0 {
            let byte = bytes[index - 1]
            if byte & 0xC0 == 0x80 {
                continuation += 1
                index -= 1
                if continuation > 3 { return nil } // invalid stream — don't carry
                continue
            }
            // Valid UTF-8 lead bytes only: 0xC2-0xDF need 1 continuation,
            // 0xE0-0xEF need 2, 0xF0-0xF4 need 3. 0xF5-0xFF are NOT lead
            // bytes — holding them back only delayed the same U+FFFD by a
            // chunk (same rule as HighlightBuffer.incompleteUTF8Tail).
            if byte >= 0xC2, byte <= 0xF4 {
                let needed = byte >= 0xF0 ? 3 : (byte >= 0xE0 ? 2 : 1)
                if continuation < needed { return index - 1 }
            }
            return nil
        }
        return nil
    }

    /// Index where an incomplete trailing escape sequence starts, or nil
    /// when the buffer doesn't end mid-sequence. Covers CSI (final byte
    /// pending), OSC (BEL/ST pending) and DCS/APC string payloads (ST
    /// pending) — an unterminated run must be carried over, or its raw
    /// bytes would be logged half-stripped.
    private static func incompleteEscapeTail(_ bytes: [UInt8]) -> Int? {
        guard let esc = bytes.lastIndex(of: 0x1B),
              bytes.count - esc <= Self.maxEscapeHold else { return nil }
        let tail = bytes[(esc + 1)...]
        if tail.isEmpty {
            // A dangling final ESC may be the ST half of an open string
            // sequence (ESC ] / ESC P / ESC _ … ESC \) — hold from that
            // opener when one is still unterminated.
            return Self.unterminatedStringOpener(bytes, before: esc) ?? esc
        }
        let complete: Bool
        if tail.first == UInt8(ascii: "[") {
            // CSI: complete at a final byte 0x40–0x7E.
            complete = tail.dropFirst().contains { $0 >= 0x40 && $0 <= 0x7E }
        } else if tail.first == UInt8(ascii: "]") {
            // OSC: BEL terminates; ST's ESC would be the last ESC, so only
            // BEL can complete the sequence inside `tail`.
            complete = tail.contains(0x07)
        } else if tail.first == UInt8(ascii: "P") || tail.first == UInt8(ascii: "_") {
            // DCS / APC: ST (ESC \) only, and the terminating ESC would be
            // the last ESC — a sequence still open at `esc` is incomplete.
            complete = false
        } else {
            // Two-byte sequence like ESC c.
            complete = true
        }
        return complete ? nil : esc
    }

    /// Start index of an ESC ] / ESC P / ESC _ sequence with no terminator
    /// before `end`, or nil. A string payload's trailing ST-ESC looks like
    /// a dangling escape but actually belongs to the payload.
    private static func unterminatedStringOpener(_ bytes: [UInt8], before end: Int) -> Int? {
        var index = end
        while index > 0 {
            index -= 1
            guard bytes[index] == 0x1B else { continue }
            switch bytes[index + 1] {
            case UInt8(ascii: "\\"):
                return nil // an ST — any opener before it is closed
            case UInt8(ascii: "]"):
                // OSC also ends at BEL.
                return bytes[(index + 2)..<end].contains(0x07) ? nil : index
            case UInt8(ascii: "P"), UInt8(ascii: "_"):
                return index
            default:
                continue // CSI / two-byte sequences don't close a string
            }
        }
        return nil
    }

    /// Single-pass byte scanner for terminal control sequences. It removes
    /// CSI, OSC, DCS, APC, ordinary two-byte ESC commands, and CR without
    /// creating five intermediate Strings as the previous regex pipeline did.
    /// `incompleteEscapeTail` ensures normal calls never end mid-sequence.
    static func stripANSIBytes(_ input: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        var index = 0

        while index < input.count {
            let byte = input[index]
            if byte == 0x0D { // normalize CRLF to LF
                index += 1
                continue
            }
            guard byte == 0x1B, index + 1 < input.count else {
                output.append(byte)
                index += 1
                continue
            }

            let introducer = input[index + 1]
            if introducer == UInt8(ascii: "[") { // CSI
                var end = index + 2
                while end < input.count, input[end] >= 0x30, input[end] <= 0x3F { end += 1 }
                while end < input.count, input[end] >= 0x20, input[end] <= 0x2F { end += 1 }
                if end < input.count, input[end] >= 0x40, input[end] <= 0x7E {
                    index = end + 1
                    continue
                }
            } else if introducer == UInt8(ascii: "]")
                        || introducer == UInt8(ascii: "P")
                        || introducer == UInt8(ascii: "_") { // OSC / DCS / APC
                var end = index + 2
                var terminated = false
                while end < input.count {
                    if introducer == UInt8(ascii: "]"), input[end] == 0x07 {
                        end += 1
                        terminated = true
                        break
                    }
                    if input[end] == 0x1B {
                        if end + 1 < input.count, input[end + 1] == UInt8(ascii: "\\") {
                            end += 2
                            terminated = true
                        }
                        break // ST, or another ESC aborts the string sequence
                    }
                    end += 1
                }
                if terminated {
                    index = end
                    continue
                }
                if end < input.count, input[end] == 0x1B {
                    // The payload before an aborting ESC is non-display data;
                    // discard it and re-examine the new ESC as a command.
                    index = end
                    continue
                }
                // Oversized malformed sequence: match the old fallback by
                // stripping its two-byte introducer but retaining the payload.
                index += 2
                continue
            } else if introducer >= 0x30 && introducer <= 0x7E {
                index += 2 // ordinary two-byte ESC command
                continue
            }

            // Not a recognized complete sequence: preserve the ESC exactly.
            output.append(byte)
            index += 1
        }
        return output
    }

    /// Produces UTF-8 log bytes. Plain ASCII without controls is the dominant
    /// router-output path and writes directly; non-ASCII still takes the lossy
    /// UTF-8 normalization path so invalid bytes retain the established U+FFFD
    /// behavior covered by tests.
    private static func encodedLogChunk(_ input: [UInt8]) -> Data? {
        guard !input.isEmpty else { return nil }
        if input.allSatisfy({ $0 < 0x80 && $0 != 0x1B && $0 != 0x0D }) {
            return Data(input)
        }
        let stripped = stripANSIBytes(input)
        guard !stripped.isEmpty else { return nil }
        if stripped.allSatisfy({ $0 < 0x80 }) {
            return Data(stripped)
        }
        return String(decoding: stripped, as: UTF8.self).data(using: .utf8)
    }

    static func stripANSI(_ input: String) -> String {
        String(decoding: stripANSIBytes(Array(input.utf8)), as: UTF8.self)
    }
}
