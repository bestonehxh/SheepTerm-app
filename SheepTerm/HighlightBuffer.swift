import Foundation
import Synchronization

/// Fixes highlight misses when a token (e.g. an IP address) or an escape
/// sequence is split across two network chunks: the "unfinished" tail is
/// held back and prepended to the next chunk. Tokens are only held for
/// large chunks so typing latency is unaffected; incomplete escapes are
/// held for every chunk size since the 40 ms flush covers them. A 40 ms
/// timer flushes any held tail when output pauses. A string sequence
/// (OSC/DCS/APC) that had to be emitted raw — oversized or flushed
/// mid-payload — is tracked so its continuation bypasses colorize().
///
/// All matching runs on a private serial queue so regex work never blocks
/// the main thread; the `feed` closure is invoked on that queue and must hop
/// to the main thread itself before touching UI.
///
/// Backpressure: `append` counts the bytes queued-but-unprocessed; once that
/// backlog exceeds `maxQueuedBytes` the regex engine is falling behind the
/// producer, so chunks pass through raw until the queue drains below the
/// cap. The decision is made on the serial queue at processing time, so
/// `feed` always fires in exact append order — no data is lost or reordered.
nonisolated final class HighlightBuffer: Sendable {
    private let queue = DispatchQueue(label: "sheepterm.highlight")
    private struct State {
        var carry: [UInt8] = []
        var flushWork: DispatchWorkItem?
        /// Opener byte of a string sequence (OSC `]`, DCS `P`, APC `_`)
        /// emitted raw while still open. Continuations stay verbatim.
        var rawMode: UInt8?
    }
    /// INVARIANT — read this before touching `feed`. Both `withLock` sites
    /// (`process`, `flush`) run only on `queue`, so the Mutex is not what
    /// serializes them; it is what makes the Sendable conformance checked,
    /// and it measured FASTER than a `nonisolated(unsafe)` field (an inout
    /// class property pays dynamic exclusivity checks a Mutex cell does not).
    /// The cost is that `Highlighter.process` and `feed` run while the lock
    /// is held — up to ~140 ms for a 256 KB escape-heavy chunk. That is
    /// harmless only because nothing else ever acquires it. So:
    ///   * `feed` must never block or re-enter this buffer — the Mutex is not
    ///     recursive, and a synchronous hop to main would hard-hang the app.
    ///     Both production feeds use `DispatchQueue.main.async`. Keep it.
    ///   * Adding any cross-thread accessor (a `reset()` from the main actor,
    ///     say) makes that caller wait out a whole highlight pass. Move the
    ///     `feed`/`Highlighter.process` calls outside `withLock` first.
    private let state = Mutex(State())
    /// Bytes handed to append but not yet processed by the queue. This must
    /// not share `state`'s mutex: the producer needs to keep enqueueing while
    /// the serial worker is highlighting, otherwise the backlog can never
    /// cross the passthrough threshold and backpressure silently stops
    /// working during a large output burst.
    private let pendingBytes = Mutex(0)
    /// A held escape run longer than this is garbage, not a sequence —
    /// pass it through raw instead of growing `carry` forever.
    private static let maxEscapeHold = 1024 * 1024
    /// Beyond this queued-but-unprocessed backlog, chunks pass through raw
    /// until the queue drains below the cap again.
    private static let maxQueuedBytes = 1024 * 1024

    /// Called from producer threads. Separate mutexes own the cross-thread
    /// backlog and queue-confined parser state, giving the class checked
    /// Sendability without serializing the producer behind highlighting.
    nonisolated func append(_ bytes: [UInt8], enabled: Bool, feed: @escaping @Sendable (ArraySlice<UInt8>) -> Void) {
        pendingBytes.withLock { $0 += bytes.count }
        queue.async { [self] in
            let queuedByteCount = pendingBytes.withLock { pendingBytes in
                pendingBytes -= bytes.count
                return pendingBytes
            }
            process(bytes, enabled: enabled, queuedByteCount: queuedByteCount, feed: feed)
        }
    }

    nonisolated private func process(
        _ bytes: [UInt8],
        enabled: Bool,
        queuedByteCount: Int,
        feed: @escaping @Sendable (ArraySlice<UInt8>) -> Void
    ) {
        state.withLock { state in
            processLocked(
                bytes,
                enabled: enabled,
                queuedByteCount: queuedByteCount,
                state: &state,
                feed: feed
            )
        }
    }

    /// Runs only while `state` is borrowed by Mutex. Recursive parsing passes
    /// the same inout state, so it never attempts to acquire the Mutex twice.
    nonisolated private func processLocked(
        _ bytes: [UInt8],
        enabled: Bool,
        queuedByteCount: Int,
        state: inout State,
        feed: @escaping @Sendable (ArraySlice<UInt8>) -> Void
    ) {
        state.flushWork?.cancel()
        state.flushWork = nil

        // Two guards against the regex engine falling behind: a single chunk
        // over 256 KB is passed raw (huge dumps would pile up faster than we
        // can chew), and a queued-but-unprocessed backlog over maxQueuedBytes
        // means the producer is outrunning us — pass chunks raw until the
        // queue drains below the cap. Both keep feed order intact: the raw
        // passthrough happens right here on the serial queue.
        let overloaded = queuedByteCount > Self.maxQueuedBytes
        guard enabled, bytes.count <= 256 * 1024, !overloaded else {
            // Everything pending goes out raw, in order: the held carry
            // first, then this chunk. They must be examined as ONE buffer —
            // the carry may hold a string sequence escapeSplit was holding
            // (e.g. a DCS dumped raw when the backlog guard fired mid-hold),
            // and an ST terminator may be split across the carry|chunk seam.
            let combined: [UInt8]
            if state.carry.isEmpty {
                combined = bytes
            } else {
                var joined = state.carry
                joined.append(contentsOf: bytes)
                combined = joined
                state.carry = []
            }
            // Still watch for the terminator of a raw-emitted string
            // sequence, or highlighting would stay off past its end.
            if let kind = state.rawMode {
                if let end = Self.stringSequenceEnd(combined, kind: kind) {
                    state.rawMode = nil
                    feed(combined[..<end])
                    if end < combined.count {
                        // The sequence ended mid-chunk: the remainder is
                        // ordinary text again — re-run it through the normal
                        // path so it gets highlighted (and any NEW string
                        // sequence it opens is tracked) instead of leaking
                        // raw passthrough past the terminator. Terminates:
                        // rawMode is nil on re-entry, so the guard below can
                        // only feed straight through.
                        processLocked(
                            Array(combined[end...]),
                            enabled: enabled,
                            queuedByteCount: queuedByteCount,
                            state: &state,
                            feed: feed
                        )
                    }
                } else {
                    feed(combined[...]) // still open — everything is payload
                }
                return
            }
            feed(combined[...])
            // The raw-fed stream may end inside a string sequence — opened
            // within this chunk, or held in the carry and dumped raw past
            // the hold cap. Track it, or once the backlog drains the
            // continuation would be colorized and SGR would land inside
            // the payload.
            state.rawMode = Self.openStringSequence(combined)?.kind
            return
        }

        var data: [UInt8]
        if state.carry.isEmpty {
            // The common path has no held tail. Assignment shares the input's
            // copy-on-write storage; `carry + bytes` allocated and copied every
            // network chunk even though there was nothing to prepend.
            data = bytes
        } else {
            data = state.carry
            data.append(contentsOf: bytes)
            state.carry = []
        }

        // A string sequence emitted raw earlier (over the hold cap, or
        // flushed mid-payload) is still open: pass its payload through
        // verbatim until the terminator arrives so colorize() never
        // injects SGR into it.
        if let kind = state.rawMode {
            if let end = Self.stringSequenceEnd(data, kind: kind) {
                if end > 0 { feed(data[..<end]) }
                state.rawMode = nil
                data = Array(data[end...])
                if data.isEmpty { return }
            } else {
                // Still open; a trailing ESC may be the ST's first half —
                // hold just that byte. The flush timer must be set here too:
                // flushWork was cancelled at the top of process(), so without
                // it the byte sat in carry until the next chunk arrived —
                // indefinitely when output paused, and lost at session close.
                if data.last == 0x1B {
                    if data.count > 1 { feed(data[..<(data.count - 1)]) }
                    state.carry = [0x1B]
                    scheduleFlushLocked(colorize: false, state: &state, feed: feed)
                } else {
                    feed(data[...])
                }
                return
            }
        }

        // One cut index for all holds: never cut inside a multi-byte UTF-8
        // character (Thai, emoji, box-drawing) — String(decoding:) would
        // replace the halves with U+FFFD permanently — and hold back an
        // unfinished trailing escape/token so it isn't highlighted in two
        // halves. Taking the MINIMUM matters: two separate assignments
        // would let a later hold overwrite an earlier one and lose the
        // held byte. The UTF-8 and escape checks apply to every chunk
        // size — holding an incomplete escape costs nothing because the
        // 40 ms flush covers it, while SGR injected mid-sequence corrupts
        // the stream. The token check stays large-chunk-only: small chunks
        // are echo/keystrokes and holding tokens there would add latency.
        var cut = data.count
        if let utf8Cut = Self.incompleteUTF8Tail(data) {
            cut = utf8Cut
        }
        cut = min(cut, Self.escapeSplit(data))
        if bytes.count >= 64 {
            cut = min(cut, Self.tokenSplit(data))
        }
        if cut < data.count {
            state.carry = Array(data[cut...])
            data = Array(data[..<cut])
        }

        if !data.isEmpty {
            feed(Highlighter.process(data)[...])
            // Emitted data that still ends inside a string sequence (the
            // hold cap was exceeded) — continuations must bypass
            // colorize() until the terminator arrives.
            state.rawMode = Self.openStringSequence(data)?.kind
        }
        if !state.carry.isEmpty {
            scheduleFlushLocked(colorize: true, state: &state, feed: feed)
        }
    }

    /// Schedules the 40 ms flush for a held tail; called on `queue` only. A
    /// tail held while a raw string sequence is still open is payload, so it
    /// is fed verbatim — colorize() would inject SGR into the sequence. A
    /// normal hold is colorized on flush, and its open-sequence state is
    /// re-derived so continuations keep bypassing colorize().
    nonisolated private func scheduleFlushLocked(
        colorize: Bool,
        state: inout State,
        feed: @escaping @Sendable (ArraySlice<UInt8>) -> Void
    ) {
        let work = DispatchWorkItem { [weak self] in
            self?.flush(colorize: colorize, feed: feed)
        }
        state.flushWork = work
        queue.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    nonisolated private func flush(
        colorize: Bool,
        feed: @escaping @Sendable (ArraySlice<UInt8>) -> Void
    ) {
        state.withLock { state in
            guard !state.carry.isEmpty else {
                state.flushWork = nil
                return
            }
            if colorize {
                feed(Highlighter.process(state.carry)[...])
                // A flushed string-sequence payload is still open — its
                // continuation must bypass colorize() as well.
                state.rawMode = Self.openStringSequence(state.carry)?.kind
            } else {
                feed(state.carry[...])
            }
            state.carry = []
            state.flushWork = nil
        }
    }

    /// Index of a trailing incomplete UTF-8 sequence — a lead byte whose
    /// continuation bytes haven't all arrived yet — or nil when the buffer
    /// ends on a character boundary (or on invalid bytes, which are passed
    /// through rather than held forever).
    nonisolated private static func incompleteUTF8Tail(_ bytes: [UInt8]) -> Int? {
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
            // bytes in valid UTF-8 — treating them as leads held plain
            // garbage back for the 40 ms flush; pass them through instead.
            if byte >= 0xC2, byte <= 0xF4 {
                let needed = byte >= 0xF0 ? 3 : (byte >= 0xE0 ? 2 : 1)
                if continuation < needed { return index - 1 }
            }
            return nil
        }
        return nil
    }

    /// Index to cut at so an unfinished trailing escape sequence is
    /// carried over instead of being colorized in two halves. An open
    /// string sequence (OSC/DCS/APC) holds from its opener however far
    /// back it is — a split sixel/kitty payload must never reach
    /// colorize() — up to maxEscapeHold; beyond the cap the run is
    /// garbage, not a sequence, and passes through raw.
    nonisolated private static func escapeSplit(_ bytes: [UInt8]) -> Int {
        if let open = openStringSequence(bytes) {
            return bytes.count - open.start <= Self.maxEscapeHold ? open.start : bytes.count
        }
        // CSI / two-byte sequences: last-ESC analysis.
        guard let esc = bytes.lastIndex(of: 0x1B),
              bytes.count - esc <= Self.maxEscapeHold else { return bytes.count }
        let tail = bytes[(esc + 1)...]
        let complete: Bool
        if tail.first == UInt8(ascii: "[") {
            complete = tail.dropFirst().contains { $0 >= 0x40 && $0 <= 0x7E }
        } else {
            complete = !tail.isEmpty
        }
        return complete ? bytes.count : esc
    }

    /// The string sequence (OSC/DCS/APC) still open at the end of `bytes`
    /// as (opener index, opener byte), or nil. Scans forward because an
    /// ESC inside a payload ABORTS the sequence — real terminals behave
    /// the same.
    nonisolated private static func openStringSequence(_ bytes: [UInt8]) -> (start: Int, kind: UInt8)? {
        var open: (start: Int, kind: UInt8)?
        var index = 0
        while index < bytes.count {
            if let current = open {
                // BEL ends OSC; ESC \ ends any of them; a trailing ESC
                // might be the ST's first half — stay open.
                if current.kind == UInt8(ascii: "]"), bytes[index] == 0x07 {
                    open = nil
                } else if bytes[index] == 0x1B {
                    if index + 1 >= bytes.count {
                        // stay open
                    } else if bytes[index + 1] == UInt8(ascii: "\\") {
                        open = nil
                        index += 1
                    } else {
                        open = nil
                        continue // re-examine the ESC as a possible new opener
                    }
                }
            } else if bytes[index] == 0x1B, index + 1 < bytes.count,
                      bytes[index + 1] == UInt8(ascii: "]") || bytes[index + 1] == UInt8(ascii: "P") || bytes[index + 1] == UInt8(ascii: "_") {
                open = (index, bytes[index + 1])
                index += 1
            }
            index += 1
        }
        return open
    }

    /// Index just past the terminator of an open string sequence of
    /// `kind` — OSC ends at BEL or ST, DCS/APC at ST (ESC \) only — or
    /// past the ESC that aborts it; nil when the sequence is still open
    /// at the end of `bytes`.
    nonisolated private static func stringSequenceEnd(_ bytes: [UInt8], kind: UInt8) -> Int? {
        var index = 0
        while index < bytes.count {
            if kind == UInt8(ascii: "]"), bytes[index] == 0x07 { return index + 1 }
            if bytes[index] == 0x1B {
                // A trailing ESC may be the ST's first half — wait for more.
                guard index + 1 < bytes.count else { return nil }
                return bytes[index + 1] == UInt8(ascii: "\\") ? index + 2 : index
            }
            index += 1
        }
        return nil
    }

    /// Index to cut at so an unfinished trailing token (IP, interface
    /// name) is carried over instead of being highlighted in two halves.
    nonisolated private static func tokenSplit(_ bytes: [UInt8]) -> Int {
        // Trailing run of token characters (alnum . / : -).
        var index = bytes.count
        while index > 0 {
            let c = bytes[index - 1]
            let isToken = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x61 && c <= 0x7A) || c == 0x2E || c == 0x2F || c == 0x3A || c == 0x2D
            if !isToken { break }
            index -= 1
        }
        if index < bytes.count, index > 0, bytes.count - index <= 32 {
            return index
        }
        return bytes.count
    }
}
