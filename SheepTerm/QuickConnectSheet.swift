import Foundation
import SwiftUI

/// Form for ad-hoc SSH / Serial connections from the + menu.
/// Supports saved credentials (Keychain-backed), a target group picker,
/// and an optional "save session" toggle.
struct QuickConnectSheet: View {
    let kind: ConnectionKind

    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    // Connection
    @State private var name = ""
    @State private var address = ""
    @State private var port = "22"

    // Credential
    @State private var credentialSelection: UUID?   // nil = enter manually
    @State private var username = ""
    @State private var password = ""
    @State private var saveCredential = false
    @State private var credentialName = ""
    @State private var cipherMode: CipherMode = .auto
    @State private var agentForward = false

    // Serial
    @State private var device = ""
    @State private var baud = 115200
    @State private var devices: [String] = []

    // Save session — off by default: Recent already remembers ad-hoc
    // connections; saving to a group is an explicit choice.
    @State private var saveSession = false
    @State private var groupSelection = QuickConnectSheet.defaultGroup
    @State private var newGroupName = ""
    @State private var saveLog = UserDefaults.standard.object(forKey: "logSessions") as? Bool ?? true

    private static let defaultGroup = "Quick Connect"
    private static let newGroupTag = "\u{0}new-group"
    private static let baudRates = [9600, 19200, 38400, 57600, 115200, 230400]

    private var groupNames: [String] {
        var names = model.store.groups.map(\.name)
        if !names.contains(Self.defaultGroup) {
            names.insert(Self.defaultGroup, at: 0)
        }
        return names
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(kind == .ssh ? "New SSH Connection" : "New Serial Console")
                .font(.headline)

            Form {
                if kind == .ssh {
                    TextField("Host / IP", text: $address, prompt: Text("10.10.1.1"))
                    TextField("Port", text: $port, prompt: Text("22"))
                    if let portError {
                        Text(portError)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }

                    Picker("Credential", selection: $credentialSelection) {
                        Text("Enter manually").tag(UUID?.none)
                        ForEach(model.credentialStore.credentials) { credential in
                            Text("\(credential.name) (\(credential.username))")
                                .tag(UUID?.some(credential.id))
                        }
                    }

                    if credentialSelection == nil {
                        TextField("Username", text: $username, prompt: Text("admin"))
                        RevealableSecureField(title: "Password", text: $password)
                        Toggle("Save as credential", isOn: $saveCredential)
                        if saveCredential {
                            TextField("Credential name", text: $credentialName,
                                      prompt: Text(defaultCredentialName))
                        }
                    }

                    Picker("Cipher mode", selection: $cipherMode) {
                        ForEach(CipherMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }

                    Toggle("Forward SSH agent", isOn: $agentForward)

                    TextField("Session name (optional)", text: $name)
                } else {
                    HStack {
                        Picker("Device", selection: $device) {
                            if devices.isEmpty {
                                Text("No serial device found").tag("")
                            }
                            ForEach(devices, id: \.self) { path in
                                Text((path as NSString).lastPathComponent).tag(path)
                            }
                        }
                        Button {
                            devices = Self.serialDevices()
                            if !devices.contains(device) {
                                device = devices.first ?? ""
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13))
                                .frame(width: 30, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Rescan serial devices (plug the console cable into a powered switch first)")
                    }
                    Picker("Baud rate", selection: $baud) {
                        ForEach(Self.baudRates, id: \.self) { rate in
                            Text(String(rate)).tag(rate)
                        }
                    }
                }

                Divider()

                if kind == .ssh {
                    Toggle("Save session to group", isOn: $saveSession)
                    if saveSession {
                        Picker("Group", selection: $groupSelection) {
                            ForEach(groupNames, id: \.self) { name in
                                Text(name).tag(name)
                            }
                            Divider()
                            Text("New group…").tag(Self.newGroupTag)
                        }
                        if groupSelection == Self.newGroupTag {
                            TextField("Group name", text: $newGroupName, prompt: Text("Branch — BKK"))
                        }
                    }
                } else {
                    Toggle("Save session log", isOn: $saveLog)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { connect() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            // Switch to an English layout before any secure field grabs
            // focus — macOS blocks input-source switching during secure input.
            AuthPrompt.forceASCIIKeyboard()
            guard kind == .serial else { return }
            devices = Self.serialDevices()
            device = devices.first ?? ""
        }
    }

    private var defaultCredentialName: String {
        username.isEmpty ? "credential" : "\(username)@\(trimmedAddress)"
    }

    /// Address with surrounding whitespace/newlines stripped — pasted
    /// values often carry a trailing newline.
    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// libssh takes the port as UInt32 — reject values it can't
    /// represent instead of trapping at connect time.
    private var parsedPort: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65535).contains(value) else { return nil }
        return value
    }

    private var portError: String? {
        guard kind == .ssh, parsedPort == nil else { return nil }
        return "Port must be 1-65535"
    }

    private var isValid: Bool {
        switch kind {
        case .ssh:
            return parsedPort != nil && !trimmedAddress.isEmpty
        default: return !device.isEmpty
        }
    }

    private var targetGroup: String? {
        guard kind == .ssh, saveSession else { return nil }
        if groupSelection == Self.newGroupTag {
            let trimmed = newGroupName.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? Self.defaultGroup : trimmed
        }
        return groupSelection
    }

    private func connect() {
        let host: Host
        if kind == .ssh {
            var hostUsername = username
            var credentialID = credentialSelection

            if let selected = model.credentialStore.credential(for: credentialSelection) {
                hostUsername = selected.username
            } else if saveCredential {
                let credential = model.credentialStore.add(
                    name: credentialName.isEmpty ? defaultCredentialName : credentialName,
                    username: username,
                    password: password
                )
                credentialID = credential.id
            }

            host = Host(
                name: name.isEmpty ? trimmedAddress : name,
                kind: .ssh,
                address: trimmedAddress,
                // isValid already guarantees a parsed in-range port; the
                // fallback only satisfies the compiler.
                port: parsedPort ?? 22,
                username: hostUsername,
                credentialID: credentialID,
                cipherMode: cipherMode,
                agentForward: agentForward
            )
        } else {
            host = Host(
                name: (device as NSString).lastPathComponent,
                kind: .serial,
                address: device,
                port: baud
            )
        }
        let sessionPassword: String?
        if kind == .ssh, credentialSelection == nil, !password.isEmpty {
            sessionPassword = password
        } else {
            sessionPassword = nil
        }
        model.connectQuick(
            host: host,
            saveTo: targetGroup,
            password: sessionPassword,
            serialLog: kind == .serial ? saveLog : nil
        )
        dismiss()
    }

    private static func serialDevices() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("cu.") && $0 != "cu.Bluetooth-Incoming-Port" }
            .map { "/dev/" + $0 }
            .sorted()
    }
}
