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
    /// Single source of truth for keyboard metrics (height + animation params).
    /// Consumers (e.g., wrapper) can animate UI in sync with iOS keyboard.
    var onKeyboardMetricsChanged: ((CGFloat, Double, UInt) -> Void)?
    /// Base inset WITHOUT safe area (composer + gap)
    var baseBottomInset: CGFloat = 64 // 48 + 16
    private var keyboardHeight: CGFloat = 0
    private var wasAtBottom = false
    private var isAtBottom = true
    private var isKeyboardVisible = false  // Track if keyboard is already showing
    private var isKeyboardHiding: Bool = false
    private let dismissKeyboardVelocityThreshold: CGFloat = -1.2

    // Pin-to-top + runway state
    private enum PinState {
        case idle
        case armed(messageStartY: CGFloat)
        case deferred(messageStartY: CGFloat, contentHeightAfter: CGFloat)
        case animating(targetOffset: CGFloat)
        case pinned(targetOffset: CGFloat, enforce: Bool)
    }

    private var pinState: PinState = .idle
    private var runwayInset: CGFloat = 0
    private var pinnedOffset: CGFloat = 0
    private var userIsInteracting: Bool = false
    private var pendingPinnedCorrection: Bool = false
    private var lastPinnedCorrectionTime: CFTimeInterval = 0
    // During streaming, avoid micro-corrections and avoid correcting every frame.
    private let pinnedDriftThreshold: CGFloat = 3.0
    private let pinnedCorrectionMinInterval: CFTimeInterval = 1.0 / 30.0

    private var isPinActive: Bool {
        switch pinState {
        case .animating, .pinned:
            return true
        case .idle, .armed, .deferred:
            return false
        }
    }

    private var isPinAnimating: Bool {
        if case .animating = pinState { return true }
        return false
    }

    private var shouldPreserveScrollDuringInsetUpdates: Bool {
        switch pinState {
        case .idle:
            return false
        case .armed, .deferred, .animating, .pinned:
            return true
        }
    }

    private var isPinnedOrRunwayActive: Bool {
        isPinActive || runwayInset > 0
    }

    // NOTE: We intentionally avoid trying to animate individual message views here.
    // With a generic UIScrollView containing React Native-managed subviews, reliably finding
    // "the new message row" is brittle and can cause glitches (including full-content flashes).

    

    private func findScrollContentContainerView(in sv: UIScrollView) -> UIView? {
        // RN ScrollView typically has a single content container that matches contentSize.
        if sv.contentSize.height > 0 {
            if let match = sv.subviews.first(where: { v in
                abs(v.frame.height - sv.contentSize.height) < 2 &&
                v.frame.width >= sv.bounds.width - 2
            }) {
                return match
            }
        }
        // Fallback: largest subview (scroll indicators are small).
        return sv.subviews.max(by: {
            ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
        })
    }

    /// Clears any active/armed pin-to-top state (runway + pinned offset).
    /// Useful when pin-to-top is disabled at runtime.
    func clearPinState(preserveScrollPosition: Bool = true) {
        pinState = .idle
        runwayInset = 0
        pinnedOffset = 0

        updateContentInset(preserveScrollPosition: preserveScrollPosition)
        recheckScrollPosition()
    }

    private func ensurePinnedOffset(reason: String) {
        guard let sv = scrollView else { return }
        guard isPinnedOrRunwayActive else { return }
        guard !userIsInteracting else { return }
        guard case .pinned(_, let enforce) = pinState, enforce else { return }
        // Only correct meaningful drift; correcting too frequently causes visible jitter.
        if abs(sv.contentOffset.y - pinnedOffset) > pinnedDriftThreshold {
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: pinnedOffset), animated: false)
        }
    }

    private func schedulePinnedOffsetCorrection(reason: String) {
        guard case .pinned(_, let enforce) = pinState, enforce else { return }
        guard !pendingPinnedCorrection else { return }
        pendingPinnedCorrection = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingPinnedCorrection = false
            let now = CACurrentMediaTime()
            if (now - self.lastPinnedCorrectionTime) < self.pinnedCorrectionMinInterval {
                return
            }
            self.lastPinnedCorrectionTime = now
            self.ensurePinnedOffset(reason: reason)
        }
    }

    private func recomputeRunwayInset(baseInset: CGFloat) {
        guard isPinActive, let sv = scrollView else { return }
        let viewportH = sv.bounds.height
        guard viewportH > 0 else { return }

        let contentH = sv.contentSize.height
        // Use the *unclamped* maxOffset so we can compute runway correctly even when
        // content is shorter than the viewport (rawMaxOffset is negative).
        // Keep runway non-scrollable by making the scroll view's max offset land on `pinnedOffset`.
        // maxOffset = rawMaxOffset + runwayInset. We want maxOffset == pinnedOffset.
        // => runwayInset = pinnedOffset - rawMaxOffset
        let rawMaxOffset = contentH - viewportH + baseInset
        runwayInset = max(0, pinnedOffset - rawMaxOffset)
        // When runway is fully consumed (content became tall enough), stop treating the scroll view as pinned.
        // Otherwise, keyboard open logic stays disabled and the keyboard can overlay content.
        if runwayInset == 0 {
            pinnedOffset = 0
            pinState = .idle
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    private func shouldAdjustScrollForKeyboard(_ scrollView: UIScrollView, keyboardHeight: CGFloat) -> Bool {
        // If the user is manually scrolling (pinned but not enforcing), allow the keyboard adjustment.
        let pinBlocksKeyboardAdjust: Bool = {
            switch self.pinState {
            case .pinned(_, let enforce):
                return enforce
            case .animating:
                return true
            case .idle, .armed, .deferred:
                return false
            }
        }()
        guard !pinBlocksKeyboardAdjust else { return false }

        // Decide based on where "bottom" will be AFTER the keyboard opens.
        // This fixes the case where content doesn't yet scroll with the keyboard closed,
        // but would become covered once the keyboard appears.
        let threshold = max(140, min(520, keyboardHeight + 80))

        let composerKeyboardGap: CGFloat = 10
        let projectedBottomInset = baseBottomInset + keyboardHeight + composerKeyboardGap
        let projectedMaxOffset = max(
            0,
            scrollView.contentSize.height - scrollView.bounds.height + projectedBottomInset
        )

        // If the content doesn't currently exceed the viewport, the user can't be "reading older messages"
        // by scrolling up — so when the keyboard opens and introduces a projected scroll range,
        // always adjust to keep bottom content visible above the composer/keyboard.
        let contentExceedsViewport = scrollView.contentSize.height > scrollView.bounds.height
        if !contentExceedsViewport {
            return projectedMaxOffset > 0.5
        }

        let distanceFromProjectedBottom = projectedMaxOffset - scrollView.contentOffset.y
        return distanceFromProjectedBottom < threshold
    }
    
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }
        
        let newKeyboardHeight = keyboardFrame.height
        onKeyboardMetricsChanged?(newKeyboardHeight, duration, curveValue)
        guard let scrollView = scrollView else { return }
        
        // Only do certain bookkeeping on initial show, but scroll adjustment is driven by `shouldAdjust`.
        let isInitialShow = !isKeyboardVisible
        isKeyboardVisible = true
        
        // Decide once for this open based on the projected keyboard-covered area.
        // When pinned (runway active + enforced), `shouldAdjustScrollForKeyboard` returns false.
        let shouldAdjust = shouldAdjustScrollForKeyboard(scrollView, keyboardHeight: newKeyboardHeight)
        if isInitialShow {
            wasAtBottom = shouldAdjust
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
                self.updateContentInset(preserveScrollPosition: self.isPinActive)
                
                // Scroll to bottom INSIDE animation block if we want content above the keyboard.
                if shouldAdjust {
                    let contentHeight = scrollView.contentSize.height
                    let scrollViewHeight = scrollView.bounds.height
                    let bottomInset = scrollView.contentInset.bottom
                    let maxOffset = max(0, contentHeight - scrollViewHeight + bottomInset)
                    scrollView.contentOffset = CGPoint(x: 0, y: maxOffset)
                }
            },
            completion: { _ in
                // The scroll view can clamp the in-animation `contentOffset` because the new `contentInset`
                // hasn't fully taken effect yet. Re-apply once at the end.
                if shouldAdjust {
                    self.scrollToBottom(animated: false)
                }
            }
        )
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }
        
        onKeyboardMetricsChanged?(0, duration, curveValue)
        guard let scrollView = scrollView else { return }

        keyboardHeight = 0
        isKeyboardVisible = false  // Reset flag when keyboard hides
        isKeyboardHiding = true
        
        // Use raw UIView.animate with keyboard's exact animation curve
        let animationOptions = UIView.AnimationOptions(rawValue: curveValue << 16)
        
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: animationOptions,
            animations: {
                // If we're about to pin, keep the visible content stable while the keyboard animates out.
                // Also preserve when content doesn't exceed the viewport, otherwise inset changes can
                // "pull" the content down as the keyboard closes.
                let contentExceedsViewport = scrollView.contentSize.height > scrollView.bounds.height
                let preserve = self.shouldPreserveScrollDuringInsetUpdates || !contentExceedsViewport
                self.updateContentInset(preserveScrollPosition: preserve)
            },
            completion: { _ in
                self.isKeyboardHiding = false
                // If content was appended while the keyboard was still open, finish pinning after it closes.
                if case .deferred(let messageStartY, let contentHeightAfter) = self.pinState {
                    self.pinState = .idle
                    self.applyPinAfterSend(messageStartY: messageStartY, contentHeightAfter: contentHeightAfter)
                }
            }
        )
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let keyboardFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveValue = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        let screenHeight = UIScreen.main.bounds.height
        let isVisibleByFrame = keyboardFrame.origin.y < screenHeight
        let newKeyboardHeight = isVisibleByFrame ? keyboardFrame.height : 0

        if abs(newKeyboardHeight - keyboardHeight) <= 0.5 { return }
        onKeyboardMetricsChanged?(newKeyboardHeight, duration, curveValue)

        guard let scrollView = scrollView else {
            keyboardHeight = newKeyboardHeight
            isKeyboardVisible = newKeyboardHeight > 0.5
            return
        }

        let wasVisible = isKeyboardVisible
        keyboardHeight = newKeyboardHeight
        isKeyboardVisible = newKeyboardHeight > 0.5
        let shouldAdjust = shouldAdjustScrollForKeyboard(scrollView, keyboardHeight: newKeyboardHeight)
        if !wasVisible && isKeyboardVisible {
            wasAtBottom = shouldAdjust
        }

        let animationOptions = UIView.AnimationOptions(rawValue: curveValue << 16)
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: animationOptions,
            animations: {
                self.updateContentInset(preserveScrollPosition: self.isPinActive)
                if shouldAdjust {
                    let contentHeight = scrollView.contentSize.height
                    let scrollViewHeight = scrollView.bounds.height
                    let bottomInset = scrollView.contentInset.bottom
                    let maxOffset = max(0, contentHeight - scrollViewHeight + bottomInset)
                    scrollView.contentOffset = CGPoint(x: 0, y: maxOffset)
                }
            },
            completion: { _ in
                if shouldAdjust {
                    self.scrollToBottom(animated: false)
                }
            }
        )
    }
    
    private func isNearBottom(_ scrollView: UIScrollView, threshold: CGFloat = 100) -> Bool {
        // When runway/pin is active, "bottom" means the pinned position (top of runway),
        // not the absolute maxOffset (which would be inside empty runway space).
        if isPinnedOrRunwayActive {
            // Treat rubber-banding past the bottom as still "at bottom" so the scroll-to-bottom
            // button doesn't flash during bounce.
            return scrollView.contentOffset.y >= (pinnedOffset - 60)
        }

        let contentHeight = scrollView.contentSize.height
        let scrollViewHeight = scrollView.bounds.height
        let bottomInset = scrollView.contentInset.bottom
        let currentOffset = scrollView.contentOffset.y
        let maxOffset = max(0, contentHeight - scrollViewHeight + bottomInset)
        
        // Consider "at bottom" if within threshold points
        return (maxOffset - currentOffset) < threshold
    }
    
    private func updateContentInset(preserveScrollPosition: Bool = false) {
        guard let scrollView = scrollView else { return }
        
        // Save current scroll position if we need to preserve it
        let savedOffset = preserveScrollPosition ? scrollView.contentOffset : nil
        
        let baseInset: CGFloat
        let indicatorInset: CGFloat
        let minBottomPadding: CGFloat = 16
        let composerKeyboardGap: CGFloat = 10
        let indicatorGapAboveInput: CGFloat = 1
        let composerHeight = max(0, baseBottomInset)

        if keyboardHeight > 0 {
            // Keyboard open: match wrapper's composer transform (keyboard height + gap)
            baseInset = baseBottomInset + keyboardHeight + composerKeyboardGap
            // Stop just above the composer when keyboard is open
            indicatorInset = keyboardHeight + composerKeyboardGap + composerHeight + indicatorGapAboveInput
        } else {
            let bottomOffset = max(safeAreaBottom, minBottomPadding)
            // Keyboard closed: match wrapper (safe area OR minimum padding)
            baseInset = baseBottomInset + bottomOffset
            // Stop just above the composer when keyboard is closed
            indicatorInset = bottomOffset + composerHeight + indicatorGapAboveInput
        }

        // Keep runway non-scrollable across keyboard/composer changes by recomputing how much
        // extra inset is needed so that maxOffset == pinnedOffset.
        if isPinActive {
            recomputeRunwayInset(baseInset: baseInset)
        }
        
        let totalInset = baseInset + runwayInset
        scrollView.contentInset.bottom = totalInset
        // Indicator should behave like content ends just above the input (not at the runway)
        scrollView.verticalScrollIndicatorInsets.bottom = indicatorInset
        
        // Restore scroll position if needed (prevents visual jump when not at bottom)
        if let savedOffset = savedOffset {
            // When pin-to-top is active, inset changes can race with contentSize growth (streaming),
            // causing a visible "bob" as we restore the old offset then correct back to pinnedOffset.
            // If we're enforcing a pinned offset, always restore directly to the pinned target.
            if case .pinned(_, let enforce) = pinState, enforce, isPinnedOrRunwayActive {
                scrollView.setContentOffset(CGPoint(x: savedOffset.x, y: pinnedOffset), animated: false)
            }
            // If a pin animation is in-flight, never "lock in" a mid-animation offset.
            // Keep the scroll view at the pinned target so streaming/content growth doesn't
            // cancel the pin and snap the content down.
            else if isPinAnimating && isPinnedOrRunwayActive {
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
        if isPinnedOrRunwayActive {
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
        // Enable native keyboard dismissal by dragging the scroll view.
        // This matches ChatGPT-style behavior on iOS.
        scrollView.keyboardDismissMode = .interactive
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
            if case .armed(let messageStartY) = self.pinState, newSize.height > oldSize.height {
                // When a send triggers keyboard dismiss, pin while the keyboard is animating out.
                // This avoids a two-phase "down then up" motion.
                self.pinState = .idle
                self.applyPinAfterSend(messageStartY: messageStartY, contentHeightAfter: newSize.height)
            } else if self.isPinActive && self.runwayInset > 0 && newSize.height > oldSize.height {
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
        if case .pinned(let targetOffset, _) = pinState {
            pinState = .pinned(targetOffset: targetOffset, enforce: false)
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate {
            userIsInteracting = false
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        userIsInteracting = false
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard isKeyboardVisible || keyboardHeight > 0.5 else { return }
        // velocity.y < 0 means the user is pulling down (a "dismiss" gesture).
        if velocity.y <= dismissKeyboardVelocityThreshold {
            scrollView.window?.endEditing(true)
        }
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
        pinState = .idle
        runwayInset = 0
        pinnedOffset = 0

        // For bottom-appended lists: the new message starts where content ends right now.
        let messageStartY = sv.contentSize.height
        pinState = .armed(messageStartY: messageStartY)
        updateContentInset(preserveScrollPosition: true)
    }

    // MARK: - Pin-to-top (internal)

    private func applyPinAfterSend(messageStartY: CGFloat, contentHeightAfter: CGFloat) {
        guard let sv = scrollView else { return }
        // If a pin animation is already running, don't start another.
        guard !isPinAnimating else { return }

        let viewportH = sv.bounds.height
        guard viewportH > 0 else { return }

        // Fresh base inset (no runway)
        let baseInset: CGFloat
        if keyboardHeight > 0 {
            baseInset = baseBottomInset + keyboardHeight
        } else {
            baseInset = baseBottomInset + safeAreaBottom
        }

        // Pin so the new message appears at the top of the viewport.
        //
        // IMPORTANT:
        // - `adjustedContentInset.top` affects the *coordinate system* (min contentOffset is -adjustedInset.top).
        // - `topPadding` should be a small *visual gap*, not the inset itself.
        //
        // If we use `contentInset.top` as the "padding", we can end up pinning too high and allow a large
        // scrollable blank area above the pinned message.
        let topPadding: CGFloat = 16
        let topInset: CGFloat = sv.adjustedContentInset.top
        let minOffsetY: CGFloat = -topInset

        // messageStartY is expressed in content coordinates (y inside the scroll content).
        // Convert into scroll offset space by subtracting the top inset that defines the coordinate system.
        let desiredPinnedOffset = messageStartY - topPadding - topInset

        // Current max offset with base inset only (UNCLAMPED so we don't lose the deficit when content < viewport).
        // This max offset is in normalized space (>= 0).
        let rawMaxOffset = contentHeightAfter - viewportH + baseInset

        // Runway is "just enough" extra inset to make maxOffset land on the pinned offset:
        // maxOffset = rawMaxOffset + runwayInset. We want maxOffset == desiredPinnedOffset.
        // => runwayInset = desiredPinnedOffset - rawMaxOffset
        let neededRunway = max(0, desiredPinnedOffset - rawMaxOffset)

        pinnedOffset = desiredPinnedOffset
        runwayInset = neededRunway
        // We haven't started the pin animator yet. Keep state non-animating so inset updates
        // don't pre-jump the scroll view to the target (which would remove the scroll animation).
        pinState = .pinned(targetOffset: desiredPinnedOffset, enforce: false)
        // updateContentInset will also reconcile runway for current baseInset
        updateContentInset(preserveScrollPosition: true)
        let targetOffset = CGPoint(x: 0, y: desiredPinnedOffset)
        let deltaY = abs(sv.contentOffset.y - desiredPinnedOffset)
        let shouldAnimateOffset = deltaY > 0.5
        let isFirstMessagePin = messageStartY <= 0.5

        // If we're already effectively at the target offset (common for the very first message),
        // don't run a reveal animation; it creates a visible flash without any meaningful scroll.
        if !shouldAnimateOffset {
            sv.setContentOffset(targetOffset, animated: false)
            pinState = .pinned(targetOffset: desiredPinnedOffset, enforce: true)
            return
        }

        // Smooth, consistent-feel pin animation:
        // Use a velocity-based duration so small scrolls don't feel sluggish with easeOut,
        // and large scrolls don't feel overly slow.
        let velocity: CGFloat = 1800 // points/sec (tuned by feel)
        let minDuration: TimeInterval = 0.16
        let maxDuration: TimeInterval = 0.26
        let pinDuration = min(maxDuration, max(minDuration, TimeInterval(deltaY / velocity)))
        pinState = .animating(targetOffset: desiredPinnedOffset)

        // Animate contentOffset with a UIKit animator so we can control timing/curve.
        let timing = UICubicTimingParameters(animationCurve: .easeOut)

        // Optional subtle "reveal" animation, but never for the first message pin.
        let shouldAnimateReveal = (!userIsInteracting && !isFirstMessagePin)
        let container = (shouldAnimateReveal ? findScrollContentContainerView(in: sv) : nil)
        let originalAlpha = container?.alpha ?? 1
        let originalTransform = container?.transform ?? .identity
        if let container {
            container.alpha = min(container.alpha, 0.96)
            container.transform = container.transform.concatenating(CGAffineTransform(translationX: 0, y: 6))
        }

        let animator = UIViewPropertyAnimator(duration: pinDuration, timingParameters: timing)
        animator.addAnimations {
            sv.contentOffset = targetOffset
            container?.alpha = originalAlpha
            container?.transform = originalTransform
        }
        animator.addCompletion { [weak self, weak sv] _ in
            guard let self, let sv else { return }
            sv.setContentOffset(targetOffset, animated: false)
            self.pinState = .pinned(targetOffset: desiredPinnedOffset, enforce: true)
            if let container {
                container.alpha = originalAlpha
                container.transform = originalTransform
            }
        }
        animator.startAnimation()

        // Clearing pinned state (if runway reaches 0) is handled by recomputeRunwayInset.
    }

    private func consumeRunway(by contentGrowth: CGFloat) {
        guard contentGrowth > 0 else { return }

        // Content grew (streaming). Recompute runway based on new content size.
        updateContentInset(preserveScrollPosition: true)
        // During streaming, contentSize can grow many times per second.
        // Coalesce corrections to at most once per runloop to avoid visible snapping.
        schedulePinnedOffsetCorrection(reason: "consumeRunway")
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

