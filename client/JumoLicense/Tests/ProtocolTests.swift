import Foundation
import CryptoKit
import Darwin

@main
struct ProtocolTests {
    static var checks = 0

    static func expect(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try condition() else { throw NSError(domain: name, code: 1) }
        checks += 1
    }

    static func rejects(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { checks += 1; return }
        throw NSError(domain: "Unexpected acceptance: " + name, code: 1)
    }

    static func main() {
        do { try runAll() }
        catch {
            FileHandle.standardError.write(Data("Native Swift test failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func runAll() throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let verifier = try JumoLicenseVerifier(publicKeyB64: fixture["PUBLIC_KEY_B64"] as! String)
        let when = Date(timeIntervalSince1970: 2_000_000_000)
        let vectors = fixture["vectors"] as! [[String: Any]]
        for (index, vector) in vectors.enumerated() {
            let response = try JSONSerialization.data(withJSONObject: vector["response"]!)
            let key = vector["key"] as! String
            let machine = vector["machineCode"] as! String
            let envelope = try JSONDecoder().decode(JumoEnvelope.self, from: response)
            try expect(envelope.data.canonical(key: key, machine: machine) == vector["canonical"] as! String,
                       "Java canonical vector \(index)")
            if index < 2 {
                let valid = try verifier.verify(response, key: key, machine: machine, receivedAt: when)
                try expect(valid.expiresAt == (index == 0 ? 2_002_592_000 : 0), "Java valid vector")
            } else {
                try rejects("signed denial") {
                    _ = try verifier.verify(response, key: key, machine: machine, receivedAt: when)
                }
            }
            try rejects("different card") {
                _ = try verifier.verify(response, key: key + "X", machine: machine, receivedAt: when)
            }
            try rejects("different device") {
                _ = try verifier.verify(response, key: key, machine: machine + "X", receivedAt: when)
            }
        }

        let baseResponse = vectors[0]["response"] as! [String: Any]
        func altered(_ mutate: (inout [String: Any]) -> Void) throws -> Data {
            var response = baseResponse
            var license = response["data"] as! [String: Any]
            mutate(&license)
            response["data"] = license
            return try JSONSerialization.data(withJSONObject: response)
        }
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("tampered expiration", { license in
                var details = license["data"] as! [String: Any]
                details["expiresAt"] = 0
                license["data"] = details
            }),
            ("tampered grace", { $0["graceUntil"] = 2_000_259_201 }),
            ("tampered signature", { $0["sig"] = Data(repeating: 0, count: 64).base64EncodedString() }),
            ("noncanonical base64", { $0["sig"] = ($0["sig"] as! String) + "\n" }),
            ("short signature", { $0["sig"] = "AA==" }),
            ("numeric bool", { $0["status"] = 1 }),
            ("mismatched booleans", { $0["canUse"] = false }),
            ("negative time", { $0["serverTime"] = -1 }),
            ("unsafe time", { $0["serverTime"] = 9_007_199_254_740_992 as Int64 }),
            ("fractional time", { $0["serverTime"] = 2_000_000_000.5 }),
            ("string time", { $0["serverTime"] = "2000000000" }),
            ("unknown version", { $0["signVersion"] = "v2" }),
            ("missing details", { $0.removeValue(forKey: "data") })
        ]
        for (name, mutation) in mutations {
            let bytes = try altered(mutation)
            try rejects(name) {
                _ = try verifier.verify(bytes, key: "TEST-CARD-001", machine: "TK-ABCD-1234", receivedAt: when)
            }
        }
        let valid = try JSONSerialization.data(withJSONObject: baseResponse)
        try rejects("stale response") {
            _ = try verifier.verify(valid, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
                receivedAt: when.addingTimeInterval(301))
        }
        try rejects("non-JSON gateway error") {
            _ = try verifier.verify(Data("<html>Bad Gateway</html>".utf8), key: "TEST-CARD-001",
                                    machine: "TK-ABCD-1234", receivedAt: when)
        }
        try rejects("RSA or malformed SPKI") { _ = try JumoProtocol.publicKey("AAAA") }
        try expect(try JumoProtocol.normalizeKey("\u{3000}\tAbC+&=123\u{a0}") == "AbC+&=123", "card normalization")
        try expect(try JumoProtocol.normalizeMachine(" ab\t-c\u{1c}d\u{3000}") == "AB-CD", "device normalization")
        try expect(try JumoProtocol.normalizeMachine("straße") == "STRASSE", "locale-independent uppercase")
        for raw in ["", "A B", "A|B", "卡密", String(repeating: "x", count: 129)] {
            try rejects("bad card input") { _ = try JumoProtocol.normalizeKey(raw) }
        }
        for raw in ["", "A|B", "AB\u{0}", "AB\u{85}", String(repeating: "x", count: 257),
                    String(repeating: " ", count: 1025)] {
            let scalars = raw.unicodeScalars.prefix(16)
                .map { String(format: "U+%04X", $0.value) }.joined(separator: " ")
            try rejects("bad device input [\(scalars)], UTF16 length \(raw.utf16.count)") {
                _ = try JumoProtocol.normalizeMachine(raw)
            }
        }
        // Preserve the protocol's allowed whitespace but reject every other
        // C0/C1 control before casing, at every position in the identifier.
        for value in Array(0x00...0x1f) + Array(0x7f...0x9f) {
            let scalar = Unicode.Scalar(value)!
            let character = String(scalar)
            let label = String(format: "U+%04X", value)
            if JumoProtocol.isWhitespace(scalar) {
                try expect(try JumoProtocol.normalizeMachine("ab" + character + "cd") == "ABCD",
                           "allowed device whitespace \(label)")
            } else {
                for (position, raw) in [character + "ab", "a" + character + "b", "ab" + character].enumerated() {
                    try rejects("device control \(label), position \(position)") {
                        _ = try JumoProtocol.normalizeMachine(raw)
                    }
                }
                try rejects("signed device identifier with appended \(label)") {
                    _ = try verifier.verify(valid, key: "TEST-CARD-001",
                        machine: "TK-ABCD-1234" + character, receivedAt: when)
                }
                try rejects("device control in request form \(label)") {
                    _ = try JumoProtocol.formBody(key: "TEST-CARD-001", machine: "ab" + character)
                }
            }
        }
        let form = try JumoProtocol.formBody(key: "AbC+&=123", machine: "ab-cd")
        try expect(String(data: form, encoding: .utf8) ==
            "key=AbC%2B%26%3D123&machine_code=AB-CD&software_id=JUMO", "exact form encoding")

        // Generate independent signed cases to test policy AFTER successful verification.
        let signer = Curve25519.Signing.PrivateKey()
        let testPublic = (JumoProtocol.spkiPrefix + signer.publicKey.rawRepresentation).base64EncodedString()
        let independent = try JumoLicenseVerifier(publicKeyB64: testPublic)
        func signed(expires: Int64, grace: Int64, ok: Bool = true) throws -> Data {
            let canonical = "v1|K|M|2000000000|\(grace)|\(expires)|\(ok ? "1" : "0")"
            let signature = try signer.signature(for: Data(canonical.utf8)).base64EncodedString()
            let license: [String: Any] = [
                "status": ok, "canUse": ok, "serverTime": 2_000_000_000,
                "graceUntil": grace, "signVersion": "v1", "sig": signature,
                "data": ["expiresAt": expires]]
            return try JSONSerialization.data(withJSONObject: ["code": 200, "data": license])
        }
        try rejects("validly signed expired card") {
            _ = try independent.verify(signed(expires: 2_000_000_000, grace: 2_000_000_000),
                                       key: "K", machine: "M", receivedAt: when)
        }
        try rejects("validly signed excessive grace") {
            _ = try independent.verify(signed(expires: 0, grace: 2_000_259_201),
                                       key: "K", machine: "M", receivedAt: when)
        }
        var uptime: TimeInterval = 100
        let gate = JumoGate(clock: { uptime })
        try expect(!gate.isOpen, "initial gate closed")
        gate.open(seconds: 10000)
        uptime = 7299
        try expect(gate.isOpen, "gate open before bounded deadline")
        uptime = 7300
        try expect(!gate.isOpen, "getter denies at deadline without a timer callback")
        gate.open(seconds: 100)
        gate.close()
        try expect(!gate.isOpen, "revocation immediate")
        gate.open(seconds: .infinity)
        try expect(!gate.isOpen, "nonfinite gate duration rejected")
        gate.open(seconds: .nan)
        try expect(!gate.isOpen, "NaN gate duration rejected")
        let shared = JumoLease(response: valid, wall: when, uptime: 100, boot: "BOOT-A", renewAfter: 3300)
        let first = try shared.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
            wall: when, uptime: 100, boot: "BOOT-A")
        try expect(first.remaining == 7200 && first.renewIn == 3300, "bounded private lease")
        let anotherApp = try shared.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
            wall: when.addingTimeInterval(1200), uptime: 1300, boot: "BOOT-A")
        try expect(anotherApp.remaining == 6000 && anotherApp.renewIn == 2100, "same App reuses signed lease")
        let due = try shared.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
            wall: when.addingTimeInterval(3600), uptime: 3700, boot: "BOOT-A")
        try expect(due.renewIn < 0 && due.remaining == 3600, "hourly renewal due without premature lock")
        try rejects("private lease hard expiry") {
            _ = try shared.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
                wall: when.addingTimeInterval(7200), uptime: 7300, boot: "BOOT-A")
        }
        try rejects("cached response cannot transfer to a different device") {
            _ = try shared.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "OTHER",
                wall: when, uptime: 100, boot: "BOOT-A")
        }
        try rejects("cached response cannot transfer to a different card") {
            _ = try shared.resolve(verifier: verifier, key: "OTHER", machine: "TK-ABCD-1234",
                wall: when, uptime: 100, boot: "BOOT-A")
        }
        try rejects("cached response after device reboot") {
            _ = try shared.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
                wall: when, uptime: 100, boot: "BOOT-B")
        }
        try rejects("clock rollback during cached session") {
            _ = try shared.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
                wall: when.addingTimeInterval(-3600), uptime: 1300, boot: "BOOT-A")
        }
        try rejects("tampered local receipt cannot replay an old signed response") {
            let forged = JumoLease(response: valid, wall: when.addingTimeInterval(86400),
                uptime: 100, boot: "BOOT-A", renewAfter: 3300)
            _ = try forged.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
                wall: when.addingTimeInterval(86400), uptime: 100, boot: "BOOT-A")
        }
        try rejects("tampered refresh interval") {
            let forged = JumoLease(response: valid, wall: when, uptime: 100, boot: "BOOT-A", renewAfter: 7000)
            _ = try forged.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
                wall: when, uptime: 100, boot: "BOOT-A")
        }
        try rejects("another software namespace cannot use the private lease") {
            var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as! [String: Any]
            json["softwareID"] = "OTHER"
            let changed = try JSONDecoder().decode(JumoLease.self,
                from: JSONSerialization.data(withJSONObject: json))
            _ = try changed.resolve(verifier: verifier, key: "TEST-CARD-001", machine: "TK-ABCD-1234",
                wall: when, uptime: 100, boot: "BOOT-A")
        }
        let shortLease = JumoLease(response: try signed(expires: 2_000_000_010, grace: 2_000_000_010),
            wall: when, uptime: 100, boot: "BOOT-A", renewAfter: 3300)
        try expect(try shortLease.resolve(verifier: independent, key: "K", machine: "M", wall: when,
            uptime: 100, boot: "BOOT-A").remaining == 10, "monthly expiry caps private lease")
        try rejects("monthly expiry forbids cached grace") {
            _ = try shortLease.resolve(verifier: independent, key: "K", machine: "M",
                wall: when.addingTimeInterval(10), uptime: 110, boot: "BOOT-A")
        }
        try expect(JumoSessionPolicy.retryDelay(failures: 1, jitter: 0) == 30, "first transient backoff")
        try expect(JumoSessionPolicy.retryDelay(failures: 10, jitter: 1) == 1125, "bounded transient backoff")
        try expect(JumoHTTPClient.retryDelay("60") == 60, "Retry-After delta")
        try expect(JumoHTTPClient.retryDelay("invalid") == 60, "Retry-After fallback")
        print("\(checks) native Swift protocol/policy checks passed")
    }

}
