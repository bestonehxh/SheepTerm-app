import SwiftUI

/// Edits an existing host in place (right-click → Edit Host…).
struct HostEditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let original: Host

    @State private var name: String
    @State private var address: String
    @State private var port: String
    @State private var username: String
    @State private var password = ""
    @State private var credentialSelection: UUID?
    @State private var cipherMode: CipherMode
    @State private var agentForward: Bool
    @State private var baud: Int

    private static let baudRates = [9600, 19200, 38400, 57600, 115200, 230400]

    init(host: Host) {
        original = host
        _name = State(initialValue: host.name)
        _address = State(initialValue: host.address)
        _port = State(initialValue: String(host.port))
        _username = State(initialValue: host.username)
        _credentialSelection = State(initialValue: host.credentialID)
        _cipherMode = State(initialValue: host.cipherMode ?? .auto)
        _agentForward = State(initialValue: host.agentForward ?? false)
        _baud = State(initialValue: host.kind == .serial ? host.port : 115200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Host")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                if original.kind == .ssh {
                    TextField("Host / IP", text: $address)
                    TextField("Port", text: $port)
                    if parsedPort == nil {
                        Text("Port must be 1-65535")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                    Picker("Credential", selection: $credentialSelection) {
                        Text("None (enter manually)").tag(UUID?.none)
                        ForEach(model.credentialStore.credentials) { credential in
                            Text("\(credential.name) (\(credential.username))")
                                .tag(UUID?.some(credential.id))
                        }
                    }
                    if credentialSelection == nil {
                        TextField("Username", text: $username)
                        RevealableSecureField(title: "Password", text: $password)
                        Text("Passwords live in the Keychain — filling this saves it as a new credential for this host.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Picker("Cipher mode", selection: $cipherMode) {
                        ForEach(CipherMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Toggle("Forward SSH agent", isOn: $agentForward)
                    Text("Lets this host use your local ssh-agent keys to hop onward. Only enable it for hosts you trust — root there can use the socket while you are connected.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if original.kind == .serial {
                    TextField("Device path", text: $address)
                    Picker("Baud rate", selection: $baud) {
                        ForEach(Self.baudRates, id: \.self) { rate in
                            Text(String(rate)).tag(rate)
                        }
                    }
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            AuthPrompt.forceASCIIKeyboard()
        }
    }

    /// libssh takes the port as UInt32 — reject values it can't
    /// represent instead of trapping at connect time.
    private var parsedPort: Int? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), (1...65535).contains(value) else { return nil }
        return value
    }

    private var isValid: Bool {
        if name.trimmingCharacters(in: .whitespaces).isEmpty
            || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if original.kind == .ssh, parsedPort == nil { return false }
        return true
    }

    private func save() {
        var host = original
        host.name = name.trimmingCharacters(in: .whitespaces)
        host.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        host.username = username.trimmingCharacters(in: .whitespaces)
        switch original.kind {
        case .ssh:
            // isValid already guarantees a parsed in-range port; the
            // fallback only satisfies the compiler.
            host.port = parsedPort ?? 22
            host.credentialID = credentialSelection
            host.cipherMode = cipherMode
            host.agentForward = agentForward
            if credentialSelection == nil, !password.isEmpty {
                let credentialName = username.isEmpty ? host.address : "\(username)@\(host.address)"
                let credential = model.credentialStore.add(
                    name: credentialName,
                    username: username,
                    password: password
                )
                host.credentialID = credential.id
            }
        case .serial:
            host.port = baud
        case .local:
            break
        }
        model.store.updateHost(host)
        dismiss()
    }
}
