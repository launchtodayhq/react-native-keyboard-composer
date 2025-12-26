import ExpoModulesCore
import UIKit

/// A native wrapper view that finds UIScrollView children and attaches keyboard handling.
/// Also finds and animates the composer container with the keyboard.
class KeyboardAwareWrapper: ExpoView, KeyboardAwareScrollHandlerDelegate {
    private let keyboardHandler = KeyboardAwareScrollHandler()
    private var hasAttached = false
    private var scrollToBottomButton: UIButton?
    private var isScrollButtonVisible = false
    private var isAnimatingScrollButton = false  // Prevents transform updates during show/hide
    private var currentKeyboardHeight: CGFloat = 0
    private var isKeyboardOpen = false  // Track true keyboard state via show/hide notifications
    
    // Composer handling (like Android)
    private weak var composerContainer: UIView?
    private weak var composerView: KeyboardComposerView?  // The actual KeyboardComposerView for height measurement
    private var safeAreaBottom: CGFloat = 0
    
    // Track composer height to detect changes (since props may not trigger observers with Fabric)
    private var lastComposerHeight: CGFloat = 0
    
    // Constants matching Android
    private let CONTENT_GAP: CGFloat = 24
    private let COMPOSER_KEYBOARD_GAP: CGFloat = 10
    private let MIN_BOTTOM_PADDING: CGFloat = 16  // Minimum padding when keyboard closed
    
    // KVO observations
    private var extraBottomInsetObservation: NSKeyValueObservation?
    private var scrollToTopTriggerObservation: NSKeyValueObservation?
    
    // Base inset: composer height only (from JS)
    // Gap and safe area are handled natively
    // Using @objc dynamic to enable KVO - required because React Native/Expo sets props via Objective-C KVC
    @objc dynamic var extraBottomInset: CGFloat = 48
    
    /// Trigger scroll to top when this value changes (use timestamp/counter from JS)
    @objc dynamic var scrollToTopTrigger: Double = 0
    
    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        keyboardHandler.delegate = self
        setupScrollToBottomButton()
        setupKeyboardObservers()
        setupPropertyObservers()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleComposerDidSend(_:)),
            name: .keyboardComposerDidSend,
            object: nil
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        extraBottomInsetObservation?.invalidate()
        scrollToTopTriggerObservation?.invalidate()
    }
    
    // MARK: - Property Observers (KVO)
    
    /// Set up KVO observers for properties that need side effects when changed.
    /// This is necessary because React Native/Expo sets props via Objective-C KVC,
    /// which bypasses Swift's didSet observers.
    private func setupPropertyObservers() {
        extraBottomInsetObservation = observe(\.extraBottomInset, options: [.old, .new]) { [weak self] _, change in
            guard let self = self,
                  let oldValue = change.oldValue,
                  let newValue = change.newValue,
                  oldValue != newValue else { return }
            
            let delta = newValue - oldValue
            
            // When composer grows (delta > 0), scroll content up to keep last message visible
            // Do this BEFORE updating insets so we can scroll properly
            if delta > 0 {
                self.keyboardHandler.adjustScrollForComposerGrowth(delta: delta)
            }
            
            // Note: scroll handler adds safeAreaBottom internally when keyboard is closed
            self.keyboardHandler.setBaseInset(newValue + self.CONTENT_GAP)
            self.updateScrollButtonBasePosition()
        }
        
        scrollToTopTriggerObservation = observe(\.scrollToTopTrigger, options: [.new]) { [weak self] _, change in
            guard let self = self,
                  let newValue = change.newValue,
                  newValue > 0 else { return }
            
            self.keyboardHandler.requestPinForNextContentAppend()
        }
    }

    @objc private func handleComposerDidSend(_ notification: Notification) {
        guard let sender = notification.object as? KeyboardComposerView else { return }

        if composerView == nil {
            composerView = findComposerView(in: self)
        }

        guard sender === composerView else { return }
        keyboardHandler.requestPinForNextContentAppend()
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
        
        // Check if keyboard is visible based on frame position
        let screenHeight = UIScreen.main.bounds.height
        let isVisibleByFrame = keyboardFrame.origin.y < screenHeight
        
        // CRITICAL: Don't trust frame-based visibility if we know keyboard is open
        // iOS can send misleading frame notifications during text input changes
        let newKeyboardHeight: CGFloat
        if isKeyboardOpen {
            // Keyboard is definitely open, use the reported height (ignore visibility check)
            newKeyboardHeight = keyboardFrame.height
        } else if isVisibleByFrame {
            // Keyboard appears to be visible by frame
            newKeyboardHeight = keyboardFrame.height
        } else {
            // Keyboard not visible and not open - this is fine
            newKeyboardHeight = 0
        }
        
        // Only animate if keyboard height actually changed
        guard newKeyboardHeight != currentKeyboardHeight else {
            return
        }
        
        currentKeyboardHeight = newKeyboardHeight
        animateComposerAndButton(duration: duration, curve: curve)
    }
    
    private func handleKeyboardChange(notification: Notification, isShowing: Bool) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt else { return }
        
        // Track true keyboard state - this is authoritative
        isKeyboardOpen = isShowing
        currentKeyboardHeight = isShowing ? keyboardFrame.height : 0
        
        #if DEBUG
        NSLog("[KeyboardWrapper] keyboard %@ height=%.0f", isShowing ? "show" : "hide", currentKeyboardHeight)
        #endif
        
        animateComposerAndButton(duration: duration, curve: curve)
    }
    
    private func animateComposerAndButton(duration: Double, curve: UInt) {
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.updateComposerTransform()
            self.updateScrollButtonTransform()
            // Note: Don't call layoutIfNeeded() here - it causes React Native layout
            // changes (like input growing) to animate unexpectedly
        }
    }
    
    private func updateComposerTransform() {
        guard let container = composerContainer else {
            return
        }
        
        // Native code handles ALL positioning:
        // - When keyboard closed: move up by safe area (or min padding)
        // - When keyboard open: move up by FULL keyboard height + gap
        let translation: CGFloat
        if currentKeyboardHeight > 0 {
            // Keyboard open - position above keyboard using FULL keyboard height
            // (not effectiveKeyboard, since we no longer have JS paddingBottom)
            translation = -(currentKeyboardHeight + COMPOSER_KEYBOARD_GAP)
        } else {
            // Keyboard closed - position above safe area
            let bottomOffset = max(safeAreaBottom, MIN_BOTTOM_PADDING)
            translation = -bottomOffset
        }
        
        // Check if transform is already correct to avoid unnecessary updates
        let currentTranslation = container.transform.ty
        if abs(currentTranslation - translation) > 0.5 {
            container.transform = CGAffineTransform(translationX: 0, y: translation)
        }
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
        
        // Constraints - base position at bottom, we'll use transform for keyboard animation
        let bottomConstraint = button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -calculateBaseButtonOffset())
        buttonBottomConstraint = bottomConstraint
        
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 32),
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            bottomConstraint
        ])
    }
    
    /// Base button offset (when keyboard is closed) - used for constraint
    private func calculateBaseButtonOffset() -> CGFloat {
        let composerHeight = lastComposerHeight > 0 ? lastComposerHeight : extraBottomInset
        // Button sits just above the composer
        // Since composer is transformed up by (safeAreaBottom or minPadding), 
        // button needs same offset + composer height + gap
        let bottomOffset = max(safeAreaBottom, MIN_BOTTOM_PADDING)
        let buttonGap: CGFloat = 8
        return bottomOffset + composerHeight + buttonGap
    }
    
    /// Update button transform to animate with keyboard (called inside animation block)
    private func updateScrollButtonTransform() {
        // Don't update transform during show/hide animation
        guard !isAnimatingScrollButton else { return }
        guard let button = scrollToBottomButton else { return }
        
        // Calculate how much to translate the button up when keyboard is open
        let effectiveKeyboard = max(currentKeyboardHeight - safeAreaBottom, 0)
        
        if effectiveKeyboard > 0 {
            // Keyboard is open - translate up by keyboard height + gap
            let translation = -(effectiveKeyboard + COMPOSER_KEYBOARD_GAP)
            button.transform = CGAffineTransform(translationX: 0, y: translation)
        } else {
            // Keyboard closed - no transform needed
            button.transform = .identity
        }
    }
    
    /// Get the current keyboard transform for the button
    private func currentButtonKeyboardTransform() -> CGAffineTransform {
        let effectiveKeyboard = max(currentKeyboardHeight - safeAreaBottom, 0)
        if effectiveKeyboard > 0 {
            let translation = -(effectiveKeyboard + COMPOSER_KEYBOARD_GAP)
            return CGAffineTransform(translationX: 0, y: translation)
        }
        return .identity
    }
    
    /// Update button's base constraint when composer height changes (outside animation)
    private func updateScrollButtonBasePosition() {
        buttonBottomConstraint?.constant = -calculateBaseButtonOffset()
    }
    
    @objc private func scrollToBottomTapped() {
        keyboardHandler.scrollToBottomAnimated()
    }
    
    private func showScrollButton() {
        guard !isScrollButtonVisible else { return }
        isScrollButtonVisible = true
        isAnimatingScrollButton = true
        
        guard let button = scrollToBottomButton else {
            isAnimatingScrollButton = false
            return
        }
        
        // Get the final keyboard transform
        let keyboardTransform = currentButtonKeyboardTransform()
        
        // Start 12pt below final position + faded out
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
            button.transform = keyboardTransform  // Final position
        } completion: { _ in
            self.isAnimatingScrollButton = false
        }
    }
    
    private func hideScrollButton() {
        guard isScrollButtonVisible else { return }
        isScrollButtonVisible = false
        isAnimatingScrollButton = true
        
        guard let button = scrollToBottomButton else {
            isAnimatingScrollButton = false
            return
        }
        
        // Get current keyboard transform (our starting point)
        let keyboardTransform = currentButtonKeyboardTransform()
        
        // Animate 12pt down from current position + fade out
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: .curveEaseIn
        ) {
            button.alpha = 0
            button.transform = keyboardTransform.concatenating(CGAffineTransform(translationX: 0, y: 12))
        } completion: { _ in
            button.isHidden = true
            // Reset to correct keyboard position for next show
            button.transform = keyboardTransform
            self.isAnimatingScrollButton = false
        }
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
        
        // Re-find composer if lost (weak reference might have been cleared)
        if composerView == nil || composerContainer == nil {
            if let comp = findComposerView(in: self) {
                composerView = comp
                var container: UIView? = comp
                while let parent = container?.superview, parent !== self {
                    container = parent
                }
                composerContainer = container
            }
        }
        
        // Detect composer height changes from actual KeyboardComposerView frame
        // This is more reliable than prop-based updates which may not trigger with Fabric
        // We use composerView (not container) because container includes padding (safe area)
        if let composer = composerView {
            let currentHeight = composer.bounds.height
            if currentHeight > 0 && abs(currentHeight - lastComposerHeight) > 0.5 {
                let delta = currentHeight - lastComposerHeight
                
                // Update insets and scroll position
                handleComposerHeightChange(newHeight: currentHeight, delta: delta)
                lastComposerHeight = currentHeight
            }
        }
        
        // CRITICAL: Re-apply transforms after every layout
        // React Native's layout system can reset transforms when views resize
        if composerContainer != nil {
            updateComposerTransform()
        }
        
        // Update scroll button base position (for composer height changes)
        // and re-apply transform (for keyboard state)
        updateScrollButtonBasePosition()
        updateScrollButtonTransform()
        
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
    
    /// Handle composer height changes detected from frame
    private func handleComposerHeightChange(newHeight: CGFloat, delta: CGFloat) {
        // Check if user is near bottom before making changes
        let isNearBottom = keyboardHandler.isUserNearBottom()
        
        #if DEBUG
        NSLog("[KeyboardWrapper] composer height=%.0f delta=%.0f atBottom=%@", newHeight, delta, isNearBottom ? "yes" : "no")
        #endif
        
        if delta > 0 && isNearBottom {
            // When composer grows AND user is at bottom, scroll content up to keep last message visible
            keyboardHandler.adjustScrollForComposerGrowth(delta: delta)
        }
        
        // Update base inset with new composer height
        // Preserve scroll position if user is NOT at bottom (prevents visual jump)
        keyboardHandler.setBaseInset(newHeight + CONTENT_GAP, preserveScrollPosition: !isNearBottom)
    }
    
    private func findAndAttachViews() {
        guard !hasAttached else { return }
        
        let scrollView = findScrollView(in: self)
        let composer = findComposerView(in: self)
        
        if let sv = scrollView {
            // Use actual composer view height if available (not container which includes padding)
            let composerHeight = composerView?.bounds.height ?? extraBottomInset
            let baseInset = composerHeight + CONTENT_GAP
            
            // Set the base inset BEFORE attaching so it's applied immediately
            // Note: scroll handler adds safeAreaBottom internally when keyboard is closed
            keyboardHandler.setBaseInset(baseInset)
            keyboardHandler.attach(to: sv)
            hasAttached = true
            #if DEBUG
            NSLog("[KeyboardWrapper] attached scrollView=%@", String(describing: type(of: sv)))
            #endif
        } else {
            // Will retry
        }
        
        // Find composer view and container
        // - composerView: the actual KeyboardComposerView (for height measurement)
        // - composerContainer: the top-level container that's a direct child of this wrapper (for transform animation)
        if let comp = composer {
            composerView = comp
            
            var container: UIView? = comp
            var depth = 0
            while let parent = container?.superview, parent !== self {
                container = parent
                depth += 1
            }
            composerContainer = container
            
            // Initialize lastComposerHeight from the actual composer view (not container which includes padding)
            lastComposerHeight = comp.bounds.height
            
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
    private func findComposerView(in view: UIView) -> KeyboardComposerView? {
        // Check if this view is a KeyboardComposerView
        if let composer = view as? KeyboardComposerView {
            return composer
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
        // Note: Don't reset hasAttached or composerContainer here
        // React calls this frequently during layout, resetting would lose our references
        setNeedsLayout()
    }
    
    // MARK: - Public API for JS
    
    /// Scroll so new content appears at top (ChatGPT-style)
    func scrollNewContentToTop(estimatedHeight: CGFloat) {
        keyboardHandler.requestPinForNextContentAppend()
    }

    // MARK: - Touch Routing (runway)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let sv = keyboardHandler.scrollView {
            let svFrame = sv.frame
            if point.y >= svFrame.minY && point.y <= svFrame.maxY {
                let contentHeight = sv.contentSize.height
                let offsetY = sv.contentOffset.y
                let contentBottomScreen = svFrame.minY + (contentHeight - offsetY)
                if point.y > contentBottomScreen {
                    return sv
                }
            }
        }
        return super.hitTest(point, with: event)
    }
}

