import AppKit
import CLibSSH
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Checks whether our third-party libraries have newer versions.
@MainActor
final class LibraryUpdateChecker: ObservableObject {
    @Published var libsshStatus: String?
    @Published var swiftTermStatus: String?
    @Published var checking = false

    var libsshInstalled: String {
        ssh_version(0).map { String(cString: $0) } ?? "unknown"
    }

    func check() {
        checking = true
        libsshStatus = "checking…"
        swiftTermStatus = "checking…"
        Task.detached { [weak self] in
            // Strong for the task's few seconds: the nested MainActor.run
            // closures may not capture the weak var (Swift 6 error).
            guard let self else { return }
            let brew = Self.runBrewOutdated()
            await MainActor.run { self.libsshStatus = brew }
            let swiftTerm = await Self.fetchSwiftTermLatest()
            await MainActor.run {
                self.swiftTermStatus = swiftTerm
                self.checking = false
            }
        }
    }

    nonisolated private static func runBrewOutdated() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/brew")
        process.arguments = ["outdated", "--verbose", "libssh"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return "Homebrew not found on this Mac"
        }
        // Watchdog: a stuck brew (lock file, network) must never hang the
        // settings UI — kill it after 10 s.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        // Drain stderr concurrently so a full stderr buffer can't block the
        // child, then read stdout BEFORE waiting — reading after
        // waitUntilExit deadlocks once the pipe buffer fills.
        let stderrDrain = DispatchWorkItem {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global().async(execute: stderrDrain)
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        stderrDrain.wait()
        process.waitUntilExit()
        watchdog.cancel()
        if output.isEmpty {
            return "✅ up to date (vs local brew index — run `brew update` to refresh)"
        }
        return "⬆️ update available: \(output) — run `brew upgrade libssh`, then rebuild SheepTerm to bundle it"
    }

    nonisolated private static func fetchSwiftTermLatest() async -> String {
        guard let url = URL(string: "https://api.github.com/repos/migueldeicaza/SwiftTerm/releases/latest") else {
            return "?"
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = object["tag_name"] as? String {
                return "latest: \(tag) — update via Xcode ▸ File ▸ Packages ▸ Update to Latest"
            }
            return "could not read GitHub response"
        } catch {
            return "network error: \(error.localizedDescription)"
        }
    }
}

/// Which Settings tab is showing — shared so menu commands can aim the
/// window at a specific tab (Highlight Rules… always lands on Highlight,
/// even if the window was left on General).
@MainActor
final class SettingsTabSelection: ObservableObject {
    static let shared = SettingsTabSelection()
    enum Tab { case general, highlight }
    @Published var tab: Tab = .general
}

struct SettingsView: View {
    @ObservedObject private var selection = SettingsTabSelection.shared

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTabSelection.Tab.general)
            HighlightSettingsView()
                .tabItem { Label("Highlight", systemImage: "highlighter") }
                .tag(SettingsTabSelection.Tab.highlight)
        }
        .frame(width: 700, height: 500)
    }
}

/// General settings: pick the app icon, auto-reconnect, library updates.
struct GeneralSettingsView: View {
    @ObservedObject private var model = AppModel.shared
    @StateObject private var updates = LibraryUpdateChecker()
    // Bumped after Browse… so the custom thumbnail refreshes.
    @State private var customIconStamp = 0
    // Cached thumbnail — reading the file in body would hit disk on every
    // re-render. Reloaded only when the stamp changes.
    @State private var customIcon: NSImage?
    @AppStorage("showRecents") private var showRecents = true
    @AppStorage("recentsShown") private var recentsShown = 5
    @AppStorage(ChromeStyle.storageKey) private var chromeStyle = ChromeStyle.glass

    // V2 is the current wool-family artwork (also the bundle's AppIcon);
    // A/B/C are the original set, kept so nobody loses the icon they liked.
    // Icon D belonged to the removed SheepTermD variant.
    private let iconChoices = ["V2", "A", "B", "C"]

    @ViewBuilder
    private func iconButton(_ choice: String, @ViewBuilder image: () -> some View) -> some View {
        Button {
            model.appIcon = choice
        } label: {
            VStack(spacing: 4) {
                image()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(model.appIcon == choice ? Theme.accent : Color.clear, lineWidth: 3)
                    )
                Text(choice)
                    .font(.system(size: 10, weight: model.appIcon == choice ? .bold : .regular))
            }
        }
        .buttonStyle(.plain)
    }

    private func browseForIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to use as the SheepTerm icon"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if model.setCustomIcon(from: url) {
            customIconStamp += 1
        }
    }

    var body: some View {
        Form {
            Section("App Icon") {
                HStack(spacing: 14) {
                    ForEach(iconChoices, id: \.self) { choice in
                        iconButton(choice) {
                            if let image = NSImage(named: "SheepIcon\(choice)") {
                                Image(nsImage: image)
                                    .resizable()
                                    .interpolation(.high)
                            } else {
                                Color.gray
                            }
                        }
                    }
                    if let custom = customIcon {
                        iconButton("Custom") {
                            Image(nsImage: custom)
                                .resizable()
                                .interpolation(.high)
                        }
                    }
                    Button {
                        browseForIcon()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus.circle.dashed")
                                .font(.system(size: 24))
                                .foregroundStyle(.secondary)
                                .frame(width: 56, height: 56)
                                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                            Text("Browse…")
                                .font(.system(size: 10))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Use your own image as the app icon")
                }
                .frame(maxWidth: .infinity)
                Text("Changes the Dock icon immediately. Browse… imports any image (PNG/JPEG) as your own icon.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Chrome", selection: $chromeStyle) {
                    ForEach(ChromeStyle.allCases) { style in
                        Text(style.label).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                Text("How the sidebar and tab bar are painted. Liquid Glass picks up the desktop behind the window (macOS 26); Solid Color keeps the flat chrome tile. The layout is the same either way — the terminal itself is never translucent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Sidebar") {
                Toggle("Show Recent", isOn: $showRecents)
                Stepper(value: $recentsShown, in: 1...HostStore.maxRecents) {
                    LabeledContent("Recent entries shown") {
                        Text("\(recentsShown)")
                            .font(.system(size: 12, design: .monospaced))
                    }
                }
                .disabled(!showRecents)
                Text("Hides the whole Recent section — header included. SheepTerm remembers at most \(HostStore.maxRecents) recent connections, so that is the ceiling here too.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                Toggle("Auto-reconnect SSH sessions", isOn: $model.autoReconnect)
                Text("When a working session drops, reconnect automatically (3 tries: 2 s / 5 s / 10 s). Keepalives are sent every 60 s to survive device idle-timeouts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Backup") {
                HStack(spacing: 10) {
                    Button {
                        BackupManager.backUp()
                    } label: {
                        Label("Back Up Configuration…", systemImage: "arrow.down.doc")
                    }
                    Button {
                        BackupManager.restore()
                    } label: {
                        Label("Restore…", systemImage: "arrow.up.doc")
                    }
                }
                Text("One file with every group and host, the Recent list, highlight rules, credential names and all app settings. Passwords are never included — they stay in this Mac's Keychain. Restoring replaces the current configuration and copies it aside first.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Libraries") {
                LabeledContent("libssh (bundled)") {
                    Text(updates.libsshInstalled)
                        .font(.system(size: 12, design: .monospaced))
                }
                if let status = updates.libsshStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("SwiftTerm") {
                    Text("Swift Package Manager")
                        .foregroundStyle(.secondary)
                }
                if let status = updates.swiftTermStatus {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Button {
                    updates.check()
                } label: {
                    if updates.checking {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        }
                    } else {
                        Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(updates.checking)
            }
        }
        .formStyle(.grouped)
        .padding(4)
        .onAppear {
            customIcon = NSImage(contentsOf: AppModel.customIconURL)
        }
        .onChange(of: customIconStamp) {
            customIcon = NSImage(contentsOf: AppModel.customIconURL)
        }
    }
}

/// Settings (⌘,) — configure the optimized built-in highlight rules.
struct HighlightSettingsView: View {
    @ObservedObject private var store = AppModel.shared.highlightStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Highlight Rules")
                    .font(.headline)
                Text("Optimized built-in rules only. Enable, recolor, make bold, or reorder them; changes apply to new output immediately.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            List {
                ForEach($store.configs) { $config in
                    HighlightRuleRow(config: $config)
                }
                .onMove { from, to in
                    store.configs.move(fromOffsets: from, toOffset: to)
                }
            }

            HStack {
                Spacer()
                Button("Reset to Defaults") {
                    store.resetToDefaults()
                }
            }
            .padding(12)
        }
    }
}

struct HighlightRuleRow: View {
    @Binding var config: HighlightRuleConfig

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $config.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Enable rule")
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name)
                    .font(.system(size: 12, weight: .medium))
                Text("Built-in scanner")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34)
            Toggle("B", isOn: $config.bold)
                .toggleStyle(.checkbox)
                .font(.system(size: 11, weight: .bold))
                .help("Bold")
        }
        .padding(.vertical, 2)
        .opacity(config.enabled ? 1 : 0.5)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let hex = UInt32(config.colorHex, radix: 16) ?? 0xFFFFFF
                return Color(
                    red: Double((hex >> 16) & 0xFF) / 255,
                    green: Double((hex >> 8) & 0xFF) / 255,
                    blue: Double(hex & 0xFF) / 255
                )
            },
            set: { newColor in
                guard let rgb = NSColor(newColor).usingColorSpace(.sRGB) else { return }
                config.colorHex = String(
                    format: "%02X%02X%02X",
                    Int(rgb.redComponent * 255),
                    Int(rgb.greenComponent * 255),
                    Int(rgb.blueComponent * 255)
                )
            }
        )
    }
}
