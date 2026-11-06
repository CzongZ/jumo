import Foundation
import CryptoKit

enum JumoLicenseError: Error, LocalizedError {
    case input, configuration, format, signature, denied, expired, clock, storage
    case transport, http(Int), throttled(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .input: return "卡密或本 App 设备码格式不正确"
        case .configuration: return "授权公钥未配置或格式不正确，请联系软件提供方"
        case .format: return "授权服务器响应格式不正确"
        case .signature: return "授权签名校验失败"
        case .denied: return "授权未通过：卡密无效、已停用、已过期或已绑定其他 App 或设备"
        case .expired: return "授权已过期"
        case .clock: return "设备时间与服务器不一致，请启用自动设置时间后重试"
        case .storage: return "无法安全保存授权信息，请解锁设备后重试"
        case .transport: return "无法连接授权服务器，请检查网络后重试"
        case .http(let status): return "授权请求失败（HTTP \(status)）"
        case .throttled: return "请求过于频繁，请稍后重试"
        }
    }
}

enum JumoProtocol {
    static let endpoint = URL(string: "https://back.czongz.site/ai/ai_key/card_vip/detail")!
    static let softwareID = "JUMO"
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991
    static let spkiPrefix = Data([0x30, 0x2a, 0x30, 0x05, 0x06, 0x03,
                                  0x2b, 0x65, 0x70, 0x03, 0x21, 0x00])

    // Matches javaWhitespace + javaSpaceChar in the server implementation.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0d, 0x1c...0x20, 0xa0, 0x1680, 0x2000...0x200a,
             0x2028, 0x2029, 0x202f, 0x205f, 0x3000: return true
        default: return false
        }
    }

    static func normalizeKey(_ raw: String) throws -> String {
        let scalars = raw.unicodeScalars
        let trimmed = scalars.drop(while: isWhitespace).reversed()
            .drop(while: isWhitespace).reversed()
        let result = String(String.UnicodeScalarView(trimmed))
        guard (1...128).contains(result.utf8.count),
              result.unicodeScalars.allSatisfy({ (33...126).contains($0.value) && $0.value != 124 })
        else { throw JumoLicenseError.input }
        return result
    }

    static func normalizeMachine(_ raw: String) throws -> String {
        guard raw.utf16.count <= 1024 else { throw JumoLicenseError.input }
        let scalars = raw.unicodeScalars.filter { !isWhitespace($0) }
        // Reject forbidden input before invoking Foundation's case conversion.
        // Allowed Java whitespace was removed above; other controls must never
        // be converted or discarded into an otherwise valid device identifier.
        func allowed(_ scalar: Unicode.Scalar) -> Bool {
            scalar.value != 124 && scalar.value > 31 && !(0x7f...0x9f).contains(scalar.value)
        }
        guard scalars.allSatisfy(allowed) else { throw JumoLicenseError.input }
        let stripped = String(String.UnicodeScalarView(scalars))
        let result = stripped.uppercased(with: Locale(identifier: "en_US_POSIX"))
        guard (1...256).contains(result.utf16.count),
              result.unicodeScalars.allSatisfy(allowed) else { throw JumoLicenseError.input }
        return result
    }

    static func strictBase64(_ raw: String) -> Data? {
        guard let data = Data(base64Encoded: raw), data.base64EncodedString() == raw else { return nil }
        return data
    }

    static func publicKey(_ base64: String) throws -> Curve25519.Signing.PublicKey {
        guard let der = strictBase64(base64), der.count == 44,
              der.prefix(12) == spkiPrefix,
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: der.suffix(32))
        else { throw JumoLicenseError.configuration }
        return key
    }

    static func formBody(key: String, machine: String) throws -> Data {
        let key = try normalizeKey(key)
        let machine = try normalizeMachine(machine)
        func encode(_ string: String) -> String {
            string.utf8.map { byte -> String in
                switch byte {
                case 65...90, 97...122, 48...57, 45, 46, 95, 42:
                    return String(UnicodeScalar(byte))
                case 32: return "+"
                default: return String(format: "%%%02X", Int(byte))
                }
            }.joined()
        }
        return Data("key=\(encode(key))&machine_code=\(encode(machine))&software_id=JUMO".utf8)
    }
}

struct JumoEnvelope: Decodable {
    let code: Int
    let data: JumoSignedLicense
}

struct JumoSignedLicense: Decodable {
    let status: Bool
    let canUse: Bool
    let serverTime: Int64
    let graceUntil: Int64
    let signVersion: String
    let sig: String
    let data: Details

    struct Details: Decodable { let expiresAt: Int64 }

    func canonical(key: String, machine: String) -> String {
        "v1|\(key)|\(machine)|\(serverTime)|\(graceUntil)|\(data.expiresAt)|\(status && canUse ? "1" : "0")"
    }
}

struct JumoVerifiedLicense {
    let serverTime: Int64
    let expiresAt: Int64
    let graceUntil: Int64

    // Online-only session. Use monotonic time for this duration in the runtime.
    var sessionSeconds: TimeInterval {
        min(JumoSessionPolicy.maximumLease, TimeInterval(graceUntil - serverTime),
            expiresAt == 0 ? JumoSessionPolicy.maximumLease : TimeInterval(expiresAt - serverTime))
    }
}

struct JumoLicenseVerifier {
    let publicKey: Curve25519.Signing.PublicKey

    init(publicKeyB64: String) throws {
        publicKey = try JumoProtocol.publicKey(publicKeyB64)
    }

    func verify(_ bytes: Data, key rawKey: String, machine rawMachine: String,
                receivedAt: Date = Date()) throws -> JumoVerifiedLicense {
        let key = try JumoProtocol.normalizeKey(rawKey)
        let machine = try JumoProtocol.normalizeMachine(rawMachine)
        guard bytes.count <= 65_536,
              let envelope = try? JSONDecoder().decode(JumoEnvelope.self, from: bytes),
              envelope.code == 200 else { throw JumoLicenseError.format }
        let license = envelope.data
        let times = [license.serverTime, license.graceUntil, license.data.expiresAt]
        guard license.signVersion == "v1", license.status == license.canUse,
              times.allSatisfy({ $0 >= 0 && $0 <= JumoProtocol.maximumSafeInteger }),
              let signature = JumoProtocol.strictBase64(license.sig), signature.count == 64
        else { throw JumoLicenseError.format }
        guard publicKey.isValidSignature(signature,
                    for: Data(license.canonical(key: key, machine: machine).utf8))
        else { throw JumoLicenseError.signature }
        // No server reason text or other unsigned display fields confer authorization.
        guard abs(receivedAt.timeIntervalSince1970 - Double(license.serverTime)) <= 300
        else { throw JumoLicenseError.clock }
        guard license.status && license.canUse else { throw JumoLicenseError.denied }
        let expires = license.data.expiresAt
        guard expires == 0 || expires > license.serverTime else { throw JumoLicenseError.expired }
        guard license.graceUntil >= license.serverTime,
              license.graceUntil - license.serverTime <= 72 * 3600,
              expires == 0 || license.graceUntil <= expires else { throw JumoLicenseError.format }
        return JumoVerifiedLicense(serverTime: license.serverTime, expiresAt: expires, graceUntil: license.graceUntil)
    }
}
