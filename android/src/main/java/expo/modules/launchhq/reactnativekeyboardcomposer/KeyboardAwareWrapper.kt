package expo.modules.launchhq.reactnativekeyboardcomposer

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.Drawable
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ScrollView
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
        private const val TAG = "KeyboardAwareWrapper"
        private const val CONTENT_GAP_DP = 24
        private const val COMPOSER_KEYBOARD_GAP_DP = 8
        private const val BUTTON_SIZE_DP = 32  // Match iOS (was 56)
        private const val BUTTON_PADDING_DP = 3
    }
    
    // Track actual composer height (measured from view, not prop)
    private var lastComposerHeight: Int = 0

    private var _extraBottomInset: Float = 64f
    var extraBottomInset: Float
        get() = _extraBottomInset
        set(value) {
            val oldValue = _extraBottomInset
            _extraBottomInset = value
            
            Log.d(TAG, "extraBottomInset: $oldValue -> $value (prop only, scroll handled by native layout listener)")
            
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
    
    var scrollToTopTrigger: Double = 0.0

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
            safeAreaBottom = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
            insets
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
    
    private fun updateScrollPadding() {
        val sv = scrollView ?: return
        val contentGap = dpToPx(CONTENT_GAP_DP)
        // lastComposerHeight is in pixels, extraBottomInset is in DP (from JS)
        val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
        val bottomSpace = if (currentKeyboardHeight > 0) currentKeyboardHeight else safeAreaBottom
        val finalPadding = composerHeight + contentGap + bottomSpace
        Log.d(TAG, "updateScrollPadding: composerHeight=$composerHeight, contentGap=$contentGap, bottomSpace=$bottomSpace, finalPadding=$finalPadding")
        sv.setPadding(sv.paddingLeft, sv.paddingTop, sv.paddingRight, finalPadding)
    }

    private fun findAndAttachViews() {
        if (hasAttached) return
        
        val sv = findScrollView(this)
        val composer = findComposerView(this)
        
        Log.d(TAG, "findAndAttachViews: scrollView=${sv != null}, composer=${composer != null}")
        
        if (sv != null) {
            scrollView = sv
            composerView = composer
            
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
            updateScrollButtonPosition()
        } else {
            postDelayed({ findAndAttachViews() }, 100)
        }
    }
    
    private fun setupComposerHeightListener(composer: KeyboardComposerView?) {
        composer ?: return
        
        Log.d(TAG, "setupComposerHeightListener: setting up OnLayoutChangeListener")
        
        // Initialize with current height if available
        if (composer.height > 0) {
            lastComposerHeight = composer.height
            Log.d(TAG, "setupComposerHeightListener: initial height=$lastComposerHeight")
        }
        
        composerLayoutListener = View.OnLayoutChangeListener { _, _, _, _, bottom, _, _, _, oldBottom ->
            val newHeight = bottom - 0  // height = bottom - top, but top is always 0 for this view
            val oldHeight = oldBottom - 0
            
            Log.d(TAG, "OnLayoutChangeListener: newHeight=$newHeight, oldHeight=$oldHeight, lastComposerHeight=$lastComposerHeight")
            
            if (newHeight > 0 && newHeight != lastComposerHeight) {
                val delta = newHeight - lastComposerHeight
                Log.d(TAG, "OnLayoutChangeListener: height changed! delta=$delta")
                
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
        val currentMaxScroll = getMaxScroll(sv)  // This now reflects the updated padding
        val nearBottom = isNearBottom(sv, dpToPx(100))
        val distanceFromBottom = currentMaxScroll - currentScrollY
        
        Log.d(TAG, "handleComposerHeightChange: delta=$delta, scrollY=$currentScrollY, maxScroll=$currentMaxScroll, distFromBottom=$distanceFromBottom, nearBottom=$nearBottom")
        
        // Only adjust if near bottom (within 100dp)
        if (!nearBottom) {
            Log.d(TAG, "handleComposerHeightChange: NOT near bottom (dist=$distanceFromBottom > ${dpToPx(100)}), skipping scroll adjust")
            return
        }
        
        if (delta > 0) {
            // Composer grew: scroll UP to keep last message visible
            // Padding already updated, so maxScroll is correct
            val newScrollY = (currentScrollY + delta).coerceIn(0, currentMaxScroll)
            
            Log.d(TAG, "handleComposerHeightChange: GROW - scrolling $currentScrollY -> $newScrollY (maxScroll=$currentMaxScroll)")
            sv.scrollTo(0, newScrollY)
            
            // Verify the scroll actually happened
            val actualScrollY = sv.scrollY
            if (actualScrollY != newScrollY) {
                Log.w(TAG, "handleComposerHeightChange: SCROLL FAILED! wanted=$newScrollY, actual=$actualScrollY")
            }
        } else if (delta < 0) {
            // Composer shrank: scroll DOWN to maintain the gap
            // Padding already updated, so maxScroll already decreased
            val absDelta = -delta  // Make positive
            val newScrollY = (currentScrollY - absDelta).coerceIn(0, currentMaxScroll)
            
            Log.d(TAG, "handleComposerHeightChange: SHRINK - scrolling $currentScrollY -> $newScrollY (maxScroll=$currentMaxScroll)")
            sv.scrollTo(0, newScrollY)
            
            // Verify the scroll actually happened
            val actualScrollY = sv.scrollY
            if (actualScrollY != newScrollY) {
                Log.w(TAG, "handleComposerHeightChange: SCROLL FAILED! wanted=$newScrollY, actual=$actualScrollY")
            }
        }
    }
    
    private fun isNearBottom(sv: ScrollView, threshold: Int): Boolean {
        val maxScroll = getMaxScroll(sv)
        if (maxScroll <= 0) return true
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
        container?.translationY = -composerGap.toFloat()
        
        Log.d(TAG, "setupKeyboardAnimation: composerHeight=$composerHeight, contentGap=$contentGap, safeArea=$safeAreaBottom, initialPadding=$initialPadding")
        
        val callback = object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
            
            override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return
                
                val maxScroll = getMaxScroll(sv)
                val contentHeight = sv.getChildAt(0)?.height ?: 0
                
                if (currentKeyboardHeight == 0) {
                    isOpening = true
                    wasAtBottom = isNearBottom(sv)
                    baseScrollY = sv.scrollY
                } else {
                    isOpening = false
                    wasAtBottom = isNearBottom(sv)
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
                val composerGap = dpToPx(COMPOSER_KEYBOARD_GAP_DP)
                container?.translationY = -(effectiveKeyboard + composerGap).toFloat()
                
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
                
                val effectiveKeyboard = (keyboardHeight - safeAreaBottom).coerceAtLeast(0)
                val composerGap = dpToPx(COMPOSER_KEYBOARD_GAP_DP)
                container?.translationY = -(effectiveKeyboard + composerGap).toFloat()
                
                val bottomSpace = if (keyboardHeight > 0) keyboardHeight else safeAreaBottom
                // Use measured composer height (pixels) or convert extraBottomInset from DP
                val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
                val finalPadding = composerHeight + contentGap + bottomSpace
                sv.setPadding(sv.paddingLeft, sv.paddingTop, sv.paddingRight, finalPadding)
                
                val maxScroll = getMaxScroll(sv)
                val currentScrollY = sv.scrollY
                
                Log.d(TAG, "onEnd: keyboardHeight=$keyboardHeight, wasAtBottom=$wasAtBottom, currentScrollY=$currentScrollY, maxScroll=$maxScroll")
                
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
                    
                    // IMPORTANT: When keyboard closes, maxScroll decreases.
                    // If current scroll position is now past maxScroll, clamp it.
                    // This prevents the gap that appears when user scrolled while keyboard was open.
                    if (currentScrollY > maxScroll && maxScroll >= 0) {
                        Log.d(TAG, "onEnd: clamping scroll from $currentScrollY to $maxScroll")
                        sv.scrollY = maxScroll
                    }
                }
                
                updateScrollButtonPosition()
                post { checkAndUpdateScrollPosition() }
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
    
    private fun setupScrollToBottomButton() {
        val buttonSize = dpToPx(BUTTON_SIZE_DP)
        
        val button = ImageButton(context).apply {
            setBackgroundColor(Color.TRANSPARENT)
            setImageDrawable(createScrollButtonDrawable(buttonSize))
            scaleType = android.widget.ImageView.ScaleType.FIT_CENTER
            contentDescription = "Scroll to bottom"
            background = null
            elevation = dpToPx(4).toFloat()
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
                color = getTextColor()
                style = Paint.Style.FILL
            }
            
            private val arrowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = getBackgroundColor()
                style = Paint.Style.STROKE
                strokeWidth = dpToPx(2).toFloat()  // Thinner for smaller 32dp button
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
    
    private fun getTextColor(): Int {
        return if (isDarkMode()) Color.WHITE else Color.BLACK
    }
    
    private fun getBackgroundColor(): Int {
        return if (isDarkMode()) Color.parseColor("#1C1C1E") else Color.WHITE
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
        isScrollButtonVisible = true
        isAnimatingScrollButton = true
        
        scrollToBottomButton?.let { button ->
            // Calculate correct base position
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
                    }
                })
                .start()
        }
    }
    
    private fun calculateButtonTranslationY(): Float {
        val buttonPadding = dpToPx(BUTTON_PADDING_DP)
        val contentGap = dpToPx(CONTENT_GAP_DP)
        val composerGap = dpToPx(COMPOSER_KEYBOARD_GAP_DP)
        // Use measured composer height (pixels) or convert extraBottomInset from DP
        val composerHeight = if (lastComposerHeight > 0) lastComposerHeight else dpToPx(extraBottomInset.toInt())
        val effectiveKeyboard = (currentKeyboardHeight - safeAreaBottom).coerceAtLeast(0)
        
        val bottomOffset = if (effectiveKeyboard > 0) {
            currentKeyboardHeight + composerGap + composerHeight + contentGap + buttonPadding
        } else {
            safeAreaBottom + composerHeight + contentGap + buttonPadding
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
        
        sv.getChildAt(0)?.viewTreeObserver?.addOnGlobalLayoutListener {
            post { checkAndUpdateScrollPosition() }
        }
    }
}
