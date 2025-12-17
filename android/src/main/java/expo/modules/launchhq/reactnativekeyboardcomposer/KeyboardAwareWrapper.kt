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
        private const val BUTTON_SIZE_DP = 56
        private const val BUTTON_PADDING_DP = 8
    }

    var extraBottomInset: Float = 64f
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
    private var isAtBottom = true

    init {
        clipChildren = false
        clipToPadding = false
        setupScrollToBottomButton()
    }
    
    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        ViewCompat.setOnApplyWindowInsetsListener(this) { _, insets ->
            safeAreaBottom = insets.getInsets(WindowInsetsCompat.Type.systemBars()).bottom
            Log.d(TAG, "📐 Safe area bottom: $safeAreaBottom")
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

    private fun findAndAttachViews() {
        if (hasAttached) return
        
        val sv = findScrollView(this)
        val composer = findComposerView(this)
        
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
            
            hasAttached = true
            Log.d(TAG, "✅ Found ScrollView, composer=${composer != null}, container depth=$depth")
            setupKeyboardAnimation(sv, composer, composerContainer)
            setupScrollListener(sv)
            updateScrollButtonPosition()
        } else {
            postDelayed({ findAndAttachViews() }, 100)
        }
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
        val maxScroll = getMaxScroll(sv)
        if (maxScroll <= 0) return true
        return (maxScroll - sv.scrollY) <= dpToPx(50)
    }

    private fun setupKeyboardAnimation(sv: ScrollView, composer: KeyboardComposerView?, container: View?) {
        Log.d(TAG, "⌨️ Setting up keyboard animation")
        
        sv.clipToPadding = false
        
        val contentGap = dpToPx(CONTENT_GAP_DP)
        val composerGap = dpToPx(COMPOSER_KEYBOARD_GAP_DP)
        val initialPadding = extraBottomInset.toInt() + contentGap + safeAreaBottom
        sv.setPadding(sv.paddingLeft, sv.paddingTop, sv.paddingRight, initialPadding)
        container?.translationY = -composerGap.toFloat()
        
        Log.d(TAG, "📐 INIT - extraBottom=${extraBottomInset.toInt()}, gap=$contentGap, safeArea=$safeAreaBottom, totalPadding=$initialPadding, composerGap=$composerGap")
        
        val callback = object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
            
            override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return
                
                val maxScroll = getMaxScroll(sv)
                val contentHeight = sv.getChildAt(0)?.height ?: 0
                
                if (currentKeyboardHeight == 0) {
                    isOpening = true
                    wasAtBottom = isNearBottom(sv)
                    baseScrollY = sv.scrollY
                    Log.d(TAG, "⌨️ onPrepare OPEN - scrollY=${sv.scrollY}, maxScroll=$maxScroll, contentHeight=$contentHeight, wasAtBottom=$wasAtBottom")
                } else {
                    isOpening = false
                    wasAtBottom = isNearBottom(sv)
                    closingStartScrollY = sv.scrollY
                    closingStartTranslation = sv.getChildAt(0)?.translationY?.toInt() ?: 0
                    maxKeyboardHeight = currentKeyboardHeight
                    if (wasAtBottom) {
                        baseScrollY = closingStartScrollY - (maxKeyboardHeight - safeAreaBottom).coerceAtLeast(0)
                    }
                    Log.d(TAG, "⌨️ onPrepare CLOSE - scrollY=${sv.scrollY}, maxScroll=$maxScroll, contentHeight=$contentHeight, wasAtBottom=$wasAtBottom, baseScrollY=$baseScrollY")
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
                val finalPadding = extraBottomInset.toInt() + contentGap + bottomSpace
                sv.setPadding(sv.paddingLeft, sv.paddingTop, sv.paddingRight, finalPadding)
                
                val maxScroll = getMaxScroll(sv)
                val contentHeight = sv.getChildAt(0)?.height ?: 0
                
                Log.d(TAG, "📐 onEnd - keyboard=$keyboardHeight, effectiveKb=$effectiveKeyboard, padding=$finalPadding, maxScroll=$maxScroll, contentHeight=$contentHeight")
                
                if (wasAtBottom) {
                    val desiredScrollY = baseScrollY + effectiveKeyboard
                    val finalScrollY = if (maxScroll <= 0) 0 else desiredScrollY.coerceAtLeast(0)
                    sv.scrollY = finalScrollY
                    val actualScrollY = sv.scrollY
                    val remainingTranslation = actualScrollY - desiredScrollY
                    sv.getChildAt(0)?.translationY = if (maxScroll <= 0) 0f else remainingTranslation.toFloat()
                    Log.d(TAG, "⌨️ onEnd SCROLL - baseScrollY=$baseScrollY, desired=$desiredScrollY, final=$finalScrollY, actual=$actualScrollY")
                } else {
                    sv.getChildAt(0)?.translationY = 0f
                    Log.d(TAG, "⌨️ onEnd - not at bottom, translation reset")
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
        
        Log.d(TAG, "📍 Scroll button created")
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
                strokeWidth = dpToPx(3).toFloat()
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
        val button = scrollToBottomButton ?: return
        
        val buttonPadding = dpToPx(BUTTON_PADDING_DP)
        val contentGap = dpToPx(CONTENT_GAP_DP)
        val composerGap = dpToPx(COMPOSER_KEYBOARD_GAP_DP)
        val composerHeight = extraBottomInset.toInt()
        
        val effectiveKeyboard = (currentKeyboardHeight - safeAreaBottom).coerceAtLeast(0)
        
        val bottomOffset = if (effectiveKeyboard > 0) {
            currentKeyboardHeight + composerGap + composerHeight + contentGap + buttonPadding
        } else {
            safeAreaBottom + composerHeight + contentGap + buttonPadding
        }
        
        button.translationY = -bottomOffset.toFloat()
    }
    
    private fun showScrollButton() {
        if (isScrollButtonVisible) return
        isScrollButtonVisible = true
        
        scrollToBottomButton?.let { button ->
            button.visibility = View.VISIBLE
            button.animate()
                .alpha(1f)
                .setDuration(200)
                .setListener(null)
                .start()
        }
        Log.d(TAG, "📍 Show scroll button")
    }
    
    private fun hideScrollButton() {
        if (!isScrollButtonVisible) return
        isScrollButtonVisible = false
        
        scrollToBottomButton?.let { button ->
            button.animate()
                .alpha(0f)
                .setDuration(200)
                .setListener(object : AnimatorListenerAdapter() {
                    override fun onAnimationEnd(animation: Animator) {
                        button.visibility = View.GONE
                    }
                })
                .start()
        }
        Log.d(TAG, "📍 Hide scroll button")
    }
    
    private fun scrollToBottom() {
        val sv = scrollView ?: return
        val maxScroll = getMaxScroll(sv)
        sv.smoothScrollTo(0, maxScroll)
        Log.d(TAG, "📍 Scroll to bottom: $maxScroll")
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
        
        Log.d(TAG, "📍 Scroll listener attached")
    }
}
