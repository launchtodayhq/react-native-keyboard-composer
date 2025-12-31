import ExpoModulesCore
import UIKit

/// A native wrapper view that finds UIScrollView children and attaches keyboard handling.
/// Also finds and animates the composer container with the keyboard.
class KeyboardAwareWrapper: ExpoView, KeyboardAwareScrollHandlerDelegate {
    private let keyboardHandler = KeyboardAwareScrollHandler()
    private var hasAttached = false
    private lazy var scrollButtonController: ScrollToBottomButtonController = {
        ScrollToBottomButtonController(hostView: self) { [weak self] in
            self?.keyboardHandler.scrollToBottomAnimated()
        }
    }()
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
    @objc dynamic var pinToTopEnabled: Bool = false
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
        let (extraObs, triggerObs) = WrapperPropertyObservers.setup(
            wrapper: self,
            onExtraBottomInsetChange: { [weak self] oldValue, newValue in
                guard let self else { return }
                let delta = newValue - oldValue

                if delta > 0 {
                    self.keyboardHandler.adjustScrollForComposerGrowth(delta: delta)
                }

                self.keyboardHandler.setBaseInset(newValue + self.CONTENT_GAP)
                self.updateScrollButtonBasePosition()
            },
            onScrollToTopTrigger: { [weak self] in
                guard let self else { return }
                guard self.pinToTopEnabled else { return }
                self.keyboardHandler.requestPinForNextContentAppend()
            }
        )

        extraBottomInsetObservation = extraObs
        scrollToTopTriggerObservation = triggerObs
    }

    @objc private func handleComposerDidSend(_ notification: Notification) {
        guard let sender = notification.object as? KeyboardComposerView else { return }

        if composerView == nil {
            composerView = ViewHierarchyFinder.findComposerView(in: self)
        }

        guard sender === composerView else { return }
        guard pinToTopEnabled else { return }
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
    
    private func setupScrollToBottomButton() {
        scrollButtonController.installIfNeeded()
        scrollButtonController.attachConstraints(
            centerXAnchor: centerXAnchor,
            bottomAnchor: bottomAnchor,
            baseOffset: calculateBaseButtonOffset()
        )
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
        // Calculate how much to translate the button up when keyboard is open
        let effectiveKeyboard = max(currentKeyboardHeight - safeAreaBottom, 0)
        
        if effectiveKeyboard > 0 {
            // Keyboard is open - translate up by keyboard height + gap
            let translation = -(effectiveKeyboard + COMPOSER_KEYBOARD_GAP)
            scrollButtonController.setTransform(CGAffineTransform(translationX: 0, y: translation))
        } else {
            // Keyboard closed - no transform needed
            scrollButtonController.setTransform(.identity)
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
        scrollButtonController.setBaseOffset(calculateBaseButtonOffset())
    }
    
    private func showScrollButton() {
        let keyboardTransform = currentButtonKeyboardTransform()
        scrollButtonController.show(usingKeyboardTransform: keyboardTransform)
    }
    
    private func hideScrollButton() {
        let keyboardTransform = currentButtonKeyboardTransform()
        scrollButtonController.hide(usingKeyboardTransform: keyboardTransform)
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
            if let comp = ViewHierarchyFinder.findComposerView(in: self) {
                composerView = comp
                composerContainer = ViewHierarchyFinder.findDirectChildContainer(for: comp, in: self)
            }
        }
        
        // Detect composer height changes from actual KeyboardComposerView frame
        // This is more reliable than prop-based updates which may not trigger with Fabric
        // We use composerView (not container) because container includes padding (safe area)
        if let composer = composerView {
            ComposerHeightCoordinator.updateIfNeeded(
                composerView: composer,
                lastComposerHeight: &lastComposerHeight,
                keyboardHandler: keyboardHandler,
                contentGap: CONTENT_GAP
            )
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
        
        scrollButtonController.bringToFront()
        
        // Find and attach to scroll view and composer (only once)
        if !hasAttached {
            DispatchQueue.main.async { [weak self] in
                self?.findAndAttachViews()
            }
        }
    }
    
    private func findAndAttachViews() {
        WrapperAttachmentCoordinator.attachIfNeeded(
            host: self,
            getHasAttached: { [weak self] in self?.hasAttached ?? true },
            setHasAttached: { [weak self] value in self?.hasAttached = value },
            getComposerView: { [weak self] in self?.composerView },
            setComposerView: { [weak self] value in self?.composerView = value },
            setComposerContainer: { [weak self] value in self?.composerContainer = value },
            getExtraBottomInset: { [weak self] in self?.extraBottomInset ?? 0 },
            getContentGap: { [weak self] in self?.CONTENT_GAP ?? 0 },
            setLastComposerHeight: { [weak self] value in self?.lastComposerHeight = value },
            updateComposerTransform: { [weak self] in self?.updateComposerTransform() },
            setBaseInset: { [weak self] baseInset in
                self?.keyboardHandler.setBaseInset(baseInset)
            },
            attachScrollHandler: { [weak self] sv in
                self?.keyboardHandler.attach(to: sv)
            },
            scheduleRetry: { [weak self] retry in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard self != nil else { return }
                    retry()
                }
            }
        )
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
        guard pinToTopEnabled else { return }
        keyboardHandler.requestPinForNextContentAppend()
    }

    // MARK: - Touch Routing (runway)

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // Never steal touches that belong to the composer or the scroll-to-bottom button.
        if let button = scrollButtonController.buttonView(), button.frame.contains(point) {
            return button
        }
        if let container = composerContainer, container.frame.contains(point) {
            return super.hitTest(point, with: event)
        }

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

