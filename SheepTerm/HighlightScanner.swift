import Foundation

/// Single-pass byte scanner for the 11 built-in highlight rules.
///
/// Replaces 11 NSRegularExpression passes (ICU, backtracking) with one walk
/// over the bytes that can never backtrack: a 256-entry start table says
/// which rules may begin at each byte, and each matcher is a direct hand
/// translation of its default regex. Measured against the regex path on a
/// 4 MB dump: ~17x faster match phase (~37 MB/s vs ~2.1 MB/s), identical
/// output byte-for-byte (corpus 121/121, seeded fuzz 20,000/20,000 — see
/// HIGHLIGHTER-PROPOSAL.md).
///
/// Used by `Highlighter.colorize` only when the text is pure ASCII and a
/// rule's pattern is untouched default — anything else stays on the regex
/// path, so semantics can never drift from what the user configured.
nonisolated enum HighlightScanner {
    enum BuiltIn: String, CaseIterable {
        case vlan, interface, cxPort = "cx-port", mask, cidr, ipv4, mac, ipv6
        case stateGood = "state-good", stateWarn = "state-warn", stateBad = "state-bad"
    }

    @inline(__always) static func isWord(_ b: UInt8) -> Bool {
        (b >= 0x61 && b <= 0x7A) || (b >= 0x41 && b <= 0x5A) || (b >= 0x30 && b <= 0x39) || b == 0x5F
    }
    @inline(__always) static func isDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }
    @inline(__always) static func isHex(_ b: UInt8) -> Bool {
        isDigit(b) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46)
    }
    @inline(__always) static func lower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b }
    @inline(__always) static func isSpace(_ b: UInt8) -> Bool {
        b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0B || b == 0x0C || b == 0x0D
    }
    /// \b before a word char: start of buffer or a non-word byte behind.
    @inline(__always) static func boundaryBefore(_ b: [UInt8], _ i: Int) -> Bool {
        i == 0 || !isWord(b[i - 1])
    }
    /// \b after a word char: end of buffer or a non-word byte ahead.
    @inline(__always) static func boundaryAfter(_ b: [UInt8], _ e: Int) -> Bool {
        e == b.count || !isWord(b[e])
    }

    static func bit(of rule: BuiltIn) -> UInt16 {
        switch rule {
        case .vlan: return 1
        case .interface: return 2
        case .cxPort: return 4
        case .mask: return 8
        case .cidr: return 16
        case .ipv4: return 32
        case .mac: return 64
        case .ipv6: return 128
        case .stateGood: return 256
        case .stateWarn: return 512
        case .stateBad: return 1024
        }
    }

    /// byte -> bitmask of rules that may START at that byte.
    static let startTable: [UInt16] = {
        var table = [UInt16](repeating: 0, count: 256)
        let maskBit = bit(of: .mask), cxBit = bit(of: .cxPort), v4Bit = bit(of: .ipv4)
        let macBit = bit(of: .mac), v6Bit = bit(of: .ipv6), cidrBit = bit(of: .cidr)
        for d: UInt8 in 0x30...0x39 {
            table[Int(d)] = cxBit | v4Bit | macBit | v6Bit
        }
        table[Int(0x32)] |= maskBit // '2' may start 255.x.x.x
        table[Int(0x2F)] = cidrBit  // '/'
        table[Int(0x3A)] = v6Bit    // ':' (::1)
        for h: UInt8 in 0x61...0x66 { table[Int(h)] |= macBit | v6Bit; table[Int(h - 0x20)] |= macBit | v6Bit }
        // keyword-led rules
        var letterRules = [UInt8: UInt16]()
        func addKeyword(_ kw: String, _ ruleBit: UInt16) {
            let first = lower(kw.utf8.first!)
            letterRules[first, default: 0] |= ruleBit
        }
        addKeyword("vlan", bit(of: .vlan))
        for kw in interfaceKeywords { addKeyword(kw, bit(of: .interface)) }
        for kw in stateGoodKeywords { addKeyword(kw, bit(of: .stateGood)) }
        addKeyword("no", bit(of: .stateGood)) // no[ \t]+shutdown
        for kw in stateWarnKeywords { addKeyword(kw, bit(of: .stateWarn)) }
        for kw in stateBadKeywords { addKeyword(kw, bit(of: .stateBad)) }
        for (letter, ruleBits) in letterRules {
            table[Int(letter)] |= ruleBits
            table[Int(letter - 0x20)] |= ruleBits // uppercase twin
        }
        return table
    }()

    // Interface keywords lowercased, longest-first (stable) — equivalent to
    // the pattern's alternation order because every keyword that prefixes
    // another appears LATER in defaultConfigs.
    static let interfaceKeywords: [String] = {
        let kws = ["GigabitEthernet", "TenGigabitEthernet", "TwoGigabitEthernet", "TwentyFiveGigE",
                   "FortyGigabitEthernet", "HundredGigE", "AppGigabitEthernet", "FastEthernet",
                   "Port-channel", "Bundle-Ether", "Ethernet", "Loopback", "Tunnel", "Management",
                   "Serial", "Vlan", "Gi", "Twe", "Tw", "Te", "Fo", "Hu", "Fa", "Eth", "Po", "Lo",
                   "Se", "lag", "Trk", "mgmt", "ens", "eno", "bond", "br"]
        return kws.map { $0.lowercased() }.enumerated()
            .sorted { $0.element.count > $1.element.count || ($0.element.count == $1.element.count && $0.offset < $1.offset) }
            .map { $0.element }
    }()

    // Try-order = pattern alternation order with quantifiers expanded.
    static let stateGoodKeywords = ["up", "connected", "active", "established", "running",
                                    "enabled", "enable", "successful", "success", "forwarding",
                                    "permitted", "permits", "permit", "reachable", "authorized",
                                    "full", "allowed", "allow"]
    static let stateWarnKeywords = ["warning", "warn"]
    static let stateBadKeywords = ["down", "shutdown", "err-disabled", "errdisable", "notconnect",
                                   "failed", "failure", "fail", "deny", "denied", "unreachable",
                                   "invalid", "error", "err", "critical", "crit", "emergency",
                                   "alert", "blocked", "blocking", "discarding", "disabled",
                                   "disable", "suspended", "violation", "half"]

    /// Keywords pre-lowered to byte arrays, bucketed by first byte — at any
    /// position only the handful of keywords that can actually start there
    /// are tried, and compares run on raw bytes (String.UTF8View iteration
    /// per attempt was the scanner's main cost in the first prototype).
    static func bucketByFirst(_ keywords: [String]) -> [[[UInt8]]] {
        var table = [[[UInt8]]](repeating: [], count: 256)
        for kw in keywords {
            let bytes = Array(kw.utf8)
            table[Int(bytes[0])].append(bytes) // source order kept inside each bucket
        }
        return table
    }
    static let interfaceByFirst = bucketByFirst(interfaceKeywords)
    static let stateGoodByFirst = bucketByFirst(stateGoodKeywords)
    static let stateWarnByFirst = bucketByFirst(stateWarnKeywords)
    static let stateBadByFirst = bucketByFirst(stateBadKeywords)
    static let shutdownBytes = Array("shutdown".utf8)

    /// Bit mask for a set of rules — cached by the caller alongside its
    /// compiled rules, so the hot path never rebuilds it.
    static func mask(of rules: some Sequence<BuiltIn>) -> UInt16 {
        rules.reduce(into: UInt16(0)) { $0 |= bit(of: $1) }
    }

    /// One pass over ASCII bytes; per-rule matches, leftmost non-overlapping
    /// within each rule (per-rule cursor) — exactly enumerateMatches semantics.
    ///
    /// Returns the matches ordinal-indexed (index == `ordinal(of:)`), always
    /// 11 entries. Re-keying into a `[BuiltIn: [Range<Int>]]` used to cost
    /// more than the scan itself on the short text runs that escape-heavy
    /// output produces, and every caller indexes by ordinal anyway.
    static func scan(_ bytes: [UInt8], enabledMask: UInt16) -> [[Range<Int>]] {
        var perRule = [[Range<Int>]](repeating: [], count: 11)
        guard enabledMask != 0 else { return perRule }
        var cursor = [Int](repeating: 0, count: 11)
        let n = bytes.count
        var i = 0
        while i < n {
            var mask = startTable[Int(bytes[i])] & enabledMask
            // Bit index == rule ordinal (bits were assigned 1 << ordinal).
            while mask != 0 {
                let ord = mask.trailingZeroBitCount
                mask &= mask &- 1
                if i >= cursor[ord], let end = matchOrdinal(ord, bytes, i) {
                    perRule[ord].append(i..<end)
                    cursor[ord] = end
                }
            }
            i += 1
        }
        return perRule
    }

    static func ordinal(of rule: BuiltIn) -> Int {
        bit(of: rule).trailingZeroBitCount
    }

    static func matchOrdinal(_ ord: Int, _ b: [UInt8], _ s: Int) -> Int? {
        switch ord {
        case 0: return matchVLAN(b, s)
        case 1: return matchInterface(b, s)
        case 2: return matchCXPort(b, s)
        case 3: return matchMask(b, s)
        case 4: return matchCIDR(b, s)
        case 5: return matchIPv4(b, s)
        case 6: return matchMAC(b, s)
        case 7: return matchIPv6(b, s)
        case 8: return matchState(b, s, stateGoodByFirst, noShutdown: true)
        case 9: return matchState(b, s, stateWarnByFirst, noShutdown: false)
        case 10: return matchState(b, s, stateBadByFirst, noShutdown: false)
        default: return nil
        }
    }

    /// \b255(?:\.\d{1,3}){3}\b — groups 1-2 need a dot after 1-3 digits,
    /// group 3 needs a word boundary; an over-long digit run can never match.
    static func matchMask(_ b: [UInt8], _ s: Int) -> Int? {
        guard boundaryBefore(b, s), s + 3 <= b.count,
              b[s] == 0x32, b[s + 1] == 0x35, b[s + 2] == 0x35 else { return nil }
        var p = s + 3
        for group in 0..<3 {
            guard p < b.count, b[p] == 0x2E else { return nil }
            p += 1
            var d = 0
            while p < b.count, isDigit(b[p]), d < 4 { p += 1; d += 1 }
            guard d >= 1, d <= 3 else { return nil }
            if group == 2 {
                guard boundaryAfter(b, p) else { return nil }
            }
        }
        return p
    }

    /// (?<=\d)/\d{1,2}\b — match starts AT the slash.
    static func matchCIDR(_ b: [UInt8], _ s: Int) -> Int? {
        guard b[s] == 0x2F, s > 0, isDigit(b[s - 1]) else { return nil }
        var p = s + 1
        var d = 0
        while p < b.count, isDigit(b[p]), d < 3 { p += 1; d += 1 }
        guard d >= 1, d <= 2, boundaryAfter(b, p) else { return nil }
        return p
    }

    /// \b\d{1,2}/\d{1,2}/\d{1,2}(?::\d)?\b
    static func matchCXPort(_ b: [UInt8], _ s: Int) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        var p = s
        for group in 0..<3 {
            var d = 0
            while p < b.count, isDigit(b[p]), d < 3 { p += 1; d += 1 }
            guard d >= 1, d <= 2 else { return nil }
            if group < 2 {
                guard p < b.count, b[p] == 0x2F else { return nil }
                p += 1
            }
        }
        // optional :d — greedy first, then backtrack to without
        if p < b.count, b[p] == 0x3A, p + 1 < b.count, isDigit(b[p + 1]) {
            let e = p + 2
            if boundaryAfter(b, e) { return e }
        }
        guard boundaryAfter(b, p) else { return nil }
        return p
    }

    /// Octet per the pattern's alternation order: 25[0-5] | 2[0-4]d | 1dd | [1-9]?d
    static func matchOctet(_ b: [UInt8], _ p: Int) -> Int? {
        guard p < b.count, isDigit(b[p]) else { return nil }
        let has1 = p + 1 < b.count && isDigit(b[p + 1])
        let has2 = p + 2 < b.count && isDigit(b[p + 2])
        if b[p] == 0x32, has1, b[p + 1] == 0x35, has2, b[p + 2] <= 0x35 { return p + 3 }
        if b[p] == 0x32, has1, b[p + 1] <= 0x34, has2 { return p + 3 }
        if b[p] == 0x31, has1, has2 { return p + 3 }
        if b[p] != 0x30, has1 { return p + 2 }
        return p + 1
    }

    /// \b(?:octet\.){3}octet\b — backtracking never helps a digit run, so a
    /// straight 4-octet parse + end boundary is equivalent.
    static func matchIPv4(_ b: [UInt8], _ s: Int) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        var p = s
        for i in 0..<4 {
            guard let e = matchOctet(b, p) else { return nil }
            p = e
            if i < 3 {
                guard p < b.count, b[p] == 0x2E else { return nil }
                p += 1
            }
        }
        guard boundaryAfter(b, p) else { return nil }
        return p
    }

    /// \b(?:h{4}\.){2}h{4}\b | \b(?:h{2}[:\-]){5}h{2}\b — left alternative first.
    static func matchMAC(_ b: [UInt8], _ s: Int) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        func hexRun(_ p: Int, _ n: Int) -> Int? {
            var q = p
            for _ in 0..<n {
                guard q < b.count, isHex(b[q]) else { return nil }
                q += 1
            }
            return q
        }
        // cisco dotted xxxx.xxxx.xxxx
        if let e1 = hexRun(s, 4), e1 < b.count, b[e1] == 0x2E,
           let e2 = hexRun(e1 + 1, 4), e2 < b.count, b[e2] == 0x2E,
           let e3 = hexRun(e2 + 1, 4), boundaryAfter(b, e3) {
            return e3
        }
        // colon/dash xx-xx-xx-xx-xx-xx
        var p = s
        var ok = true
        for _ in 0..<5 {
            guard let e = hexRun(p, 2), e < b.count, b[e] == 0x3A || b[e] == 0x2D else { ok = false; break }
            p = e + 1
        }
        if ok, let e = hexRun(p, 2), boundaryAfter(b, e) { return e }
        return nil
    }

    /// \bvlan[ \t-]+\d{1,4}(?:[ \t]*[,\-][ \t]*\d{1,4})* — no trailing \b, so
    /// a 5th digit is simply left out; the repeat group backtracks cleanly.
    static func matchVLAN(_ b: [UInt8], _ s: Int) -> Int? {
        guard boundaryBefore(b, s), s + 4 <= b.count,
              lower(b[s]) == 0x76, lower(b[s + 1]) == 0x6C,
              lower(b[s + 2]) == 0x61, lower(b[s + 3]) == 0x6E else { return nil }
        var p = s + 4
        let sepStart = p
        while p < b.count, b[p] == 0x20 || b[p] == 0x09 || b[p] == 0x2D { p += 1 }
        guard p > sepStart else { return nil }
        var d = 0
        while p < b.count, isDigit(b[p]), d < 4 { p += 1; d += 1 }
        guard d >= 1 else { return nil }
        while true {
            var q = p
            while q < b.count, b[q] == 0x20 || b[q] == 0x09 { q += 1 }
            guard q < b.count, b[q] == 0x2C || b[q] == 0x2D else { break }
            q += 1
            while q < b.count, b[q] == 0x20 || b[q] == 0x09 { q += 1 }
            var dd = 0
            while q < b.count, isDigit(b[q]), dd < 4 { q += 1; dd += 1 }
            guard dd >= 1 else { break }
            p = q
        }
        return p
    }

    /// keyword\s?\d+(?:[\/.:_-]\d+)*\b — longest keyword first; the \b at the
    /// end picks the longest candidate prefix that lands on a boundary.
    static func matchInterface(_ b: [UInt8], _ s: Int) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        for kw in interfaceByFirst[Int(lower(b[s]))] {
            let klen = kw.count
            guard s + klen <= b.count else { continue }
            var hit = true
            for i in 1..<klen {
                if lower(b[s + i]) != kw[i] { hit = false; break }
            }
            guard hit else { continue }
            var p = s + klen
            if p < b.count, isSpace(b[p]) { p += 1 }
            let dStart = p
            while p < b.count, isDigit(b[p]) { p += 1 }
            guard p > dStart else { continue } // try a shorter keyword
            var candidates = [p]
            while p < b.count, b[p] == 0x2F || b[p] == 0x2E || b[p] == 0x3A || b[p] == 0x5F || b[p] == 0x2D {
                let sep = p
                p += 1
                let ds = p
                while p < b.count, isDigit(b[p]) { p += 1 }
                guard p > ds else { p = sep; break }
                candidates.append(p)
            }
            for end in candidates.reversed() where boundaryAfter(b, end) {
                return end
            }
        }
        return nil
    }

    /// (?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![0-9A-Fa-f:])
    static func matchIPv6(_ b: [UInt8], _ s: Int) -> Int? {
        if s > 0, isHex(b[s - 1]) || b[s - 1] == 0x3A { return nil } // lookbehind
        // Parse colon-terminated groups greedily: 0-4 hex then ':'.
        var groupEnds: [Int] = []
        var p = s
        while true {
            var q = p
            while q < b.count, isHex(b[q]) { q += 1 }
            guard q - p <= 4, q < b.count, b[q] == 0x3A else { break }
            groupEnds.append(q + 1)
            p = q + 1
        }
        // k groups (7 down to 2), then 0-4 hex, then the lookahead class.
        var k = min(groupEnds.count, 7)
        while k >= 2 {
            let afterGroups = groupEnds[k - 1]
            var hexEnd = afterGroups
            while hexEnd < b.count, isHex(b[hexEnd]) { hexEnd += 1 }
            var take = min(hexEnd - afterGroups, 4)
            while take >= 0 {
                let end = afterGroups + take
                if end == b.count || !(isHex(b[end]) || b[end] == 0x3A) { return end }
                take -= 1
            }
            k -= 1
        }
        return nil
    }

    /// Keyword sets with \b on both sides; "no[ \t]+shutdown" handled apart.
    static func matchState(_ b: [UInt8], _ s: Int, _ byFirst: [[[UInt8]]], noShutdown: Bool) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        if noShutdown {
            // no[ \t]+shutdown — first alternative in the pattern
            if s + 2 <= b.count, lower(b[s]) == 0x6E, lower(b[s + 1]) == 0x6F {
                var p = s + 2
                let spStart = p
                while p < b.count, b[p] == 0x20 || b[p] == 0x09 { p += 1 }
                if p > spStart, p + 8 <= b.count {
                    var hit = true
                    for i in 0..<8 {
                        if lower(b[p + i]) != shutdownBytes[i] { hit = false; break }
                    }
                    if hit, boundaryAfter(b, p + 8) { return p + 8 }
                }
            }
        }
        for kw in byFirst[Int(lower(b[s]))] {
            let klen = kw.count
            guard s + klen <= b.count else { continue }
            var hit = true
            for i in 1..<klen {
                if lower(b[s + i]) != kw[i] { hit = false; break }
            }
            if hit, boundaryAfter(b, s + klen) { return s + klen }
        }
        return nil
    }
}
