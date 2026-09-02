import Combine
import Foundation

enum ConnectionKind: String, Codable {
    case ssh
    case serial
    case local

    var badge: String {
        switch self {
        case .ssh: return "SSH"
        case .serial: return "SER"
        case .local: return "ZSH"
        }
    }
}

/// Which device family a session talks to. Selects the highlight rule pack:
/// the eleven rule NAMES are the same everywhere, but their keyword lists and
/// a few shape flags come from `HighlightScanner.Profile` for this vendor.
///
/// `auto` is the vendor-NEUTRAL CORE, not a union: addresses, masks, CIDR,
/// MACs, VLAN ids, and the state words that mean the same thing on every box.
/// It deliberately carries NO `interface` and NO `cx-port` rule, because an
/// interface name is the most vendor-specific token there is and guessing it
/// is what tore `ge-0/0/0` in half and would put FortiGate's `port1` and a
/// service `port 443` in the same colour.
///
/// So a host that has never been given a family colours LESS than it did
/// before packs existed — port names stay plain until a family is picked.
/// That is the intended trade: never mislead, rather than always colour.
/// Picking a family adds its port names and re-reads the words whose MEANING
/// is vendor specific — `deny` is a fault on a switch and an intended policy
/// action on a firewall, and FortiOS ends nearly every config line in
/// enable/disable.
///
/// Adding a device family is meant to be one `Profile` literal and one case
/// here — never a change to a matcher, a rule bit, or the start table.
nonisolated enum Vendor: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case cisco
    case arubaCX
    case arubaOS
    case huawei
    case comware
    case juniper
    case panos
    case fortios
    case gaia
    case linux

    var id: String { rawValue }

    /// Tolerant of raw values this build does not know. The synthesized
    /// decoder THROWS on an unrecognised string, and `Vendor?` does not save
    /// you — optionality covers a missing key, not a bad value — so one
    /// stale or hand-edited entry would fail the whole `[HostGroup]` decode
    /// and send hosts.json to the corrupt-file quarantine. Unknown reads as
    /// `.auto`, which is exactly what "we don't know this device" means.
    init(from decoder: Decoder) throws {
        let raw = try? decoder.singleValueContainer().decode(String.self)
        self = raw.flatMap(Vendor.init(rawValue:)) ?? .auto
    }

    var label: String {
        switch self {
        case .auto: return "Auto (all vendors)"
        case .cisco: return "Cisco IOS / IOS-XE / NX-OS"
        case .arubaCX: return "Aruba CX"
        case .arubaOS: return "ArubaOS (Controller / MM)"
        case .huawei: return "Huawei VRP"
        case .comware: return "H3C / HPE Comware"
        case .juniper: return "Juniper Junos"
        case .panos: return "Palo Alto PAN-OS"
        case .fortios: return "Fortinet FortiOS"
        case .gaia: return "Check Point Gaia"
        case .linux: return "Linux / server"
        }
    }

    /// Dense index into `Highlighter`'s per-vendor rule table. Written out
    /// rather than derived from `allCases` because the matching path reads it
    /// once per text run — thousands of times per escape-heavy chunk.
    var slot: Int {
        switch self {
        case .auto: return 0
        case .cisco: return 1
        case .arubaCX: return 2
        case .arubaOS: return 3
        case .huawei: return 4
        case .comware: return 5
        case .juniper: return 6
        case .panos: return 7
        case .fortios: return 8
        case .gaia: return 9
        case .linux: return 10
        }
    }

    /// Short form for the status bar and the tab context menu.
    var badge: String {
        switch self {
        case .auto: return "Auto"
        case .cisco: return "Cisco"
        case .arubaCX: return "Aruba CX"
        case .arubaOS: return "ArubaOS"
        case .huawei: return "Huawei"
        case .comware: return "Comware"
        case .juniper: return "Junos"
        case .panos: return "PAN-OS"
        case .fortios: return "FortiOS"
        case .gaia: return "Gaia"
        case .linux: return "Linux"
        }
    }
}

enum CipherMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto
    case modern
    case legacy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (recommended)"
        case .modern: return "Modern only"
        case .legacy: return "Legacy allowed"
        }
    }
}

struct Host: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var kind: ConnectionKind
    var address: String = ""
    var port: Int = 22
    var username: String = ""
    var credentialID: UUID? = nil
    var cipherMode: CipherMode? = nil
    /// ForwardAgent for this host. Optional (not a defaulted Bool) so hosts
    /// written by an older build still decode — a missing key would throw.
    var agentForward: Bool? = nil
    /// Highlight rule pack. Optional for the same forward-compat reason as
    /// `agentForward`; a missing key means `.auto`, so hosts saved before
    /// this existed keep the union behaviour they were coloured with.
    var vendor: Vendor? = nil

    /// The pack to actually highlight with — `vendor` with the nil hole filled.
    var highlightVendor: Vendor { vendor ?? .auto }

    /// Connection identity used for recents dedup and "same target"
    /// matching — the UUID is NOT part of it, so a recent entry and the
    /// host it came from (different ids) still match.
    var connectionKey: String {
        "\(kind.rawValue)\u{0}\(address)\u{0}\(port)\u{0}\(username)"
    }

    func sameConnection(as other: Host) -> Bool {
        connectionKey == other.connectionKey
    }
}

struct HostGroup: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var hosts: [Host]
}

/// Parses "admin@192.168.1.1", "admin@sw01:2222", "admin@2001:db8::1" or
/// "user@[2001:db8::1]:2222" into an ad-hoc SSH target.
enum ConnectParser {
    static func parse(_ text: String) -> Host? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No whitespace may survive anywhere in the target — a pasted
        // newline/tab/inner space would otherwise reach libssh raw.
        guard !trimmed.isEmpty, !trimmed.contains(where: { $0.isWhitespace }) else { return nil }

        var username = ""
        var rest = trimmed
        if let at = trimmed.firstIndex(of: "@") {
            username = String(trimmed[..<at])
            rest = String(trimmed[trimmed.index(after: at)...])
        }

        var port = 22
        var isIPv6 = false
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            // Bracketed IPv6 — [2001:db8::1]:2222; the brackets are not
            // part of the address.
            let after = rest.index(after: close)
            if after < rest.endIndex {
                guard rest[after] == ":",
                      let parsed = Int(rest[rest.index(after: after)...]) else { return nil }
                port = parsed
            }
            rest = String(rest[rest.index(after: rest.startIndex)..<close])
            isIPv6 = true
        } else if rest.filter({ $0 == ":" }).count > 1 {
            // Bare IPv6 (2001:db8::1): several colons and no brackets
            // means the whole thing is the address — no port split.
            isIPv6 = true
        } else if let colon = rest.lastIndex(of: ":") {
            // Exactly one colon means host:port. A port that doesn't parse
            // ("user@host:abc") is a reject, not a silent fallback to 22.
            guard let parsed = Int(rest[rest.index(after: colon)...]) else { return nil }
            port = parsed
            rest = String(rest[..<colon])
        }

        // libssh takes the port as UInt32 — reject values it can't
        // represent here instead of trapping at connect time.
        guard (1...65535).contains(port) else { return nil }

        guard !rest.isEmpty else { return nil }
        // Require either user@ or something host-shaped, so plain-name
        // searches don't turn into connect rows.
        guard !username.isEmpty || rest.contains(".") || isIPv6 else { return nil }

        return Host(
            name: username.isEmpty ? rest : "\(username)@\(rest)",
            kind: .ssh,
            address: rest,
            port: port,
            username: username
        )
    }
}

@MainActor
final class HostStore: ObservableObject {
    @Published var groups: [HostGroup] { didSet { revision &+= 1 } }
    @Published var recents: [Host] { didSet { revision &+= 1 } }
    /// Bumped on every change to either list. The sidebar compares this
    /// instead of rebuilding every SidebarItem and joining a String from
    /// every row just to discover nothing changed — which it did on every
    /// AppModel publish, including each frame of a divider drag.
    private(set) var revision = 0

    /// Non-nil when a data file existed at launch but failed to decode.
    /// The original is preserved next to it as "<name>.corrupt-<timestamp>";
    /// AppModel can surface this message to the user.
    @Published private(set) var dataLoadWarning: String?

    /// Hard cap on stored recents — the sidebar's "show N recents"
    /// setting can never ask for more than this.
    static let maxRecents = 20

    /// Last known modification dates of the files on disk — recorded at
    /// load and after each save so a save can tell whether another
    /// running copy wrote in between (last-writer-wins mitigation).
    private var knownGroupsMtime: Date?
    private var knownRecentsMtime: Date?

    /// Set when a corrupt file was found at launch: blocks automatic
    /// writes until the first explicit user mutation, so a corrupt
    /// original is never overwritten by empty in-memory state.
    private var suppressWritesAfterCorruptLoad = false

    /// Test hook: when set, hosts/recents live here instead of
    /// Application Support. Production code never sets it.
    static var testBaseDirectory: URL?

    private static var baseDirectory: URL {
        if let testBaseDirectory { return testBaseDirectory }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static var fileURL: URL { baseDirectory.appendingPathComponent("hosts.json") }
    private static var recentsURL: URL { baseDirectory.appendingPathComponent("recents.json") }

    init() {
        let groupsLoad = Self.loadList([HostGroup].self, from: Self.fileURL)
        groups = groupsLoad.value
        let recentsLoad = Self.loadList([Host].self, from: Self.recentsURL)
        recents = recentsLoad.value
        let warnings = [groupsLoad.warning, recentsLoad.warning].compactMap { $0 }
        if !warnings.isEmpty {
            dataLoadWarning = warnings.joined(separator: "\n")
            suppressWritesAfterCorruptLoad = true
        }
        knownGroupsMtime = Self.mtime(of: Self.fileURL)
        knownRecentsMtime = Self.mtime(of: Self.recentsURL)
    }

    /// Loads a Codable list from disk. A missing file is normal (fresh
    /// install) and yields an empty list. A file that exists but fails to
    /// decode is data the user had, so it is moved aside to
    /// "<name>.corrupt-<timestamp>" instead of being silently dropped,
    /// and a human-readable warning comes back for the UI.
    private static func loadList<T: Decodable>(_ type: [T].Type, from url: URL) -> (value: [T], warning: String?) {
        guard let data = try? Data(contentsOf: url) else {
            return ([], nil)   // no file yet — normal first launch
        }
        do {
            return (try JSONDecoder().decode(type, from: data), nil)
        } catch {
            let corruptURL = url.appendingPathExtension("corrupt-\(corruptStamp())")
            do {
                try FileManager.default.moveItem(at: url, to: corruptURL)
            } catch {
                NSLog("SheepTerm: could not move corrupt %@ aside: %@",
                      url.lastPathComponent, error.localizedDescription)
            }
            let warning = "\(url.lastPathComponent) was unreadable; the original was preserved as \(corruptURL.lastPathComponent) and the list starts empty."
            NSLog("SheepTerm: %@ (decode error: %@)", warning, error.localizedDescription)
            return ([], warning)
        }
    }

    /// Same rule as the log and backup file names: a timestamp that ends up
    /// in a FILE NAME is always Gregorian + POSIX. A Thai-locale Mac would
    /// otherwise preserve the file as "hosts.json.corrupt-25690826-131403",
    /// which sorts nowhere near the data it was rescued from.
    private static func corruptStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Re-reads both files, replacing whatever is in memory — used after a
    /// backup restore has written new files underneath us. Same corrupt-file
    /// handling as `init`, and the mtimes are re-recorded so the next save
    /// doesn't think another copy of the app wrote in between.
    func reloadFromDisk() {
        let groupsLoad = Self.loadList([HostGroup].self, from: Self.fileURL)
        let recentsLoad = Self.loadList([Host].self, from: Self.recentsURL)
        groups = groupsLoad.value
        recents = recentsLoad.value
        let warnings = [groupsLoad.warning, recentsLoad.warning].compactMap { $0 }
        dataLoadWarning = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
        suppressWritesAfterCorruptLoad = !warnings.isEmpty
        knownGroupsMtime = Self.mtime(of: Self.fileURL)
        knownRecentsMtime = Self.mtime(of: Self.recentsURL)
    }

    /// Every public mutator calls this first — the user's own change is
    /// what re-arms saving after a corrupt load.
    private func noteUserMutation() {
        suppressWritesAfterCorruptLoad = false
    }

    /// For the one caller that mutates `groups` directly instead of going
    /// through a mutator here (Quick Connect's save-to-group).
    func noteExplicitUserMutation() {
        noteUserMutation()
    }

    func save() {
        mergeGroupsFromDiskIfNeeded()
        if write(groups, to: Self.fileURL) {
            knownGroupsMtime = Self.mtime(of: Self.fileURL)
        }
    }

    private func saveRecents() {
        mergeRecentsFromDiskIfNeeded()
        if write(recents, to: Self.recentsURL) {
            knownRecentsMtime = Self.mtime(of: Self.recentsURL)
        }
    }

    /// Two running copies (e.g. via `open -n`) each rewrite the whole file;
    /// when the file on disk is NEWER than our last known state, merge it in
    /// before overwriting. The merge is host-level, not just group-level —
    /// a coarse "groups only, by id" merge silently dropped a host the other
    /// copy added to a group that also exists here (whole new groups
    /// survived; new hosts inside a shared group did not). The rule:
    /// groups present only on disk are kept as-is; for a group present in
    /// both, hosts are unioned by host id — the in-memory host wins on a
    /// same-id conflict (unchanged rule), and hosts that exist only on disk
    /// are appended to the in-memory group's host list, after its existing
    /// hosts, so the user's order is never reshuffled; other group-level
    /// attributes (name, etc.) keep the in-memory value. `groups` is only
    /// reassigned when the disk actually contributed something, so the
    /// overwhelmingly common single-instance case (the mtime guard above
    /// returns early) never publishes from inside a view update.
    private func mergeGroupsFromDiskIfNeeded() {
        guard let diskMtime = Self.mtime(of: Self.fileURL),
              knownGroupsMtime == nil || diskMtime > knownGroupsMtime!,
              let data = try? Data(contentsOf: Self.fileURL),
              let diskGroups = try? JSONDecoder().decode([HostGroup].self, from: data) else { return }

        // uniquingKeysWith, never uniqueKeysWithValues: this is user data that
        // has been through imports, shares and restores, and a duplicate group
        // id in the file would TRAP — a crash on save is a far worse outcome
        // than merging against the first of the duplicates.
        let diskGroupsByID = Dictionary(diskGroups.map { ($0.id, $0) },
                                        uniquingKeysWith: { first, _ in first })
        let knownIDs = Set(groups.map(\.id))
        var merged = groups
        var changed = false

        for i in merged.indices {
            guard let diskGroup = diskGroupsByID[merged[i].id] else { continue }
            let knownHostIDs = Set(merged[i].hosts.map(\.id))
            // Deduped by id for the same reason the group merge below is: a
            // disk group can carry the same host id twice, and appending both
            // puts two rows with one identity into the outline.
            var seenHostIDs = knownHostIDs
            let hostsOnlyOnDisk = diskGroup.hosts.filter { seenHostIDs.insert($0.id).inserted }
            guard !hostsOnlyOnDisk.isEmpty else { continue }
            merged[i].hosts.append(contentsOf: hostsOnlyOnDisk)
            changed = true
        }

        // Deduped by id, not just filtered: a file can carry the SAME group
        // id twice (imports, LAN shares and restores all copy ids), and
        // appending both would put two groups with one id into `groups` —
        // colliding SwiftUI row identities, the same class of bug that made
        // recents get a fresh id per entry.
        var seenGroupIDs = knownIDs
        let groupsOnlyOnDisk = diskGroups.filter { seenGroupIDs.insert($0.id).inserted }
        if !groupsOnlyOnDisk.isEmpty {
            merged.append(contentsOf: groupsOnlyOnDisk)
            changed = true
        }

        if changed {
            groups = merged
        }
    }

    /// Same merge for recents: most-recent-first (in-memory order wins),
    /// deduped by (address, port, username), capped at the usual limit.
    /// Only publishes when the capped/deduped result actually differs from
    /// what's already in memory — same "don't publish from a view update
    /// for nothing" reasoning as the groups merge above.
    private func mergeRecentsFromDiskIfNeeded() {
        guard let diskMtime = Self.mtime(of: Self.recentsURL),
              knownRecentsMtime == nil || diskMtime > knownRecentsMtime!,
              let data = try? Data(contentsOf: Self.recentsURL),
              let diskRecents = try? JSONDecoder().decode([Host].self, from: data) else { return }
        var seen = Set<String>()
        var merged: [Host] = []
        for host in recents + diskRecents {
            if seen.insert(host.connectionKey).inserted {
                merged.append(host)
            }
        }
        let capped = Array(merged.prefix(Self.maxRecents))
        if capped != recents {
            recents = capped
        }
    }

    private static func mtime(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    /// Every write first copies the existing file to "<name>.bak" (a
    /// failed backup only logs — it must not block the save) and reports
    /// success, because a silently lost write means hosts vanish on the
    /// next launch.
    @discardableResult
    private func write(_ value: some Encodable, to url: URL) -> Bool {
        guard !suppressWritesAfterCorruptLoad else {
            NSLog("SheepTerm: write to %@ suppressed until the first user change (corrupt previous file was preserved)",
                  url.lastPathComponent)
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(value)
            if FileManager.default.fileExists(atPath: url.path) {
                // Copy beside the old .bak and swap, so a failed copy leaves
                // the PREVIOUS backup in place instead of no backup at all.
                let backupURL = url.appendingPathExtension("bak")
                let stagingURL = url.appendingPathExtension("bak.tmp")
                do {
                    try? FileManager.default.removeItem(at: stagingURL)
                    try FileManager.default.copyItem(at: url, to: stagingURL)
                    _ = try FileManager.default.replaceItemAt(backupURL, withItemAt: stagingURL)
                } catch {
                    try? FileManager.default.removeItem(at: stagingURL)
                    NSLog("SheepTerm: could not back up %@: %@",
                          url.lastPathComponent, error.localizedDescription)
                }
            }
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("SheepTerm: failed to write %@: %@", url.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    // MARK: Recents

    func noteRecent(_ host: Host) {
        noteUserMutation()
        // Recents always get a fresh id — reusing the host's id made two
        // entries share one id (colliding SwiftUI row identities).
        var entry = host
        entry.id = UUID()
        recents.removeAll { $0.sameConnection(as: entry) }
        recents.insert(entry, at: 0)
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    func removeRecent(_ host: Host) {
        noteUserMutation()
        // Match by connection key, not id: the caller hands us a host
        // whose id need not be the recent entry's id.
        recents.removeAll { $0.sameConnection(as: host) }
        saveRecents()
    }

    // MARK: Group management

    func addGroup(named name: String) {
        noteUserMutation()
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !groups.contains(where: { $0.name == trimmed }) else { return }
        groups.append(HostGroup(name: trimmed, hosts: []))
        save()
    }

    /// Same duplicate-name rule as addGroup — renaming into an existing
    /// name would make the two groups indistinguishable in pickers.
    /// Returns false (and changes nothing) when the name is taken.
    @discardableResult
    func renameGroup(_ group: HostGroup, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = groups.firstIndex(where: { $0.id == group.id }) else { return false }
        guard !groups.contains(where: { $0.id != group.id && $0.name == trimmed }) else { return false }
        // AFTER validation: a rejected rename is not a user change, and
        // re-arming writes on one would let the next automatic save overwrite
        // a file that was deliberately quarantined.
        noteUserMutation()
        groups[index].name = trimmed
        save()
        return true
    }

    func deleteGroup(_ group: HostGroup) {
        noteUserMutation()
        groups.removeAll { $0.id == group.id }
        save()
    }

    /// The group an import would merge into — same id first, then same
    /// name — or nil when the import lands as a brand-new group (0.4 ก).
    func existingGroup(matching incoming: HostGroup) -> HostGroup? {
        groups.first { $0.id == incoming.id } ?? groups.first { $0.name == incoming.name }
    }

    /// "Name 2", "Name 3", … — the first numbered variant not taken, so an
    /// import never creates an accidental duplicate group name (0.4 ค4).
    func uniqueGroupName(base: String) -> String {
        if !groups.contains(where: { $0.name == base }) { return base }
        var number = 2
        while groups.contains(where: { $0.name == "\(base) \(number)" }) { number += 1 }
        return "\(base) \(number)"
    }

    /// Incoming hosts that collide with an existing host (same id, or same
    /// address+port+username) AND differ in content — the pairs the
    /// Replace/Keep dialog asks about (0.4 ข).
    func conflictingHosts(incoming: HostGroup, existing: HostGroup) -> [(incoming: Host, existing: Host)] {
        incoming.hosts.compactMap { inc in
            guard let current = existing.hosts.first(where: {
                $0.id == inc.id
                    || ($0.address == inc.address && $0.port == inc.port && $0.username == inc.username)
            }), !Self.sameForImport(current, inc) else { return nil }
            return (incoming: inc, existing: current)
        }
    }

    /// Equality for import conflict detection, excluding id and
    /// credentialID: the id is a local implementation detail (a file from
    /// another machine carries different ids for the same hosts) and
    /// import files never carry credentials — a host differing only in
    /// those two fields is not a conflict worth asking about, or every
    /// re-import would re-ask about hosts the user already resolved.
    private static func sameForImport(_ a: Host, _ b: Host) -> Bool {
        a.name == b.name && a.kind == b.kind && a.address == b.address
            && a.port == b.port && a.username == b.username && a.cipherMode == b.cipherMode
            && (a.agentForward ?? false) == (b.agentForward ?? false)
    }

    /// Applies an import after the dialog decided the outcome (0.4).
    /// `.merge` adds new hosts and replaces/keeps conflicts per `replace`
    /// (incoming host id → true = use the file's version); `.createNew`
    /// appends the group under a unique numbered name with a fresh id.
    /// Invariants (0.4 ค): the existing group's name is never changed,
    /// hosts only in the existing group are never deleted, and a replaced
    /// host keeps its credentialID — the file carries none.
    @discardableResult
    func applyImport(_ incoming: HostGroup, action: ImportGroupAction, replace: [UUID: Bool]) -> GroupImportStats {
        noteUserMutation()
        var stats = GroupImportStats()
        switch action {
        case .createNew:
            var group = incoming
            group.id = UUID()
            group.name = uniqueGroupName(base: incoming.name)
            group.hosts = Self.freshIDs(group.hosts)
            groups.append(group)
            stats.addedGroup = true
            stats.addedHosts = group.hosts.count
        case .merge:
            guard let index = groups.firstIndex(where: { $0.id == incoming.id })
                ?? groups.firstIndex(where: { $0.name == incoming.name }) else {
                // The match vanished between dialog and apply — land as a
                // new group instead of failing silently.
                var group = incoming
                group.id = UUID()
                group.name = uniqueGroupName(base: incoming.name)
                group.hosts = Self.freshIDs(group.hosts)
                groups.append(group)
                stats.addedGroup = true
                stats.addedHosts = group.hosts.count
                break
            }
            // 0.4 (ค)2: never rename the existing group after the file.
            for inc in incoming.hosts {
                if let hostIndex = groups[index].hosts.firstIndex(where: {
                    $0.id == inc.id
                        || ($0.address == inc.address && $0.port == inc.port && $0.username == inc.username)
                }) {
                    let current = groups[index].hosts[hostIndex]
                    guard !Self.sameForImport(current, inc) else { continue }
                    // No decision (aborted dialog) defaults to keep.
                    guard replace[inc.id] == true else { continue }
                    var merged = inc
                    // 0.4 (ค)1: a replaced host keeps OUR credential
                    // reference — the file carries none — and OUR id, so
                    // open tabs and the sidebar keep pointing at it.
                    merged.credentialID = current.credentialID
                    merged.id = current.id
                    groups[index].hosts[hostIndex] = merged
                    stats.replacedHosts += 1
                } else {
                    var added = inc
                    added.id = UUID()
                    groups[index].hosts.append(added)
                    stats.addedHosts += 1
                }
            }
        }
        save()
        return stats
    }

    /// A host id must be unique across ALL groups: removeHost and updateHost
    /// look hosts up by id, and the sidebar caches rows by it. The file's
    /// own ids are kept out on purpose — importing the same file twice as
    /// two groups used to give both groups hosts with identical ids, so one
    /// delete removed the host from BOTH and an edit reached only the first.
    /// Conflict matching does not need them (address+port+username).
    private static func freshIDs(_ hosts: [Host]) -> [Host] {
        hosts.map { var host = $0; host.id = UUID(); return host }
    }

    /// Records a live device-family switch everywhere this connection is
    /// remembered. Matched by connection identity, not id, so a tab opened
    /// from a recent entry still updates the saved host it belongs to.
    ///
    /// EVERY match is written, not just the first: the same box can be saved
    /// in two groups, and leaving the others stale means the choice silently
    /// depends on which copy you happened to launch from. Recents are written
    /// too — a Quick Connect target or a serial console that is not a saved
    /// host has nowhere else to keep it, and that is precisely the case where
    /// the family had to be identified by eye and must not be asked again.
    func setVendor(_ vendor: Vendor, matching target: Host) {
        var changedHosts = false
        for groupIndex in groups.indices {
            for hostIndex in groups[groupIndex].hosts.indices
            where groups[groupIndex].hosts[hostIndex].sameConnection(as: target)
                && groups[groupIndex].hosts[hostIndex].vendor != vendor {
                if !changedHosts { noteUserMutation(); changedHosts = true }
                groups[groupIndex].hosts[hostIndex].vendor = vendor
            }
        }
        if changedHosts { save() }

        var changedRecents = false
        for index in recents.indices
        where recents[index].sameConnection(as: target) && recents[index].vendor != vendor {
            // Before the write, not after: this is a user action, and under
            // post-corrupt write suppression an un-armed saveRecents() drops
            // it silently — which is exactly the Quick Connect / serial
            // console case this method exists for.
            if !changedRecents { noteUserMutation(); changedRecents = true }
            recents[index].vendor = vendor
        }
        if changedRecents { saveRecents() }
    }

    func updateHost(_ host: Host) {
        noteUserMutation()
        for groupIndex in groups.indices {
            if let hostIndex = groups[groupIndex].hosts.firstIndex(where: { $0.id == host.id }) {
                let old = groups[groupIndex].hosts[hostIndex]
                groups[groupIndex].hosts[hostIndex] = host
                // Recents keyed by the old address+port+username follow
                // the edit instead of pointing at a stale connection.
                updateRecents(from: old, to: host)
                save()
                return
            }
        }
    }

    /// Recents matching old's connection key take over the new values;
    /// dedup afterwards in case the new values now collide with another
    /// recent entry.
    private func updateRecents(from old: Host, to new: Host) {
        var changed = false
        for index in recents.indices where recents[index].sameConnection(as: old) {
            recents[index].name = new.name
            recents[index].kind = new.kind
            recents[index].address = new.address
            recents[index].port = new.port
            recents[index].username = new.username
            recents[index].credentialID = new.credentialID
            recents[index].cipherMode = new.cipherMode
            recents[index].agentForward = new.agentForward
            recents[index].vendor = new.vendor
            changed = true
        }
        guard changed else { return }
        var seen = Set<String>()
        recents = recents.filter { seen.insert($0.connectionKey).inserted }
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        saveRecents()
    }

    func removeHost(_ host: Host) {
        noteUserMutation()
        for index in groups.indices {
            groups[index].hosts.removeAll { $0.id == host.id }
        }
        // A removed host must not linger in Recent — it can no longer be
        // connected to.
        let countBefore = recents.count
        recents.removeAll { $0.sameConnection(as: host) }
        if recents.count != countBefore { saveRecents() }
        save()
    }

    // MARK: Credential references

    /// How many saved hosts reference a credential — shown in the delete
    /// confirmation before the credential is removed.
    /// Counts recents too: the delete dialog quoting a smaller number than
    /// the change actually affects is worse than no number.
    func hostCount(usingCredential id: UUID) -> Int {
        groups.reduce(0) { $0 + $1.hosts.filter { $0.credentialID == id }.count }
            + recents.filter { $0.credentialID == id }.count
    }

    /// Detaches a credential from every host that references it (used
    /// when the credential itself is deleted, so hosts fall back to
    /// manual login instead of pointing at a dead Keychain entry).
    func clearCredentialID(_ id: UUID) {
        noteUserMutation()
        var changed = false
        for groupIndex in groups.indices {
            for hostIndex in groups[groupIndex].hosts.indices
            where groups[groupIndex].hosts[hostIndex].credentialID == id {
                groups[groupIndex].hosts[hostIndex].credentialID = nil
                changed = true
            }
        }
        if changed { save() }
        // Recents carry credentialID too (updateRecents propagates it on an
        // edit), so leaving them behind pointed at a Keychain entry that no
        // longer exists.
        var changedRecents = false
        for index in recents.indices where recents[index].credentialID == id {
            recents[index].credentialID = nil
            changedRecents = true
        }
        if changedRecents { saveRecents() }
    }

    /// Live reorder used while dragging a group over another; call save() when
    /// the drop completes.
    func reorderGroup(withID id: UUID, over targetID: UUID) {
        noteUserMutation()
        guard id != targetID,
              let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let group = groups.remove(at: from)
        // The drop target can vanish between drag start and this call (the
        // row was deleted, or an import rebuilt the list). Put the group
        // back where it was instead of computing an index past the end —
        // `insert(at: count + 1)` traps.
        guard let dest = groups.firstIndex(where: { $0.id == targetID }) else {
            groups.insert(group, at: min(from, groups.count))
            return
        }
        groups.insert(group, at: min(from <= dest ? dest + 1 : dest, groups.count))
    }

    /// Where a host currently lives, as (group index, index in that group).
    /// Public twin of `locateHost` — the sidebar needs it to work out which
    /// side of the row under the pointer the insertion gap belongs on.
    func location(ofHost id: UUID) -> (group: Int, index: Int)? {
        locateHost(id)
    }

    /// Position of a group in the sidebar order.
    func location(ofGroup id: UUID) -> Int? {
        groups.firstIndex { $0.id == id }
    }

    /// Where a host currently lives, as (group index, index in that group).
    private func locateHost(_ id: UUID) -> (group: Int, index: Int)? {
        for groupIndex in groups.indices {
            if let hostIndex = groups[groupIndex].hosts.firstIndex(where: { $0.id == id }) {
                return (groupIndex, hostIndex)
            }
        }
        return nil
    }

    /// Which group a host belongs to. The drag layer uses it to tell an
    /// in-place reorder (which must track the pointer exactly, no animation)
    /// from a jump into another group (animated, so the move is visible).
    func groupID(ofHost id: UUID) -> UUID? {
        groups.first { $0.hosts.contains { $0.id == id } }?.id
    }

    /// Live reorder used while dragging a host over another host row; call
    /// save() when the drop completes. Dropping onto a host in a DIFFERENT
    /// group moves it there, landing in the target's slot. Same insertion
    /// rule as reorderGroup — after the target when dragging down within a
    /// group, before it when dragging up — and every index is clamped: the
    /// rows can change under a drag that is still in flight.
    func reorderHost(withID id: UUID, over targetID: UUID) {
        noteUserMutation()
        guard id != targetID, let from = locateHost(id) else { return }
        let host = groups[from.group].hosts.remove(at: from.index)
        // Re-locate AFTER the removal: in the same group every index past
        // the old slot has shifted down by one.
        guard let target = locateHost(targetID) else {
            // The target vanished mid-drag — put the host back untouched.
            groups[from.group].hosts.insert(host, at: min(from.index, groups[from.group].hosts.count))
            return
        }
        let destination: Int
        if target.group == from.group {
            destination = from.index <= target.index ? target.index + 1 : target.index
        } else {
            destination = target.index
        }
        groups[target.group].hosts.insert(host, at: min(destination, groups[target.group].hosts.count))
    }

    /// Index-based group move — the sidebar's NSOutlineView reports a drop
    /// as "insert before child N of the root", counted BEFORE the dragged row
    /// is taken out, so the destination shifts down by one when the row came
    /// from above it. Every index is clamped: the list can change under a
    /// drag that is still in flight.
    func moveGroup(withID id: UUID, toIndex index: Int) {
        noteUserMutation()
        guard let from = groups.firstIndex(where: { $0.id == id }) else { return }
        let target = max(0, min(index, groups.count))
        let destination = target > from ? target - 1 : target
        guard destination != from else { return }
        let group = groups.remove(at: from)
        groups.insert(group, at: min(destination, groups.count))
        save()
    }

    /// Index-based host move, within a group or into another one. Same
    /// before-removal index convention as `moveGroup`.
    func moveHost(withID id: UUID, toGroupID groupID: UUID, atIndex index: Int) {
        noteUserMutation()
        guard let from = locateHost(id),
              let destGroup = groups.firstIndex(where: { $0.id == groupID }) else { return }
        var destination = max(0, min(index, groups[destGroup].hosts.count))
        if destGroup == from.group {
            if destination > from.index { destination -= 1 }
            guard destination != from.index else { return }
        }
        let host = groups[from.group].hosts.remove(at: from.index)
        groups[destGroup].hosts.insert(host, at: min(destination, groups[destGroup].hosts.count))
        save()
    }

    func move(host: Host, toGroupNamed name: String) {
        noteUserMutation()
        for index in groups.indices {
            groups[index].hosts.removeAll { $0.id == host.id }
        }
        if let index = groups.firstIndex(where: { $0.name == name }) {
            groups[index].hosts.append(host)
        } else {
            groups.append(HostGroup(name: name, hosts: [host]))
        }
        save()
    }

}

/// How an imported group should land — decided by the import dialog (0.4 ก).
enum ImportGroupAction {
    case merge
    case createNew
}

/// Outcome of HostStore.applyImport — callers can show what an import
/// actually did ("added 3 hosts, updated 1").
struct GroupImportStats {
    /// True when the group was appended as a brand-new group.
    var addedGroup = false
    /// Hosts appended to an existing (or new) group.
    var addedHosts = 0
    /// Existing hosts overwritten by an incoming host with the same id
    /// or address+port+username.
    var replacedHosts = 0
}

extension String {
    /// Sidebar / Quick Search matching: case- and diacritic-insensitive, so
    /// `cafe` finds `café-sw1`. Thai has neither, so it is unaffected.
    func matchesSearch(_ query: String) -> Bool {
        range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: .current) != nil
    }
}
