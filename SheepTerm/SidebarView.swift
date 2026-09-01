import AppKit
import SwiftUI

/// Sidebar chrome: search field on top, buttons on the bottom, and the row
/// list in between. The rows themselves are an NSOutlineView
/// (`SidebarOutline.swift`) — SwiftUI's List could not do drag-to-reorder
/// without the drop always looking like it drifted into place.
struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: HostStore
    @State private var searchText = ""
    @State private var showNewGroup = false
    @State private var renameTarget: HostGroup?
    @State private var editTarget: Host?
    @FocusState private var searchFocused: Bool
    /// Mirrors TopBarView's own fullscreen state — same will*-notification
    /// pattern, so the gap changes DURING the system transition.
    @State private var isFullScreen = false
    @State private var collapsedGroups: Set<UUID> = Self.loadCollapsedGroups()
    @AppStorage("showRecents") private var showRecents = true
    @AppStorage("recentsShown") private var recentsShown = 5

    private static let collapsedKey = "collapsedGroups"

    private static func loadCollapsedGroups() -> Set<UUID> {
        let strings = UserDefaults.standard.stringArray(forKey: collapsedKey) ?? []
        return Set(strings.compactMap(UUID.init(uuidString:)))
    }

    private func persistCollapsed() {
        UserDefaults.standard.set(collapsedGroups.map(\.uuidString), forKey: Self.collapsedKey)
    }

    /// Drops ids of groups that no longer exist so the collapsed set
    /// can't accumulate stale UUIDs (e.g. after a delete on another
    /// running copy of the app).
    private func pruneCollapsedGroups() {
        let valid = Set(store.groups.map(\.id))
        let pruned = collapsedGroups.intersection(valid)
        if pruned != collapsedGroups {
            collapsedGroups = pruned
            persistCollapsed()
        }
    }

    /// Space above the search field. The sidebar owns the titlebar row, so
    /// windowed mode has to clear the traffic lights; macOS hides those in
    /// fullscreen, where the field sits flush to the top instead.
    private var topGap: CGFloat { isFullScreen ? 8 : 36 }

    private var searchConnectTarget: Host? {
        ConnectParser.parse(searchText)
    }

    var body: some View {
        SidebarOutline(
            store: store,
            model: model,
            searchText: searchText,
            connectTarget: searchConnectTarget,
            showRecents: showRecents,
            recentsShown: recentsShown,
            collapsedGroups: $collapsedGroups,
            onEditHost: { editTarget = $0 },
            onRenameGroup: { renameTarget = firstGroup(withID: $0.id) },
            onReorderGroups: { model.showReorderGroups = true },
            onDeleteGroup: { group in
                if let original = firstGroup(withID: group.id) {
                    // Forget its collapsed state too — a stale id would
                    // linger in UserDefaults forever.
                    collapsedGroups.remove(original.id)
                    persistCollapsed()
                    store.deleteGroup(original)
                }
            },
            onExportGroup: { group in
                if let original = firstGroup(withID: group.id) {
                    model.exportGroup(original)
                }
            }
        )
        .onChange(of: collapsedGroups) { _, _ in persistCollapsed() }
        .onAppear {
            pruneCollapsedGroups()
            isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willEnterFullScreenNotification)) { _ in
            isFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willExitFullScreenNotification)) { _ in
            isFullScreen = false
        }
        // [] is load-bearing: default backgrounds auto-expand into the
        // titlebar safe area and would paint over the tab bar above.
        .background { ChromeBackground(zone: .sidebar) }
        .safeAreaInset(edge: .top, spacing: 0) {
            // The sidebar sits below the top bar in every mode, so the search
            // field keeps the same small top gap everywhere.
            VStack(spacing: 4) {
                Color.clear.frame(height: topGap)
                searchField
            }
            .padding(.bottom, 4)
            // [] keeps this from expanding up over the tab bar (titlebar row).
            .background { ChromeBackground(zone: .sidebar) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 14) {
                Button {
                    showNewGroup = true
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.showReorderGroups = true
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reorder groups")
                Button {
                    if collapsedGroups.isEmpty {
                        collapsedGroups = Set(store.groups.map(\.id))
                    } else {
                        collapsedGroups = []
                    }
                    persistCollapsed()
                } label: {
                    Image(systemName: collapsedGroups.isEmpty
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(collapsedGroups.isEmpty ? "Collapse all groups" : "Expand all groups")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background { ChromeBackground(zone: .sidebar) }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Theme.chromeLine)
                    .frame(height: 1)
            }
        }
        .sheet(isPresented: $model.showReorderGroups) {
            ReorderGroupsSheet(store: store)
        }
        .sheet(isPresented: $showNewGroup) {
            NamePromptSheet(title: "New Group", confirmLabel: "Create") { name in
                store.addGroup(named: name)
            }
        }
        .sheet(item: $renameTarget) { group in
            NamePromptSheet(title: "Rename Group", initialName: group.name) { name in
                store.renameGroup(group, to: name)
            }
        }
        .sheet(item: $editTarget) { host in
            HostEditSheet(host: host)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search or user@host", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit {
                    if let target = searchConnectTarget {
                        connect(to: target)
                    }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background { ControlFill(zone: .sidebar) }
        .padding(.horizontal, 10)
    }

    private func firstGroup(withID id: UUID) -> HostGroup? {
        store.groups.first { $0.id == id }
    }

    private func connect(to target: Host) {
        model.open(host: target)
        model.collapseSidebar()
        searchText = ""
    }
}
