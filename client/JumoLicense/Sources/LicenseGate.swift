import Foundation

/// Readable by Cam's capture threads. Uses monotonic process uptime, never wall time.
final class JumoGate {
    static let shared = JumoGate()
    private let lock = NSLock()
    private let clock: () -> TimeInterval
    private var deadline: TimeInterval = 0

    init(clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return deadline > clock()
    }

    func close() {
        lock.lock()
        deadline = 0
        lock.unlock()
    }

    func open(seconds: TimeInterval) {
        lock.lock()
        deadline = seconds.isFinite ? clock() + max(0, min(seconds, JumoSessionPolicy.maximumLease)) : 0
        lock.unlock()
    }
}
