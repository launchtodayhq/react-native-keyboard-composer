package expo.modules.launchhq.reactnativekeyboardcomposer

import android.content.Context
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import android.widget.ScrollView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.views.ExpoView
import kotlin.math.abs

/**
 * Keyboard-aware wrapper for Android.
 * 
 * Manages both ScrollView content AND composer position from the same
 * WindowInsetsAnimationCompat callback for perfect sync.
 */
class KeyboardAwareWrapper(context: Context, appContext: AppContext) : ExpoView(context, appContext) {

    companion object {
        private const val CONTENT_GAP_DP = 24
        private const val COMPOSER_KEYBOARD_GAP_DP = 8
        private const val BUTTON_SIZE_DP = 32
        private const val BUTTON_GAP_DP = 24   // Gap between button and input
        private const val PINNED_TOP_PADDING_DP = 16
        private const val DEBUG_LOGS = true
        private const val TAG = "KeyboardComposerNative"
    }
    
    // Track actual composer height (measured from view, not prop)
    private var lastComposerHeight: Int = 0

    private var _pinToTopEnabled: Boolean = false
    var pinToTopEnabled: Boolean
        get() = _pinToTopEnabled
        set(value) {
            _pinToTopEnabled = value
            if (!value) {
                clearPinnedState()
                // If pin-to-top is disabled while the IME animation left a translation,
                // reset it so content doesn't appear "dragged".
                scrollView?.getChildAt(0)?.translationY = 0f
                updateScrollPadding()
                post { checkAndUpdateScrollPosition() }
            }
        }

    private var _extraBottomInset: Float = 64f
    var extraBottomInset: Float
        get() = _extraBottomInset
        set(value) {
            val oldValue = _extraBottomInset
            _extraBottomInset = value
            
            // DON'T adjust scroll here - this causes double-handling because:
            // 1. Native layout listener detects height change and adjusts scroll
            // 2. JS receives onHeightChange, updates state
            // 3. Prop comes back here - if we adjust scroll again, it causes jitter
            // 
            // The native layout listener (setupComposerHeightListener) handles scroll adjustment.
            // This prop is only used as a fallback for padding when lastComposerHeight is 0.
            
            // Update padding and button position only
            updateScrollPadding()
            updateScrollButtonPosition()
        }
    
    private var _scrollToTopTrigger: Double = 0.0
    var scrollToTopTrigger: Double
        get() = _scrollToTopTrigger
        set(value) {
            _scrollToTopTrigger = value
            if (value > 0 && pinToTopEnabled) {
                requestPinForNextContentAppend()
            }
        }

    private var scrollView: ScrollView? = null
    private var composerView: KeyboardComposerView? = null
    private var composerContainer: View? = null
    private var hasAttached = false
    private var safeAreaBottom = 0
    private var currentKeyboardHeight = 0
    
    private val scrollToBottomButtonController: ScrollToBottomButtonController by lazy {
        ScrollToBottomButtonController(
            context = context,
            parent = this,
            buttonSizePx = dpToPx(BUTTON_SIZE_DP),
            dpToPxInt = { dpToPx(it) },
            dpToPxFloat = { dpToPx(it) },
            isDarkMode = { isDarkMode() },
            calculateTranslationY = { calculateButtonTranslationY() },
            onClick = { scrollToBottom() }
        )
    }
    private var isAtBottom = true
    private var suppressScrollButtonVisibility = false

    // Pin-to-top + runway state (Android uses paddingBottom as the "inset")
    private var isPinned = false
    private var runwayInsetPx = 0
    private var pinnedScrollY = 0
    private var pendingPin = false
    private var pendingPinMessageStartY = 0
    private var pendingPinReady = false
    private var pendingPinContentHeightAfter = 0
    private var lastContentHeight = 0

    
    // Layout listener to detect composer height changes
    private var composerLayoutListener: View.OnLayoutChangeListener? = null

    init {
        clipChildren = false
        clipToPadding = false
        scrollToBottomButtonController.createIfNeeded()
    }
    
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val newSafeAreaBottom = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            if (newSafeAreaBottom != safeAreaBottom) {
                safeAreaBottom = newSafeAreaBottom
                applyComposerTranslation()
                // Update button position now that we have correct safe area
                scrollToBottomButtonController.updatePosition()
                updateScrollPadding()
            }
            insets
        }

        // Ensure we receive an initial insets pass on first render.
        ViewCompat.requestApplyInsets(this)
        post {
            // Some devices/layouts don't dispatch the listener until an insets-affecting change (e.g. IME).
            // Pull from root insets once after layout so the composer isn't under the nav bar on first paint.
            if (updateSafeAreaBottomFromRootInsets()) {
                applyComposerTranslation()
                scrollToBottomButtonController.updatePosition()
                updateScrollPadding()
            }
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        val width = right - left
        val height = bottom - top

        if (DEBUG_LOGS) {
            android.util.Log.w(TAG, "Wrapper onLayout changed=$changed size=${width}x$height childCount=$childCount")
        }

        scrollToBottomButtonController.layout(width, height)
        scrollToBottomButtonController.updatePosition()
        
        if (!hasAttached) {
            post { findAndAttachViews() }
        }
    }
    
    private fun getBasePaddingBottomPx(): Int {
        val contentGap = dpToPx(CONTENT_GAP_DP)
        val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
        // When the IME is dismissing, some devices report intermediate IME heights that dip
        // below the navigation bar inset. Never allow bottom space to go below safeAreaBottom,
        // otherwise the composer can briefly slide behind the nav bar and then jump back up.
        val bottomSpace = maxOf(safeAreaBottom, currentKeyboardHeight)
        return composerHeight + contentGap + bottomSpace
    }

    private fun updateScrollPadding() {
        val sv = scrollView ?: return
        val basePaddingBottom = getBasePaddingBottomPx()
        if (isPinned) {
            recomputeRunwayInset(basePaddingBottom)
        }
        val finalPadding = basePaddingBottom + runwayInsetPx
        sv.setPadding(sv.paddingLeft, sv.paddingTop, sv.paddingRight, finalPadding)
    }

    private fun findAndAttachViews() {
        if (hasAttached) return
        
        val sv = findScrollView(this)
        val composer = findComposerView(this)

        if (DEBUG_LOGS) {
            android.util.Log.w(TAG, "findAndAttachViews sv=${sv?.javaClass?.simpleName} composer=${composer?.javaClass?.simpleName}")
        }
        
        if (sv != null) {
            scrollView = sv
            composerView = composer
            composer?.onNativeSend = {
                if (pinToTopEnabled) {
                    requestPinForNextContentAppend()
                }
            }
            
            var container: View? = composer
            var depth = 0
            while (container != null && container.parent != this && container.parent is View) {
                container = container.parent as? View
                depth++
                (container as? ViewGroup)?.let {
                    it.clipChildren = false
                    it.clipToPadding = false
                }
            }
            composerContainer = container
            (container as? ViewGroup)?.let {
                it.clipChildren = false
                it.clipToPadding = false
            }
            
            // Initialize lastComposerHeight from actual composer
            composer?.let { comp ->
                if (comp.height > 0) {
                    lastComposerHeight = comp.height
                }
            }
            
            hasAttached = true
            setupKeyboardAnimation(sv, composer, composerContainer)
            setupScrollListener(sv)
            setupComposerHeightListener(composer)
            updateSafeAreaBottomFromRootInsets()
            applyComposerTranslation()
            updateScrollButtonPosition()

            if (DEBUG_LOGS) {
                val content = sv.getChildAt(0)
                android.util.Log.w(
                    TAG,
                    "attached svSize=${sv.width}x${sv.height} scrollY=${sv.scrollY} contentH=${content?.height} composerH=${composer?.height} composerContainer=${composerContainer?.javaClass?.simpleName}"
                )
            }
        } else {
            // Try again on the next layout pass (avoid timed delays)
            viewTreeObserver.addOnGlobalLayoutListener(object : ViewTreeObserver.OnGlobalLayoutListener {
                override fun onGlobalLayout() {
                    viewTreeObserver.removeOnGlobalLayoutListener(this)
                    post { findAndAttachViews() }
                }
            })
        }
    }

    private fun updateSafeAreaBottomFromRootInsets(): Boolean {
        val rootInsets = ViewCompat.getRootWindowInsets(this) ?: return false
        val navBottom = rootInsets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
        if (navBottom != safeAreaBottom) {
            safeAreaBottom = navBottom
            return true
        }
        return false
    }

    private fun applyComposerTranslation() {
        val container = composerContainer ?: return
        val composerGap = dpToPx(COMPOSER_KEYBOARD_GAP_DP)
        // Clamp to safe area so the composer never dips behind the nav bar during IME close.
        val composerBottomOffset = maxOf(safeAreaBottom, currentKeyboardHeight)
        container.translationY = -(composerBottomOffset + composerGap).toFloat()
    }
    
    private fun setupComposerHeightListener(composer: KeyboardComposerView?) {
        composer ?: return
        
        // Initialize with current height if available
        if (composer.height > 0) {
            lastComposerHeight = composer.height
        } else {
            // Height not available yet, try after layout
            composer.post {
                if (lastComposerHeight <= 0 && composer.height > 0) {
                    lastComposerHeight = composer.height
                    updateScrollPadding()
                    updateScrollButtonPosition()
                }
            }
        }
        
        composerLayoutListener = View.OnLayoutChangeListener { view, _, _, _, bottom, _, oldTop, _, oldBottom ->
            val newHeight = view.height
            
            if (newHeight > 0 && newHeight != lastComposerHeight) {
                val delta = newHeight - lastComposerHeight
                
                // Store old height before updating
                val oldComposerHeight = lastComposerHeight
                lastComposerHeight = newHeight
                
                // IMPORTANT: Update padding FIRST so maxScroll is correct for scrolling
                updateScrollPadding()
                
                // Now adjust scroll position (padding is already updated)
                if (oldComposerHeight > 0) {
                    handleComposerHeightChange(delta)
                }
                
                updateScrollButtonPosition()
            }
        }
        
        composer.addOnLayoutChangeListener(composerLayoutListener)
    }
    
    private fun handleComposerHeightChange(delta: Int) {
        val sv = scrollView ?: return
        
        val currentScrollY = sv.scrollY
        val currentMaxScroll = getMaxScroll(sv)
        val nearBottom = isNearBottom(sv, dpToPx(100))
        
        if (!nearBottom) return
        
        if (delta > 0) {
            // Composer grew: scroll UP to keep last message visible
            val newScrollY = (currentScrollY + delta).coerceIn(0, currentMaxScroll)
            sv.scrollTo(0, newScrollY)
        } else if (delta < 0) {
            // Composer shrank: scroll DOWN to maintain the gap
            val absDelta = -delta
            val newScrollY = (currentScrollY - absDelta).coerceIn(0, currentMaxScroll)
            sv.scrollTo(0, newScrollY)
        }
    }
    
    private fun isNearBottom(sv: ScrollView, threshold: Int): Boolean {
        val maxScroll = getMaxScroll(sv)
        if (maxScroll <= 0) return true
        if (isPinned || runwayInsetPx > 0) {
            return sv.scrollY >= (pinnedScrollY - threshold)
        }
        return (maxScroll - sv.scrollY) <= threshold
    }

    private fun findScrollView(view: View): ScrollView? {
        if (view is ScrollView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findScrollView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }
    
    private fun findComposerView(view: View): KeyboardComposerView? {
        if (view is KeyboardComposerView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                findComposerView(view.getChildAt(i))?.let { return it }
            }
        }
        return null
    }

    private fun getMaxScroll(sv: ScrollView): Int {
        val child = sv.getChildAt(0) ?: return 0
        return (child.height - sv.height + sv.paddingBottom).coerceAtLeast(0)
    }
    
    private fun isNearBottom(sv: ScrollView): Boolean {
        return isNearBottom(sv, dpToPx(50))
    }

    private fun setupKeyboardAnimation(sv: ScrollView, composer: KeyboardComposerView?, container: View?) {
        sv.clipToPadding = false
        
        val contentGap = dpToPx(CONTENT_GAP_DP)
        // extraBottomInset is in DP (from JS), convert to pixels
        // But prefer lastComposerHeight if available (already in pixels)
        val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
        val initialPadding = composerHeight + contentGap + safeAreaBottom
        sv.setPadding(sv.paddingLeft, sv.paddingTop, sv.paddingRight, initialPadding)
        applyComposerTranslation()

        ImeKeyboardAnimationController(
            scrollView = sv,
            getSafeAreaBottom = { safeAreaBottom },
            getCurrentKeyboardHeight = { currentKeyboardHeight },
            setCurrentKeyboardHeight = { currentKeyboardHeight = it },
            applyComposerTranslation = { applyComposerTranslation() },
            updateScrollButtonPosition = { updateScrollButtonPosition() },
            updateScrollPadding = { updateScrollPadding() },
            getMaxScroll = { scroll -> getMaxScroll(scroll) },
            isNearBottom = { scroll -> isNearBottom(scroll) },
            isPinned = { isPinned },
            isPinPendingOrDeferred = { pendingPin || pendingPinReady },
            getPendingPinReady = { pendingPinReady },
            setPendingPinReady = { pendingPinReady = it },
            getPendingPinContentHeightAfter = { pendingPinContentHeightAfter },
            applyPinAfterSend = { contentAfter -> applyPinAfterSend(contentAfter) },
            postToUi = { runnable -> post(runnable) },
            checkAndUpdateScrollPosition = { checkAndUpdateScrollPosition() }
        ).attach()
    }

    private fun dpToPx(dp: Int): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp.toFloat(),
            resources.displayMetrics
        ).toInt()
    }
    
    private fun dpToPx(dp: Float): Float {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp,
            resources.displayMetrics
        )
    }
    
    private fun isDarkMode(): Boolean {
        val nightModeFlags = resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK
        return nightModeFlags == android.content.res.Configuration.UI_MODE_NIGHT_YES
    }
    
    private fun updateScrollButtonPosition() {
        scrollToBottomButtonController.updatePosition()
    }
    
    private fun showScrollButton() {
        // If composer height not measured yet, try to get it now
        if (lastComposerHeight <= 0) {
            composerView?.let { composer ->
                if (composer.height > 0) {
                    lastComposerHeight = composer.height
                }
            }
        }
        scrollToBottomButtonController.show()
    }
    
    private fun calculateButtonTranslationY(): Float {
        val buttonGap = dpToPx(BUTTON_GAP_DP)  // Gap between button and input
        val composerGap = dpToPx(COMPOSER_KEYBOARD_GAP_DP)
        // Use measured composer height (pixels) - must wait for layout listener to set this
        val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
        val effectiveKeyboard = (currentKeyboardHeight - safeAreaBottom).coerceAtLeast(0)
        
        val bottomOffset = if (effectiveKeyboard > 0) {
            currentKeyboardHeight + composerGap + composerHeight + buttonGap
        } else {
            safeAreaBottom + composerHeight + buttonGap
        }
        
        return -bottomOffset.toFloat()
    }
    
    private fun hideScrollButton() {
        scrollToBottomButtonController.hide()
    }
    
    private fun scrollToBottom() {
        val sv = scrollView ?: return
        if (isPinned || runwayInsetPx > 0) {
            sv.smoothScrollTo(0, pinnedScrollY)
            return
        }
        val maxScroll = getMaxScroll(sv)
        sv.smoothScrollTo(0, maxScroll)
    }
    
    private fun checkAndUpdateScrollPosition() {
        val sv = scrollView ?: return

        // During pin-to-top flow (send -> IME closing -> runway/pin -> smooth scroll),
        // scrollY/maxScroll can transiently make us appear "not at bottom". Never show
        // the scroll-to-bottom button during this stabilization window.
        if (suppressScrollButtonVisibility || pendingPin || pendingPinReady) {
            hideScrollButton()
            isAtBottom = true
            return
        }
        
        val child = sv.getChildAt(0) ?: return
        val contentExceedsViewport = child.height > sv.height
        
        if (!contentExceedsViewport) {
            if (!isAtBottom) {
                isAtBottom = true
                hideScrollButton()
            }
            return
        }
        
        val newIsAtBottom = isNearBottom(sv)
        if (newIsAtBottom != isAtBottom) {
            isAtBottom = newIsAtBottom
            if (isAtBottom) {
                hideScrollButton()
            } else {
                showScrollButton()
            }
        }
    }
    
    private fun setupScrollListener(sv: ScrollView) {
        sv.viewTreeObserver.addOnScrollChangedListener {
            checkAndUpdateScrollPosition()
        }

        // ReactScrollView updates content via layout passes; a direct layout-change listener
        // fires immediately when RN lays out new children (more reliable than global layout).
        sv.getChildAt(0)?.let { content ->
            content.addOnLayoutChangeListener { v, _, _, _, _, _, _, _, _ ->
                val newHeight = v.height
                if (newHeight > 0 && newHeight != lastContentHeight) {
                    lastContentHeight = newHeight
                    handleContentSizeChange(newHeight)
                }
                post { checkAndUpdateScrollPosition() }
            }
        }
    }

    private fun requestPinForNextContentAppend() {
        val sv = scrollView ?: return
        val child = sv.getChildAt(0) ?: return

        pendingPin = true
        pendingPinMessageStartY = child.height
    }

    private fun handleContentSizeChange(contentHeight: Int) {
        val sv = scrollView ?: return
        if (!pinToTopEnabled) return

        if (pendingPin) {
            pendingPin = false
            // Defer pinning until keyboard is fully hidden (if it was open/closing).
            // Otherwise the temporary IME padding can make runway math resolve to 0 and the pin won't stick.
            if (currentKeyboardHeight > 0) {
                pendingPinReady = true
                pendingPinContentHeightAfter = contentHeight
            } else {
                applyPinAfterSend(contentHeight)
            }
            return
        }

        if (isPinned) {
            updateScrollPadding()
        }
    }

    private fun applyPinAfterSend(contentHeightAfter: Int) {
        val sv = scrollView ?: return
        val child = sv.getChildAt(0) ?: return
        val viewportH = sv.height
        if (viewportH <= 0) return

        // If the IME close animation left any transient translation on the content container,
        // clear it before pinning so the pinned top gap is consistent whether the keyboard was open or closed.
        child.translationY = 0f

        val basePaddingBottom = getBasePaddingBottomPx()
        val result = PinToTopRunway.computeApplyPin(
            contentHeightAfter = contentHeightAfter,
            viewportH = viewportH,
            basePaddingBottom = basePaddingBottom,
            topPaddingPx = dpToPx(PINNED_TOP_PADDING_DP),
            pendingPinMessageStartY = pendingPinMessageStartY,
            sv = sv,
            child = child
        )

        isPinned = result.isPinned
        pinnedScrollY = result.pinnedScrollY
        runwayInsetPx = result.runwayInsetPx
        updateScrollPadding()

        // Prevent scroll-to-bottom button flicker while we smooth-scroll into the pinned position.
        suppressScrollButtonVisibility = true
        hideScrollButton()
        isAtBottom = true

        sv.smoothScrollTo(0, pinnedScrollY)
        suppressScrollButtonUntilPinned()
    }

    private fun suppressScrollButtonUntilPinned() {
        val sv = scrollView ?: return
        val targetY = pinnedScrollY
        var frames = 0
        val maxFrames = 90
        val thresholdPx = dpToPx(4)

        fun tick() {
            if (!ViewCompat.isAttachedToWindow(sv)) {
                suppressScrollButtonVisibility = false
                return
            }

            frames++
            val delta = abs(sv.scrollY - targetY)
            val settled = delta <= thresholdPx

            if (settled || frames >= maxFrames) {
                suppressScrollButtonVisibility = false
                post { checkAndUpdateScrollPosition() }
                return
            }

            ViewCompat.postOnAnimation(sv) { tick() }
        }

        ViewCompat.postOnAnimation(sv) { tick() }
    }

    private fun recomputeRunwayInset(basePaddingBottom: Int) {
        val sv = scrollView ?: return
        val child = sv.getChildAt(0) ?: return
        val viewportH = sv.height
        if (viewportH <= 0) return

        runwayInsetPx = PinToTopRunway.computeRunwayInsetPx(
            childHeight = child.height,
            viewportH = viewportH,
            basePaddingBottom = basePaddingBottom,
            pinnedScrollY = pinnedScrollY
        )
        if (runwayInsetPx == 0) {
            clearPinnedState()
        }
    }

    private fun clearPinnedState() {
        isPinned = false
        runwayInsetPx = 0
        pinnedScrollY = 0
        pendingPin = false
        pendingPinMessageStartY = 0
        pendingPinReady = false
        pendingPinContentHeightAfter = 0
    }
}
