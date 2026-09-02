import SwiftUI

/// Floating quick-connect palette shown from the magnifier button (or ⌘K).
/// Type to filter saved hosts, or type user@host and press ↩ to connect.
struct QuickSearchView: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @FocusState private var focused: Bool

    private var connectTarget: Host? {
        ConnectParser.parse(text)
    }

    /// Computed ONCE per body evaluation. It used to be read twice — for the
    /// isEmpty check and for the ForEach — so every keystroke ran the
    /// locale-aware filter over every host twice.
    private var matches: [Host] { computeMatches() }

    private func computeMatches() -> [Host] {
        var all = model.store.recents + model.store.groups.flatMap(\.hosts)
        if !text.isEmpty {
            all = all.filter { $0.name.matchesSearch(text) || $0.address.matchesSearch(text) }
        }
        var seen = Set<String>()
        var unique: [Host] = []
        for host in all {
            let key = "\(host.kind.rawValue)|\(host.address)|\(host.port)|\(host.username)"
            if seen.insert(key).inserted {
                unique.append(host)
            }
            if unique.count == 8 { break }
        }
        return unique
    }

    var body: some View {
        let results = matches
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search or user@host", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit(connectFirst)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            // The palette is a .popover, so macOS already gives it a glass
            // container — the field just needs to stay readable on it.
            .background { ControlFill(zone: .sidebar, cornerRadius: 8) }

            if let target = connectTarget {
                paletteRow(
                    badge: "SSH",
                    badgeColor: Theme.accent,
                    name: target.name,
                    detail: "port \(target.port) · press ↩"
                ) {
                    connect(target)
                }
            }

            if !results.isEmpty {
                Divider()
                ForEach(results) { host in
                    paletteRow(
                        badge: host.kind.badge,
                        badgeColor: host.kind == .serial ? Theme.warn : Theme.accent,
                        name: host.name,
                        detail: host.address.isEmpty ? nil : host.address
                    ) {
                        connect(host)
                    }
                }
            }

            Text("↩ connect first result · esc close")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func paletteRow(
        badge: String,
        badgeColor: Color,
        name: String,
        detail: String?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(badge)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1.5)
                    .background(badgeColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(badgeColor)
                Text(name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }

    private func connect(_ host: Host) {
        model.showQuickSearch = false
        model.open(host: host)
        model.collapseSidebar()
    }

    private func connectFirst() {
        if let target = connectTarget ?? matches.first {
            connect(target)
        }
    }
}
