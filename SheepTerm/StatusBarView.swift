import Combine
import SwiftUI

struct StatusBarView: View {
    static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // The status-bar clock is Gregorian as well — pinned explicitly so a
        // Buddhist-era system calendar can never reach it.
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    @EnvironmentObject var model: AppModel
    // Empty until onAppear — getifaddrs isn't free, so don't run it in the
    // initializer that every re-render of the parent evaluates.
    @State private var localAddress = ""
    // Hoisted so the publisher isn't recreated on every re-render.
    /// `static`, not an instance `let`: an instance initializer runs on every
    /// struct init, so every AppModel publish built a fresh publisher and
    /// resubscribed — restarting the 15 s phase each time, which a chattier
    /// model would turn into an IP that never refreshes.
    private static let ipTimer = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            // The connection-state sheep and the highlight vendor control
            // always show for a remote tab; only the session/cipher/device-IP/
            // user TEXT is gated by statusShowSession (hidden by default).
            if let tab = model.selectedTab {
                SessionStatusText(tab: tab, showText: model.statusShowSession) {
                    model.setHighlightVendorCurrent($0)
                }
            } else if model.statusShowSession {
                Text("no session")
            }
            Spacer()
            if model.statusShowHints {
                Text("⌘T tab · ⌘0 sidebar · ⌘1–9 switch")
                    .foregroundStyle(Theme.dimText.opacity(0.7))
            }
            Spacer()
            if model.statusShowClock {
                ClockText()
            }
            if model.statusShowIP {
                Text(localAddress)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(Theme.dimText)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background { ChromeBackground(zone: .statusBar) }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.chromeLine)
                .frame(height: 1)
        }
        .onAppear {
            localAddress = NetworkInfo.summary()
        }
        .onReceive(Self.ipTimer) { _ in
            // getifaddrs isn't free — skip while the IP segment is hidden or
            // nothing of the app is on screen to show it on.
            guard model.statusShowIP, MainWindowKeyMonitor.shared.isVisible else { return }
            localAddress = NetworkInfo.summary()
        }
        .onReceive(MainWindowKeyMonitor.shared.$isVisible) { visible in
            // Coming back on screen: refresh the address that went stale
            // while the ticks were skipped.
            guard visible, model.statusShowIP else { return }
            localAddress = NetworkInfo.summary()
        }
    }
}

/// The status-bar clock. It ticks once a second only while some part of the
/// app is actually on screen — while everything is occluded (minimized,
/// hidden, fully covered) the timeline is torn down, so the app stops waking
/// up 60 times a minute for a clock nobody can read. Re-appearing re-renders
/// with the current time immediately, so it can never show a stale one.
private struct ClockText: View {
    @ObservedObject private var window = MainWindowKeyMonitor.shared

    var body: some View {
        if window.isVisible {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(StatusBarView.clockFormatter.string(from: context.date))
            }
        } else {
            Text(StatusBarView.clockFormatter.string(from: Date()))
        }
    }
}

/// Tiny sheep pacing back and forth — the "connecting" indicator. (The
/// sheep picks connectionState: walking = connecting, napping = connected,
/// faded = closed; the highlight on/off state lives in the button tooltip.)
struct WalkingSheepView: View {
    @ObservedObject private var windowKey = MainWindowKeyMonitor.shared

    var body: some View {
        if !windowKey.isKey {
            // Static frame while the window isn't key — no TimelineView
            // ticking at 20 fps in the background.
            Text("🐑")
                .font(.system(size: 12))
        } else {
            TimelineView(.animation(minimumInterval: 0.05)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let period = 3.2
                let phase = time.truncatingRemainder(dividingBy: period) / period
                let walkingRight = phase < 0.5
                let progress = walkingRight ? phase * 2 : (1 - phase) * 2
                let x = (progress - 0.5) * 18
                let bob = abs(sin(progress * .pi * 8)) * -1.2
                Text("🐑")
                    .font(.system(size: 12))
                    .scaleEffect(x: walkingRight ? -1 : 1, y: 1)
                    .offset(x: x, y: bob)
            }
        }
    }
}

/// Connected: the sheep naps with a gently drifting 💤.
struct SleepingSheepView: View {
    @ObservedObject private var windowKey = MainWindowKeyMonitor.shared

    var body: some View {
        if !windowKey.isKey {
            // Static frame while the window isn't key — no TimelineView
            // ticking in the background.
            HStack(spacing: 1) {
                Text("🐑")
                    .font(.system(size: 12))
                Text("💤")
                    .font(.system(size: 8))
                    .opacity(0.7)
            }
        } else {
            TimelineView(.animation(minimumInterval: 0.12)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = (sin(time * 2.2) + 1) / 2
                HStack(spacing: 1) {
                    Text("🐑")
                        .font(.system(size: 12))
                    Text("💤")
                        .font(.system(size: 8))
                        .opacity(0.35 + 0.65 * pulse)
                        .offset(y: 2 - 3 * pulse)
                }
            }
        }
    }
}

struct SessionStatusText: View {
    @ObservedObject var tab: SessionTab
    /// Whether the session/cipher/device-IP/username line is shown. The
    /// remote controls (state sheep + vendor picker) show regardless.
    var showText: Bool = true
    var onVendorChange: (Vendor) -> Void = { _ in }

    private var text: String {
        switch tab.content {
        case .local:
            return "local · \((LocalTerminalController.userShell() as NSString).lastPathComponent)"
        case .ssh(let controller):
            return tab.statusInfo ?? "connecting to \(controller.host.address)…"
        case .serial(let controller):
            return tab.statusInfo ?? "opening \(controller.host.address)…"
        }
    }

    private var isRemote: Bool {
        switch tab.content {
        case .ssh, .serial: return true
        case .local: return false
        }
    }

    private var isLegacy: Bool {
        tab.statusInfo?.hasSuffix("LEGACY") == true
    }

    private enum ConnectionState {
        case connecting, connected, closed
    }

    private var connectionState: ConnectionState {
        guard let info = tab.statusInfo else { return .connecting }
        // Prefix, not equality: the auto-reconnect budget appends a reason
        // ("disconnected — auto-reconnect limit reached"), and an exact
        // compare put that dead session back on the napping/Connected sheep.
        return info.hasPrefix("disconnected") ? .closed : .connected
    }

    private var connectionStateText: String {
        switch connectionState {
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .closed: return "Disconnected"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if showText {
                Text(text)
                    .foregroundStyle(isLegacy ? Theme.warn : Theme.dimText)
                    .lineLimit(1)
            }
            if isRemote {
                Button {
                    tab.highlightEnabled.toggle() // didSet records the new default
                } label: {
                    Group {
                        switch connectionState {
                        case .connecting:
                            WalkingSheepView()
                        case .connected:
                            SleepingSheepView()
                        case .closed:
                            Text("🐑")
                                .font(.system(size: 12))
                                .opacity(0.25)
                        }
                    }
                    .frame(width: 36, height: 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(connectionStateText) · Highlight \(tab.highlightEnabled ? "ON" : "OFF") — click to toggle (⌘⇧H)")
                // The pack this session colours with, and a one-click way to
                // correct it: a serial console does not announce its vendor,
                // so the first thing you learn about a box is often that it
                // is not the one you expected.
                Menu {
                    ForEach(Vendor.allCases) { family in
                        Toggle(family.label, isOn: Binding(
                            get: { tab.highlightVendor == family },
                            set: { _ in onVendorChange(family) }
                        ))
                    }
                } label: {
                    Text(tab.highlightVendor.badge)
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.dimText)
                .opacity(tab.highlightEnabled ? 1 : 0.4)
                .help("Highlight rules for this session — \(tab.highlightVendor.label)")
            }
        }
    }
}
