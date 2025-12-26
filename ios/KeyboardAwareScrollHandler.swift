import ExpoModulesCore
import UIKit

/// Delegate to notify when scroll position or runway height changes
protocol KeyboardAwareScrollHandlerDelegate: AnyObject {
    func scrollHandler(_ handler: KeyboardAwareScrollHandler, didUpdateScrollPosition isAtBottom: Bool)
    func scrollHandler(_ handler: KeyboardAwareScrollHandler, didUpdateRunwayHeight height: CGFloat)
}

/// Native keyboard handler that directly controls a UIScrollView's contentInset.
/// This bypasses React Native's JS bridge for smooth keyboard animations.
class KeyboardAwareScrollHandler: NSObject, UIGestureRecognizerDelegate, UIScrollViewDelegate {
    weak var scrollView: UIScrollView?
    weak var delegate: KeyboardAwareScrollHandlerDelegate?
    /// Base inset WITHOUT safe area (composer + gap)
    var baseBottomInset: CGFloat = 64 // 48 + 16
    private var keyboardHeight: CGFloat = 0
    private var wasAtBottom = false
    private var isAtBottom = true
    private var isKeyboardVisible = false  // Track if keyboard is already showing
    
    // Native send detection: keyboard hides → content grows = message sent
    private var keyboardJustHid = false
    private var contentSizeBeforeHide: CGFloat = 0
    
    // Pin-to-top state
    private var isPinned = false
    private var runwayInset: CGFloat = 0  // Extra inset for runway space
    private var pinnedOffset: CGFloat = 0  // The offset to return to when scrolling back down
    
    /// Get safe area bottom from window
    private var safeAreaBottom: CGFloat {
        scrollView?.window?.safeAreaInsets.bottom ?? 34
    }
    
    override init() {
        super.init()
        setupKeyboardObservers()
        NSLog("[ScrollHandler] ✅ Initialized - logging active")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        contentSizeObservation?.invalidate()
        contentSizeObservation = nil
    }
    
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
    }
    
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let scrollView = scrollView,
              let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }
        
        let newKeyboardHeight = keyboardFrame.height
        
        // Only do scroll-to-bottom logic on INITIAL keyboard show, not on subsequent height changes
        let isInitialShow = !isKeyboardVisible
        isKeyboardVisible = true
        
        NSLog("[ScrollHandler] keyboardWillShow: height=%.0f isInitial=%@", newKeyboardHeight, isInitialShow ? "yes" : "no")
        
        // Check if at bottom BEFORE animation (only on initial show)
        if isInitialShow {
            wasAtBottom = isNearBottom(scrollView)
        }
        keyboardHeight = newKeyboardHeight
        
        // Use raw UIView.animate with keyboard's exact animation curve
        // The curve value (7) is converted to animation options by shifting left 16 bits
        let animationOptions = UIView.AnimationOptions(rawValue: curveValue << 16)
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: animationOptions,
            animations: {
                // Update content inset
                self.updateContentInset()
                
                // Scroll to bottom INSIDE animation block - ONLY on initial keyboard show
                // Skip when pinned - keep the pinned view stable while typing new message
                if isInitialShow && self.wasAtBottom && !self.isPinned {
                    let contentHeight = scrollView.contentSize.height
                    let scrollViewHeight = scrollView.bounds.height
                    let keyboardOpenPadding: CGFloat = 8
                    let bottomInset = self.baseBottomInset + self.keyboardHeight + keyboardOpenPadding
                    let maxOffset = max(0, contentHeight - scrollViewHeight + bottomInset)
                    scrollView.contentOffset = CGPoint(x: 0, y: maxOffset)
                }
            },
            completion: nil
        )
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }
        
        // Record state for native send detection
        keyboardJustHid = true
        contentSizeBeforeHide = scrollView?.contentSize.height ?? 0
        
        NSLog("[ScrollHandler] keyboardWillHide - expecting content growth from %.0f", contentSizeBeforeHide)
        
        keyboardHeight = 0
        isKeyboardVisible = false  // Reset flag when keyboard hides
        
        // Use raw UIView.animate with keyboard's exact animation curve
        let animationOptions = UIView.AnimationOptions(rawValue: curveValue << 16)
        
        // When pinned, preserve scroll position during keyboard hide
        // The new pin-to-top will handle positioning after content grows
        let shouldPreservePosition = isPinned
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: animationOptions,
            animations: {
                self.updateContentInset(preserveScrollPosition: shouldPreservePosition)
            },
            completion: nil
        )
    }
    
    private func isNearBottom(_ scrollView: UIScrollView) -> Bool {
        let currentOffset = scrollView.contentOffset.y
        
        // When pinned, "bottom" means near the pinned position
        // When not pinned, "bottom" means near the natural content bottom
        let targetOffset: CGFloat
        if isPinned {
            targetOffset = pinnedOffset
        } else {
            let contentHeight = scrollView.contentSize.height
            let scrollViewHeight = scrollView.bounds.height
            let realBottomInset = scrollView.contentInset.bottom - runwayInset
            targetOffset = max(0, contentHeight - scrollViewHeight + realBottomInset)
        }
        
        // Consider "at bottom" if within 100pt of target
        return abs(targetOffset - currentOffset) < 100
    }
    
    private func updateContentInset(preserveScrollPosition: Bool = false) {
        guard let scrollView = scrollView else { return }
        
        // Save current scroll position if we need to preserve it
        let savedOffset = preserveScrollPosition ? scrollView.contentOffset : nil
        
        // The composer's paddingBottom from animatedPaddingStyle:
        // - Keyboard closed: safeAreaBottom + Spacing.sm
        // - Keyboard open: Spacing.sm (8)
        let keyboardOpenPadding: CGFloat = 8  // Spacing.sm from JS
        
        let baseInset: CGFloat
        if keyboardHeight > 0 {
            // Keyboard open: base + keyboard + small padding
            baseInset = baseBottomInset + keyboardHeight + keyboardOpenPadding
        } else {
            // Keyboard closed: base + safe area
            baseInset = baseBottomInset + safeAreaBottom
        }
        
        // Total inset = base + runway (if pinned)
        let totalInset = baseInset + runwayInset
        
        scrollView.contentInset.bottom = totalInset
        
        // Scroll indicator should NOT include runway - it should end at the content
        // This makes the indicator go closer to the input, like ChatGPT
        scrollView.verticalScrollIndicatorInsets.bottom = baseInset
        
        NSLog("[ScrollHandler] updateContentInset: baseInset=%.0f runway=%.0f total=%.0f indicatorInset=%.0f",
              baseInset, runwayInset, totalInset, baseInset)
        
        // Restore scroll position if needed (prevents visual jump when not at bottom)
        if let savedOffset = savedOffset {
            scrollView.contentOffset = savedOffset
        }
    }
    
    private func scrollToBottom(animated: Bool) {
        guard let scrollView = scrollView else { return }
        
        // When pinned, "bottom" means the pinned position (messages at top, runway below)
        // When not pinned, "bottom" means the natural content bottom
        let targetOffset: CGFloat
        if isPinned {
            targetOffset = pinnedOffset
            NSLog("[ScrollHandler] scrollToBottom: using pinnedOffset=%.0f", pinnedOffset)
        } else {
            let contentHeight = scrollView.contentSize.height
            let scrollViewHeight = scrollView.bounds.height
            let realBottomInset = scrollView.contentInset.bottom - runwayInset
            targetOffset = max(0, contentHeight - scrollViewHeight + realBottomInset)
        }
        
        scrollView.setContentOffset(CGPoint(x: 0, y: targetOffset), animated: animated)
    }
    
    // MARK: - Public API
    
    private var tapGesture: UITapGestureRecognizer?
    private var contentSizeObservation: NSKeyValueObservation?
    
    func attach(to scrollView: UIScrollView) {
        self.scrollView = scrollView
        scrollView.delegate = self
        updateContentInset()
        
        // Add tap gesture to dismiss keyboard
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false // Allow other touches to pass through
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
        tapGesture = tap
        
        // Observe content size changes
        contentSizeObservation = scrollView.observe(\.contentSize, options: [.new, .old]) { [weak self] scrollView, change in
            guard let self = self else { return }
            
            guard let oldSize = change.oldValue, let newSize = change.newValue else { return }
            
            // Log content size changes for debugging
            if oldSize.height != newSize.height {
                NSLog("[ScrollHandler] contentSize changed: %.0f -> %.0f (delta: %.0f)", 
                      oldSize.height, newSize.height, newSize.height - oldSize.height)
                
                // Native send detection: keyboard just hid + content grew = message was sent
                if self.keyboardJustHid && newSize.height > self.contentSizeBeforeHide {
                    let messageHeight = newSize.height - self.contentSizeBeforeHide
                    let messageStartY = self.contentSizeBeforeHide
                    let messageEndY = newSize.height
                    
                    NSLog("[ScrollHandler] *** NATIVE SEND DETECTED ***")
                    NSLog("[ScrollHandler] User message: Y=%.0f to %.0f (height=%.0f)", 
                          messageStartY, messageEndY, messageHeight)
                    
                    self.keyboardJustHid = false  // Reset flag
                    
                    // Log full state for analysis
                    self.logScrollViewState(context: "after native send detected")
                    
                    // Calculate pin-to-top values (viewport-relative)
                    self.calculatePinToTopValues(messageHeight: messageHeight)
                } else if newSize.height > oldSize.height {
                    // Content grew but not from send - likely AI response
                    let contentGrowth = newSize.height - oldSize.height
                    NSLog("[ScrollHandler] Content grew (not send): %.0f to %.0f - likely AI response", 
                          oldSize.height, newSize.height)
                    
                    // When pinned, reduce runway as content fills it
                    // This keeps maxOffset = pinnedOffset, preserving natural scroll limits
                    // IMPORTANT: Preserve scroll position to prevent snapping
                    if self.isPinned && self.runwayInset > 0 {
                        let newRunway = max(0, self.runwayInset - contentGrowth)
                        NSLog("[ScrollHandler] Reducing runway: %.0f -> %.0f (content grew %.0f)", 
                              self.runwayInset, newRunway, contentGrowth)
                        self.runwayInset = newRunway
                        self.updateContentInset(preserveScrollPosition: true)
                        
                        // Notify delegate of runway change
                        NSLog("[ScrollHandler] 📨 Notifying delegate of runway height: %.0f", newRunway)
                        self.delegate?.scrollHandler(self, didUpdateRunwayHeight: newRunway)
                        
                        // When runway is fully consumed, clear pinned state
                        // This returns scroll-to-bottom and isNearBottom to normal behavior
                        if newRunway == 0 {
                            NSLog("[ScrollHandler] Runway exhausted - clearing pinned state")
                            self.isPinned = false
                            self.pinnedOffset = 0
                        }
                    }
                }
            }
            
            // Check position when content size changes
            DispatchQueue.main.async {
                self.checkAndUpdateScrollPosition()
            }
        }
    }
    
    // MARK: - UIScrollViewDelegate
    
    private var lastLoggedOffset: CGFloat = -1000
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // No hard clamping - let iOS handle natural physics
        // The runway is adjusted dynamically as content grows to maintain scroll limits
        
        #if DEBUG
        // Log scroll position periodically (not every frame)
        let currentOffset = scrollView.contentOffset.y
        if abs(currentOffset - lastLoggedOffset) > 50 {
            lastLoggedOffset = currentOffset
            let contentH = scrollView.contentSize.height
            let viewportH = scrollView.bounds.height
            let insetBottom = scrollView.contentInset.bottom
            let maxOffset = contentH - viewportH + insetBottom
            
            NSLog("[DEBUG SCROLL] offset=%.0f / max=%.0f (content=%.0f viewport=%.0f inset=%.0f) isPinned=%@",
                  currentOffset, maxOffset, contentH, viewportH, insetBottom, isPinned ? "YES" : "NO")
        }
        #endif
        
        checkAndUpdateScrollPosition()
    }
    
    /// Check scroll position and notify delegate if changed
    private func checkAndUpdateScrollPosition() {
        guard let scrollView = scrollView else { return }
        
        // Calculate real bottom inset (excluding runway)
        let realBottomInset = scrollView.contentInset.bottom - runwayInset
        let visibleHeight = scrollView.bounds.height - realBottomInset
        
        // Only show button if content exceeds visible area
        let contentExceedsViewport = scrollView.contentSize.height > visibleHeight
        
        if !contentExceedsViewport {
            if !isAtBottom {
                isAtBottom = true
                delegate?.scrollHandler(self, didUpdateScrollPosition: true)
            }
            return
        }
        
        let newIsAtBottom = isNearBottom(scrollView)
        if newIsAtBottom != isAtBottom {
            isAtBottom = newIsAtBottom
            delegate?.scrollHandler(self, didUpdateScrollPosition: isAtBottom)
        }
    }
    
    /// Public method to scroll to bottom
    func scrollToBottomAnimated() {
        scrollToBottom(animated: true)
    }
    
    /// Called to recheck position (e.g., after content changes)
    func recheckScrollPosition() {
        checkAndUpdateScrollPosition()
    }
    
    /// Check if user is currently near the bottom of the scroll view
    func isUserNearBottom() -> Bool {
        guard let scrollView = scrollView else { return true }
        return isNearBottom(scrollView)
    }
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Dismiss keyboard by ending editing on the window
        scrollView?.window?.endEditing(true)
    }
    
    // MARK: - UIGestureRecognizerDelegate
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Allow tap gesture to work alongside scroll gestures
        return true
    }
    
    func setBaseInset(_ inset: CGFloat, preserveScrollPosition: Bool = false) {
        baseBottomInset = inset
        updateContentInset(preserveScrollPosition: preserveScrollPosition)
    }
    
    /// Adjust scroll position when composer grows to keep content visible.
    /// Only adjusts if user is near the bottom (within 100pt).
    func adjustScrollForComposerGrowth(delta: CGFloat) {
        guard let scrollView = scrollView, delta > 0 else { return }
        
        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.bounds.height
        let currentInset = scrollView.contentInset.bottom
        let currentOffset = scrollView.contentOffset.y
        
        // Check if near bottom - only adjust scroll if user is already at/near bottom
        let currentMaxOffset = max(0, contentHeight - scrollViewHeight + currentInset)
        let distanceFromBottom = currentMaxOffset - currentOffset
        let nearBottom = distanceFromBottom < 100
        
        guard nearBottom else {
            return
        }
        
        // Scroll up by the delta amount to compensate for composer growth
        let newOffset = currentOffset + delta
        
        // Clamp to valid range - account for the pending inset increase (delta)
        let bottomInset = currentInset + delta
        let maxOffset = max(0, contentHeight - scrollViewHeight + bottomInset)
        let clampedOffset = max(0, min(newOffset, maxOffset))
        
        // Apply immediately
        scrollView.setContentOffset(CGPoint(x: 0, y: clampedOffset), animated: false)
    }
    
    /// Scroll so that new content appears at the top of the visible area (ChatGPT-style).
    /// This leaves empty space below for the response to stream in.
    /// - Parameter estimatedNewContentHeight: Approximate height of new content to show at top
    func scrollNewContentToTop(estimatedHeight: CGFloat = 100) {
        guard let scrollView = scrollView else { return }
        
        // Small delay to let content layout settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self, let scrollView = self.scrollView else { return }
            
            let contentHeight = scrollView.contentSize.height
            let visibleHeight = scrollView.bounds.height
            let topInset = scrollView.contentInset.top
            
            // Calculate offset to show new content at top:
            // We want the bottom portion of content (new messages) to appear at the top of screen
            // Offset = total content - visible area + top inset + small padding for the message
            let targetOffset = contentHeight - visibleHeight + topInset + estimatedHeight
            
            // Only scroll if content is tall enough
            let minOffset = -topInset
            let offset = max(minOffset, targetOffset)
            
            UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
                scrollView.contentOffset = CGPoint(x: 0, y: offset)
            }
        }
    }
    
    // MARK: - Pin-to-Top Calculations
    
    /// Calculate and apply pin-to-top
    private func calculatePinToTopValues(messageHeight: CGFloat) {
        guard let sv = scrollView else { return }
        
        let viewportH = sv.bounds.height
        
        // IMPORTANT: Calculate from BASE inset only (no runway)
        // Otherwise old runway affects the calculation
        let keyboardOpenPadding: CGFloat = 8
        let freshBaseInset: CGFloat
        if keyboardHeight > 0 {
            freshBaseInset = baseBottomInset + keyboardHeight + keyboardOpenPadding
        } else {
            freshBaseInset = baseBottomInset + safeAreaBottom
        }
        
        // Reset runway for fresh calculation
        runwayInset = 0
        
        // Where the new message starts in content coordinates
        let newMessageY = contentSizeBeforeHide
        
        // To pin message at top: scroll so newMessageY is at top of viewport
        let topPadding: CGFloat = 8
        let pinnedOffset = newMessageY - topPadding
        
        // Max offset with BASE inset only (no runway)
        let contentH = sv.contentSize.height
        let currentMaxOffset = max(0, contentH - viewportH + freshBaseInset)
        
        // How much extra inset we need to enable scrolling to pinnedOffset
        // If pinnedOffset > currentMaxOffset, we need runway
        // No arbitrary extra values - exactly what's needed so pinnedOffset == maxOffset
        let neededRunway = max(0, pinnedOffset - currentMaxOffset)
        
        NSLog("[ScrollHandler] === PIN-TO-TOP ===")
        NSLog("[ScrollHandler] viewport=%.0f messageHeight=%.0f", viewportH, messageHeight)
        NSLog("[ScrollHandler] newMessageY=%.0f pinnedOffset=%.0f", newMessageY, pinnedOffset)
        NSLog("[ScrollHandler] currentMaxOffset=%.0f neededRunway=%.0f", currentMaxOffset, neededRunway)
        NSLog("[ScrollHandler] After pin: maxOffset will be %.0f (should equal pinnedOffset)", 
              currentMaxOffset + neededRunway)
        
        // Apply the pin
        performPinToTop(pinnedOffset: pinnedOffset, runway: neededRunway)
    }
    
    /// Apply pin-to-top: add just enough runway to enable pinned scroll
    private func performPinToTop(pinnedOffset offset: CGFloat, runway: CGFloat) {
        guard let sv = scrollView else { return }
        
        // Set state
        isPinned = true
        runwayInset = runway
        pinnedOffset = offset  // Store for scrollToBottom
        
        // Update insets (adds runway)
        updateContentInset()
        
        // Animate scroll to pinned position
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 1.0,
            initialSpringVelocity: 0,
            options: [.curveEaseOut]
        ) {
            sv.contentOffset = CGPoint(x: 0, y: offset)
        } completion: { [weak self] _ in
            guard let self = self else { return }
            NSLog("[ScrollHandler] Pin complete. offset=%.0f runway=%.0f", sv.contentOffset.y, runway)
            self.logScrollViewState(context: "after pin complete")
            
            // Notify delegate of runway change
            NSLog("[ScrollHandler] 📨 Notifying delegate of runway height: %.0f", runway)
            self.delegate?.scrollHandler(self, didUpdateRunwayHeight: runway)
            
            // Log scroll view frame and scroll state
            NSLog("[ScrollHandler] scrollView.frame=%.0f,%.0f,%.0f,%.0f", 
                  sv.frame.origin.x, sv.frame.origin.y, sv.frame.size.width, sv.frame.size.height)
            NSLog("[ScrollHandler] scrollEnabled=%@ bounces=%@ isScrollEnabled=%@", 
                  sv.isScrollEnabled ? "YES" : "NO",
                  sv.bounces ? "YES" : "NO",
                  sv.panGestureRecognizer.isEnabled ? "YES" : "NO")
        }
    }
    
    // MARK: - Diagnostics
    
    /// Log complete scroll view state for debugging
    func logScrollViewState(context: String) {
        guard let sv = scrollView else {
            NSLog("[ScrollHandler] \(context): no scrollView attached")
            return
        }
        
        let contentH = sv.contentSize.height
        let boundsH = sv.bounds.height
        let offsetY = sv.contentOffset.y
        let topInset = sv.adjustedContentInset.top
        let bottomInset = sv.contentInset.bottom
        let indicatorBottom = sv.verticalScrollIndicatorInsets.bottom
        
        // Calculate key positions
        let maxOffset = max(0, contentH - boundsH + bottomInset)
        let visibleContentTop = offsetY
        let visibleContentBottom = offsetY + boundsH - bottomInset
        
        NSLog("[ScrollHandler] === %@ ===", context)
        NSLog("[ScrollHandler] bounds.height=%.0f contentSize.height=%.0f", boundsH, contentH)
        NSLog("[ScrollHandler] contentOffset.y=%.0f maxOffset=%.0f", offsetY, maxOffset)
        NSLog("[ScrollHandler] contentInset: top=%.0f bottom=%.0f", topInset, bottomInset)
        NSLog("[ScrollHandler] indicatorInsets.bottom=%.0f", indicatorBottom)
        NSLog("[ScrollHandler] visible content range: %.0f - %.0f", visibleContentTop, visibleContentBottom)
        NSLog("[ScrollHandler] safeAreaBottom=%.0f keyboardHeight=%.0f", safeAreaBottom, keyboardHeight)
    }
}

