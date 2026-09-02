import Foundation

/// Single-pass byte scanner for the 11 built-in highlight rules.
///
/// Replaces 11 NSRegularExpression passes (ICU, backtracking) with one walk
/// over the bytes that can never backtrack: a 256-entry start table says
/// which rules may begin at each byte, and each matcher is a direct hand
/// translation of its default regex. Measured against the regex path on a
/// 4 MB dump: ~17x faster match phase, identical output byte-for-byte.
///
/// Used by `Highlighter.colorize` only when the text is pure ASCII and a
/// rule's pattern is untouched default — anything else stays on the regex
/// path, so semantics can never drift from what the user configured.
///
/// ## Vendors
///
/// The eleven rule NAMES are fixed. What varies between device families is
/// the DATA inside them — which interface spellings exist, which words are
/// states rather than policy, whether ports are written `10GE1/1/1` or
/// `ge-0/0/0` or `1/1/1` — and that data lives in `Profile`. Adding a device
/// family is one `Profile` literal plus one `Vendor` case: never a new rule
/// bit, a new ordinal, or a change to a matcher.
///
/// The keyword arrays a profile is built from are also what
/// `Highlighter.defaultConfigs(for:)` generates its regex alternations from,
/// in the same sorted order. That is deliberate: the two matching paths can
/// only agree if, for every pair where one keyword is a prefix of another,
/// the longer one is tried first. Generating both from one sorted array makes
/// that true by construction instead of by review.
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

    static func ordinal(of rule: BuiltIn) -> Int {
        bit(of: rule).trailingZeroBitCount
    }

    /// Bit mask for a set of rules — cached by the caller alongside its
    /// compiled rules, so the hot path never rebuilds it.
    static func mask(of rules: some Sequence<BuiltIn>) -> UInt16 {
        rules.reduce(into: UInt16(0)) { $0 |= bit(of: $1) }
    }

    // MARK: - Profile

    /// Everything that differs between device families, plus the lookup
    /// tables derived from it. One immutable instance per `Vendor`.
    /// A class, not a struct, and that is a performance decision: the
    /// matching path lifts an `ActiveRules` out of the Mutex once per text
    /// run — thousands of times per escape-heavy chunk — and a struct here
    /// would retain/release all seven tables on every one of those copies.
    /// Every stored property is a `let`, so sharing the reference is safe.
    final class Profile: Sendable {
        /// Interface name prefixes, longest-first (see the type comment for
        /// why the order is load-bearing). A prefix may end in `-` or `.`
        /// (`ge-`, `irb.`) — the shared tail then supplies the digits, which
        /// is how Junos and PAN-OS names are expressed without a new matcher.
        let interfaceKeywords: [String]
        /// Interface names that stand alone with no number after them —
        /// Check Point's `Mgmt`/`Sync`, FortiGate's `internal`/`dmz`, the
        /// plain `lo` in `ip addr`. They are the SECOND top-level alternative
        /// of the interface pattern, so the numbered form always wins first.
        let bareInterfaces: [String]
        let stateGoodKeywords: [String]
        let stateWarnKeywords: [String]
        let stateBadKeywords: [String]
        /// Words that mean "not" in front of `shutdown` — Cisco says `no`,
        /// Huawei and Comware say `undo`, a firewall says neither.
        let negations: [String]
        /// `\d{1,3}GE` — Huawei/Comware ports whose speed leads the name
        /// (`10GE1/1/1`, `100GE1/2/3`). No other family writes them this way.
        let digitSpeedPorts: Bool
        /// `vlan batch 2110 to 2113 2120` — the `batch` keyword and `to`
        /// ranges. Huawei and Comware only; elsewhere a vlan list is commas.
        let vlanRanges: Bool
        /// `00e0-fc12-3456` — three dash-separated 4-hex groups. Enabling it
        /// everywhere would colour any `1234-5678-9012`-shaped token, so it
        /// stays with the families that actually print MACs that way.
        let macDashGroups: Bool
        /// Which of the eleven rules this family uses at all. `cx-port` is
        /// the one that matters: it claims `0/0/0`, so leaving it on for
        /// Junos would tear `ge-0/0/0` in half.
        let rules: UInt16

        let startTable: [UInt16]
        let interfaceByFirst: [[[UInt8]]]
        let bareByFirst: [[[UInt8]]]
        let stateGoodByFirst: [[[UInt8]]]
        let stateWarnByFirst: [[[UInt8]]]
        let stateBadByFirst: [[[UInt8]]]
        let negationBytes: [[UInt8]]

        init(
            interface: [String],
            bare: [String] = [],
            stateGood: [String],
            stateBad: [String],
            stateWarn: [String] = ["warning", "warn"],
            negations: [String] = [],
            digitSpeedPorts: Bool = false,
            vlanRanges: Bool = false,
            macDashGroups: Bool = false,
            omitting: Set<BuiltIn> = []
        ) {
            let ifKws = Profile.sortLongestFirst(interface)
            let bareKws = Profile.sortLongestFirst(bare)
            let good = Profile.sortLongestFirst(stateGood)
            let warn = Profile.sortLongestFirst(stateWarn)
            let bad = Profile.sortLongestFirst(stateBad)
            interfaceKeywords = ifKws
            bareInterfaces = bareKws
            stateGoodKeywords = good
            stateWarnKeywords = warn
            stateBadKeywords = bad
            self.negations = negations
            self.digitSpeedPorts = digitSpeedPorts
            self.vlanRanges = vlanRanges
            self.macDashGroups = macDashGroups
            rules = BuiltIn.allCases.reduce(into: UInt16(0)) {
                if !omitting.contains($1) { $0 |= HighlightScanner.bit(of: $1) }
            }
            interfaceByFirst = Profile.bucketByFirst(ifKws)
            bareByFirst = Profile.bucketByFirst(bareKws)
            stateGoodByFirst = Profile.bucketByFirst(good)
            stateWarnByFirst = Profile.bucketByFirst(warn)
            stateBadByFirst = Profile.bucketByFirst(bad)
            negationBytes = negations.map { Array($0.lowercased().utf8) }
            startTable = Profile.makeStartTable(
                interface: ifKws + bareKws, good: good, warn: warn, bad: bad,
                negations: negations, digitSpeedPorts: digitSpeedPorts,
                rules: rules
            )
        }

        /// Longest first, ties in the order written. A proper prefix is
        /// always strictly shorter, so this alone guarantees the invariant
        /// the two matching paths depend on.
        static func sortLongestFirst(_ keywords: [String]) -> [String] {
            var seen = Set<String>()
            let unique = keywords.map { $0.lowercased() }.filter { seen.insert($0).inserted }
            return unique.enumerated()
                .sorted {
                    $0.element.count > $1.element.count
                        || ($0.element.count == $1.element.count && $0.offset < $1.offset)
                }
                .map(\.element)
        }

        /// Keywords pre-lowered to byte arrays, bucketed by first byte — at
        /// any position only the handful that can actually start there are
        /// tried, and compares run on raw bytes (iterating String.UTF8View
        /// per attempt was the scanner's main cost in the first prototype).
        static func bucketByFirst(_ keywords: [String]) -> [[[UInt8]]] {
            var table = [[[UInt8]]](repeating: [], count: 256)
            for kw in keywords {
                let bytes = Array(kw.utf8)
                table[Int(bytes[0])].append(bytes) // sorted order kept inside each bucket
            }
            return table
        }

        /// byte -> bitmask of rules that may START at that byte.
        static func makeStartTable(
            interface: [String], good: [String], warn: [String], bad: [String],
            negations: [String], digitSpeedPorts: Bool, rules: UInt16
        ) -> [UInt16] {
            var table = [UInt16](repeating: 0, count: 256)
            let maskBit = bit(of: .mask), cxBit = bit(of: .cxPort), v4Bit = bit(of: .ipv4)
            let macBit = bit(of: .mac), v6Bit = bit(of: .ipv6), cidrBit = bit(of: .cidr)
            let ifBit = bit(of: .interface)
            for d: UInt8 in 0x30...0x39 {
                table[Int(d)] = cxBit | v4Bit | macBit | v6Bit
                // Huawei's digit-led \d{1,3}GE ports are the only rule that
                // can begin on a digit but is not a number.
                if digitSpeedPorts { table[Int(d)] |= ifBit }
            }
            table[Int(0x32)] |= maskBit // '2' may start 255.x.x.x
            table[Int(0x2F)] = cidrBit  // '/'
            table[Int(0x3A)] = v6Bit    // ':' (::1)
            for h: UInt8 in 0x61...0x66 {
                table[Int(h)] |= macBit | v6Bit
                table[Int(h - 0x20)] |= macBit | v6Bit
            }
            var letterRules = [UInt8: UInt16]()
            func addKeyword(_ kw: String, _ ruleBit: UInt16) {
                guard let first = kw.utf8.first else { return }
                letterRules[lower(first), default: 0] |= ruleBit
            }
            addKeyword("vlan", bit(of: .vlan))
            for kw in interface { addKeyword(kw, ifBit) }
            for kw in good { addKeyword(kw, bit(of: .stateGood)) }
            // The negation branch of state-good is spelled out rather than
            // left to whatever else happens to claim 'n'/'u': the branch must
            // not silently stop matching if a keyword list is refactored.
            for kw in negations { addKeyword(kw, bit(of: .stateGood)) }
            for kw in warn { addKeyword(kw, bit(of: .stateWarn)) }
            for kw in bad { addKeyword(kw, bit(of: .stateBad)) }
            for (letter, ruleBits) in letterRules {
                table[Int(letter)] |= ruleBits
                if letter >= 0x61, letter <= 0x7A { table[Int(letter - 0x20)] |= ruleBits }
            }
            // A rule the family does not use must never start anywhere.
            for i in 0..<256 { table[i] &= rules }
            return table
        }
    }

    // MARK: - Scan

    /// One pass over ASCII bytes; per-rule matches, leftmost non-overlapping
    /// within each rule (per-rule cursor) — exactly enumerateMatches semantics.
    ///
    /// Returns the matches ordinal-indexed (index == `ordinal(of:)`), always
    /// 11 entries. Re-keying into a `[BuiltIn: [Range<Int>]]` used to cost
    /// more than the scan itself on the short text runs that escape-heavy
    /// output produces, and every caller indexes by ordinal anyway.
    static func scan(_ bytes: [UInt8], enabledMask: UInt16, profile: Profile) -> [[Range<Int>]] {
        var perRule = [[Range<Int>]](repeating: [], count: 11)
        let active = enabledMask & profile.rules
        guard active != 0 else { return perRule }
        var cursor = [Int](repeating: 0, count: 11)
        let n = bytes.count
        var i = 0
        while i < n {
            var mask = profile.startTable[Int(bytes[i])] & active
            // Bit index == rule ordinal (bits were assigned 1 << ordinal).
            while mask != 0 {
                let ord = mask.trailingZeroBitCount
                mask &= mask &- 1
                if i >= cursor[ord], let end = matchOrdinal(ord, bytes, i, profile) {
                    perRule[ord].append(i..<end)
                    cursor[ord] = end
                }
            }
            i += 1
        }
        return perRule
    }

    static func matchOrdinal(_ ord: Int, _ b: [UInt8], _ s: Int, _ p: Profile) -> Int? {
        switch ord {
        case 0: return matchVLAN(b, s, p)
        case 1: return matchInterface(b, s, p)
        case 2: return matchCXPort(b, s)
        case 3: return matchMask(b, s)
        case 4: return matchCIDR(b, s)
        case 5: return matchIPv4(b, s)
        case 6: return matchMAC(b, s, p)
        case 7: return matchIPv6(b, s)
        case 8: return matchState(b, s, p.stateGoodByFirst, negations: p.negationBytes)
        case 9: return matchState(b, s, p.stateWarnByFirst, negations: [])
        case 10: return matchState(b, s, p.stateBadByFirst, negations: [])
        default: return nil
        }
    }

    // MARK: - Matchers

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

    /// (?<=[.:]\d{1,3})/\d{1,2}\b — match starts AT the slash.
    ///
    /// The lookbehind used to be a bare `(?<=\d)`, which made every port
    /// number a CIDR prefix: `Gi1/0/1` came out with `/0` and `/1` in the
    /// mask colour whenever no interface rule claimed the token first. A
    /// prefix length follows an ADDRESS, so require the digits before the
    /// slash to be preceded by a `.` or `:` — true of `10.0.0.1/24` and
    /// `fe80::1/64`, false of `Gi1/0/1`, `Fa0/1`, `100GE1/2/3` and `1/1/1`.
    static func matchCIDR(_ b: [UInt8], _ s: Int) -> Int? {
        guard b[s] == 0x2F, s > 0, isDigit(b[s - 1]) else { return nil }
        // [.:]\d{1,3} ending at s — existential in the digit count, so the
        // order the regex tries them in cannot matter.
        var anchored = false
        for k in 1...3 {
            let sep = s - k - 1
            guard sep >= 0, s - k >= 0 else { break }
            guard (s - k ..< s).allSatisfy({ isDigit(b[$0]) }) else { break }
            if b[sep] == 0x2E || b[sep] == 0x3A { anchored = true; break }
        }
        guard anchored else { return nil }
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

    /// \b(?:h{4}[.\-]){2}h{4}\b | \b(?:h{2}[:\-]){5}h{2}\b — left alternative
    /// first. The dash form of the left one is Huawei's 00e0-fc12-3456 and is
    /// only in the pattern for families that print MACs that way.
    static func matchMAC(_ b: [UInt8], _ s: Int, _ profile: Profile) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        func hexRun(_ p: Int, _ n: Int) -> Int? {
            var q = p
            for _ in 0..<n {
                guard q < b.count, isHex(b[q]) else { return nil }
                q += 1
            }
            return q
        }
        // cisco dotted xxxx.xxxx.xxxx / huawei dashed xxxx-xxxx-xxxx
        // (the class is per separator, so a mixed pair matches too — exactly
        // what the regex does)
        let dash = profile.macDashGroups
        @inline(__always) func isGroupSep(_ p: Int) -> Bool {
            b[p] == 0x2E || (dash && b[p] == 0x2D)
        }
        if let e1 = hexRun(s, 4), e1 < b.count, isGroupSep(e1),
           let e2 = hexRun(e1 + 1, 4), e2 < b.count, isGroupSep(e2),
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

    /// \bvlan(?:[ \t]+batch)?[ \t-]+\d{1,4}(?:[ \t]*[,\-][ \t]*\d{1,4}|[ \t]+(?:to[ \t]+)?\d{1,4})*
    /// — no trailing \b, so a 5th digit is simply left out; the repeat group
    /// backtracks cleanly. The `batch` keyword and the second alternative
    /// exist only when `profile.vlanRanges` is set (Huawei "vlan batch 2110
    /// to 2113 2120"); the two alternatives are disjoint at the decision byte
    /// (one needs a `,` or `-`, the other a blank then a digit or "to"), so
    /// trying them in pattern order is what the regex does.
    static func matchVLAN(_ b: [UInt8], _ s: Int, _ profile: Profile) -> Int? {
        guard boundaryBefore(b, s), s + 4 <= b.count,
              lower(b[s]) == 0x76, lower(b[s + 1]) == 0x6C,
              lower(b[s + 2]) == 0x61, lower(b[s + 3]) == 0x6E else { return nil }
        @inline(__always) func isBlank(_ p: Int) -> Bool { b[p] == 0x20 || b[p] == 0x09 }
        var p = s + 4
        if profile.vlanRanges {
            // (?:[ \t]+batch)? — greedy, and dropping it can never rescue a
            // failed match (the separator run below then lands on the `b`,
            // which is never a digit).
            var q = p
            while q < b.count, isBlank(q) { q += 1 }
            if q > p, q + 5 <= b.count, lower(b[q]) == 0x62, lower(b[q + 1]) == 0x61,
               lower(b[q + 2]) == 0x74, lower(b[q + 3]) == 0x63, lower(b[q + 4]) == 0x68 {
                p = q + 5
            }
        }
        let sepStart = p
        while p < b.count, isBlank(p) || b[p] == 0x2D { p += 1 }
        guard p > sepStart else { return nil }
        var d = 0
        while p < b.count, isDigit(b[p]), d < 4 { p += 1; d += 1 }
        guard d >= 1 else { return nil }
        while true {
            // [ \t]*[,\-][ \t]*\d{1,4}
            var q = p
            while q < b.count, isBlank(q) { q += 1 }
            if q < b.count, b[q] == 0x2C || b[q] == 0x2D {
                var r = q + 1
                while r < b.count, isBlank(r) { r += 1 }
                var dd = 0
                while r < b.count, isDigit(b[r]), dd < 4 { r += 1; dd += 1 }
                if dd >= 1 { p = r; continue }
            }
            guard profile.vlanRanges else { break }
            // [ \t]+(?:to[ \t]+)?\d{1,4}
            var r = p
            while r < b.count, isBlank(r) { r += 1 }
            guard r > p else { break }
            if r + 2 <= b.count, lower(b[r]) == 0x74, lower(b[r + 1]) == 0x6F {
                var t = r + 2
                let tSpace = t
                while t < b.count, isBlank(t) { t += 1 }
                if t > tSpace {
                    var dd = 0
                    var u = t
                    while u < b.count, isDigit(b[u]), dd < 4 { u += 1; dd += 1 }
                    if dd >= 1 { p = u; continue }
                }
            }
            var dd = 0
            var u = r
            while u < b.count, isDigit(b[u]), dd < 4 { u += 1; dd += 1 }
            guard dd >= 1 else { break }
            p = u
        }
        return p
    }

    /// \s?\d+(?:[\/.:_-]\d+)*\b — the part every interface spelling shares,
    /// starting right after the name prefix. nil = this prefix cannot match,
    /// so the caller falls back to a shorter keyword (or fewer speed digits).
    @inline(__always)
    static func matchInterfaceTail(_ b: [UInt8], _ start: Int) -> Int? {
        var p = start
        if p < b.count, isSpace(b[p]) { p += 1 }
        let dStart = p
        while p < b.count, isDigit(b[p]) { p += 1 }
        guard p > dStart else { return nil }
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
        return nil
    }

    /// (?:\d{1,3}GE|keyword)\s?\d+(?:[\/.:_-]\d+)*\b — longest keyword first;
    /// the \b at the end picks the longest candidate prefix that lands on a
    /// boundary. The digit-led alternative is Huawei's 10GE1/1/1 form: it is
    /// first in the pattern and can never share a start byte with a keyword,
    /// so trying it before the buckets matches the regex exactly.
    static func matchInterface(_ b: [UInt8], _ s: Int, _ profile: Profile) -> Int? {
        if profile.digitSpeedPorts, isDigit(b[s]) {
            guard boundaryBefore(b, s) else { return nil }
            // \d{1,3} is greedy, then backtracks: 3 digits, 2, then 1.
            var digits = 0
            while digits < 3, s + digits < b.count, isDigit(b[s + digits]) { digits += 1 }
            while digits >= 1 {
                let g = s + digits
                if g + 1 < b.count, lower(b[g]) == 0x67, lower(b[g + 1]) == 0x65,
                   let end = matchInterfaceTail(b, g + 2) {
                    return end
                }
                digits -= 1
            }
            return nil
        }
        // A keyword may open with `-`/`.`-adjacent text (ge-, irb.) but its
        // FIRST byte is always a word char, so \b still applies here.
        guard boundaryBefore(b, s) else { return nil }
        for kw in profile.interfaceByFirst[Int(lower(b[s]))] {
            let klen = kw.count
            guard s + klen <= b.count else { continue }
            var hit = true
            for i in 1..<klen where lower(b[s + i]) != kw[i] { hit = false; break }
            guard hit else { continue }
            guard let end = matchInterfaceTail(b, s + klen) else { continue }
            return end
        }
        // Second top-level alternative: \b(?:bare)\b. Reached only after
        // every numbered spelling has failed at this position, which is what
        // the regex does with its alternation.
        for kw in profile.bareByFirst[Int(lower(b[s]))] {
            let klen = kw.count
            guard s + klen <= b.count else { continue }
            var hit = true
            for i in 1..<klen where lower(b[s + i]) != kw[i] { hit = false; break }
            if hit, boundaryAfter(b, s + klen) { return s + klen }
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

    static let shutdownBytes = Array("shutdown".utf8)

    /// Keyword sets with \b on both sides; "(?:no|undo)[ \t]+shutdown" is the
    /// leading alternative of state-good and is handled apart.
    static func matchState(
        _ b: [UInt8], _ s: Int, _ byFirst: [[[UInt8]]], negations: [[UInt8]]
    ) -> Int? {
        guard boundaryBefore(b, s) else { return nil }
        for word in negations {
            guard s + word.count <= b.count else { continue }
            var hit = true
            for i in 0..<word.count where lower(b[s + i]) != word[i] { hit = false; break }
            guard hit else { continue }
            var p = s + word.count
            let spStart = p
            while p < b.count, b[p] == 0x20 || b[p] == 0x09 { p += 1 }
            if p > spStart, p + 8 <= b.count {
                var ok = true
                for i in 0..<8 where lower(b[p + i]) != shutdownBytes[i] { ok = false; break }
                if ok, boundaryAfter(b, p + 8) { return p + 8 }
            }
        }
        for kw in byFirst[Int(lower(b[s]))] {
            let klen = kw.count
            guard s + klen <= b.count else { continue }
            var hit = true
            for i in 1..<klen where lower(b[s + i]) != kw[i] { hit = false; break }
            if hit, boundaryAfter(b, s + klen) { return s + klen }
        }
        return nil
    }
}

// MARK: - Vendor catalogue
//
// Data only. A new device family is one `Vocab` entry plus one line in
// `profiles` — no matcher, rule bit, or start-table change.

nonisolated extension HighlightScanner {
    /// Word lists shared between families, so a family only spells out what
    /// is actually its own.
    enum Vocab {
        /// States that mean the same thing on every box.
        static let goodCore = ["up", "connected", "active", "established", "running",
                               "enabled", "enable", "successful", "success", "forwarding",
                               "reachable", "authorized", "full"]
        static let badCore = ["down", "shutdown", "fail", "failed", "failure", "unreachable",
                              "invalid", "error", "err", "critical", "crit", "emergency",
                              "alert", "suspended", "half", "disabled", "disable"]
        /// Filter/ACL verdicts. On a switch these ARE the health signal; on a
        /// firewall they are the configured policy and colouring them red or
        /// green says nothing, so the firewall packs leave them out.
        static let policyGood = ["permit", "permitted", "permits", "allow", "allowed"]
        static let policyBad = ["deny", "denied", "blocked", "blocking", "discarding"]
        /// Port-level faults only switches report.
        static let switchBad = ["err-disabled", "errdisable", "notconnect", "violation"]
        /// Huawei/Comware board, AP and optical-module states.
        static let vrpGood = ["normal", "online"]
        static let vrpBad = ["abnormal", "offline", "fault", "faulty"]

        static let cisco = ["GigabitEthernet", "TenGigabitEthernet", "TwoGigabitEthernet",
                            "TwentyFiveGigE", "FortyGigabitEthernet", "HundredGigE",
                            "AppGigabitEthernet", "FastEthernet", "Port-channel",
                            "Bundle-Ether", "Ethernet", "Vethernet", "Loopback", "Tunnel",
                            "Management", "Serial", "Nve", "Vlan", "Gi", "Twe", "Tw", "Te",
                            "Fo", "Hu", "Fa", "Eth", "Po", "Lo", "Se", "mgmt"]
        static let arubaCX = ["Vlan", "Loopback", "Tunnel", "lag", "mgmt"]
        static let arubaOS = ["GigabitEthernet", "FastEthernet", "Port-channel", "Loopback",
                              "Tunnel", "Vlan", "Trk", "Gi", "Fa", "Po", "Lo", "mgmt"]
        static let huawei = ["GigabitEthernet", "XGigabitEthernet", "M-GigabitEthernet",
                             "Virtual-Template", "Eth-Trunk", "Stack-Port", "LoopBack",
                             "Vlanif", "Ethernet", "Tunnel", "Serial", "MEth", "NULL",
                             "Vlan", "Aux", "Pos", "GE", "XGE", "FGE", "HGE"]
        static let comware = ["Ten-GigabitEthernet", "Twenty-FiveGigE", "Hundred-GigE",
                              "Forty-GigE", "M-GigabitEthernet", "XGigabitEthernet",
                              "Bridge-Aggregation", "Route-Aggregation", "Vlan-interface",
                              "InLoopBack", "M-Ethernet", "Ethernet", "Loopback", "Tunnel",
                              "NULL", "BAGG", "RAGG", "Vlan", "XGE", "FGE", "HGE", "WGE", "GE"]
        /// Junos names carry their separator in the prefix (`ge-`, `irb.`),
        /// which the shared tail then completes — no new matcher needed.
        static let juniper = ["ge-", "xe-", "et-", "xle-", "fte-", "vcp-", "gr-", "ip-",
                              "vt-", "sp-", "vme.", "irb.", "vlan.", "demux", "reth",
                              "fxp", "vme", "irb", "ae", "em", "me", "lo", "st"]
        static let panos = ["loopback.", "ethernet", "tunnel.", "vlan.", "ae"]
        /// `port` is exactly why a session needs to know its vendor: it is
        /// mandatory here (`port1`, `edit "port1"`) and poison everywhere
        /// else, where `port 443` is a service number.
        static let fortios = ["redundant", "aggregate", "internal", "modem", "ssl.",
                              "port", "wan", "lan", "dmz", "agg", "npu", "mgmt", "vlan",
                              "ha", "ppp"]
        static let gaia = ["bond", "eth", "wrp", "lo", "bp"]
        static let linux = ["docker", "virbr", "dummy", "vmbr", "wlan", "veth", "bond",
                            "wlp", "enp", "ens", "eno", "esp", "eth", "tun", "tap",
                            "sit", "br", "lo"]
    }

    /// The pack a `Vendor` resolves to. Built once, then shared — every
    /// derived table inside is immutable.
    static let profiles: [String: Profile] = [
        // `auto` is the vendor-NEUTRAL core, not a union: addresses, masks,
        // CIDR, MACs, VLAN ids, and the state words that mean the same thing
        // on every box. `interface` and `cx-port` are left out on purpose —
        // an interface name is the most vendor-specific token there is, and
        // guessing it is what tore `ge-0/0/0` in half and what would put a
        // FortiGate's `port1` and a service `port 443` in the same colour.
        // Pick a vendor to get port names; the neutral core never misleads.
        "auto": Profile(
            interface: [],
            stateGood: Vocab.goodCore,
            stateBad: Vocab.badCore,
            omitting: [.interface, .cxPort]
        ),
        "cisco": Profile(
            interface: Vocab.cisco,
            stateGood: Vocab.goodCore + Vocab.policyGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad,
            negations: ["no"],
            omitting: [.cxPort]
        ),
        "arubaCX": Profile(
            interface: Vocab.arubaCX,
            stateGood: Vocab.goodCore + Vocab.policyGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad,
            negations: ["no"]
        ),
        "arubaOS": Profile(
            interface: Vocab.arubaOS,
            stateGood: Vocab.goodCore + Vocab.policyGood + ["registered"],
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad
                + ["rebooting", "unprovisioned"],
            negations: ["no"]
        ),
        "huawei": Profile(
            interface: Vocab.huawei,
            stateGood: Vocab.goodCore + Vocab.policyGood + Vocab.vrpGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad + Vocab.vrpBad,
            negations: ["no", "undo"],
            digitSpeedPorts: true, vlanRanges: true, macDashGroups: true,
            omitting: [.cxPort]
        ),
        "comware": Profile(
            interface: Vocab.comware,
            stateGood: Vocab.goodCore + Vocab.policyGood + Vocab.vrpGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad + Vocab.vrpBad,
            negations: ["undo", "no"],
            digitSpeedPorts: true, vlanRanges: true, macDashGroups: true,
            omitting: [.cxPort]
        ),
        // cx-port off is the whole point here: `\d{1,2}/\d{1,2}/\d{1,2}` was
        // claiming the `0/0/0` out of `ge-0/0/0` and leaving `ge-` grey.
        "juniper": Profile(
            interface: Vocab.juniper,
            stateGood: Vocab.goodCore,
            stateBad: Vocab.badCore + ["inactive", "flapping"],
            omitting: [.cxPort]
        ),
        "panos": Profile(
            interface: Vocab.panos, bare: ["mgt"],
            stateGood: ["up", "active", "enabled", "established", "connected", "running", "valid"],
            stateBad: ["down", "disabled", "error", "fail", "failed", "failure", "critical",
                       "unreachable", "invalid", "dead", "expired"],
            omitting: [.cxPort]
        ),
        // No enable/disable: FortiOS ends nearly every config line in one of
        // them, so colouring them turns a config dump into a wall of green.
        "fortios": Profile(
            interface: Vocab.fortios, bare: ["internal", "modem", "dmz", "mgmt"],
            stateGood: ["up", "connected", "established", "active", "alive", "ok", "reachable"],
            stateBad: ["down", "dead", "fail", "failed", "failure", "error", "critical",
                       "unreachable", "invalid", "expired"],
            omitting: [.cxPort]
        ),
        "gaia": Profile(
            interface: Vocab.gaia, bare: ["Mgmt", "Sync", "lo"],
            stateGood: ["up", "active", "ready", "connected", "established", "running",
                        "enabled", "enable", "ok"],
            stateBad: Vocab.badCore + ["problem"],
            omitting: [.cxPort]
        ),
        catalogueKey: Profile(
            interface: Vocab.cisco + Vocab.arubaCX + Vocab.arubaOS + Vocab.huawei
                + Vocab.comware + Vocab.juniper + Vocab.panos + Vocab.fortios
                + Vocab.gaia + Vocab.linux,
            bare: ["internal", "modem", "Mgmt", "Sync", "dmz", "mgt", "lo"],
            stateGood: Vocab.goodCore + Vocab.policyGood + Vocab.vrpGood,
            stateBad: Vocab.badCore + Vocab.policyBad + Vocab.switchBad + Vocab.vrpBad,
            negations: ["no", "undo"],
            digitSpeedPorts: true, vlanRanges: true, macDashGroups: true
        ),
        "linux": Profile(
            interface: Vocab.linux, bare: ["lo"],
            stateGood: Vocab.goodCore + ["listening", "loaded", "ok"],
            stateBad: Vocab.badCore + ["dead", "inactive", "masked", "refused", "denied"],
            omitting: [.cxPort]
        ),
    ]

    /// Key of the catalogue profile — every rule, the union vocabulary. It
    /// is NOT a vendor and is never used to match anything: it exists so the
    /// settings list and highlight-rules.json can carry all eleven rule names
    /// whatever pack a session happens to be on.
    static let catalogueKey = "\u{0}catalogue"

    /// Never nil in practice — `Vendor` and `profiles` are kept in step by
    /// `Highlighter.vendorCoverageIsComplete()`, which the test suite asserts.
    static func profile(_ key: String) -> Profile {
        profiles[key] ?? profiles["auto"]!
    }
}

/// Passive device-family fingerprint driven off the terminal stream.
///
/// Some sessions announce their family loudly — an SSH login banner or a
/// `display version` header carries a string only one vendor prints. When a
/// tab is still on `.auto` and the user has made no explicit choice, this
/// watches the output for such a string and, on the first strong hit, names
/// the vendor ONCE. It never runs on serial-vs-SSH assumptions: both feed the
/// same bytes, and the same table serves both.
///
/// It is deliberately conservative — a wrong lock is worse than none, since
/// the user still has the manual pick. So the signatures are long, specific
/// substrings (`"cisco ios software"`, not bare `"cisco"`), tried in a fixed
/// priority order, and once one matches the fingerprint is spent. If nothing
/// matches inside a bounded byte budget it gives up for good, so a session
/// that never shows a banner costs nothing after that.
struct VendorFingerprint {
    /// Locked once a signature has matched (holds the vendor) OR the byte
    /// budget ran out with no match. Either way `consider` becomes a no-op.
    private(set) var locked = false
    /// Total bytes examined so far. Past `budget`, give up: a banner shows up
    /// in the first handful of kilobytes or not at all, and an endless scan
    /// of a `cat bigfile` must not cost anything.
    private var scanned = 0
    private static let budget = 64 * 1024
    /// The tail of the previous chunk, kept so a signature split across a
    /// chunk boundary is still found. 64 bytes comfortably spans the longest
    /// signature.
    private var carry: [UInt8] = []
    private static let carryLen = 64

    /// Vendor signatures in PRIORITY order — the more specific families come
    /// before the generic ones so, e.g., a Linux jump host that merely prints
    /// a vendor's name somewhere cannot outrank that vendor's own banner.
    /// All lowercased ASCII; matching lowercases the stream to compare.
    static let signatures: [(Vendor, [[UInt8]])] = {
        func s(_ strings: [String]) -> [[UInt8]] { strings.map { Array($0.utf8) } }
        return [
            // `aos-cx` covers every command that matters: the `show version`
            // / `show system` banner AND the `!Version AOS-CX ...` header that
            // opens `show running-config`, which is what most sessions run.
            (.arubaCX, s(["arubaos-cx", "aos-cx"])),
            (.cisco, s(["cisco ios software", "ios-xe", "nx-os", "cisco nexus",
                        "cisco adaptive security"])),
            (.comware, s(["comware software", "h3c comware", "hpe comware"])),
            (.huawei, s(["huawei versatile routing platform", "vrp (r)",
                         "huawei technologies"])),
            // `aruba operating system`/`arubaos (` catch `show version`;
            // `[mynode]` is the Mobility Master node-path shown in EVERY
            // prompt, so a controller session that never runs show version
            // still locks — and it is durable, unlike a hostname. NOT a
            // hostname such as `arubavmc` (a renamed box would not match), and
            // NOT `*#`/`) *#` (2–3 generic chars that appear all over text).
            (.arubaOS, s(["aruba operating system", "arubaos (", "[mynode]"])),
            (.juniper, s(["junos ", "juniper networks"])),
            (.panos, s(["pan-os", "palo alto networks"])),
            // `fortigate`/`fortios ` catch `get system status`; the two
            // `config ...` blocks catch `show` / `show full-configuration` —
            // the command most sessions run. FortiOS has no version header in
            // `show`, so unlike AOS-CX its config SYNTAX is the signal:
            // `config system global` opens every config, `config firewall
            // policy` is on every box, and no other family uses this
            // `config …/edit …/set …` grammar.
            // `config system global`/`config firewall policy` catch `show`;
            // `execute ping`/`execute traceroute` catch the diagnostic the
            // user runs from the box. NOT bare `execute `/`diagnose `: those
            // CLI verbs turn up in other vendors' help text and aliases (an
            // Aruba CX capture prints `Execute "show alias" ...`) and
            // mislocked — the full command form is FortiOS-specific (everyone
            // else says just `ping`/`traceroute`) and clean across the corpus.
            (.fortios, s(["fortigate", "fortios ", "config system global",
                          "config firewall policy", "execute ping",
                          "execute traceroute"])),
            // `check point gaia`/`gaia r8` catch `show version all` and the
            // banner. But Gaia `show configuration` (clish) prints neither —
            // its config syntax is the signal: `set installer policy` opens
            // it and `set clienv` (clish environment) is Gaia-only. Both are
            // unique across the captured corpus; no other family uses them.
            // `check point gaia`/`gaia r8` = `show version all` + banner;
            // `set installer policy`/`set clienv` = `show configuration`
            // (clish); `enter expert password` = the prompt when dropping to
            // expert mode. NOT bare `expert` — that word alone shows up in
            // three unrelated captures; the full phrase is Gaia-only.
            (.gaia, s(["check point gaia", "gaia r8", "set installer policy",
                       "set clienv", "enter expert password"])),
            (.linux, s(["gnu/linux", "ubuntu ", "debian gnu", "centos",
                        "red hat enterprise", "linux version"])),
        ]
    }()

    /// Feed the next chunk. Returns the detected vendor exactly once, on the
    /// first chunk that completes a signature; nil otherwise (including once
    /// locked or over budget). Cost after a lock is a single branch.
    mutating func consider(_ bytes: [UInt8]) -> Vendor? {
        guard !locked, scanned < Self.budget, !bytes.isEmpty else { return nil }
        scanned += bytes.count

        // Search over (carry + lowercased(chunk)) so a signature that
        // straddled the previous boundary is seen whole. Non-ASCII bytes are
        // left as-is: they simply never match an ASCII signature.
        var hay = carry
        hay.reserveCapacity(carry.count + bytes.count)
        for b in bytes {
            hay.append((b >= 0x41 && b <= 0x5A) ? b + 0x20 : b)
        }
        // Keep the last bytes as the next carry regardless of outcome.
        if hay.count > Self.carryLen {
            carry = Array(hay[(hay.count - Self.carryLen)...])
        } else {
            carry = hay
        }

        for (vendor, patterns) in Self.signatures {
            for pattern in patterns where Self.contains(hay, pattern) {
                locked = true
                return vendor
            }
        }
        if scanned >= Self.budget { locked = true }   // spent; stop for good
        return nil
    }

    /// Straight substring search — the signatures are short and matches are
    /// rare, so a plain scan beats building any index.
    private static func contains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        let first = needle[0]
        let last = hay.count - needle.count
        var i = 0
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }
}
