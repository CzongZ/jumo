import Foundation
import UIKit

final class JumoLicenseManager: NSObject {
    static let shared = JumoLicenseManager()
    private var machine = ""
    private var boot = ""
    private var credentials: JumoKeychain.Credentials?
    private var verifier: JumoLicenseVerifier?
    private var client: JumoHTTPClient?
    private var inFlight = false
    private var timer: Timer?
    private var window: UIWindow?
    private weak var previousWindow: UIWindow?
    private var screen: JumoLicenseScreen?
    private var setupError: Error?
    private var initialized = false
    private var managementPresented = false
    private var blockedInMemory: String?

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        if !initialized {
            initialized = true
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.start() }
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                object: nil, queue: .main) { [weak self] _ in self?.suspend() }
        }
        guard UIApplication.shared.applicationState == .active else { return }
        do {
            credentials = try JumoKeychain.credentials()
            machine = try JumoKeychain.machineCode()
            guard Bundle.main.bundleIdentifier != nil else { throw JumoLicenseError.configuration }
            boot = try JumoKeychain.bootIdentifier()
            verifier = try JumoLicenseVerifier(publicKeyB64: JumoTrust.publicKeyB64)
            setupError = nil
            evaluate()
        } catch {
            setupError = error
            closeGate()
            show(error.localizedDescription)
        }
    }

    func present() {
        if JumoGate.shared.isOpen { presentManagement() }
        else { start() }
    }

    /// Also wired to the plugin panel's BM / authorization-management button.
    @objc func presentManagement() {
        managementPresented = true
        start()
        if setupError == nil { show("此 App 独立保存卡密；其他 App 请分别使用各自的卡。") }
    }

    private func suspend() {
        timer?.invalidate()
        timer = nil
        closeGate()
        hide()
    }

    private func closeGate() {
        JumoGate.shared.close()
        _ = JumoCamSetAuthorized(false)
    }

    private func schedule(_ seconds: TimeInterval) {
        timer?.invalidate()
        guard UIApplication.shared.applicationState == .active else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(1, min(seconds, 60)), repeats: false) { [weak self] _ in
            self?.evaluate()
        }
    }

    private func readLease() throws -> JumoLeaseStatus? {
        guard let verifier = verifier, let credentials = credentials,
              let lease = credentials.lease else { return nil }
        return try lease.resolve(verifier: verifier, key: credentials.card, machine: credentials.machine,
            wall: Date(), uptime: ProcessInfo.processInfo.systemUptime, boot: boot)
    }

    private func openGate(_ lease: JumoLeaseStatus) throws {
        JumoGate.shared.open(seconds: lease.remaining)
        guard JumoCamSetAuthorized(true) else {
            closeGate()
            throw JumoLicenseError.configuration
        }
        if !managementPresented { hide() }
        else { updateScreen() }
    }

    /// Each host validates only its own receipt; this timer performs local reads.
    private func evaluate() {
        guard UIApplication.shared.applicationState == .active, setupError == nil else { return }
        do {
            credentials = try JumoKeychain.credentials()
            guard let credentials = credentials else {
                closeGate()
                show("请输入用于此 App 的 JUMO 卡密，首次激活需要联网。")
                return
            }
            machine = credentials.machine
            if let blocked = blockedInMemory {
                closeGate()
                show(blocked)
                return
            }
            var lease: JumoLeaseStatus?
            do { lease = try readLease() } catch { closeGate() }
            if let lease = lease {
                try openGate(lease)
                if lease.renewIn > 0 { schedule(lease.renewIn); return }
            } else { closeGate() }
            if let blocked = credentials.blockedMessage {
                show(blocked)
                return // Permanent rejection waits for an explicit retry.
            }
            guard !inFlight else { schedule(5); return }
            let uptime = ProcessInfo.processInfo.systemUptime
            if let backoff = try JumoKeychain.backoff(boot: boot), backoff.until > uptime {
                let wait = backoff.until - uptime
                if lease == nil { show("暂时无法验证授权，请稍后重试（\(Int(min(wait, 86400))) 秒）") }
                schedule(min(wait, lease?.remaining ?? wait))
                return
            }
            authorize(credentials.card, userInitiated: false)
        } catch {
            closeGate()
            show(error.localizedDescription)
            schedule(60)
        }
    }

    private func authorize(_ raw: String, userInitiated: Bool) {
        guard !inFlight, UIApplication.shared.applicationState == .active else { return }
        guard let verifier = verifier, setupError == nil else { start(); return }
        do {
            let card = try JumoProtocol.normalizeKey(raw)
            let requestedMachine = try JumoProtocol.normalizeMachine(machine)
            let uptime = ProcessInfo.processInfo.systemUptime
            if let backoff = try JumoKeychain.backoff(boot: boot), backoff.until > uptime {
                show("请求冷却中，请稍后重试")
                schedule(backoff.until - uptime)
                return
            }
            let request = JumoHTTPClient()
            inFlight = true
            client = request
            updateScreen()
            if userInitiated || !JumoGate.shared.isOpen { show("正在联网验证此 App 授权…") }
            do {
                try request.authorize(key: card, machine: requestedMachine) { [weak self] result in
                    guard let self = self else { return }
                    self.inFlight = false
                    self.client = nil
                    do {
                        let bytes = try result.get()
                        let wall = Date()
                        let license = try verifier.verify(bytes, key: card, machine: requestedMachine, receivedAt: wall)
                        guard license.sessionSeconds > 0 else { throw JumoLicenseError.expired }
                        let lease = JumoLease(response: bytes, wall: wall,
                            uptime: ProcessInfo.processInfo.systemUptime, boot: self.boot)
                        let next = JumoKeychain.Credentials(machine: requestedMachine, card: card,
                            lease: lease, blockedMessage: nil)
                        // Replacing a card commits only after successful online verification.
                        try JumoKeychain.saveCredentials(next)
                        self.credentials = next
                        self.machine = requestedMachine
                        self.blockedInMemory = nil
                        try? JumoKeychain.delete("backoff")
                        if userInitiated {
                            self.managementPresented = true
                            self.show("此 App 激活成功，点击「继续使用」进入功能。")
                        }
                        self.evaluate()
                    } catch {
                        self.handleFailure(error, card: card, requestedMachine: requestedMachine, userInitiated: userInitiated)
                    }
                }
            } catch {
                inFlight = false
                client = nil
                handleFailure(error, card: card, requestedMachine: requestedMachine, userInitiated: userInitiated)
            }
        } catch { show(error.localizedDescription) }
    }

    private func handleFailure(_ error: Error, card: String, requestedMachine: String, userInitiated: Bool) {
        let replacement = credentials.map { $0.card != card || $0.machine != requestedMachine } ?? false
        var transient = false
        var delay: TimeInterval = 0
        let previous = try? JumoKeychain.backoff(boot: boot)
        let failures = min((previous?.failures ?? 0) + 1, 10)
        if let issue = error as? JumoLicenseError {
            switch issue {
            case .transport: transient = true
            case .throttled(let seconds):
                transient = true
                delay = seconds.isFinite ? max(1, seconds) : 86400
            case .http(let code): transient = code >= 500 || code == 408
            default: break
            }
        }
        delay = transient
            ? max(delay, JumoSessionPolicy.retryDelay(failures: failures, jitter: Double.random(in: 0...1)))
            : 60
        let backoff = JumoKeychain.Backoff(boot: boot,
            until: ProcessInfo.processInfo.systemUptime + delay, failures: failures)
        if let data = try? JSONEncoder().encode(backoff) { try? JumoKeychain.saveData("backoff", data: data) }
        if !transient && !replacement, var current = credentials {
            blockedInMemory = error.localizedDescription
            current.lease = nil
            current.blockedMessage = error.localizedDescription
            // Even if storage fails, close this process's gate immediately.
            try? JumoKeychain.saveCredentials(current)
            credentials = current
        }
        var retained: JumoLeaseStatus?
        if transient || replacement { retained = try? readLease() }
        if let lease = retained, UIApplication.shared.applicationState == .active {
            do { try openGate(lease) } catch { closeGate() }
            schedule(min(delay, lease.remaining))
            if !userInitiated && !managementPresented { return }
        } else { closeGate() }
        if userInitiated { managementPresented = true }
        show(error.localizedDescription)
        if transient || replacement { schedule(delay) }
    }

    private func updateScreen() {
        guard let screen = screen else { return }
        screen.loadViewIfNeeded()
        screen.update(machineCode: machine, canContinue: JumoGate.shared.isOpen,
            enabled: !inFlight && setupError == nil, remembered: credentials != nil)
    }

    private func show(_ message: String) {
        guard UIApplication.shared.applicationState == .active else { return }
        if window == nil {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }) else { return }
            previousWindow = scene.windows.first(where: { $0.isKeyWindow })
            let controller = JumoLicenseScreen()
            controller.submit = { [weak self] raw in
                guard let self = self else { return }
                self.authorize(raw.isEmpty ? (self.credentials?.card ?? "") : raw, userInitiated: true)
            }
            controller.dismissManagement = { [weak self] in
                guard JumoGate.shared.isOpen else { return }
                self?.managementPresented = false
                self?.hide()
            }
            let overlay = UIWindow(windowScene: scene)
            overlay.windowLevel = .alert + 1
            overlay.rootViewController = controller
            window = overlay
            screen = controller
            overlay.makeKeyAndVisible()
        }
        updateScreen()
        screen?.message.text = message
    }

    private func hide() {
        screen?.card.text = nil
        window?.isHidden = true
        window = nil
        screen = nil
        previousWindow?.makeKey()
        previousWindow = nil
    }
}

