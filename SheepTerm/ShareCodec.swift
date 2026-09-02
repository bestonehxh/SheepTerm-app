import Foundation

/// The .sheepterm file format. Credentials never travel: only host
/// structure is included, credential references are stripped.
struct SharePayload: Codable {
    var version = 1
    var sender: String
    var group: HostGroup
}

enum ShareCodec {
    static func encode(_ group: HostGroup, sender: String) throws -> Data {
        var sanitized = group
        sanitized.hosts = group.hosts.map { host in
            var copy = host
            copy.credentialID = nil
            return copy
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(SharePayload(sender: sender, group: sanitized))
    }

    static func decode(_ data: Data) throws -> SharePayload {
        var payload = try JSONDecoder().decode(SharePayload.self, from: data)
        // Strip on the way IN as well. encode() drops credentialID, but a
        // hand-edited or third-party file can carry one, and an imported host
        // that points at a local credential would connect with a password the
        // sender never had. "Credentials never travel" has to be true of the
        // files we read, not only the ones we write.
        payload.group.hosts = payload.group.hosts.map { host in
            var copy = host
            copy.credentialID = nil
            return copy
        }
        return payload
    }

    static var deviceName: String {
        Foundation.Host.current().localizedName ?? "Mac"
    }
}
