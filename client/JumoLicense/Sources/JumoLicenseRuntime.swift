import Foundation
import UIKit

final class JumoLicenseScreen: UIViewController {
    let card = UITextField()
    let pairing = UITextField()
    let message = UILabel()
    let button = UIButton(type: .system)
    private let code = UITextView()
    private let copy = UIButton(type: .system)
    private let instance = UILabel()
    private let copyInstance = UIButton(type: .system)
    private let continueButton = UIButton(type: .system)
    private var pairingCode: String?
    private var installation: JumoInstallation?
    var submit: ((String, String) -> Void)?
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
        title.text = "授权管理"
        title.font = .boldSystemFont(ofSize: 29)
        title.textColor = .white
        let help = UILabel()
        help.text = "第一个 App：输入卡密，配对码留空。\n其他 App：导入已有配对码，输入同一张卡。\n每个 App 仅在首次登记时占用一个激活名额。"
        help.font = .systemFont(ofSize: 14)
        help.textColor = .secondaryLabel
        help.numberOfLines = 0
        for field in [card, pairing] {
            field.borderStyle = .roundedRect
            field.backgroundColor = BaimingTheme.surface
            field.textColor = .white
            field.layer.cornerRadius = 12
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.spellCheckingType = .no
            field.clearButtonMode = .whileEditing
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant: 48).isActive = true
        }
        card.placeholder = "输入百鸣科技卡密"
        card.isSecureTextEntry = true
        card.accessibilityLabel = "百鸣科技卡密"
        pairing.placeholder = "其他 App 的配对码（首次创建时留空）"
        pairing.accessibilityIdentifier = "jumo.license.pairing.input"
        message.font = .systemFont(ofSize: 14)
        message.numberOfLines = 0
        message.textColor = .secondaryLabel
        message.accessibilityIdentifier = "jumo.license.message"
        button.setTitle("联网激活 / 重新验证  →", for: .normal)
        button.backgroundColor = BaimingTheme.accent
        button.setTitleColor(BaimingTheme.background, for: .normal)
        button.titleLabel?.font = .boldSystemFont(ofSize: 16)
        button.layer.cornerRadius = 12
        button.addTarget(self, action: #selector(verifyTapped), for: .touchUpInside)
        button.accessibilityIdentifier = "jumo.license.verify"
        let codeTitle = UILabel()
        codeTitle.text = "我的配对码"
        codeTitle.textColor = .white
        codeTitle.font = .boldSystemFont(ofSize: 15)
        code.isEditable = false
        code.isSelectable = true
        code.isScrollEnabled = false
        code.backgroundColor = BaimingTheme.surface
        code.textColor = .secondaryLabel
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.layer.cornerRadius = 10
        code.accessibilityIdentifier = "jumo.license.pairing.code"
        copy.setTitle("复制配对码", for: .normal)
        copy.addTarget(self, action: #selector(copyPairing), for: .touchUpInside)
        instance.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        instance.textColor = .secondaryLabel
        instance.numberOfLines = 0
        copyInstance.setTitle("复制 App 实例编号（用于后台解绑）", for: .normal)
        copyInstance.addTarget(self, action: #selector(copyInstallation), for: .touchUpInside)
        continueButton.setTitle("继续使用", for: .normal)
        continueButton.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        for control in [copy, copyInstance, continueButton] {
            control.setTitleColor(BaimingTheme.accent, for: .normal)
        }
        let footer = UILabel()
        footer.text = "百鸣科技  /  配对码可转移，请妥善保管卡密。"
        footer.font = .systemFont(ofSize: 12, weight: .medium)
        footer.textColor = .secondaryLabel
        footer.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [mark, title, help, card, pairing, button,
            message, codeTitle, code, copy, instance, copyInstance, continueButton, footer])
        stack.axis = .vertical
        stack.spacing = 16
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
            button.heightAnchor.constraint(equalToConstant: 52),
            code.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)
        ])
    }

    func update(pairingCode: String?, installation: JumoInstallation?, canContinue: Bool,
                enabled: Bool, remembered: Bool) {
        self.pairingCode = pairingCode
        self.installation = installation
        code.text = pairingCode ?? "联网激活成功后，即可随时在这里查看配对码。"
        copy.isEnabled = pairingCode != nil
        instance.text = installation.map { "当前 App：\($0.bundleID)\n实例编号：\($0.id)" } ?? ""
        copyInstance.isEnabled = installation != nil
        continueButton.isHidden = !canContinue
        continueButton.isEnabled = canContinue
        card.isEnabled = enabled
        pairing.isEnabled = enabled
        button.isEnabled = enabled
        card.placeholder = remembered ? "已保存卡密，留空可重新验证" : "输入百鸣科技卡密"
    }

    @objc private func verifyTapped() {
        let input = card.text ?? ""
        let imported = pairing.text ?? ""
        card.text = nil
        view.endEditing(true)
        submit?(input, imported)
    }

    @objc private func copyPairing() {
        guard let pairingCode = pairingCode else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: pairingCode]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        message.text = "配对码已复制；请在其他 App 中手动粘贴，并输入同一张卡。"
    }

    @objc private func copyInstallation() {
        guard let installation = installation else { return }
        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: installation.id]],
            options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(600)])
        message.text = "App 实例编号已复制，可交给管理员查找或解绑。"
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

