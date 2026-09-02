import AppKit
import UniformTypeIdentifiers

/// One-file backup of a whole SheepTerm configuration: every group and
/// host, the recents list, credential *metadata*, the custom icon, and the
/// app's settings.
///
/// **Passwords are deliberately not in it.** They live only in the macOS
/// Keychain (service `Bestchaan.SheepTerm`) and a backup file is meant to
/// be copied around — putting them in would turn every backup into a
/// plaintext password store. After restoring on another Mac, SheepTerm has
/// no password for those credentials and prompts on EVERY connection: there
/// is no path that stores a password typed at a connect prompt. Re-entering
/// the credential in Settings is what puts it in that Mac's Keychain.
@MainActor
enum BackupManager {
    static let fileExtension = "sheeptermbackup"
    /// Bump only for a change old builds could not read.
    static let currentFormat = 1

    /// The files under Application Support that make up a configuration.
    /// A missing one is normal (no custom icon, no credentials yet) and is
    /// simply left out of the backup.
    private static let fileNames = [
        "hosts.json", "recents.json",
        "credentials.json", "custom-icon.png",
    ]

    /// Settings carried across — an explicit list on purpose. Copying the
    /// whole UserDefaults domain would also drag window frames and
    /// SwiftUI's own bookkeeping onto the other Mac.
    private static let settingKeys = [
        // "didMigrateIconToV2" travels with "appIcon": without it a restore
        // onto a fresh Mac would re-run the one-time B -> V2 move and stomp a
        // deliberate choice of icon B.
        "appIcon", "didMigrateIconToV2",
        "appearanceMode", "autoReconnect", "chromeStyle", "collapsedGroups",
        "highlightDefault", "logSessions", "recentsShown", "showRecents",
        "safePasteDelayMilliseconds", "safePasteEnabled",
        "showStatusBar", "sidebarWidth", "statusShowClock", "statusShowHints",
        "statusShowIP", "statusShowSession", "terminalTheme",
        "TSMLanguageIndicatorEnabled",
    ]

    private static var baseDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheepTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    // MARK: Payload

    /// A UserDefaults value, kept typed so a Bool doesn't come back as 1.
    enum Setting: Codable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case strings([String])

        private enum CodingKeys: String, CodingKey { case type, value }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(String.self, forKey: .type) {
            case "bool": self = .bool(try container.decode(Bool.self, forKey: .value))
            case "int": self = .int(try container.decode(Int.self, forKey: .value))
            case "double": self = .double(try container.decode(Double.self, forKey: .value))
            case "string": self = .string(try container.decode(String.self, forKey: .value))
            case "strings": self = .strings(try container.decode([String].self, forKey: .value))
            default:
                throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                       debugDescription: "unknown setting type")
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .bool(let value):
                try container.encode("bool", forKey: .type); try container.encode(value, forKey: .value)
            case .int(let value):
                try container.encode("int", forKey: .type); try container.encode(value, forKey: .value)
            case .double(let value):
                try container.encode("double", forKey: .type); try container.encode(value, forKey: .value)
            case .string(let value):
                try container.encode("string", forKey: .type); try container.encode(value, forKey: .value)
            case .strings(let value):
                try container.encode("strings", forKey: .type); try container.encode(value, forKey: .value)
            }
        }

        var objectValue: Any {
            switch self {
            case .bool(let value): return value
            case .int(let value): return value
            case .double(let value): return value
            case .string(let value): return value
            case .strings(let value): return value
            }
        }
    }

    struct Payload: Codable {
        var format: Int
        var app: String
        var created: Date
        var device: String
        /// Raw file contents, keyed by file name (Data is base64 in JSON).
        var files: [String: Data]
        var settings: [String: Setting]

        var groupCount: Int {
            guard let data = files["hosts.json"],
                  let groups = try? JSONDecoder().decode([HostGroup].self, from: data) else { return 0 }
            return groups.count
        }

        var hostCount: Int {
            guard let data = files["hosts.json"],
                  let groups = try? JSONDecoder().decode([HostGroup].self, from: data) else { return 0 }
            return groups.reduce(0) { $0 + $1.hosts.count }
        }
    }

    // MARK: Making one

    static func makePayload() -> Payload {
        var files: [String: Data] = [:]
        for name in fileNames {
            let url = baseDirectory.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url) { files[name] = data }
        }

        let settings = currentSettings()

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return Payload(
            format: currentFormat,
            app: "SheepTerm \(version) (\(build))",
            created: Date(),
            device: ShareCodec.deviceName,
            files: files,
            settings: settings
        )
    }

    /// File → Back Up Configuration…
    static func backUp() {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.nameFieldStringValue = "SheepTerm-\(fileStamp("yyyy-MM-dd")).\(fileExtension)"
        panel.message = "Groups, hosts and settings. Passwords stay in your Keychain and are not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(makePayload())
            try data.write(to: url, options: .atomic)
        } catch {
            report("Could not write the backup", error.localizedDescription, style: .warning)
        }
    }

    // MARK: Restoring one

    /// File → Restore Configuration…
    static func restore() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.json]
        if let type = UTType(filenameExtension: fileExtension) { types.insert(type, at: 0) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SheepTerm backup to restore"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            report("That file is not a SheepTerm backup",
                   "It could not be read as one. Nothing was changed.", style: .warning)
            return
        }
        guard payload.format <= currentFormat else {
            report("This backup is from a newer SheepTerm",
                   "Update SheepTerm and try again. Nothing was changed.", style: .warning)
            return
        }

        let stamp = DateFormatter()
        // Dates SHOWN to the user are Gregorian too, not just the ones in
        // file names: a Thai-locale Mac would otherwise date the backup
        // "18 ส.ค. 2569". Only the calendar is pinned — month names and
        // ordering still follow the machine's language.
        stamp.calendar = Calendar(identifier: .gregorian)
        stamp.dateStyle = .medium
        stamp.timeStyle = .short
        let alert = NSAlert()
        alert.messageText = "Restore this backup?"
        alert.informativeText = """
            \(payload.app) · \(payload.device) · \(stamp.string(from: payload.created))
            \(payload.groupCount) groups, \(payload.hostCount) hosts.

            This replaces every group, host and setting in SheepTerm. Your current \
            hosts, credentials list and settings are copied aside \
            first, so nothing is lost for good. Passwords are not part of a backup — \
            they stay in the Keychain of the Mac they were saved on, so a credential \
            restored from another Mac will ask for its password on every connection \
            until you re-enter it in Settings.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let safety = snapshotCurrent()
        apply(payload)
        AppModel.shared.reloadAfterRestore()

        let done = NSAlert()
        done.messageText = "Configuration restored"
        done.informativeText = safety.map {
            "Your previous configuration is in \($0.lastPathComponent) inside SheepTerm's Application Support folder."
        } ?? "Your previous configuration was empty, so nothing was set aside."
        done.addButton(withTitle: "OK")
        if safety != nil { done.addButton(withTitle: "Show Backup Folder") }
        if done.runModal() == .alertSecondButtonReturn, let safety {
            NSWorkspace.shared.activateFileViewerSelecting([safety])
        }
    }


    /// The app's settings as the payload stores them. Shared by the backup
    /// itself and by the pre-restore snapshot, which has to capture the same
    /// thing a restore can overwrite.
    private static func currentSettings() -> [String: Setting] {
        var settings: [String: Setting] = [:]
        let defaults = UserDefaults.standard
        for key in settingKeys {
            guard let object = defaults.object(forKey: key) else { continue }
            switch object {
            // NSNumber is Bool, Int and Double all at once, so ask the
            // number itself which one it actually holds.
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    settings[key] = .bool(number.boolValue)
                } else if CFNumberIsFloatType(number) {
                    settings[key] = .double(number.doubleValue)
                } else {
                    settings[key] = .int(number.intValue)
                }
            case let text as String:
                settings[key] = .string(text)
            case let list as [String]:
                settings[key] = .strings(list)
            default:
                continue
            }
        }
        return settings
    }

    /// Copies the current configuration into a dated folder before a
    /// restore overwrites it. Returns the folder, or nil when there was
    /// nothing to copy.
    private static func snapshotCurrent() -> URL? {
        let folder = baseDirectory.appendingPathComponent("pre-restore-\(fileStamp("yyyyMMdd-HHmmss"))",
                                                          isDirectory: true)
        var copied = false
        for name in fileNames {
            let source = baseDirectory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            if !copied {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            // Only a copy that LANDED counts. `copied = true` regardless
            // meant a second restore in the same second — same folder name,
            // every copy refused with "file exists" — still told the user
            // their previous configuration was safely in that folder.
            do {
                try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent(name))
                copied = true
            } catch {
                NSLog("SheepTerm: pre-restore copy of %@ failed: %@", name, error.localizedDescription)
            }
        }
        // Settings are part of what a restore overwrites, so they are part of
        // what "copied aside first, so nothing is lost for good" has to mean.
        // Written in the same shape a payload uses, so it can be restored by
        // importing this folder's file like any other backup.
        let settings = currentSettings()
        if !settings.isEmpty {
            if !copied {
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(settings) {
                try? data.write(to: folder.appendingPathComponent("settings.json"), options: .atomic)
                copied = true
            }
        }
        return copied ? folder : nil
    }

    /// Writes the payload over the live configuration. Files that the
    /// backup does not carry are removed, so restoring a configuration with
    /// no custom icon doesn't leave the old one behind.
    private static func apply(_ payload: Payload) {
        for name in fileNames {
            let url = baseDirectory.appendingPathComponent(name)
            if let data = payload.files[name] {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let defaults = UserDefaults.standard
        for key in settingKeys {
            if let setting = payload.settings[key] {
                defaults.set(setting.objectValue, forKey: key)
            }
            // A key the payload does not carry is LEFT ALONE. Clearing it
            // meant restoring a backup taken before a setting existed reset
            // that setting to its default — and since the pre-restore
            // snapshot only copies files, never UserDefaults, there was
            // nothing to undo it with. A backup restores what it contains.
        }
    }

    /// Timestamps that end up in file names are always Gregorian and
    /// POSIX-formatted — a Thai locale would otherwise name the backup
    /// "SheepTerm-2569-08-23" and sort it nowhere near the others.
    private static func fileStamp(_ format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter.string(from: Date())
    }

    private static func report(_ title: String, _ detail: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
