import UIKit

final class ScrollToBottomButtonController {
    private weak var hostView: UIView?
    private weak var button: UIButton?
    private var bottomConstraint: NSLayoutConstraint?

    private var isVisible = false
    private var isAnimating = false

    private let onTap: () -> Void

    init(hostView: UIView, onTap: @escaping () -> Void) {
        self.hostView = hostView
        self.onTap = onTap
    }

    func installIfNeeded() {
        guard let hostView, button == nil else { return }

        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false

        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let arrowImage = UIImage(systemName: "arrow.down", withConfiguration: config)
        button.setImage(arrowImage, for: .normal)
        button.tintColor = UIColor.label

        button.backgroundColor = UIColor.systemBackground
        button.layer.cornerRadius = 16
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowOpacity = 0.15
        button.layer.shadowRadius = 4

        button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)

        button.alpha = 0
        button.isHidden = true

        hostView.addSubview(button)
        self.button = button
    }

    func attachConstraints(centerXAnchor: NSLayoutXAxisAnchor, bottomAnchor: NSLayoutYAxisAnchor, baseOffset: CGFloat) {
        guard let button, let hostView, bottomConstraint == nil else { return }

        let bottomConstraint = button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -baseOffset)
        self.bottomConstraint = bottomConstraint

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomConstraint
        ])

        hostView.bringSubviewToFront(button)
    }

    func bringToFront() {
        guard let hostView, let button else { return }
        hostView.bringSubviewToFront(button)
    }

    func buttonView() -> UIButton? {
        return button
    }

    func setBaseOffset(_ offset: CGFloat) {
        bottomConstraint?.constant = -offset
    }

    func setTransform(_ transform: CGAffineTransform) {
        guard !isAnimating, let button else { return }
        button.transform = transform
    }

    func currentTransform() -> CGAffineTransform {
        return button?.transform ?? .identity
    }

    func show(usingKeyboardTransform keyboardTransform: CGAffineTransform) {
        guard !isVisible else { return }
        isVisible = true
        isAnimating = true

        guard let button else {
            isAnimating = false
            return
        }

        button.isHidden = false
        button.alpha = 0
        button.transform = keyboardTransform.concatenating(CGAffineTransform(translationX: 0, y: 12))

        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            usingSpringWithDamping: 0.8,
            initialSpringVelocity: 0.5,
            options: .curveEaseOut
        ) {
            button.alpha = 1
            button.transform = keyboardTransform
        } completion: { _ in
            self.isAnimating = false
        }
    }

    func hide(usingKeyboardTransform keyboardTransform: CGAffineTransform) {
        guard isVisible else { return }
        isVisible = false
        isAnimating = true

        guard let button else {
            isAnimating = false
            return
        }

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: .curveEaseIn
        ) {
            button.alpha = 0
            button.transform = keyboardTransform.concatenating(CGAffineTransform(translationX: 0, y: 12))
        } completion: { _ in
            button.isHidden = true
            button.transform = keyboardTransform
            self.isAnimating = false
        }
    }

    @objc private func handleTap() {
        onTap()
    }
}


