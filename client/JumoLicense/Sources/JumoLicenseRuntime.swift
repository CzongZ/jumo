import Foundation
import UIKit

final class JumoLicenseScreen: UIViewController {
    let card = UITextField()
    let message = UILabel()
    let button = UIButton(type: .system)
    private let device = UILabel()
    private let copy = UIButton(type: .system)
    private let continueButton = UIButton(type: .system)
    private var machineCode = ""
    var submit: ((String) -> Void)?
    var dismissManagement: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = BaimingTheme.background
        overrideUserInterfaceStyle = .dark
        let mark = UILabel()
        mark.text = "BM  /  百鸣科技"
        mark.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        mark.textColor = BaimingTheme.accent
        let title = UILabel()
        title.text = "App 授权"
        title.font = .boldSystemFont(ofSize: 29)
        title.textColor = .white
        let help = UILabel()
        help.text = "每个 App 独立激活、独立保存卡密。\n首次激活需要联网，之后自动验证。"
        help.font = .systemFont(ofSize: 14)
        help.textColor = .secondaryLabel
        help.numberOfLines = 0
        card.borderStyle = .roundedRect
        card.backgroundColor = BaimingTheme.surface
        card.textColor = .white
        card.layer.cornerRadius = 12
        card.autocorrectionType = .no
        card.autocapitalizationType = .none
        card.spellCheckingType = .no
        card.clearButtonMode = .whileEditing
        card.placeholder = "输入此 App 使用的 JUMO 卡密"
        card.isSecureTextEntry = true
        card.accessibilityLabel = "此 App 的百鸣科技卡密"
        message.font = .systemFont(ofSize: 14)
        message.numberOfLines = 0
        message.textColor = .secondaryLabel
        message.accessibilityIdentifier = "jumo.license.message"
        button.setTitle("激活 / 重新验证  →", for: .normal)
        button.backgroundColor = BaimingTheme.accent
        button.setTitleColor(BaimingTheme.background, for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 16)
        button.layer.cornerRadius = 12
        button.addTarget(self, action: #selector(verifyTapped), for: .touchUpInside)
        button.accessibilityIdentifier = "jumo.license.verify"
        device.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        device.textColor = .secondaryLabel
        device.numberOfLines = 0
        copy.setTitle("复制本 App 设备码", for: .normal)
        copy.setTitleColor(BaimingTheme.accent, for: .normal)
        copy.addTarget(self, action: #selector(copyDevice), for: .touchUpInside)
        continueButton.setTitle("继续使用", for: .normal)
        continueButton.setTitleColor(BaimingTheme.accent, for: .normal)
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        let footer = UILabel()
        footer.text = "百鸣科技  /  创作工具"
        footer.font = .systemFont(ofSize: 12, weight: .medium)
        footer.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [mark, title, help, card, button,
            message, device, copy, continueButton, footer])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            card.heightAnchor.constraint(equalToConstant: 48),
            button.heightAnchor.constraint(equalToConstant: 52)
        ])
    }

    func update(machineCode: String, canContinue: Bool, enabled: Bool, remembered: Bool) {
        self.machineCode = machineCode
        device.text = "本 App 设备码\n\(machineCode)"
        copy.isEnabled = !machineCode.isEmpty
        continueButton.isHidden = !canContinue
        continueButton.isEnabled = canContinue
        card.isEnabled = enabled
        button.isEnabled = enabled
        card.placeholder = remembered ? "已保存卡密，留空可重新验证" : "输入此 App 使用的 JUMO 卡密"
    }

    @objc private func verifyTapped() {
        let input = card.text ?? ""
        card.text = nil
        view.endEditing(true)
        submit?(input)
    }

    @objc private func copyDevice() {
        guard !machineCode.isEmpty else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: machineCode]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        message.text = "本 App 设备码已复制，可交给管理员核对绑定。"
    }

    @objc private func continueTapped() { dismissManagement?() }
}

@_cdecl("JumoIsAuthorized")
func jumoIsAuthorized() -> Bool { JumoGate.shared.isOpen }

@_cdecl("JumoStartAuthorization")
func jumoStartAuthorization() {
    if Thread.isMainThread { JumoLicenseManager.shared.start() }
    else { DispatchQueue.main.async { JumoLicenseManager.shared.start() } }
}

@_cdecl("JumoPresentAuthorization")
func jumoPresentAuthorization() {
    if Thread.isMainThread { JumoLicenseManager.shared.present() }
    else { DispatchQueue.main.async { JumoLicenseManager.shared.present() } }
}

