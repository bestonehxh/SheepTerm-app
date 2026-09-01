import SwiftUI

/// Session tabs, rendered inside the window toolbar next to the + button.
struct TabStripView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.tabs) { tab in
                    // Chips get plain values/closures — observing the whole
                    // AppModel per chip would re-render every chip on any
                    // @Published change.
                    TabItemView(
                        tab: tab,
                        isSelected: model.selectedID == tab.id,
                        onSelect: {
                            model.selectedID = tab.id
                            model.collapseSidebar()
                        },
                        onClose: { model.close(tab: tab) },
                        onReconnect: { model.reconnect(tab: tab) }
                    )
                }
            }
        }
        .frame(height: 24)
    }
}

struct TabItemView: View {
    @ObservedObject var tab: SessionTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReconnect: () -> Void
    @State private var hovering = false

    private var indicatorColor: Color {
        switch tab.content {
        case .local: return Theme.ok
        case .ssh: return tab.statusInfo == "disconnected" ? Color.red : Theme.accent
        case .serial: return tab.statusInfo == "disconnected" ? Color.red : Theme.warn
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 7, height: 7)
            Text(tab.title)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 190)
                .fixedSize(horizontal: true, vertical: false)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(
                        Circle().fill(Color.primary.opacity(hovering ? 0.12 : 0))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.tabActive : (hovering ? Theme.tabActive.opacity(0.5) : Color.clear))
        )
        .foregroundStyle(isSelected ? Theme.tabText : Theme.dimText)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering = $0 }
        .contextMenu {
            switch tab.content {
            case .ssh, .serial:
                Button("Reconnect") { onReconnect() }
                Toggle("Highlight", isOn: $tab.highlightEnabled)
                Divider()
            case .local:
                EmptyView()
            }
            Button("Close Tab") { onClose() }
        }
    }
}
