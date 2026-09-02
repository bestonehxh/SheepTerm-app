import SwiftUI

/// Edits an existing host in place (right-click → Edit Host…).
struct HostEditSheet: View {
    @EnvironmentObject var model: AppModel
    /// Observed explicitly: `credentials` is @Published on CredentialStore,
    /// not on AppModel, so observing `model` alone never redraws this list.
    /// It looked fine only because every interaction happened to touch some
    /// local @State as well.
    @ObservedObject private var credentialStore = AppModel.shared.credentialStore
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
    @State private var vendor: Vendor
    @State private var baud: Int

    private static let baudRates = [9600, 19200, 38400, 57600, 115200, 230400]
    /// Console ports on network gear are 9600 8N1 out of the box — Cisco,
    /// Aruba, Huawei and Juniper all ship that way.
    private static let defaultBaud = 9600

    init(host: Host) {
        original = host
        _name = State(initialValue: host.name)
        _address = State(initialValue: host.address)
        _port = State(initialValue: String(host.port))
        _username = State(initialValue: host.username)
        _credentialSelection = State(initialValue: host.credentialID)
        _cipherMode = State(initialValue: host.cipherMode ?? .auto)
        _agentForward = State(initialValue: host.agentForward ?? false)
        _vendor = State(initialValue: host.highlightVendor)
        _baud = State(initialValue: host.kind == .serial ? host.port : Self.defaultBaud)
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
                Picker("Device family", selection: $vendor) {
                    ForEach(Vendor.allCases) { family in
                        Text(family.label).tag(family)
                    }
                }
                Text("Picks the highlight rules. Auto colours only what every device shares — addresses, masks, MACs, VLAN ids, up/down. Naming the family adds its port names and reads its state words the way that platform means them.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
        host.vendor = vendor
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
        // The cached password belongs to the OLD user@address:port.
        if let old = model.store.groups.flatMap(\.hosts).first(where: { $0.id == host.id }) {
            model.forgetCachedPassword(for: old)
        }
        model.store.updateHost(host)
        dismiss()
    }
}
