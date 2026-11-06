import Foundation

enum JumoSessionPolicy {
    static let maximumLease: TimeInterval = 2 * 3600
    static let renewalRange: ClosedRange<TimeInterval> = 55 * 60 ... 65 * 60
    static let clockTolerance: TimeInterval = 120

    static func retryDelay(failures: Int, jitter: Double) -> TimeInterval {
        let base = min(900, 30 * pow(2, Double(max(0, min(failures - 1, 5)))))
        return base * (1 + max(0, min(jitter, 1)) * 0.25)
    }
}

/// Only the server response confers authorization; local timestamps only shorten
/// its lifetime. ThisDeviceOnly Keychain storage prevents backup/iCloud migration.
struct JumoLease: Codable {
    let response: Data
    let receivedWall: TimeInterval
    let receivedUptime: TimeInterval
    let boot: String
    let renewAfter: TimeInterval
    let softwareID: String
    let installation: JumoInstallation?

    init(response: Data, wall: Date, uptime: TimeInterval, boot: String,
         renewAfter: TimeInterval = Double.random(in: JumoSessionPolicy.renewalRange),
         installation: JumoInstallation? = nil) {
        self.response = response
        receivedWall = wall.timeIntervalSince1970
        receivedUptime = uptime
        self.boot = boot
        self.renewAfter = renewAfter
        softwareID = JumoProtocol.softwareID
        self.installation = installation
    }

    func resolve(verifier: JumoLicenseVerifier, key: String, machine: String,
                 wall: Date, uptime: TimeInterval, boot currentBoot: String,
                 installation expectedInstallation: JumoInstallation? = nil) throws -> JumoLeaseStatus {
        guard installation == expectedInstallation,
              softwareID == JumoProtocol.softwareID, !boot.isEmpty, boot == currentBoot,
              receivedWall.isFinite, receivedUptime.isFinite, receivedUptime >= 0,
              JumoSessionPolicy.renewalRange.contains(renewAfter)
        else { throw JumoLicenseError.expired }
        let elapsed = uptime - receivedUptime
        let wallElapsed = wall.timeIntervalSince1970 - receivedWall
        guard elapsed >= 0, elapsed < JumoSessionPolicy.maximumLease,
              abs(elapsed - wallElapsed) <= JumoSessionPolicy.clockTolerance
        else { throw JumoLicenseError.clock }
        // Re-verify on every read, binding the cached response to THIS card and
        // device. The original receipt time must itself satisfy fresh verification.
        let license = try verifier.verify(response, key: key, machine: machine, installation: expectedInstallation,
                                         receivedAt: Date(timeIntervalSince1970: receivedWall))
        let serverAge = wall.timeIntervalSince1970 - Double(license.serverTime)
        guard serverAge >= -300, serverAge < JumoSessionPolicy.maximumLease + 300
        else { throw JumoLicenseError.clock }
        // Use the larger age, so initial local clock skew cannot extend a lease.
        let age = max(elapsed, serverAge)
        let remaining = min(license.sessionSeconds - age,
                            JumoSessionPolicy.maximumLease - elapsed)
        guard remaining > 0 else { throw JumoLicenseError.expired }
        return JumoLeaseStatus(remaining: remaining, renewIn: min(renewAfter - elapsed, remaining))
    }
}

struct JumoLeaseStatus {
    let remaining: TimeInterval
    let renewIn: TimeInterval
}
