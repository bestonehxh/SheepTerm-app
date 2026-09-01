import AppKit
import Combine
import Foundation
import Security

struct Credential: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var username: String
}

/// Credential metadata lives in credentials.json; the password itself only
/// ever lives in the macOS Keychain, keyed by the credential's UUID.
@MainActor
final class CredentialStore: ObservableObject {
    @Published var credentials: [Credential]

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("credentials.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([Credential].self, from: data) {
            credentials = decoded
        } else {
            credentials = []
        }
    }

    /// Re-reads credentials.json after a backup restore. Passwords are not
    /// part of a backup, so a credential restored from another Mac has no
    /// Keychain entry here until the user types it once.
    func reloadFromDisk() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([Credential].self, from: data) {
            credentials = decoded
        } else {
            credentials = []
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Swallowing this with try? left credentials.json silently out of
        // sync with what the UI shows as saved — the failure has to reach
        // the person editing, the same way a Keychain write failure does
        // below, or they lose data with no clue why.
        do {
            let data = try encoder.encode(credentials)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            Self.reportSaveFailure(error)
        }
    }

    private static func reportSaveFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Credentials not saved"
        alert.informativeText = """
            SheepTerm could not write credentials.json (\(error.localizedDescription)). \
            Recent changes to your saved hosts may be lost the next time SheepTerm quits.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @discardableResult
    func add(name: String, username: String, password: String) -> Credential {
        let credential = Credential(name: name, username: username)
        credentials.append(credential)
        save()
        // The Keychain CAN refuse (locked keychain, denied access). Saying
        // nothing left the credential listed as if it had a password, and
        // every connect would then prompt with no clue why — the failure has
        // to reach the person who just typed it, not only the log.
        if !password.isEmpty, !Keychain.setPassword(password, for: credential.id) {
            Self.reportKeychainFailure(for: credential)
        }
        return credential
    }

    private static func reportKeychainFailure(for credential: Credential) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Password not saved to the Keychain"
        alert.informativeText = """
            “\(credential.name)” was saved, but macOS refused to store its \
            password. SheepTerm will ask for it on every connection until \
            the credential is added again with the Keychain unlocked.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func credential(for id: UUID?) -> Credential? {
        guard let id else { return nil }
        return credentials.first { $0.id == id }
    }

    func password(for credential: Credential) -> String? {
        Keychain.password(for: credential.id)
    }

    func remove(_ credential: Credential) {
        credentials.removeAll { $0.id == credential.id }
        save()
        Keychain.deletePassword(for: credential.id)
    }
}

enum Keychain {
    private static let service = "Bestchaan.SheepTerm"

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func baseQuery(for id: UUID) -> [String: Any] {
        baseQuery(account: id.uuidString)
    }

    /// Returns whether the value actually landed in the Keychain. The add
    /// status must be checked: an ignored failure would silently lose the
    /// password while callers report success.
    ///
    /// Deliberately updates in place rather than delete-then-add: a bare
    /// SecItemDelete followed by a failed SecItemAdd (locked keychain,
    /// denied access) used to destroy the previous, working password before
    /// ever confirming the new one was stored. SecItemUpdate has no such
    /// window. Delete+add is kept only as a fallback for the case where
    /// there is genuinely no existing item to update, and even then the
    /// previous value is captured first so a failed add can be undone.
    @discardableResult
    private static func set(_ password: String, baseQuery: [String: Any]) -> Bool {
        let newData = Data(password.utf8)
        let account = baseQuery[kSecAttrAccount as String] as? String ?? "?"

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary,
                                          [kSecValueData as String: newData] as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            NSLog("SheepTerm: Keychain write failed (status %d) for account %@", updateStatus, account)
            return false
        }

        // Nothing existed to update, so an add is safe. Still read whatever
        // might be there first — costs nothing, and guarantees the failure
        // path below has a correct value to restore rather than assuming
        // "not found" means "nothing to lose".
        let previous = get(baseQuery: baseQuery)
        SecItemDelete(baseQuery as CFDictionary)
        var attributes = baseQuery
        attributes[kSecValueData as String] = newData
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return true
        }
        NSLog("SheepTerm: Keychain write failed (status %d) for account %@", addStatus, account)
        if let previous {
            var restoreAttributes = baseQuery
            restoreAttributes[kSecValueData as String] = Data(previous.utf8)
            SecItemAdd(restoreAttributes as CFDictionary, nil)
        }
        return false
    }

    private static func get(baseQuery: [String: Any]) -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Returns false when the password did not land in the Keychain —
    /// callers must surface that, never swallow it.
    @discardableResult
    static func setPassword(_ password: String, for id: UUID) -> Bool {
        set(password, baseQuery: baseQuery(for: id))
    }

    static func password(for id: UUID) -> String? {
        get(baseQuery: baseQuery(for: id))
    }

    static func deletePassword(for id: UUID) {
        SecItemDelete(baseQuery(for: id) as CFDictionary)
    }
}
