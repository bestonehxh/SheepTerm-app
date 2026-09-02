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

    /// Set when credentials.json was unreadable at load: blocks automatic
    /// writes until the user explicitly changes something.
    ///
    /// This file is the POINTER to every password in the Keychain. Loading
    /// it as an empty list and then saving over it — which is what the old
    /// `try?`-and-fall-back-to-`[]` did on any transient read failure —
    /// destroys the names and usernames AND orphans every Keychain item,
    /// because the items are keyed by the UUIDs that just went away. Nothing
    /// in the app can reach an orphaned item again. So credentials.json now
    /// gets the same treatment hosts.json has always had: the unreadable
    /// original is preserved, writes stop until the user acts, and every
    /// write leaves a .bak behind.
    private var suppressWritesAfterCorruptLoad = false

    init() {
        let (loaded, warning) = Self.load()
        credentials = loaded
        suppressWritesAfterCorruptLoad = warning != nil
        if let warning { Self.reportCorruptLoad(warning) }
    }

    /// Re-reads credentials.json after a backup restore.
    ///
    /// Passwords are not part of a backup, so a credential restored from
    /// another Mac has no Keychain entry here. NOTE: it will be prompted for
    /// on EVERY connection, not stored after the first — `Keychain.setPassword`
    /// has exactly one caller, `add(name:username:password:)`, and there is no
    /// re-save path. The doc used to claim otherwise. Editing the credential
    /// and entering the password stores it; that is the way to fix it today.
    func reloadFromDisk() {
        let (loaded, warning) = Self.load()
        credentials = loaded
        suppressWritesAfterCorruptLoad = warning != nil
        if let warning { Self.reportCorruptLoad(warning) }
    }

    /// A missing file is normal (fresh install). A file that exists but does
    /// not decode is data the user had, so it is preserved rather than
    /// overwritten — same rule, same naming, as HostStore.loadList.
    private static func load() -> (value: [Credential], warning: String?) {
        guard let data = try? Data(contentsOf: fileURL) else { return ([], nil) }
        do {
            return (try JSONDecoder().decode([Credential].self, from: data), nil)
        } catch {
            let corruptURL = fileURL.appendingPathExtension("corrupt-\(corruptStamp())")
            do {
                try FileManager.default.moveItem(at: fileURL, to: corruptURL)
            } catch {
                NSLog("SheepTerm: could not move corrupt credentials.json aside: %@",
                      error.localizedDescription)
            }
            let warning = "credentials.json was unreadable; the original was preserved as \(corruptURL.lastPathComponent). Your saved passwords are still in the Keychain, but SheepTerm cannot see which is which until the file is restored or the credentials are re-added."
            NSLog("SheepTerm: %@ (decode error: %@)", warning, error.localizedDescription)
            return ([], warning)
        }
    }

    /// A timestamp that ends up in a FILE NAME is always Gregorian + POSIX,
    /// for the reason spelled out on HostStore.corruptStamp.
    private static func corruptStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// Re-arms saving after a corrupt load. Every mutator calls this: an
    /// automatic write must not overwrite the rescued file, but a change the
    /// user just made deliberately should.
    private func noteUserMutation() {
        suppressWritesAfterCorruptLoad = false
    }

    func save() {
        guard !suppressWritesAfterCorruptLoad else {
            NSLog("SheepTerm: write to credentials.json suppressed until the first user change (corrupt previous file was preserved)")
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Swallowing this with try? left credentials.json silently out of
        // sync with what the UI shows as saved — the failure has to reach
        // the person editing, the same way a Keychain write failure does
        // below, or they lose data with no clue why.
        do {
            let data = try encoder.encode(credentials)
            if FileManager.default.fileExists(atPath: Self.fileURL.path) {
                let backupURL = Self.fileURL.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backupURL)
                do {
                    try FileManager.default.copyItem(at: Self.fileURL, to: backupURL)
                } catch {
                    NSLog("SheepTerm: could not back up credentials.json: %@",
                          error.localizedDescription)
                }
            }
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            Self.reportSaveFailure(error)
        }
    }

    private static func reportCorruptLoad(_ warning: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Saved credentials could not be read"
        alert.informativeText = warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
        noteUserMutation()
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
        noteUserMutation()
        credentials.removeAll { $0.id == credential.id }
        save()
        // Delete the secret only after its metadata is safely gone. If the
        // Keychain refuses (locked, denied), the item would otherwise stay
        // forever with nothing left that can name it — so say so.
        if !Keychain.deletePassword(for: credential.id) {
            Self.reportKeychainDeleteFailure(for: credential)
        }
    }

    private static func reportKeychainDeleteFailure(for credential: Credential) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Password not removed from the Keychain"
        alert.informativeText = """
            “\(credential.name)” was removed from SheepTerm, but macOS refused \
            to delete its stored password. It is still in your login keychain \
            under “Bestchaan.SheepTerm” and SheepTerm can no longer reach it — \
            remove it in Keychain Access if you want it gone.
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    /// Reports success so the caller can tell the user: a refused delete
    /// leaves the secret in the keychain with its metadata already gone, and
    /// nothing in the app can name it again.
    @discardableResult
    static func deletePassword(for id: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(for: id) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
