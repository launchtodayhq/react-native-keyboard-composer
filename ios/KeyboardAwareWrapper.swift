import ExpoModulesCore
import UIKit

/// A native wrapper view that finds UIScrollView children and attaches keyboard handling.
/// Also finds and animates the composer container with the keyboard.
class KeyboardAwareWrapper: ExpoView, KeyboardAwareScrollHandlerDelegate, UIGestureRecognizerDelegate {
    private let keyboardHandler = KeyboardAwareScrollHandler()
    private var hasAttached = false
    private var scrollToBottomButton: UIButton?
    private var isScrollButtonVisible = false
    private var isAnimatingScrollButton = false  // Prevents transform updates during show/hide
    private var currentKeyboardHeight: CGFloat = 0
    private var isKeyboardOpen = false  // Track true keyboard state via show/hide notifications
    
    // Composer handling (like Android)
    private weak var composerContainer: UIView?
    private weak var composerView: UIView?  // The actual KeyboardComposerView for height measurement
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
    
    /// Event dispatcher to notify JS when runway height changes
    let onRunwayChange = EventDispatcher()
    
    required init(appContext: AppContext? = nil) {
        super.init(appContext: appContext)
        keyboardHandler.delegate = self
        setupScrollToBottomButton()
        setupKeyboardObservers()
        setupPropertyObservers()
        setupRunwayPanGesture()
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
            
            // Log state BEFORE any action
            self.keyboardHandler.logScrollViewState(context: "scrollToTopTrigger fired")
            
            // For now, just log - we'll add behavior incrementally
            // self.keyboardHandler.scrollNewContentToTop(estimatedHeight: 100)
        }
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
    
    func scrollHandler(_ handler: KeyboardAwareScrollHandler, didUpdateRunwayHeight height: CGFloat) {
        NSLog("[KeyboardWrapper] 📨 Runway height changed: %.0f", height)
        
        #if DEBUG
        // Update debug runway overlay
        DispatchQueue.main.async {
            self.updateDebugRunwayView(height: height)
        }
        #endif
        
        // NOTE: Event dispatch disabled temporarily - causes "Unsupported top level event" error
        // TODO: Fix event registration for this view
        // DispatchQueue.main.async {
        //     self.onRunwayChange(["height": height])
        // }
    }
    
    #if DEBUG
    private var debugContentEndLine: UIView?
    
    private func updateDebugRunwayView(height: CGFloat) {
        guard let sv = keyboardHandler.scrollView else { return }
        
        if height > 0 {
            // Create debug content end line (shows exactly where content ends)
            if debugContentEndLine == nil {
                let line = UIView()
                line.backgroundColor = UIColor.blue
                line.isUserInteractionEnabled = false
                self.addSubview(line)
                debugContentEndLine = line
            }
            
            // Create or update debug runway view
            if debugRunwayView == nil {
                let view = UIView()
                view.backgroundColor = UIColor.red.withAlphaComponent(0.15)
                view.layer.borderWidth = 2
                view.layer.borderColor = UIColor.red.cgColor
                view.isUserInteractionEnabled = false // Don't block touches
                
                // Add label
                let label = UILabel()
                label.text = "RUNWAY"
                label.textColor = .red
                label.font = .boldSystemFont(ofSize: 12)
                label.textAlignment = .center
                label.tag = 999
                view.addSubview(label)
                
                self.addSubview(view)
                debugRunwayView = view
            }
            
            // Calculate where content ends in screen coordinates
            let contentHeight = sv.contentSize.height
            let scrollViewFrame = sv.convert(sv.bounds, to: self)
            
            // Content bottom in SCREEN coordinates (relative to wrapper)
            let contentBottomScreen = scrollViewFrame.origin.y + (contentHeight - sv.contentOffset.y)
            
            // Blue line at content end
            debugContentEndLine?.frame = CGRect(
                x: scrollViewFrame.origin.x,
                y: contentBottomScreen,
                width: scrollViewFrame.width,
                height: 3
            )
            debugContentEndLine?.isHidden = false
            
            // Red runway area (from content end to composer)
            let runwayVisibleHeight = min(height, scrollViewFrame.maxY - contentBottomScreen)
            
            debugRunwayView?.frame = CGRect(
                x: scrollViewFrame.origin.x + 10,
                y: contentBottomScreen,
                width: scrollViewFrame.width - 20,
                height: max(0, runwayVisibleHeight)
            )
            
            // Update label
            if let label = debugRunwayView?.viewWithTag(999) as? UILabel {
                label.text = "← TOUCH HERE TO SCROLL (\(Int(height))pt runway)"
                label.frame = debugRunwayView?.bounds ?? .zero
            }
            
            debugRunwayView?.isHidden = runwayVisibleHeight <= 0
            
            NSLog("[DEBUG] Content ends at screen Y=%.0f, runway visible=%.0f (contentH=%.0f offset=%.0f)",
                  contentBottomScreen, runwayVisibleHeight, contentHeight, sv.contentOffset.y)
        } else {
            debugRunwayView?.isHidden = true
            debugContentEndLine?.isHidden = true
        }
    }
    #endif
    
    private var hasLoggedFrames = false
    
    // DEBUG: Visual overlays
    private var debugRunwayView: UIView?
    private var debugContentView: UIView?
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        // Update safe area
        safeAreaBottom = window?.safeAreaInsets.bottom ?? 34
        
        // Log frames once after layout is stable
        if !hasLoggedFrames, let sv = findScrollView(in: self) {
            hasLoggedFrames = true
            NSLog("[KeyboardWrapper] === FRAME DEBUG ===")
            NSLog("[KeyboardWrapper] wrapper.bounds: h=%.0f", bounds.height)
            NSLog("[KeyboardWrapper] scrollView.frame: y=%.0f h=%.0f", sv.frame.origin.y, sv.frame.size.height)
            NSLog("[KeyboardWrapper] safeAreaBottom=%.0f", safeAreaBottom)
            if let window = window {
                let svFrameInWindow = sv.convert(sv.bounds, to: window)
                NSLog("[KeyboardWrapper] scrollView in window: y=%.0f h=%.0f bottom=%.0f", 
                      svFrameInWindow.origin.y, svFrameInWindow.size.height, 
                      window.bounds.height - svFrameInWindow.maxY)
            }
        }
        
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
            NSLog("[KeyboardWrapper] FRAMES: wrapper=%.0f,%.0f,%.0f,%.0f scrollView=%.0f,%.0f,%.0f,%.0f",
                  bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
                  sv.frame.origin.x, sv.frame.origin.y, sv.frame.size.width, sv.frame.size.height)
            
            // DEBUG: Add visual overlay to show scroll view bounds (subtle)
            sv.layer.borderWidth = 2
            sv.layer.borderColor = UIColor.green.withAlphaComponent(0.3).cgColor
            
            // DEBUG: Add pan gesture logger to see if touches are received
            let debugPan = UIPanGestureRecognizer(target: self, action: #selector(debugPanGesture(_:)))
            debugPan.delegate = self
            sv.addGestureRecognizer(debugPan)
            
            NSLog("[DEBUG] ✅ Scroll view should now receive touches in runway area via hitTest override")
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
            
            #if DEBUG
            if let cc = composerContainer {
                NSLog("[KeyboardWrapper] composerContainer frame=%.0f,%.0f,%.0f,%.0f (depth=%d)",
                      cc.frame.origin.x, cc.frame.origin.y, cc.frame.size.width, cc.frame.size.height, depth)
            }
            #endif
            
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
        // Note: Don't reset hasAttached or composerContainer here
        // React calls this frequently during layout, resetting would lose our references
        setNeedsLayout()
    }
    
    // MARK: - Public API for JS
    
    /// Scroll so new content appears at top (ChatGPT-style)
    func scrollNewContentToTop(estimatedHeight: CGFloat) {
        keyboardHandler.scrollNewContentToTop(estimatedHeight: estimatedHeight)
    }
    
    // MARK: - Touch Handling for Runway Area
    
    /// Pan gesture recognizer for the runway area.
    /// UIScrollView's native pan gesture doesn't activate in contentInset areas (no content to grab).
    /// This gesture handles pans that start in the runway and forwards them to the scroll view.
    private var runwayPanGesture: UIPanGestureRecognizer?
    private var runwayPanStartOffset: CGFloat = 0
    
    // Physics-based deceleration
    private var displayLink: CADisplayLink?
    private var decelerationVelocity: CGFloat = 0
    private var decelerationTarget: CGFloat = 0
    
    private func setupRunwayPanGesture() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleRunwayPan(_:)))
        pan.delegate = self
        self.addGestureRecognizer(pan)
        runwayPanGesture = pan
    }
    
    @objc private func handleRunwayPan(_ gesture: UIPanGestureRecognizer) {
        guard let sv = keyboardHandler.scrollView else { return }
        
        switch gesture.state {
        case .began:
            // Store the starting offset
            runwayPanStartOffset = sv.contentOffset.y
            NSLog("[RunwayPan] 🖐️ Pan BEGAN in runway, startOffset=%.0f", runwayPanStartOffset)
            
        case .changed:
            // Calculate new offset based on pan translation
            let translation = gesture.translation(in: self)
            let newOffset = runwayPanStartOffset - translation.y
            
            // Clamp to valid range
            let minOffset: CGFloat = 0
            let maxOffset = sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom
            let clampedOffset = max(minOffset, min(maxOffset, newOffset))
            
            sv.contentOffset = CGPoint(x: 0, y: clampedOffset)
            
        case .ended, .cancelled:
            let velocity = gesture.velocity(in: self)
            NSLog("[RunwayPan] 🏁 Pan ENDED, velocity=%.0f", velocity.y)
            
            // For significant velocity, project where the scroll should end
            // and let it decelerate there
            if abs(velocity.y) > 50 {
                // Use iOS's standard deceleration rate formula
                // The deceleration rate is approximately 0.998, meaning velocity 
                // decays to near-zero over about 1-2 seconds
                // Projected distance ≈ initialVelocity / (1 - decelerationRate) * timeConstant
                // Simplified: velocity * ~0.3-0.5 gives a good feel
                let projectedDistance = velocity.y * 0.25
                
                let targetOffset = sv.contentOffset.y - projectedDistance
                let minOffset: CGFloat = 0
                let maxOffset = sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom
                let clampedTarget = max(minOffset, min(maxOffset, targetOffset))
                
                // Animate using CADisplayLink for frame-accurate physics
                decelerateToOffset(clampedTarget, initialVelocity: velocity.y)
            }
            // If low velocity, just stop where it is (already set during .changed)
            
        default:
            break
        }
    }
    
    /// Start physics-based deceleration animation
    private func decelerateToOffset(_ target: CGFloat, initialVelocity: CGFloat) {
        // Stop any existing animation
        displayLink?.invalidate()
        
        decelerationTarget = target
        decelerationVelocity = -initialVelocity  // Negative because scroll direction is inverted
        
        let link = CADisplayLink(target: self, selector: #selector(decelerationStep))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }
    
    @objc private func decelerationStep() {
        guard let sv = keyboardHandler.scrollView else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        
        // Apply deceleration (friction)
        let decelerationRate: CGFloat = 0.95  // Higher = more friction, stops faster
        decelerationVelocity *= decelerationRate
        
        // Calculate new offset
        let dt: CGFloat = 1.0 / 60.0  // Assume 60fps
        let delta = decelerationVelocity * dt
        var newOffset = sv.contentOffset.y + delta
        
        // Clamp to bounds
        let minOffset: CGFloat = 0
        let maxOffset = sv.contentSize.height - sv.bounds.height + sv.contentInset.bottom
        newOffset = max(minOffset, min(maxOffset, newOffset))
        
        // Apply
        sv.contentOffset = CGPoint(x: 0, y: newOffset)
        
        // Stop when velocity is low enough or we've reached bounds
        if abs(decelerationVelocity) < 10 || newOffset <= minOffset || newOffset >= maxOffset {
            displayLink?.invalidate()
            displayLink = nil
        }
    }
    
    /// Determine if a point is in the runway area (below content, within scroll view frame)
    private func isPointInRunwayArea(_ point: CGPoint) -> Bool {
        guard let sv = keyboardHandler.scrollView else { 
            NSLog("[RunwayArea] No scroll view!")
            return false 
        }
        
        // Get scroll view's frame in wrapper coordinates
        let scrollViewFrame = sv.frame
        
        // Check if point is within scroll view's frame (vertically)
        guard point.y >= scrollViewFrame.minY && point.y <= scrollViewFrame.maxY else {
            return false
        }
        
        // Calculate where content ends in SCREEN coordinates (relative to wrapper)
        let contentHeight = sv.contentSize.height
        let offsetY = sv.contentOffset.y
        let contentBottomScreen = scrollViewFrame.minY + (contentHeight - offsetY)
        
        // Runway is below content end but within scroll view frame
        let isInRunway = point.y > contentBottomScreen && point.y < scrollViewFrame.maxY
        
        #if DEBUG
        NSLog("[RunwayArea] screenY=%.0f, contentBottomScreen=%.0f, svMaxY=%.0f → isInRunway=%@",
              point.y, contentBottomScreen, scrollViewFrame.maxY, isInRunway ? "YES" : "NO")
        #endif
        
        return isInRunway
    }
    
    // MARK: - Debug Gesture Handling
    
    #if DEBUG
    @objc private func debugPanGesture(_ gesture: UIPanGestureRecognizer) {
        guard let sv = gesture.view as? UIScrollView else { return }
        
        // location(in: scrollView) returns CONTENT coordinates (includes contentOffset)
        let locationInContent = gesture.location(in: sv)
        
        // Calculate screen position (relative to scroll view's visible frame)
        let screenY = locationInContent.y - sv.contentOffset.y
        
        let contentHeight = sv.contentSize.height
        
        // Is touch in content area or inset/runway area?
        let isInContent = locationInContent.y < contentHeight
        let isInRunway = locationInContent.y >= contentHeight
        
        if gesture.state == .began {
            NSLog("[DEBUG TOUCH] 🖐️ Pan at SCREEN Y=%.0f (content Y=%.0f)",
                  screenY, locationInContent.y)
            NSLog("[DEBUG TOUCH] contentHeight=%.0f → isInContent=%@ isInRunway=%@",
                  contentHeight, isInContent ? "YES" : "NO", isInRunway ? "YES" : "NO")
            
            if isInRunway {
                NSLog("[DEBUG TOUCH] ✅ TOUCH IS IN RUNWAY AREA!")
            }
        }
    }
    
    // Allow debug gesture to work simultaneously with scroll view's pan
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    #endif
    
    // MARK: - UIGestureRecognizerDelegate for Runway Pan
    
    /// Only allow the runway pan gesture to begin if the touch is in the runway area
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Only filter our runway pan gesture
        guard gestureRecognizer === runwayPanGesture else { return true }
        
        let location = gestureRecognizer.location(in: self)
        let isInRunway = isPointInRunwayArea(location)
        
        #if DEBUG
        NSLog("[RunwayPan] gestureRecognizerShouldBegin called at y=%.0f, isInRunway=%@", 
              location.y, isInRunway ? "YES" : "NO")
        if isInRunway {
            NSLog("[RunwayPan] ✅ Gesture SHOULD start in runway area")
        }
        #endif
        
        return isInRunway
    }
}

