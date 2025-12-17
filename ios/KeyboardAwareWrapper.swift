import ExpoModulesCore
import UIKit

/// A native wrapper view that finds UIScrollView children and attaches keyboard handling.
/// Also finds and animates the composer container with the keyboard.
class KeyboardAwareWrapper: ExpoView, KeyboardAwareScrollHandlerDelegate {
    private let keyboardHandler = KeyboardAwareScrollHandler()
    private var hasAttached = false
    private var scrollToBottomButton: UIButton?
    private var isScrollButtonVisible = false
    private var currentKeyboardHeight: CGFloat = 0
    
    // Composer handling (like Android)
    private weak var composerContainer: UIView?
    private var safeAreaBottom: CGFloat = 0
    
    // Constants matching Android
    private let CONTENT_GAP: CGFloat = 24
    private let COMPOSER_KEYBOARD_GAP: CGFloat = 8
    
    // Base inset: composer height only (from JS)
    // Gap and safe area are handled natively
    var extraBottomInset: CGFloat = 48 {
        didSet {
            print("🎯 [KeyboardWrapper] extraBottomInset set to: \(extraBottomInset)")
            // Note: scroll handler adds safeAreaBottom internally when keyboard is closed
            keyboardHandler.setBaseInset(extraBottomInset + CONTENT_GAP)
            updateScrollButtonPosition()
        }
    }
    
    /// Trigger scroll to top when this value changes (use timestamp/counter from JS)
    var scrollToTopTrigger: Double = 0 {
        didSet {
            if scrollToTopTrigger > 0 {
                print("🎯 [KeyboardWrapper] scrollToTopTrigger: \(scrollToTopTrigger)")
                keyboardHandler.scrollNewContentToTop(estimatedHeight: 100)
            }
        }
    }
    
    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        keyboardHandler.delegate = self
        setupScrollToBottomButton()
        setupKeyboardObservers()
        print("🎯 [KeyboardWrapper] initialized")
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Keyboard Observers
    
    private func setupKeyboardObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }
    
    @objc private func keyboardWillShow(_ notification: Notification) {
        handleKeyboardChange(notification: notification, isShowing: true)
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        handleKeyboardChange(notification: notification, isShowing: false)
    }
    
    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        // This handles interactive dismiss and height changes
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt else { return }
        
        // Check if keyboard is visible (frame intersects with screen)
        let screenHeight = UIScreen.main.bounds.height
        let isVisible = keyboardFrame.origin.y < screenHeight
        
        if isVisible {
            currentKeyboardHeight = keyboardFrame.height
        } else {
            currentKeyboardHeight = 0
        }
        
        animateComposerAndButton(duration: duration, curve: curve)
    }
    
    private func handleKeyboardChange(notification: Notification, isShowing: Bool) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt else { return }
        
        currentKeyboardHeight = isShowing ? keyboardFrame.height : 0
        
        print("🎯 [KeyboardWrapper] keyboard \(isShowing ? "show" : "hide") - height=\(currentKeyboardHeight), safeArea=\(safeAreaBottom)")
        
        animateComposerAndButton(duration: duration, curve: curve)
    }
    
    private func animateComposerAndButton(duration: Double, curve: UInt) {
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.updateComposerTransform()
            self.updateScrollButtonPosition()
            self.layoutIfNeeded()
        }
    }
    
    private func updateComposerTransform() {
        guard let container = composerContainer else { return }
        
        // Calculate effective keyboard height (above safe area)
        let effectiveKeyboard = max(currentKeyboardHeight - safeAreaBottom, 0)
        
        // Only translate when keyboard is open
        // When closed, React Native handles positioning via paddingBottom
        let translation: CGFloat
        if effectiveKeyboard > 0 {
            translation = -(effectiveKeyboard + COMPOSER_KEYBOARD_GAP)
        } else {
            translation = 0
        }
        
        container.transform = CGAffineTransform(translationX: 0, y: translation)
        
        print("🎯 [KeyboardWrapper] composer transform: \(translation), effectiveKb=\(effectiveKeyboard)")
    }
    
    // MARK: - Scroll to Bottom Button
    
    private var buttonBottomConstraint: NSLayoutConstraint?
    
    private func setupScrollToBottomButton() {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        
        // Configure button appearance - use arrow.down for clearer visual
        let config = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let arrowImage = UIImage(systemName: "arrow.down", withConfiguration: config)
        button.setImage(arrowImage, for: .normal)
        button.tintColor = UIColor.label
        
        // Style the button
        button.backgroundColor = UIColor.systemBackground
        button.layer.cornerRadius = 16
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.layer.shadowOpacity = 0.15
        button.layer.shadowRadius = 4
        
        // Add action
        button.addTarget(self, action: #selector(scrollToBottomTapped), for: .touchUpInside)
        
        // Initially hidden
        button.alpha = 0
        button.isHidden = true
        
        addSubview(button)
        scrollToBottomButton = button
        
        // Constraints - start with initial position
        let bottomConstraint = button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -calculateButtonBottomOffset())
        buttonBottomConstraint = bottomConstraint
        
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomConstraint
        ])
    }
    
    private func calculateButtonBottomOffset() -> CGFloat {
        // Button padding above the composer
        let buttonPadding: CGFloat = 16
        
        // Calculate effective keyboard (above safe area)
        let effectiveKeyboard = max(currentKeyboardHeight - safeAreaBottom, 0)
        
        // Composer height from JS
        let composerHeight = extraBottomInset
        
        if effectiveKeyboard > 0 {
            // Keyboard is open - button above keyboard + gap + composer + content gap
            return currentKeyboardHeight + COMPOSER_KEYBOARD_GAP + composerHeight + CONTENT_GAP + buttonPadding
        } else {
            // Keyboard closed - button above safe area + composer + content gap
            return safeAreaBottom + composerHeight + CONTENT_GAP + buttonPadding
        }
    }
    
    private func updateScrollButtonPosition() {
        buttonBottomConstraint?.constant = -calculateButtonBottomOffset()
    }
    
    @objc private func scrollToBottomTapped() {
        keyboardHandler.scrollToBottomAnimated()
    }
    
    private func showScrollButton() {
        guard !isScrollButtonVisible else { return }
        isScrollButtonVisible = true
        
        scrollToBottomButton?.isHidden = false
        UIView.animate(withDuration: 0.2) {
            self.scrollToBottomButton?.alpha = 1
        }
    }
    
    private func hideScrollButton() {
        guard isScrollButtonVisible else { return }
        isScrollButtonVisible = false
        
        UIView.animate(withDuration: 0.2, animations: {
            self.scrollToBottomButton?.alpha = 0
        }, completion: { _ in
            self.scrollToBottomButton?.isHidden = true
        })
    }
    
    // MARK: - KeyboardAwareScrollHandlerDelegate
    
    func scrollHandler(_ handler: KeyboardAwareScrollHandler, didUpdateScrollPosition isAtBottom: Bool) {
        DispatchQueue.main.async {
            if isAtBottom {
                self.hideScrollButton()
            } else {
                self.showScrollButton()
            }
        }
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Update safe area
        safeAreaBottom = window?.safeAreaInsets.bottom ?? 34
        
        // Don't override React Native's layout - it handles positioning via Yoga
        // Only the scroll button needs manual positioning since we add it natively
        
        // Position the scroll button
        updateScrollButtonPosition()
        
        // Bring button to front
        if let button = scrollToBottomButton {
            bringSubviewToFront(button)
        }
        
        // Find and attach to scroll view and composer (only once)
        if !hasAttached {
            DispatchQueue.main.async { [weak self] in
                self?.findAndAttachViews()
            }
        }
    }
    
    private func findAndAttachViews() {
        guard !hasAttached else { return }
        
        let scrollView = findScrollView(in: self)
        let composer = findComposerView(in: self)
        
        if let sv = scrollView {
            // Set the base inset BEFORE attaching so it's applied immediately
            // Note: scroll handler adds safeAreaBottom internally when keyboard is closed
            keyboardHandler.setBaseInset(extraBottomInset + CONTENT_GAP)
            keyboardHandler.attach(to: sv)
            hasAttached = true
            print("🎯 [KeyboardWrapper] attached ScrollView with baseInset=\(extraBottomInset + CONTENT_GAP)")
        } else {
            print("🎯 [KeyboardWrapper] no UIScrollView found yet, will retry...")
        }
        
        // Find composer container (parent of LaunchComposerView that's a direct child of this wrapper)
        if let comp = composer {
            var container: UIView? = comp
            var depth = 0
            while let parent = container?.superview, parent !== self {
                container = parent
                depth += 1
            }
            composerContainer = container
            print("🎯 [KeyboardWrapper] found composer, container depth=\(depth)")
            
            // Apply initial transform (gap only, no keyboard)
            updateComposerTransform()
        }
        
        // Retry if scroll view not found
        if scrollView == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.findAndAttachViews()
            }
        }
    }
    
    /// Recursively find UIScrollView in view hierarchy
    private func findScrollView(in view: UIView) -> UIScrollView? {
        // Check if this view is a scroll view
        if let scrollView = view as? UIScrollView {
            print("🎯 [KeyboardWrapper] found UIScrollView: \(type(of: scrollView))")
            return scrollView
        }
        
        // Search children
        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }
        
        return nil
    }
    
    /// Recursively find KeyboardComposerView in view hierarchy
    private func findComposerView(in view: UIView) -> UIView? {
        // Check if this view is a KeyboardComposerView
        if type(of: view) == KeyboardComposerView.self {
            return view
        }
        
        // Search children
        for subview in view.subviews {
            if let composer = findComposerView(in: subview) {
                return composer
            }
        }
        
        return nil
    }
    
    // MARK: - React Native Subview Management
    
    override func insertReactSubview(_ subview: UIView!, at atIndex: Int) {
        super.insertReactSubview(subview, at: atIndex)
        hasAttached = false // Reset so we can find scroll view and composer in new children
        composerContainer = nil
        setNeedsLayout()
    }
    
    // MARK: - Public API for JS
    
    /// Scroll so new content appears at top (ChatGPT-style)
    func scrollNewContentToTop(estimatedHeight: CGFloat) {
        keyboardHandler.scrollNewContentToTop(estimatedHeight: estimatedHeight)
    }
}

