import Combine
import Foundation
import Synchronization

/// One built-in highlight rule and its user-selectable presentation settings,
/// persisted to highlight-rules.json.
struct HighlightRuleConfig: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var pattern: String
    var colorHex: String        // "RRGGBB"
    var bold = false
    var caseInsensitive = false
    var enabled = true
}

/// A compiled rule ready for matching.
struct HighlightRule {
    let regex: NSRegularExpression
    let sgrStart: String
    /// `sgrStart` as UTF-8 — the byte assembler in `colorizeBytes` appends
    /// it per match, and re-encoding the string every time was measurable.
    let sgrStartBytes: [UInt8]
    /// Non-nil when this rule is a built-in default (same name, pattern, and
    /// case-sensitivity) — only then may the byte scanner take over matching,
    /// because the scanner hard-codes the default patterns.
    let builtIn: HighlightScanner.BuiltIn?

    init?(config: HighlightRuleConfig) {
        guard config.enabled else { return nil }
        var options: NSRegularExpression.Options = []
        if config.caseInsensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: config.pattern, options: options) else {
            return nil
        }
        self.regex = regex
        let hex = UInt32(config.colorHex, radix: 16) ?? 0xFFFFFF
        let r = (hex >> 16) & 0xFF
        let g = (hex >> 8) & 0xFF
        let b = hex & 0xFF
        sgrStart = "\u{1B}[38;2;\(r);\(g);\(b)\(config.bold ? ";1" : "")m"
        sgrStartBytes = Array(sgrStart.utf8)
        if let def = Highlighter.defaultConfigs.first(where: { $0.name == config.name }),
           def.pattern == config.pattern, def.caseInsensitive == config.caseInsensitive {
            builtIn = HighlightScanner.BuiltIn(rawValue: config.name)
        } else {
            builtIn = nil
        }
    }
}

/// Loads, persists, and compiles the rule set for the Highlighter.
@MainActor
final class HighlightStore: ObservableObject {
    @Published var configs: [HighlightRuleConfig] {
        didSet {
            save()
            recompile()
        }
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("highlight-rules.json")
    }

    init() {
        let decoded: [HighlightRuleConfig]?
        if let data = try? Data(contentsOf: Self.fileURL) {
            decoded = try? JSONDecoder().decode([HighlightRuleConfig].self, from: data)
        } else {
            decoded = nil
        }
        let loaded = decoded.flatMap { $0.isEmpty ? nil : $0 } ?? Highlighter.defaultConfigs
        configs = Self.builtInConfigs(from: loaded)
        if configs != loaded {
            save()
        }
        recompile()
    }

    /// Re-reads highlight-rules.json after a backup restore replaced it.
    /// Assigning `configs` runs its didSet, which writes the same bytes
    /// back and recompiles — cheap, and it keeps every observer in step.
    func reloadFromDisk() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([HighlightRuleConfig].self, from: data),
           !decoded.isEmpty {
            configs = Self.builtInConfigs(from: decoded)
        } else {
            configs = Highlighter.defaultConfigs
        }
    }

    /// Restricts persisted settings to the optimized built-in scanner rules.
    /// Name, pattern, and case-sensitivity always come from the app. Existing
    /// enable/color/bold choices and ordering remain user-owned. Custom,
    /// renamed, and duplicate rules are dropped; newly shipped rules append.
    static func builtInConfigs(from saved: [HighlightRuleConfig]) -> [HighlightRuleConfig] {
        let defaultsByName = Dictionary(
            uniqueKeysWithValues: Highlighter.defaultConfigs.map { ($0.name, $0) }
        )
        var seen = Set<String>()
        var normalized: [HighlightRuleConfig] = []
        normalized.reserveCapacity(Highlighter.defaultConfigs.count)

        for stored in saved {
            guard seen.insert(stored.name).inserted,
                  var builtIn = defaultsByName[stored.name] else { continue }
            builtIn.id = stored.id
            builtIn.colorHex = stored.colorHex
            builtIn.bold = stored.bold
            builtIn.enabled = stored.enabled
            normalized.append(builtIn)
        }

        for builtIn in Highlighter.defaultConfigs where seen.insert(builtIn.name).inserted {
            normalized.append(builtIn)
        }
        return normalized
    }

    func recompile() {
        Highlighter.active = configs.compactMap(HighlightRule.init)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(configs) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    func resetToDefaults() {
        configs = Highlighter.defaultConfigs
    }
}

/// Injects ANSI color sequences around network-relevant tokens in the
/// incoming byte stream. Only display attributes are added — characters are
/// untouched, so copy/paste and session logs stay clean.
nonisolated enum Highlighter {
    /// Compiled rules currently in effect plus the scanner mask derived from
    /// them. The mask is cached with the rules because it only changes when
    /// HighlightStore recompiles: deriving it per call cost ~1.4 µs, and
    /// escape-heavy output calls the matcher once per text run BETWEEN escape
    /// sequences — thousands of times per chunk, not once.
    private struct ActiveRules {
        var rules: [HighlightRule] = []
        /// Bit per built-in rule the scanner may match; 0 = regex path only.
        var scannerMask: UInt16 = 0
    }

    /// `Mutex` makes the cross-actor ownership explicit: matching runs on
    /// background highlight queues while HighlightStore recompiles on the
    /// main actor. NSRegularExpression is thread-safe for matching.
    private static let activeStorage = Mutex(ActiveRules())

    /// Called from background highlight queues as well as the main actor.
    nonisolated static var active: [HighlightRule] {
        get { activeStorage.withLock { $0.rules } }
        set {
            let mask = HighlightScanner.mask(of: newValue.compactMap(\.builtIn))
            activeStorage.withLock { $0 = ActiveRules(rules: newValue, scannerMask: mask) }
        }
    }

    /// Rules and mask in one lock acquisition — the matching path needs both.
    nonisolated private static var activeSnapshot: ActiveRules {
        activeStorage.withLock { $0 }
    }

    private static let sgrEnd = "\u{1B}[39;22m"
    private static let sgrEndBytes = Array(sgrEnd.utf8)

    /// Order = priority: earlier rules claim their ranges first.
    /// Patterns aligned with BeeSheep's BestTextLog grammar.
    static let defaultConfigs: [HighlightRuleConfig] = [
        // Before "interface": "vlan 1,10,225-227" (spaced list) is the vlan
        // keyword; "Vlan10" (attached) stays an interface name.
        HighlightRuleConfig(
            name: "vlan",
            pattern: #"\bvlan[ \t-]+\d{1,4}(?:[ \t]*[,\-][ \t]*\d{1,4})*"#,
            colorHex: "E8D06B", caseInsensitive: true
        ),
        HighlightRuleConfig(
            name: "interface",
            pattern: #"\b(?:GigabitEthernet|TenGigabitEthernet|TwoGigabitEthernet|TwentyFiveGigE|FortyGigabitEthernet|HundredGigE|AppGigabitEthernet|FastEthernet|Port-channel|Bundle-Ether|Ethernet|Loopback|Tunnel|Management|Serial|Vlan|Gi|Twe|Tw|Te|Fo|Hu|Fa|Eth|Po|Lo|Se|lag|Trk|mgmt|ens|eno|bond|br)\s?\d+(?:[\/.:_-]\d+)*\b"#,
            colorHex: "F0A860", caseInsensitive: true
        ),
        HighlightRuleConfig(name: "cx-port", pattern: #"\b\d{1,2}/\d{1,2}/\d{1,2}(?::\d)?\b"#, colorHex: "F0A860"),
        HighlightRuleConfig(name: "mask", pattern: #"\b255(?:\.\d{1,3}){3}\b"#, colorHex: "B39DE8"),
        HighlightRuleConfig(name: "cidr", pattern: #"(?<=\d)/\d{1,2}\b"#, colorHex: "B39DE8"),
        // Octets are capped at 255 so "999.999.999.999" no longer matches.
        HighlightRuleConfig(
            name: "ipv4",
            pattern: #"\b(?:(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.){3}(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\b"#,
            colorHex: "6CD1E0"
        ),
        HighlightRuleConfig(
            name: "mac",
            pattern: #"\b(?:[0-9A-Fa-f]{4}\.){2}[0-9A-Fa-f]{4}\b|\b(?:[0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}\b"#,
            colorHex: "E08BC7"
        ),
        // Empty groups allow the compressed "::" form (2001:db8::1). Custom
        // boundaries instead of \b so a leading "::" (e.g. ::1) also matches —
        // ":" is a non-word char, so \b would never fire before it.
        HighlightRuleConfig(name: "ipv6", pattern: #"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])"#, colorHex: "6CD1E0"),
        HighlightRuleConfig(
            name: "state-good",
            pattern: #"\b(?:no[ \t]+shutdown|up|connected|active|established|running|enabled?|successful|success|forwarding|permit(?:ted|s)?|reachable|authorized|full|allow(?:ed)?)\b"#,
            colorHex: "7DD98C", bold: true, caseInsensitive: true
        ),
        HighlightRuleConfig(
            name: "state-warn",
            pattern: #"\b(?:warning|warn)\b"#,
            colorHex: "E0B568", bold: true, caseInsensitive: true
        ),
        HighlightRuleConfig(
            name: "state-bad",
            pattern: #"\b(?:down|shutdown|err-disabled|errdisable|notconnect|fail(?:ed|ure)?|den(?:y|ied)|unreachable|invalid|error|err|crit(?:ical)?|emergency|alert|blocked|blocking|discarding|disabled?|suspended|violation|half)\b"#,
            colorHex: "ED7A7A", bold: true, caseInsensitive: true
        ),
    ]

    /// Runs on background highlight queues (via HighlightBuffer) — never on
    /// the main actor — so it is honestly nonisolated.
    nonisolated static func process(_ bytes: [UInt8]) -> [UInt8] {
        if bytes.contains(0x1B) {
            return processPreservingEscapes(bytes)
        }
        return colorizeBytes(bytes)
    }

    /// Splits the stream into escape sequences (kept verbatim) and plain-text
    /// runs (colorized), so the device's own formatting never breaks.
    nonisolated private static func processPreservingEscapes(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 64)
        var textRun: [UInt8] = []
        textRun.reserveCapacity(bytes.count)
        var index = 0

        func flushText() {
            guard !textRun.isEmpty else { return }
            output.append(contentsOf: colorizeBytes(textRun))
            // Keep the reserved capacity: escape-heavy streams flush on every
            // sequence, and reallocating the full-size buffer each time was
            // pure churn.
            textRun.removeAll(keepingCapacity: true)
        }

        while index < bytes.count {
            guard bytes[index] == 0x1B else {
                textRun.append(bytes[index])
                index += 1
                continue
            }
            flushText()
            let start = index
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "[") {
                index += 1
                while index < bytes.count, !(bytes[index] >= 0x40 && bytes[index] <= 0x7E) {
                    index += 1
                }
                if index < bytes.count { index += 1 }
            } else if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                while index < bytes.count, bytes[index] != 0x07, bytes[index] != 0x1B {
                    index += 1
                }
                if index < bytes.count {
                    index += bytes[index] == 0x1B ? 2 : 1
                }
            } else if index < bytes.count, bytes[index] == UInt8(ascii: "P") || bytes[index] == UInt8(ascii: "_") {
                // DCS / APC string payloads (sixel, kitty images): only ST
                // (ESC \) terminates them — consume the whole run so SGR
                // injection never lands inside the base64 payload.
                index += 1
                while index < bytes.count, bytes[index] != 0x1B {
                    index += 1
                }
                if index < bytes.count {
                    index += 2
                }
            } else if index < bytes.count {
                index += 1
            }
            output.append(contentsOf: bytes[start..<min(index, bytes.count)])
        }
        flushText()
        return output
    }

    /// Runs on background highlight queues (via process) — honestly
    /// nonisolated like the rest of the matching path.
    nonisolated static func colorize(_ text: String) -> String {
        let snapshot = activeSnapshot
        let rules = snapshot.rules
        guard !text.isEmpty, !rules.isEmpty else { return text }

        // The byte scanner hard-codes the default patterns and assumes ASCII
        // (ICU \b uses Unicode properties), so it takes over only for pure
        // ASCII text and only for rules whose pattern is an untouched
        // default — everything else stays on the regex path. Byte offsets
        // equal UTF-16 offsets when every byte is ASCII.
        let bytes = Array(text.utf8)
        let claimed = claimedSpans(
            rules: rules,
            scannerMask: snapshot.scannerMask,
            asciiBytes: isASCII(bytes) ? bytes : nil,
            text: text
        )
        guard !claimed.isEmpty else { return text }

        // Assemble from one UTF-16 array instead of repeated
        // NSString.substring calls — each substring re-bridges and re-scans
        // the encoding, so the old way cost per MATCH, not per byte.
        // NSRange is already in UTF-16 units, so indexing is direct.
        // (HIGHLIGHTER-SPEC PART A; output is byte-identical to the old code.)
        let units = Array(text.utf16)
        var result = ""
        result.reserveCapacity(text.utf8.count + claimed.count * 24)
        var position = 0
        for (range, ruleIndex) in claimed {
            if range.location > position {
                result += String(decoding: units[position..<range.location], as: UTF16.self)
            }
            result += rules[ruleIndex].sgrStart
            result += String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
            result += sgrEnd
            position = range.location + range.length
        }
        if position < units.count {
            result += String(decoding: units[position...], as: UTF16.self)
        }
        return result
    }

    /// Byte-in/byte-out twin of `colorize` for the streaming path.
    ///
    /// For pure-ASCII text — what network gear emits — nothing ever becomes
    /// a String: byte offsets equal UTF-16 offsets, so the spans the scanner
    /// produces index straight into the input and the output is assembled by
    /// copying byte ranges. The old route (bytes → String → [UTF16] →
    /// per-segment String → utf8) spent ~75 % of colorize's time building
    /// three Strings per match; matching itself was never the bottleneck.
    /// Anything non-ASCII falls back to the String path unchanged, so output
    /// stays byte-identical either way.
    nonisolated static func colorizeBytes(_ bytes: [UInt8]) -> [UInt8] {
        let snapshot = activeSnapshot
        let rules = snapshot.rules
        guard !bytes.isEmpty, !rules.isEmpty else { return bytes }
        guard isASCII(bytes) else {
            return Array(colorize(String(decoding: bytes, as: UTF8.self)).utf8)
        }

        let claimed = claimedSpans(
            rules: rules,
            scannerMask: snapshot.scannerMask,
            asciiBytes: bytes,
            text: nil
        )
        guard !claimed.isEmpty else { return bytes }

        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + claimed.count * 24)
        var position = 0
        for (range, ruleIndex) in claimed {
            if range.location > position {
                output.append(contentsOf: bytes[position..<range.location])
            }
            output.append(contentsOf: rules[ruleIndex].sgrStartBytes)
            output.append(contentsOf: bytes[range.location..<(range.location + range.length)])
            output.append(contentsOf: sgrEndBytes)
            position = range.location + range.length
        }
        if position < bytes.count {
            output.append(contentsOf: bytes[position...])
        }
        return output
    }

    /// One byte pass instead of `text.allSatisfy { $0.isASCII }` on top of
    /// the utf8 copy the scanner needs anyway — the Character-level probe
    /// was ~10 % of colorize by itself.
    @inline(__always)
    nonisolated private static func isASCII(_ bytes: [UInt8]) -> Bool {
        for byte in bytes where byte >= 0x80 { return false }
        return true
    }

    /// The non-overlapping spans each rule claims, in priority order.
    ///
    /// `asciiBytes` is non-nil only when the input is pure ASCII, which is
    /// what lets the byte scanner stand in for a rule's regex; `text` is the
    /// String form when the caller already has one. Rules the scanner can't
    /// serve (user-edited patterns) need a String for ICU, so one is built
    /// on demand and reused for every remaining regex rule.
    ///
    /// Claimed spans stay sorted by location and never overlap, and each
    /// rule's matches arrive sorted too — so each rule is merged into
    /// claimed in one linear pass. A match is dropped iff it overlaps an
    /// already-claimed span: spans ending at or before the match start
    /// cannot overlap, and the first span reaching into it is the only
    /// one that can (later spans start even further out). That is exactly
    /// the old prev/next neighbour check around a binary-search insert —
    /// but with no O(n) middle-of-array memmoves, which made multi-MB
    /// dumps quadratic.
    nonisolated private static func claimedSpans(
        rules: [HighlightRule],
        scannerMask: UInt16,
        asciiBytes: [UInt8]?,
        text: String?
    ) -> [(range: NSRange, rule: Int)] {
        let scannable = asciiBytes != nil && scannerMask != 0
        // Ordinal-indexed, so a rule's matches are an array subscript rather
        // than a Dictionary lookup — and building the result costs no hashing.
        var scanned: [[Range<Int>]] = []
        if scannable, let asciiBytes {
            scanned = HighlightScanner.scan(asciiBytes, enabledMask: scannerMask)
        }

        var regexText: String?
        var regexRange = NSRange(location: 0, length: 0)
        var claimed: [(range: NSRange, rule: Int)] = []

        for (ruleIndex, rule) in rules.enumerated() {
            if let builtIn = rule.builtIn, scannable {
                // Merging is a full rebuild of `claimed`, so a rule that
                // matched nothing must not pay for one. On escape-heavy
                // output the text runs between sequences are a few bytes
                // long and almost every rule lands here.
                let matches = scanned[HighlightScanner.ordinal(of: builtIn)]
                if matches.isEmpty { continue }
                var merged: [(range: NSRange, rule: Int)] = []
                merged.reserveCapacity(claimed.count + matches.count)
                var ci = 0
                for match in matches where !match.isEmpty {
                    while ci < claimed.count,
                          claimed[ci].range.location + claimed[ci].range.length <= match.lowerBound {
                        merged.append(claimed[ci])
                        ci += 1
                    }
                    // Overlaps a claimed span — drop this match, keep `ci`.
                    if ci < claimed.count, claimed[ci].range.location < match.upperBound { continue }
                    merged.append((NSRange(location: match.lowerBound, length: match.count), ruleIndex))
                }
                while ci < claimed.count { // remaining spans start past the last match
                    merged.append(claimed[ci])
                    ci += 1
                }
                claimed = merged
                continue
            }

            var merged: [(range: NSRange, rule: Int)] = []
            merged.reserveCapacity(claimed.count + 16)
            var ci = 0
            let offer = { (range: NSRange) in
                guard range.length > 0 else { return }
                let end = range.location + range.length
                while ci < claimed.count, claimed[ci].range.location + claimed[ci].range.length <= range.location {
                    merged.append(claimed[ci])
                    ci += 1
                }
                if ci < claimed.count, claimed[ci].range.location < end { return } // overlaps a claimed span
                merged.append((range, ruleIndex))
            }
            if regexText == nil {
                let built = text ?? String(decoding: asciiBytes ?? [], as: UTF8.self)
                regexText = built
                regexRange = NSRange(location: 0, length: (built as NSString).length)
            }
            if let regexText {
                rule.regex.enumerateMatches(in: regexText, range: regexRange) { match, _, _ in
                    if let range = match?.range { offer(range) }
                }
            }
            while ci < claimed.count {
                merged.append(claimed[ci])
                ci += 1
            }
            claimed = merged
        }
        return claimed
    }

}
