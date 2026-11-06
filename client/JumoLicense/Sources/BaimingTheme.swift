import UIKit

enum BaimingTheme {
    static let background = UIColor(red: 0.035, green: 0.065, blue: 0.11, alpha: 1)
    static let surface = UIColor(red: 0.075, green: 0.12, blue: 0.19, alpha: 1)
    static let accent = UIColor(red: 0.32, green: 0.88, blue: 0.76, alpha: 1)
    static let legacyBrandTexts: Set<String> = ["Tang 抖音授权", "打开 Tang 抖音", "jì shù", "SKY LAB · 增强项", "SkyCam"]

    /// Only called for Cam's own floating panel. No global UIKit interception,
    /// changes to capture behavior, button actions, or host application styling.
    static func apply(to view: UIView) {
        view.overrideUserInterfaceStyle = .dark
        view.tintColor = accent
        if let button = view as? UIButton {
            button.layer.cornerRadius = 10
            button.layer.borderWidth = 1
            button.layer.borderColor = accent.withAlphaComponent(0.22).cgColor
            button.backgroundColor = surface
            button.setTitleColor(accent, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            return // UIKit owns the button's internal title/image hierarchy.
        } else if let label = view as? UILabel {
            label.textColor = .white
            if let text = label.text, legacyBrandTexts.contains(text) {
                label.text = "百鸣科技"
            }
        }
        for child in view.subviews { apply(to: child) }
    }
}

@_cdecl("BaimingStyleView")
func baimingStyleView(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer = pointer,
          let view = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue() as? UIView else { return }
    BaimingTheme.apply(to: view)
    view.backgroundColor = BaimingTheme.background
    view.layer.cornerRadius = 18
    view.layer.borderWidth = 1
    view.layer.borderColor = BaimingTheme.accent.withAlphaComponent(0.4).cgColor
}
