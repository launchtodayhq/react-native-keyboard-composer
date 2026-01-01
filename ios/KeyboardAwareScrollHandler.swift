import ExpoModulesCore
import UIKit

/// Delegate to notify when scroll position changes
protocol KeyboardAwareScrollHandlerDelegate: AnyObject {
    func scrollHandler(_ handler: KeyboardAwareScrollHandler, didUpdateScrollPosition isAtBottom: Bool)
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

    // Pin-to-top + runway state
    private var isPinned = false
    private var runwayInset: CGFloat = 0
    private var pinnedOffset: CGFloat = 0
    private var pendingPin = false
    private var pendingPinMessageStartY: CGFloat = 0
    private var pendingPinReady = false
    private var pendingPinContentHeightAfter: CGFloat = 0
    private var isPinAnimating: Bool = false
    private var userIsInteracting: Bool = false
    private var stickToPinned: Bool = false

    /// Clears any active/armed pin-to-top state (runway + pinned offset).
    /// Useful when pin-to-top is disabled at runtime.
    func clearPinState(preserveScrollPosition: Bool = true) {
        pendingPin = false
        pendingPinReady = false
        pendingPinContentHeightAfter = 0
        pendingPinMessageStartY = 0

        isPinned = false
        runwayInset = 0
        pinnedOffset = 0

        isPinAnimating = false
        stickToPinned = false

        updateContentInset(preserveScrollPosition: preserveScrollPosition)
        recheckScrollPosition()
    }

    private func ensurePinnedOffset(reason: String) {
        guard let sv = scrollView else { return }
        guard isPinned || runwayInset > 0 else { return }
        guard stickToPinned else { return }
        guard !userIsInteracting else { return }
        // Only correct meaningful drift; correcting every tick causes visible jitter and can kill animations.
        if abs(sv.contentOffset.y - pinnedOffset) > 1.5 {
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: pinnedOffset), animated: false)
        }
    }

    private func recomputeRunwayInset(baseInset: CGFloat) {
        guard isPinned, let sv = scrollView else { return }
        let viewportH = sv.bounds.height
        guard viewportH > 0 else { return }

        let contentH = sv.contentSize.height
        // Use the *unclamped* maxOffset so we can compute runway correctly even when
        // content is shorter than the viewport (rawMaxOffset is negative).
        // maxOffset = max(0, rawMaxOffset + runwayInset). We want maxOffset == pinnedOffset.
        // => runwayInset = pinnedOffset - rawMaxOffset
        let rawMaxOffset = contentH - viewportH + baseInset
        runwayInset = max(0, pinnedOffset - rawMaxOffset)
        if runwayInset == 0 {
            isPinned = false
            pinnedOffset = 0
        }
    }
    
    /// Get safe area bottom from window
    private var safeAreaBottom: CGFloat {
        scrollView?.window?.safeAreaInsets.bottom ?? 34
    }
    
    override init() {
        super.init()
        setupKeyboardObservers()
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
        
        // Check if at bottom BEFORE animation (only on initial show)
        if isInitialShow {
            // When pinned (runway active), don't treat this as "at bottom" for keyboard open behavior,
            // otherwise we'll pull the pinned content down by scrolling to a non-runway maxOffset.
            wasAtBottom = !isPinned && isNearBottom(scrollView)
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
                self.updateContentInset(preserveScrollPosition: self.isPinned)
                
                // Scroll to bottom INSIDE animation block - ONLY on initial keyboard show
                if isInitialShow && self.wasAtBottom {
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
        
        keyboardHeight = 0
        isKeyboardVisible = false  // Reset flag when keyboard hides
        
        // Use raw UIView.animate with keyboard's exact animation curve
        let animationOptions = UIView.AnimationOptions(rawValue: curveValue << 16)
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: animationOptions,
            animations: {
                // If we're about to pin, keep the visible content stable while the keyboard animates out.
                self.updateContentInset(preserveScrollPosition: self.pendingPin || self.pendingPinReady || self.isPinned)
            },
            completion: { _ in
                // If content was appended while the keyboard was still open, finish pinning after it closes.
                if self.pendingPinReady {
                    self.pendingPinReady = false
                    self.applyPinAfterSend(contentHeightAfter: self.pendingPinContentHeightAfter)
                }
            }
        )
    }
    
    private func isNearBottom(_ scrollView: UIScrollView) -> Bool {
        // When runway/pin is active, "bottom" means the pinned position (top of runway),
        // not the absolute maxOffset (which would be inside empty runway space).
        if isPinned || runwayInset > 0 {
            // Treat rubber-banding past the bottom as still "at bottom" so the scroll-to-bottom
            // button doesn't flash during bounce.
            return scrollView.contentOffset.y >= (pinnedOffset - 60)
        }

        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.bounds.height
        let bottomInset = scrollView.contentInset.bottom
        let currentOffset = scrollView.contentOffset.y
        let maxOffset = max(0, contentHeight - scrollViewHeight + bottomInset)
        
        // Consider "at bottom" if within 100pt
        return (maxOffset - currentOffset) < 100
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
        let indicatorInset: CGFloat
        let contentGap: CGFloat = 24
        let minBottomPadding: CGFloat = 16
        let composerKeyboardGap: CGFloat = 10
        let indicatorGapAboveInput: CGFloat = 1
        let composerHeight = max(0, baseBottomInset - contentGap)

        if keyboardHeight > 0 {
            // Keyboard open: base + keyboard + small padding
            baseInset = baseBottomInset + keyboardHeight + keyboardOpenPadding
            // Stop just above the composer when keyboard is open
            indicatorInset = keyboardHeight + composerKeyboardGap + composerHeight + indicatorGapAboveInput
        } else {
            // Keyboard closed: base + safe area
            baseInset = baseBottomInset + safeAreaBottom
            // Stop just above the composer when keyboard is closed
            let bottomOffset = max(safeAreaBottom, minBottomPadding)
            indicatorInset = bottomOffset + composerHeight + indicatorGapAboveInput
        }

        // Keep runway non-scrollable across keyboard/composer changes by recomputing how much
        // extra inset is needed so that maxOffset == pinnedOffset.
        if isPinned {
            recomputeRunwayInset(baseInset: baseInset)
        }
        
        let totalInset = baseInset + runwayInset
        scrollView.contentInset.bottom = totalInset
        // Indicator should behave like content ends just above the input (not at the runway)
        scrollView.verticalScrollIndicatorInsets.bottom = indicatorInset
        
        // Restore scroll position if needed (prevents visual jump when not at bottom)
        if let savedOffset = savedOffset {
            // If a pin animation is in-flight, never "lock in" a mid-animation offset.
            // Keep the scroll view at the pinned target so streaming/content growth doesn't
            // cancel the pin and snap the content down.
            if isPinAnimating && (isPinned || runwayInset > 0) {
                scrollView.setContentOffset(CGPoint(x: savedOffset.x, y: pinnedOffset), animated: false)
            } else {
                scrollView.setContentOffset(savedOffset, animated: false)
            }
        }
    }
    
    private func scrollToBottom(animated: Bool) {
        guard let scrollView = scrollView else { return }

        // When pin/runway is active, "bottom" should mean the pinned position (top of runway),
        // not the absolute maxOffset which would land in empty runway space.
        if isPinned || runwayInset > 0 {
            scrollView.setContentOffset(CGPoint(x: 0, y: pinnedOffset), animated: animated)
            return
        }

        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.bounds.height
        let bottomInset = scrollView.contentInset.bottom
        let maxOffset = max(0, contentHeight - scrollViewHeight + bottomInset)

        scrollView.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: animated)
    }
    
    // MARK: - Public API
    
    private var tapGesture: UITapGestureRecognizer?
    private var contentSizeObservation: NSKeyValueObservation?
    
    func attach(to scrollView: UIScrollView) {
        self.scrollView = scrollView
        if #available(iOS 13.0, *) {
            // Ensure our manual `verticalScrollIndicatorInsets` values take effect.
            scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        scrollView.delegate = self
        updateContentInset()
        
        // Add tap gesture to dismiss keyboard
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false // Allow other touches to pass through
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)
        tapGesture = tap
        
        // Observe content size changes
        contentSizeObservation = scrollView.observe(\.contentSize, options: [.new, .old]) { [weak self] _, change in
            guard let self,
                  let oldSize = change.oldValue,
                  let newSize = change.newValue,
                  oldSize.height != newSize.height
            else { return }

            // Pin is armed first, then executed on the next content growth (user message append).
            if self.pendingPin && newSize.height > oldSize.height {
                self.pendingPin = false
                // If the keyboard is still open/animating, defer the pin until keyboard hide completes
                // to avoid the "content moves down, then up" effect.
                if self.keyboardHeight > 0 || self.isKeyboardVisible {
                    self.pendingPinReady = true
                    self.pendingPinContentHeightAfter = newSize.height
                } else {
                    self.applyPinAfterSend(contentHeightAfter: newSize.height)
                }
            } else if self.isPinned && self.runwayInset > 0 && newSize.height > oldSize.height {
                let growth = newSize.height - oldSize.height
                self.consumeRunway(by: growth)
            }

            DispatchQueue.main.async {
                self.checkAndUpdateScrollPosition()
            }
        }
    }
    
    // MARK: - UIScrollViewDelegate
    
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        checkAndUpdateScrollPosition()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userIsInteracting = true
        stickToPinned = false
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            userIsInteracting = false
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userIsInteracting = false
    }
    
    /// Check scroll position and notify delegate if changed
    private func checkAndUpdateScrollPosition() {
        guard let scrollView = scrollView else { return }
        
        // Only show button if content exceeds viewport
        let contentExceedsViewport = scrollView.contentSize.height > scrollView.bounds.height
        
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

    // MARK: - Pin-to-top (public)

    /// Arm pin-to-top: the next content append will be pinned to the top, and a runway will be created below.
    func requestPinForNextContentAppend() {
        guard let sv = scrollView else { return }

        // Reset any previous pin/runway
        pendingPin = true
        pendingPinReady = false
        pendingPinContentHeightAfter = 0
        isPinned = false
        runwayInset = 0
        pinnedOffset = 0

        // For bottom-appended lists: the new message starts where content ends right now.
        pendingPinMessageStartY = sv.contentSize.height
        updateContentInset(preserveScrollPosition: true)
    }

    // MARK: - Pin-to-top (internal)

    private func applyPinAfterSend(contentHeightAfter: CGFloat) {
        guard let sv = scrollView else { return }

        let viewportH = sv.bounds.height
        guard viewportH > 0 else { return }

        // Fresh base inset (no runway)
        let keyboardOpenPadding: CGFloat = 8
        let baseInset: CGFloat
        if keyboardHeight > 0 {
            baseInset = baseBottomInset + keyboardHeight + keyboardOpenPadding
        } else {
            baseInset = baseBottomInset + safeAreaBottom
        }

        // Pin so the new message appears at the top of the viewport (small padding for feel)
        // Increased to avoid being too close to the header/nav bar.
        let topPadding: CGFloat = 16
        let desiredPinnedOffset = max(0, pendingPinMessageStartY - topPadding)

        // Current max offset with base inset only (UNCLAMPED so we don't lose the deficit when content < viewport).
        let rawMaxOffset = contentHeightAfter - viewportH + baseInset

        // Runway is "just enough" extra inset to make maxOffset == desiredPinnedOffset
        // maxOffset = max(0, rawMaxOffset + runwayInset). We want maxOffset == desiredPinnedOffset.
        // => runwayInset = desiredPinnedOffset - rawMaxOffset
        let neededRunway = max(0, desiredPinnedOffset - rawMaxOffset)

        isPinned = true
        pinnedOffset = desiredPinnedOffset
        runwayInset = neededRunway
        // updateContentInset will also reconcile runway for current baseInset
        updateContentInset(preserveScrollPosition: true)

        // Smooth pin animation (configurable feel)
        let pinDelay: TimeInterval = 0
        // Slightly longer so the deceleration is perceptible near the top
        let pinDuration: TimeInterval = 0.28
        let targetOffset = CGPoint(x: 0, y: desiredPinnedOffset)

        // Mark pin animation in-flight so content growth won't preserve an intermediate offset.
        isPinAnimating = true
        // Don't enforce pinned offset while the pin animation is running (it would cancel the animation).
        stickToPinned = false

        // Animate contentOffset with a UIKit animator so we can control timing/curve.
        // Stronger ease-out curve: fast start, slow finish
        let timing = UICubicTimingParameters(
            controlPoint1: CGPoint(x: 0.10, y: 0.90),
            controlPoint2: CGPoint(x: 0.20, y: 1.00)
        )
        let animator = UIViewPropertyAnimator(duration: pinDuration, timingParameters: timing)
        animator.addAnimations {
            sv.contentOffset = targetOffset
        }
        animator.addCompletion { [weak self, weak sv] _ in
            guard let self, let sv else { return }
            self.isPinAnimating = false
            // Ensure we land exactly on the pinned target.
            sv.setContentOffset(targetOffset, animated: false)
            // Start enforcing pinned offset only after the animation completes (for streaming).
            self.stickToPinned = true
        }
        animator.startAnimation(afterDelay: pinDelay)

        // Clearing pinned state (if runway reaches 0) is handled by recomputeRunwayInset.
    }

    private func consumeRunway(by contentGrowth: CGFloat) {
        guard contentGrowth > 0 else { return }

        // Content grew (streaming). Recompute runway based on new content size.
        updateContentInset(preserveScrollPosition: true)
        // Force pinned target after each content growth (streaming), unless user is dragging.
        ensurePinnedOffset(reason: "consumeRunway")
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
    
}

