import SwiftUI

/// Groups-only list for easy drag reordering (no hosts in the way).
struct ReorderGroupsSheet: View {
    @ObservedObject var store: HostStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reorder Groups")
                .font(.headline)
            Text("Drag to change the order shown in the sidebar")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            List {
                ForEach(store.groups) { group in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text(group.name)
                            .font(.system(size: 13))
                        Spacer()
                        Text("\(group.hosts.count)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                }
                .onMove { from, to in
                    // Direct mutation, like Quick Connect's save-to-group:
                    // the user's own change is what re-arms saving after a
                    // corrupt load, and a plain save() is silently dropped.
                    store.noteExplicitUserMutation()
                    store.groups.move(fromOffsets: from, toOffset: to)
                    store.save()
                }
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 320, height: 380)
    }
}
