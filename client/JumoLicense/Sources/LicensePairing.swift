import Foundation
import CryptoKit

/// This is an installation identifier, never proof of physical device identity.
struct JumoInstallation: Codable, Equatable {
    let id: String
    let bundleID: String

    func validate() throws {
        guard let uuid = UUID(uuidString: id), uuid.uuidString == id,
              (1...255).contains(bundleID.utf8.count),
              bundleID.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || [45, 46, 95].contains(byte)
              }) else { throw JumoLicenseError.input }
    }
}

/// A transferable authorization number with a typo checksum, not a credential,
/// hardware binding, signature, or successful license response. Card + online
/// verification are always required to activate another installation.
enum JumoPairing {
    static func encode(machine raw: String) throws -> String {
        let machine = try JumoProtocol.normalizeMachine(raw)
        let payload = Data(machine.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let body = "BM1." + payload
        let checksum = SHA256.hash(data: Data(body.utf8)).prefix(8)
            .map { String(format: "%02X", Int($0)) }.joined()
        return body + "." + checksum
    }

    static func decode(_ raw: String) throws -> String {
        guard raw.utf8.count <= 2048 else { throw JumoLicenseError.pairing }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "BM1", !parts[1].isEmpty,
              parts[1].utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 45 || byte == 95
              }) else { throw JumoLicenseError.pairing }
        let payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let bytes = Data(base64Encoded: payload + padding),
              let machine = String(data: bytes, encoding: .utf8),
              let canonical = try? encode(machine: machine), canonical == trimmed
        else { throw JumoLicenseError.pairing }
        return try JumoProtocol.normalizeMachine(machine)
    }
}
