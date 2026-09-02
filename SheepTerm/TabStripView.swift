import SwiftUI

/// Session tabs, rendered inside the window toolbar next to the + button.
struct TabStripView: View {
    @ObservedObject private var model = AppModel.shared
    /// Windowed: the window's own border covers the top bar's first point,
    /// so the chips are nudged 1pt down to centre on the row the eye reads
    /// (see the comment below). Fullscreen has no border — the same nudge
    /// there put the chips 1pt BELOW the icons beside them.
    var compensateWindowBorder = true

    var body: some View {
        // ScrollViewReader so a newly created or ⌘-selected tab is brought
        // into view: with many tabs the active one could sit off-screen with
        // nothing to scroll it back.
        ScrollViewReader { scroller in
        ScrollView(.horizontal, showsIndicators: false) {
            // maxHeight so the chips CENTRE in the strip, plus 2pt of top
            // padding — which shifts them down 1pt, because a centred box
            // absorbs half of it.
            //
            // The 1pt is not arbitrary: the top bar's frame starts at the
            // window's very top, but its first point is covered by the
            // window's own border, so centring in the FRAME lands one point
            // above the row the eye actually reads — the one the traffic
            // lights sit on. Measured against them, not against the frame.
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
                    .id(tab.id)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(.top, compensateWindowBorder ? 2 : 0)
        }
        // Fill the top bar's height rather than a fixed 24, so the chips are
        // centred against the buttons either side of them instead of against
        // a box that is shorter than the bar.
        .frame(maxHeight: .infinity)
        .onChange(of: model.selectedID) { _, id in
            guard let id else { return }
            withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(id) }
        }
        }
    }
}

struct TabItemView: View {
    @ObservedObject var tab: SessionTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onReconnect: () -> Void
    @State private var hovering = false

    /// Prefix, not equality: a session that burned its auto-reconnect budget
    /// reports "disconnected — auto-reconnect limit reached", and an exact
    /// compare left that permanently dead tab wearing its connected colour.
    /// (StatusBarView has always used hasPrefix; this was the odd one out.)
    private var isDisconnected: Bool {
        tab.statusInfo?.hasPrefix("disconnected") == true
    }

    private var indicatorColor: Color {
        switch tab.content {
        case .local: return Theme.ok
        case .ssh: return isDisconnected ? Color.red : Theme.accent
        case .serial: return isDisconnected ? Color.red : Theme.warn
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
        // The chip is an HStack with a tap gesture, so VoiceOver saw a pile
        // of unrelated labels rather than one selectable tab.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tab.title)
        .accessibilityValue(tab.statusInfo ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Switches to this session")
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
