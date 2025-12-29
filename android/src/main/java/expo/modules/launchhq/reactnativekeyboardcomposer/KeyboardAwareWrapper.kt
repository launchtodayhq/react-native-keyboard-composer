package expo.modules.launchhq.reactnativekeyboardcomposer

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.Drawable
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ScrollView
import android.util.Log
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.views.ExpoView

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
        private const val BUTTON_SIZE_DP = 42  // 32 * 1.3 = ~42
        private const val BUTTON_GAP_DP = 24   // Gap between button and input
    }
    
    // Track actual composer height (measured from view, not prop)
    private var lastComposerHeight: Int = 0

    private var _pinToTopEnabled: Boolean = false
    var pinToTopEnabled: Boolean
        get() = _pinToTopEnabled
        set(value) {
            _pinToTopEnabled = value
            Log.w("KeyboardComposerNative", "pinToTopEnabled set -> $value")
            if (!value) {
                clearPinnedState()
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
    
    private var wasAtBottom = false
    private var baseScrollY = 0
    private var isOpening = false
    private var closingStartScrollY = 0
    private var closingStartTranslation = 0
    private var maxKeyboardHeight = 0
    
    private var scrollToBottomButton: ImageButton? = null
    private var isScrollButtonVisible = false
    private var isAnimatingScrollButton = false
    private var isAtBottom = true

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
        setupScrollToBottomButton()
    }
    
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            val newSafeAreaBottom = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            if (newSafeAreaBottom != safeAreaBottom) {
                safeAreaBottom = newSafeAreaBottom
                applyComposerTranslation()
                // Update button position now that we have correct safe area
                updateScrollButtonPosition()
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
                updateScrollButtonPosition()
                updateScrollPadding()
            }
        }
    }

    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        super.onLayout(changed, left, top, right, bottom)
        
        val width = right - left
        val height = bottom - top
        
        for (i in 0 until childCount) {
            val child = getChildAt(i)
            if (child !== scrollToBottomButton) {
                child.layout(0, 0, width, height)
            }
        }
        
        scrollToBottomButton?.let { button ->
            val buttonSize = dpToPx(BUTTON_SIZE_DP)
            val buttonLeft = (width - buttonSize) / 2
            val buttonTop = height - buttonSize
            button.layout(buttonLeft, buttonTop, buttonLeft + buttonSize, buttonTop + buttonSize)
            button.bringToFront()
        }
        
        updateScrollButtonPosition()
        
        if (!hasAttached) {
            post { findAndAttachViews() }
        }
    }
    
    private fun getBasePaddingBottomPx(): Int {
        val contentGap = dpToPx(CONTENT_GAP_DP)
        val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
        val bottomSpace = if (currentKeyboardHeight > 0) currentKeyboardHeight else safeAreaBottom
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
        
        if (sv != null) {
            Log.w(
                "KeyboardComposerNative",
                "attach: scrollView=${sv.javaClass.simpleName}, composer=${composer?.javaClass?.simpleName}, safeAreaBottom=$safeAreaBottom"
            )
            scrollView = sv
            composerView = composer
            composer?.onNativeSend = {
                Log.w(
                    "KeyboardComposerNative",
                    "onNativeSend: pinToTopEnabled=$pinToTopEnabled, keyboardHeight=$currentKeyboardHeight"
                )
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
        val composerBottomOffset = if (currentKeyboardHeight > 0) currentKeyboardHeight else safeAreaBottom
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
        val composerGap = dpToPx(COMPOSER_KEYBOARD_GAP_DP)
        // extraBottomInset is in DP (from JS), convert to pixels
        // But prefer lastComposerHeight if available (already in pixels)
        val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
        val initialPadding = composerHeight + contentGap + safeAreaBottom
        sv.setPadding(sv.paddingLeft, sv.paddingTop, sv.paddingRight, initialPadding)
        applyComposerTranslation()
        
        val callback = object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
            
            override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return
                
                val maxScroll = getMaxScroll(sv)
                val contentHeight = sv.getChildAt(0)?.height ?: 0
                
                if (currentKeyboardHeight == 0) {
                    isOpening = true
                    wasAtBottom = !isPinned && isNearBottom(sv)
                    baseScrollY = sv.scrollY
                } else {
                    isOpening = false
                    wasAtBottom = !isPinned && isNearBottom(sv)
                    closingStartScrollY = sv.scrollY
                    closingStartTranslation = sv.getChildAt(0)?.translationY?.toInt() ?: 0
                    maxKeyboardHeight = currentKeyboardHeight
                    if (wasAtBottom) {
                        baseScrollY = closingStartScrollY - (maxKeyboardHeight - safeAreaBottom).coerceAtLeast(0)
                    }
                }
            }

            override fun onStart(
                animation: WindowInsetsAnimationCompat,
                bounds: WindowInsetsAnimationCompat.BoundsCompat
            ): WindowInsetsAnimationCompat.BoundsCompat = bounds

            override fun onProgress(
                insets: WindowInsetsCompat,
                runningAnimations: MutableList<WindowInsetsAnimationCompat>
            ): WindowInsetsCompat {
                val imeAnimation = runningAnimations.find { 
                    it.typeMask and WindowInsetsCompat.Type.ime() != 0 
                } ?: return insets
                
                val keyboardHeight = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
                currentKeyboardHeight = keyboardHeight
                
                val effectiveKeyboard = (keyboardHeight - safeAreaBottom).coerceAtLeast(0)
                applyComposerTranslation()
                
                updateScrollButtonPosition()
                
                if (wasAtBottom) {
                    val contentTranslation = if (isOpening) {
                        -effectiveKeyboard
                    } else {
                        val maxEffectiveKeyboard = (maxKeyboardHeight - safeAreaBottom).coerceAtLeast(0)
                        closingStartTranslation + (maxEffectiveKeyboard - effectiveKeyboard)
                    }
                    sv.getChildAt(0)?.translationY = contentTranslation.toFloat()
                }
                
                return insets
            }

            override fun onEnd(animation: WindowInsetsAnimationCompat) {
                if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return
                
                val rootInsets = ViewCompat.getRootWindowInsets(sv)
                val keyboardHeight = rootInsets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0
                currentKeyboardHeight = keyboardHeight
                Log.w("KeyboardComposerNative", "IME onEnd: keyboardHeight=$keyboardHeight pendingPinReady=$pendingPinReady")
                
                val effectiveKeyboard = (keyboardHeight - safeAreaBottom).coerceAtLeast(0)
                applyComposerTranslation()
                
                val bottomSpace = if (keyboardHeight > 0) keyboardHeight else safeAreaBottom
                // Use measured composer height (pixels) or convert extraBottomInset from DP
                val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
                val basePadding = composerHeight + contentGap + bottomSpace
                if (isPinned) {
                    recomputeRunwayInset(basePadding)
                }
                val finalPadding = basePadding + runwayInsetPx
                sv.setPadding(sv.paddingLeft, sv.paddingTop, sv.paddingRight, finalPadding)
                
                val maxScroll = getMaxScroll(sv)
                val currentScrollY = sv.scrollY
                
                if (wasAtBottom) {
                    val desiredScrollY = baseScrollY + effectiveKeyboard
                    val finalScrollY = if (maxScroll <= 0) 0 else desiredScrollY.coerceAtLeast(0)
                    sv.scrollY = finalScrollY
                    val actualScrollY = sv.scrollY
                    val remainingTranslation = actualScrollY - desiredScrollY
                    sv.getChildAt(0)?.translationY = if (maxScroll <= 0) 0f else remainingTranslation.toFloat()
                } else {
                    // User was NOT at bottom - reset translation and clamp scroll position
                    sv.getChildAt(0)?.translationY = 0f
                    
                    // When keyboard closes, clamp scroll if past maxScroll
                    if (currentScrollY > maxScroll && maxScroll >= 0) {
                        sv.scrollY = maxScroll
                    }
                }
                
                updateScrollButtonPosition()
                post { checkAndUpdateScrollPosition() }

                // If content was appended while the IME was still open, finish pinning after it closes.
                if (keyboardHeight == 0 && pendingPinReady) {
                    pendingPinReady = false
                    Log.w(
                        "KeyboardComposerNative",
                        "IME onEnd: applying deferred pin contentAfter=$pendingPinContentHeightAfter"
                    )
                    applyPinAfterSend(pendingPinContentHeightAfter)
                }
            }
        }

        ViewCompat.setWindowInsetsAnimationCallback(sv, callback)
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
    
    private fun setupScrollToBottomButton() {
        val buttonSize = dpToPx(BUTTON_SIZE_DP)
        
        val button = ImageButton(context).apply {
            setImageDrawable(createScrollButtonDrawable(buttonSize))
            scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
            contentDescription = "Scroll to bottom"
            
            // Use the drawable as background so elevation shadow works
            background = createScrollButtonDrawable(buttonSize)
            setImageDrawable(null)  // Don't need image since background has the content
            
            // Shadow via elevation (matches iOS shadowRadius: 4, shadowOpacity: 0.15)
            elevation = dpToPx(4).toFloat()
            
            // Make outline circular for proper shadow shape
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setOval(0, 0, view.width, view.height)
                }
            }
            clipToOutline = false  // Don't clip, just use for shadow
            
            alpha = 0f
            visibility = View.GONE
            
            setOnClickListener {
                scrollToBottom()
            }
        }
        
        val params = FrameLayout.LayoutParams(buttonSize, buttonSize).apply {
            gravity = Gravity.CENTER_HORIZONTAL or Gravity.BOTTOM
        }
        addView(button, params)
        scrollToBottomButton = button
    }
    
    private fun createScrollButtonDrawable(size: Int): Drawable {
        return object : Drawable() {
            private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = getButtonCircleColor()
                style = Paint.Style.FILL
            }
            
            private val arrowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = getButtonArrowColor()
                style = Paint.Style.STROKE
                strokeWidth = dpToPx(2.5f).toFloat()  // Slightly thicker for 42dp button
                strokeCap = Paint.Cap.ROUND
                strokeJoin = Paint.Join.ROUND
            }
            
            override fun draw(canvas: Canvas) {
                val bounds = bounds
                val cx = bounds.exactCenterX()
                val cy = bounds.exactCenterY()
                val radius = minOf(bounds.width(), bounds.height()) / 2f
                
                canvas.drawCircle(cx, cy, radius, circlePaint)
                
                val arrowSize = radius * 0.7f
                val arrowPath = Path().apply {
                    moveTo(cx, cy - arrowSize * 0.5f)
                    lineTo(cx, cy + arrowSize * 0.5f)
                    moveTo(cx - arrowSize * 0.5f, cy + arrowSize * 0.1f)
                    lineTo(cx, cy + arrowSize * 0.6f)
                    lineTo(cx + arrowSize * 0.5f, cy + arrowSize * 0.1f)
                }
                canvas.drawPath(arrowPath, arrowPaint)
            }
            
            override fun setAlpha(alpha: Int) {
                circlePaint.alpha = alpha
                arrowPaint.alpha = alpha
            }
            
            override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {
                circlePaint.colorFilter = colorFilter
                arrowPaint.colorFilter = colorFilter
            }
            
            override fun getOpacity(): Int = android.graphics.PixelFormat.TRANSLUCENT
            override fun getIntrinsicWidth(): Int = size
            override fun getIntrinsicHeight(): Int = size
        }
    }
    
    private fun getButtonCircleColor(): Int {
        // Light mode: white circle, Dark mode: dark circle
        return if (isDarkMode()) Color.parseColor("#2C2C2E") else Color.WHITE
    }
    
    private fun getButtonArrowColor(): Int {
        // Light mode: black arrow, Dark mode: white arrow
        return if (isDarkMode()) Color.WHITE else Color.BLACK
    }
    
    private fun isDarkMode(): Boolean {
        val nightModeFlags = resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK
        return nightModeFlags == android.content.res.Configuration.UI_MODE_NIGHT_YES
    }
    
    private fun updateScrollButtonPosition() {
        // Don't update position during show/hide animation
        if (isAnimatingScrollButton) return
        
        val button = scrollToBottomButton ?: return
        button.translationY = calculateButtonTranslationY()
    }
    
    private fun showScrollButton() {
        if (isScrollButtonVisible) return
        
        // If composer height not measured yet, try to get it now
        if (lastComposerHeight <= 0) {
            composerView?.let { composer ->
                if (composer.height > 0) {
                    lastComposerHeight = composer.height
                }
            }
        }
        
        isScrollButtonVisible = true
        isAnimatingScrollButton = true
        
        scrollToBottomButton?.let { button ->
            val baseTranslationY = calculateButtonTranslationY()
            
            // Start 12dp lower (slide up animation)
            button.translationY = baseTranslationY + dpToPx(12)
            button.alpha = 0f
            button.visibility = View.VISIBLE
            
            button.animate()
                .alpha(1f)
                .translationY(baseTranslationY)
                .setDuration(250)
                .setInterpolator(android.view.animation.DecelerateInterpolator())
                .setListener(object : AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: Animator) {
                        isAnimatingScrollButton = false
                        // Recalculate position in case lastComposerHeight changed during animation
                        updateScrollButtonPosition()
                    }
                })
                .start()
        }
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
        if (!isScrollButtonVisible) return
        isScrollButtonVisible = false
        isAnimatingScrollButton = true
        
        scrollToBottomButton?.let { button ->
            // Get current position (slide down animation)
            val currentTranslationY = button.translationY
            
            button.animate()
                .alpha(0f)
                .translationY(currentTranslationY + dpToPx(12))
                .setDuration(180)
                .setInterpolator(android.view.animation.AccelerateInterpolator())
                .setListener(object : AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: Animator) {
                        button.visibility = View.GONE
                        // Reset to correct position for next show
                        updateScrollButtonPosition()
                        isAnimatingScrollButton = false
                    }
                })
                .start()
        }
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
        Log.w(
            "KeyboardComposerNative",
            "requestPinForNextContentAppend: startY=$pendingPinMessageStartY, contentH=${child.height}, viewportH=${sv.height}, keyboardH=$currentKeyboardHeight"
        )
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
                Log.w(
                    "KeyboardComposerNative",
                    "contentSizeChange: defer pin (keyboardH=$currentKeyboardHeight), contentH=$contentHeight"
                )
            } else {
                Log.w("KeyboardComposerNative", "contentSizeChange: apply pin now, contentH=$contentHeight")
                applyPinAfterSend(contentHeight)
            }
            return
        }

        if (isPinned) {
            Log.w("KeyboardComposerNative", "contentSizeChange: pinned=true, recompute runway. contentH=$contentHeight")
            updateScrollPadding()
        }
    }

    private fun applyPinAfterSend(contentHeightAfter: Int) {
        val sv = scrollView ?: return
        val child = sv.getChildAt(0) ?: return
        val viewportH = sv.height
        if (viewportH <= 0) return

        val basePaddingBottom = getBasePaddingBottomPx()
        val baseMax = (contentHeightAfter - viewportH + basePaddingBottom).coerceAtLeast(0)

        // Respect the actual content container's top spacing (no magic numbers):
        // - contentContainerStyle.paddingTop typically lands on the inner content view's paddingTop
        // - some RN layouts may express this as first-child top offset
        // - also include ScrollView paddingTop as a fallback
        val contentGroup = child as? ViewGroup
        val topGap = maxOf(
            0,
            sv.paddingTop,
            child.paddingTop,
            if (contentGroup != null && contentGroup.childCount > 0) contentGroup.getChildAt(0).top else 0
        )
        val desiredPinned = pendingPinMessageStartY.coerceAtLeast(0)
        val pinnedTarget = (desiredPinned - topGap).coerceAtLeast(0)
        val neededRunway = (pinnedTarget - baseMax).coerceAtLeast(0)

        isPinned = neededRunway > 0
        pinnedScrollY = pinnedTarget
        runwayInsetPx = neededRunway
        Log.w(
            "KeyboardComposerNative",
            "applyPinAfterSend: contentAfter=$contentHeightAfter viewport=$viewportH basePad=$basePaddingBottom baseMax=$baseMax desiredPinned=$desiredPinned topGap=$topGap pinnedTarget=$pinnedTarget neededRunway=$neededRunway isPinned=$isPinned"
        )

        updateScrollPadding()
        sv.smoothScrollTo(0, pinnedScrollY)
    }

    private fun recomputeRunwayInset(basePaddingBottom: Int) {
        val sv = scrollView ?: return
        val child = sv.getChildAt(0) ?: return
        val viewportH = sv.height
        if (viewportH <= 0) return

        val baseMax = (child.height - viewportH + basePaddingBottom).coerceAtLeast(0)
        runwayInsetPx = (pinnedScrollY - baseMax).coerceAtLeast(0)
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
