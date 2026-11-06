import Foundation
import Security
import Darwin

enum JumoKeychain {
    // Ordinary host-private Keychain; no additional host entitlements.
    // Also namespace by host bundle, even if its pre-existing default group is
    // shared with a sibling app. Each host must still have its own instance ID.
    static var service: String {
        "site.czongz.JUMO.baiming.pairing.v3." + (Bundle.main.bundleIdentifier ?? "missing-bundle")
    }

    struct Credentials: Codable {
        let machine: String
        let card: String
        var lease: JumoLease?
        var blockedMessage: String?
    }

    static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: account, kSecAttrSynchronizable: false]
    }

    static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw JumoLicenseError.storage }
    }

    static func readData(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw JumoLicenseError.storage }
        return data
    }

    static func read(_ account: String) throws -> String? {
        guard let data = try readData(account) else { return nil }
        guard let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw JumoLicenseError.storage }
        return value
    }

    static func saveData(_ account: String, data: Data) throws {
        let attributes: [CFString: Any] = [kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(account)
            for (key, value) in attributes { request[key] = value }
            status = SecItemAdd(request as CFDictionary, nil)
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
            }
        }
        try check(status)
    }

    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func getOrCreate(_ account: String, candidate: String) throws -> String {
        if let existing = try read(account) { return existing }
        var request = query(account)
        request[kSecValueData] = Data(candidate.utf8)
        request[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        if status == errSecDuplicateItem, let winner = try read(account) { return winner }
        try check(status)
        return candidate
    }

    static func credentials() throws -> Credentials? {
        guard let raw = try readData("credentials") else { return nil }
        let value = try JSONDecoder().decode(Credentials.self, from: raw)
        guard try JumoProtocol.normalizeMachine(value.machine) == value.machine,
              try JumoProtocol.normalizeKey(value.card) == value.card else { throw JumoLicenseError.storage }
        return value
    }

    // One update commits the new identity, card, and verified response together.
    static func saveCredentials(_ value: Credentials) throws {
        try saveData("credentials", data: JSONEncoder().encode(value))
    }

    static func machineCode() throws -> String {
        if let active = try credentials() { return active.machine }
        let previous = try? previousMachine()
        let candidate = previous ?? ("JUMO-" + UUID().uuidString)
        return try JumoProtocol.normalizeMachine(getOrCreate("machine-code", candidate: candidate))
    }

    private static func previousMachine() throws -> String? {
        // Only the preceding private JUMO identity is eligible for migration.
        let request: [CFString: Any] = [kSecClass: kSecClassGenericPassword,
            kSecAttrService: "site.czongz.JUMO.license.v1", kSecAttrAccount: "machine-code",
            kSecAttrSynchronizable: false, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let bytes = value as? Data, let text = String(data: bytes, encoding: .utf8) else { return nil }
        return try JumoProtocol.normalizeMachine(text)
    }

    static func installation(bundleID: String) throws -> JumoInstallation {
        let value = JumoInstallation(id: try getOrCreate("installation-id", candidate: UUID().uuidString), bundleID: bundleID)
        try value.validate()
        return value
    }

    static func bootIdentifier() throws -> String {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0
        else { throw JumoLicenseError.storage }
        return "\(boot.tv_sec):\(boot.tv_usec)"
    }

    struct Backoff: Codable { let boot: String; let until: TimeInterval; let failures: Int }

    static func backoff(boot: String) throws -> Backoff? {
        guard let raw = try readData("backoff") else { return nil }
        let value = try JSONDecoder().decode(Backoff.self, from: raw)
        guard value.until.isFinite, value.until >= 0, (0...10).contains(value.failures)
        else { throw JumoLicenseError.storage }
        return value.boot == boot ? value : nil
    }
}

