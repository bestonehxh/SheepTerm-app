import SwiftUI

/// Manage saved credentials: add new ones and remove old ones.
/// Passwords go straight to the Keychain and are never displayed back.
struct CredentialsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var revealedIDs: Set<UUID> = []
    // Credential waiting on the delete confirmation dialog.
    @State private var pendingDelete: Credential?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Credentials")
                .font(.headline)

            if model.credentialStore.credentials.isEmpty {
                Text("No saved credentials yet")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                List {
                    ForEach(model.credentialStore.credentials) { credential in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(credential.name)
                                Text(credential.username)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if revealedIDs.contains(credential.id) {
                                    Text(model.credentialStore.password(for: credential) ?? "(no password stored)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.warn)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Button {
                                if revealedIDs.contains(credential.id) {
                                    revealedIDs.remove(credential.id)
                                } else {
                                    revealedIDs.insert(credential.id)
                                }
                            } label: {
                                Image(systemName: revealedIDs.contains(credential.id) ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help(revealedIDs.contains(credential.id)
                                  ? "Hide password" : "Show password from Keychain")
                            Button {
                                pendingDelete = credential
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.red)
                            .help("Delete credential")
                        }
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: min(CGFloat(model.credentialStore.credentials.count) * 40 + 20, 200))
            }

            Divider()

            Text("Add Credential")
                .font(.subheadline.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("netops-prod"))
                TextField("Username", text: $username, prompt: Text("admin"))
                RevealableSecureField(title: "Password", text: $password)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Add") { add() }
                    // A credential without a password is useless — every
                    // connect would still prompt interactively.
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear {
            AuthPrompt.forceASCIIKeyboard()
        }
        .alert("Delete credential?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { credential in
            Button("Delete", role: .destructive) { delete(credential) }
            Button("Cancel", role: .cancel) {}
        } message: { credential in
            let count = model.store.hostCount(usingCredential: credential.id)
            if count == 0 {
                Text("“\(credential.name)” is not used by any saved host.")
            } else {
                Text("\(count) saved host\(count == 1 ? "" : "s") use\(count == 1 ? "s" : "") “\(credential.name)”. Deleting it also removes the reference — \(count == 1 ? "that host" : "those hosts") will fall back to manual password entry.")
            }
        }
    }

    private func add() {
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty, !password.isEmpty else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        model.credentialStore.add(
            name: trimmedName.isEmpty ? trimmedUser : trimmedName,
            username: trimmedUser,
            password: password
        )
        name = ""
        username = ""
        password = ""
    }

    /// Removes the credential and clears it from every host that
    /// references it, so no host points at a dead Keychain entry.
    private func delete(_ credential: Credential) {
        model.store.clearCredentialID(credential.id)
        model.credentialStore.remove(credential)
    }
}
