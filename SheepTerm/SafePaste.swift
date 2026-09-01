import Foundation

/// A bounded, normalized multi-line paste ready to be sent one command at a
/// time. Parsing is UI-independent so newline and size behaviour stays covered
/// by the standalone test harness.
nonisolated struct SafePastePlan: Equatable, Sendable {
    static let maxBytes = 5 * 1024 * 1024
    static let maxLines = 10_000

    enum ParseError: Error, Equatable {
        case singleLine
        case tooManyBytes
        case tooManyLines
    }

    let lines: [String]
    let sourceByteCount: Int

    static func parse(
        _ text: String,
        maxBytes: Int = SafePastePlan.maxBytes,
        maxLines: Int = SafePastePlan.maxLines
    ) throws -> SafePastePlan {
        let byteCount = text.utf8.count
        guard byteCount <= maxBytes else { throw ParseError.tooManyBytes }

        // Clipboard text can come from Unix, Windows, or a serial capture.
        // Split on any of "\r\n", "\r", or "\n" in one pass instead of
        // normalizing then splitting (each of those was a full string copy,
        // and this can run on paste text up to maxBytes on the main actor).
        // Scanning is done over UTF-8 bytes, not Characters: grapheme-cluster
        // iteration walks the Unicode segmentation algorithm at every step,
        // which is far more expensive than a byte comparison. A byte scan is
        // safe here because UTF-8 continuation bytes are always >= 0x80, so
        // 0x0D and 0x0A can only ever appear as themselves, never as part of
        // a multi-byte character's encoding - the scan cannot split a
        // character. Removing exactly one terminal empty component consumes
        // the separator after the final command while preserving intentional
        // blank lines.
        let utf8 = text.utf8
        var lines: [String] = []
        var start = utf8.startIndex
        var idx = utf8.startIndex
        while idx < utf8.endIndex {
            let byte = utf8[idx]
            if byte == 0x0D {
                lines.append(String(decoding: utf8[start..<idx], as: UTF8.self))
                var next = utf8.index(after: idx)
                if next < utf8.endIndex, utf8[next] == 0x0A {
                    next = utf8.index(after: next)
                }
                idx = next
                start = idx
            } else if byte == 0x0A {
                lines.append(String(decoding: utf8[start..<idx], as: UTF8.self))
                idx = utf8.index(after: idx)
                start = idx
            } else {
                idx = utf8.index(after: idx)
            }
        }
        lines.append(String(decoding: utf8[start...], as: UTF8.self))
        if lines.last == "" { lines.removeLast() }

        guard lines.count > 1 else { throw ParseError.singleLine }
        guard lines.count <= maxLines else { throw ParseError.tooManyLines }
        return SafePastePlan(lines: lines, sourceByteCount: byteCount)
    }

    /// Network CLIs expect the Return key (CR), not a clipboard's platform
    /// newline. Safe mode deliberately submits the final line too; the user
    /// chose "Send N Lines", rather than byte-for-byte immediate paste.
    func bytes(forLine index: Int) -> [UInt8] {
        Array(lines[index].utf8) + [0x0D]
    }
}

@MainActor
final class SafePastePacer {
    enum EndReason: Equatable {
        case finished
        case stopped
        case keyboardInput
        case sessionEnded
        case replaced
    }

    private var task: Task<Void, Never>?
    private var completion: ((EndReason, Int) -> Void)?
    private(set) var sentCount = 0
    private(set) var totalCount = 0

    var isActive: Bool { task != nil }

    func start(
        plan: SafePastePlan,
        delayMilliseconds: Int,
        send: @escaping ([UInt8]) -> Void,
        progress: @escaping (_ sent: Int, _ total: Int) -> Void,
        completion: @escaping (_ reason: EndReason, _ sent: Int) -> Void
    ) {
        stop(reason: .replaced)
        sentCount = 0
        totalCount = plan.lines.count
        self.completion = completion
        let delay = max(delayMilliseconds, 1)

        task = Task { @MainActor [weak self] in
            for index in plan.lines.indices {
                guard !Task.isCancelled, self != nil else { return }
                send(plan.bytes(forLine: index))
                self?.sentCount = index + 1
                progress(index + 1, plan.lines.count)
                guard index + 1 < plan.lines.count else { continue }
                do {
                    try await Task.sleep(for: .milliseconds(delay))
                } catch {
                    return
                }
            }
            self?.finish(reason: .finished)
        }
    }

    func stop(reason: EndReason) {
        guard task != nil else { return }
        task?.cancel()
        task = nil
        let callback = completion
        completion = nil
        callback?(reason, sentCount)
    }

    private func finish(reason: EndReason) {
        guard task != nil else { return }
        task = nil
        let callback = completion
        completion = nil
        callback?(reason, sentCount)
    }
}
