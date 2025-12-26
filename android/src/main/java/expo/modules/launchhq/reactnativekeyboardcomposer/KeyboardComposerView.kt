package expo.modules.launchhq.reactnativekeyboardcomposer

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.Drawable
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.text.method.ScrollingMovementMethod
import android.util.TypedValue
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class KeyboardComposerView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {

    // MARK: - Event Dispatchers
    private val onChangeText by EventDispatcher()
    private val onSend by EventDispatcher()
    private val onStop by EventDispatcher()
    private val onHeightChange by EventDispatcher()
    private val onKeyboardHeightChange by EventDispatcher()
    private val onComposerFocus by EventDispatcher()
    private val onComposerBlur by EventDispatcher()
    private val onPTTPress by EventDispatcher()
    private val onPTTPressIn by EventDispatcher()
    private val onPTTPressOut by EventDispatcher()

    // MARK: - Props
    var placeholderText: String = "Type a message..."
        set(value) {
            field = value
            editText.hint = value
        }

    var minHeightDp: Float = 48f
        set(value) {
            field = value
            minHeightPx = dpToPx(value)
            updateHeight()
        }

    var maxHeightDp: Float = 120f
        set(value) {
            field = value
            maxHeightPx = dpToPx(value)
            val lineHeight = editText.lineHeight
            if (lineHeight > 0) {
                val maxLines = (maxHeightPx - dpToPx(28f)) / lineHeight
                editText.maxLines = maxLines.coerceAtLeast(1)
            }
            updateHeight()
        }

    var sendButtonEnabled: Boolean = true
        set(value) {
            field = value
            updateSendButtonState()
        }

    var editable: Boolean = true
        set(value) {
            field = value
            editText.isEnabled = value
        }

    var autoFocus: Boolean = false
        set(value) {
            field = value
            if (value) {
                post {
                    editText.requestFocus()
                    showKeyboard()
                }
            }
        }

    var isStreaming: Boolean = false
        set(value) {
            field = value
            updateButtonAppearance()
        }

    var showPTTButton: Boolean = false
        set(value) {
            field = value
            pttButton.visibility = if (value) View.VISIBLE else View.GONE
            updateEditTextPadding()
            requestLayout()
        }

    var pttEnabled: Boolean = true
        set(value) {
            field = value
            updatePTTEnabledState()
        }

    var pttState: String = "available"
        set(value) {
            field = value
            updatePTTButtonAppearance()
        }

    var pttPressedScale: Float = 0.92f
        set(value) {
            field = value
        }

    var pttPressedOpacity: Float = 0.85f
        set(value) {
            field = value
        }

    // MARK: - UI Elements
    private val backgroundView: FrameLayout
    private val editText: EditText
    private val sendButton: ImageButton
    private val pttButton: ImageButton
    private var currentHeight: Int = 0
    private var minHeightPx: Int = 0
    private var maxHeightPx: Int = 0

    // Layout constants
    private val buttonSize: Int
    private val buttonPadding: Int
    private val cornerRadius: Float

    init {
        minHeightPx = dpToPx(minHeightDp)
        maxHeightPx = dpToPx(maxHeightDp)
        currentHeight = minHeightPx
        buttonSize = dpToPx(48f)
        buttonPadding = dpToPx(8f)
        cornerRadius = dpToPx(24f).toFloat()
        
        setBackgroundColor(Color.TRANSPARENT)

        // Solid background container with rounded corners (no blur on Android)
        backgroundView = FrameLayout(context).apply {
            setBackgroundColor(getSolidBackgroundColor())
            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setRoundRect(0, 0, view.width, view.height, cornerRadius)
                }
            }
            clipToOutline = true
        }

        editText = EditText(context).apply {
            hint = placeholderText
            setHintTextColor(getPlaceholderColor())
            setTextColor(getTextColor())
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            background = null
            inputType = InputType.TYPE_CLASS_TEXT or 
                        InputType.TYPE_TEXT_FLAG_MULTI_LINE or 
                        InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            minLines = 1
            maxLines = 5
            isVerticalScrollBarEnabled = true
            movementMethod = ScrollingMovementMethod.getInstance()
            gravity = Gravity.TOP or Gravity.START
            
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
                override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
                override fun afterTextChanged(s: Editable?) {
                    onChangeText(mapOf("text" to (s?.toString() ?: "")))
                    post { updateHeight() }
                    updateSendButtonState()
                }
            })

            setOnFocusChangeListener { _, hasFocus ->
                if (hasFocus) {
                    performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                    onComposerFocus(emptyMap())
                } else {
                    onComposerBlur(emptyMap())
                }
            }
        }
        updateEditTextPadding()

        setupEditTextTouchHandling()

        // PTT Button (left side)
        pttButton = ImageButton(context).apply {
            setBackgroundColor(Color.TRANSPARENT)
            scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
            contentDescription = "Push to talk"
            visibility = View.GONE

            setOnTouchListener { v, event ->
                if (!pttEnabled) {
                    true
                } else {
                when (event.action) {
                    MotionEvent.ACTION_DOWN -> {
                        v.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
                        v.scaleX = pttPressedScale
                        v.scaleY = pttPressedScale
                        v.alpha = pttPressedOpacity
                        onPTTPressIn(emptyMap())
                        true
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        v.scaleX = 1f
                        v.scaleY = 1f
                        v.alpha = 1f
                        onPTTPressOut(emptyMap())
                        if (event.action == MotionEvent.ACTION_UP) {
                            onPTTPress(emptyMap())
                        }
                        true
                    }
                    else -> false
                }
                }
            }
        }
        updatePTTButtonAppearance()
        updatePTTEnabledState()

        // Send button (right side)
        sendButton = ImageButton(context).apply {
            setBackgroundColor(Color.TRANSPARENT)
            scaleType = android.widget.ImageView.ScaleType.CENTER_INSIDE
            contentDescription = "Send message"

            setOnClickListener {
                if (isStreaming) {
                    handleStop()
                } else {
                    handleSend()
                }
            }
        }

        // Add views
        addView(backgroundView, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        backgroundView.addView(editText, FrameLayout.LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        
        addView(pttButton, LayoutParams(buttonSize, buttonSize).apply {
            gravity = Gravity.START or Gravity.CENTER_VERTICAL
            marginStart = buttonPadding / 2
        })
        
        addView(sendButton, LayoutParams(buttonSize, buttonSize).apply {
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            marginEnd = buttonPadding / 2
        })

        updateButtonAppearance()
        updateSendButtonState()

        post {
            onHeightChange(mapOf("height" to minHeightDp.toDouble()))
            
            if (editText.hint.isNullOrEmpty()) {
                editText.hint = placeholderText
            }
            
            editText.setHintTextColor(getPlaceholderColor())
            editText.hint = placeholderText
            editText.requestLayout()
            editText.invalidate()
        }
    }

    private fun updateEditTextPadding() {
        val leftPadding = if (showPTTButton) buttonSize + buttonPadding else dpToPx(16f)
        val rightPadding = buttonSize + buttonPadding / 2
        editText.setPadding(leftPadding, dpToPx(14f), rightPadding, dpToPx(14f))
    }
    
    @SuppressLint("ClickableViewAccessibility")
    private fun setupEditTextTouchHandling() {
        editText.setOnTouchListener { v, event ->
            if (v.canScrollVertically(1) || v.canScrollVertically(-1)) {
                v.parent?.requestDisallowInterceptTouchEvent(true)
                if (event.action == MotionEvent.ACTION_UP) {
                    v.parent?.requestDisallowInterceptTouchEvent(false)
                }
            }
            false
        }
    }

    private fun handleSend() {
        val text = editText.text?.toString() ?: ""
        if (text.isEmpty()) return

        performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        onSend(mapOf("text" to text))
        editText.setText("")
        post { updateHeight() }
        updateSendButtonState()
    }

    private fun handleStop() {
        performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        onStop(emptyMap())
    }

    private fun updatePTTButtonAppearance() {
        val size = dpToPx(32f)
        pttButton.setImageDrawable(createPTTButtonDrawable(size))
    }

    private fun createPTTButtonDrawable(size: Int): Drawable {
        return object : Drawable() {
            private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = when (pttState.lowercase()) {
                    "talking" -> Color.parseColor("#FF3B30")
                    "listening" -> Color.parseColor("#007AFF")
                    else -> getTextColor()
                }
                style = Paint.Style.FILL
            }
            
            private val waveformPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (pttState.lowercase() == "available") getContrastColor() else Color.WHITE
                style = Paint.Style.STROKE
                strokeWidth = dpToPx(2.5f).toFloat()
                strokeCap = Paint.Cap.ROUND
            }

            override fun draw(canvas: Canvas) {
                val bounds = bounds
                val cx = bounds.exactCenterX()
                val cy = bounds.exactCenterY()
                val radius = minOf(bounds.width(), bounds.height()) / 2f

                // Draw circle background
                canvas.drawCircle(cx, cy, radius, circlePaint)

                // Draw waveform bars
                val spacing = dpToPx(4f).toFloat()
                val heights = floatArrayOf(0.3f, 0.55f, 0.9f, 0.55f, 0.3f)
                val maxHeight = radius * 1.2f

                var x = cx - (heights.size / 2) * spacing
                for (heightFactor in heights) {
                    val barHeight = maxHeight * heightFactor
                    canvas.drawLine(x, cy - barHeight / 2, x, cy + barHeight / 2, waveformPaint)
                    x += spacing
                }
            }

            override fun setAlpha(alpha: Int) {
                circlePaint.alpha = alpha
                waveformPaint.alpha = alpha
            }
            
            override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {
                circlePaint.colorFilter = colorFilter
                waveformPaint.colorFilter = colorFilter
            }
            
            override fun getOpacity(): Int = android.graphics.PixelFormat.TRANSLUCENT
            override fun getIntrinsicWidth(): Int = size
            override fun getIntrinsicHeight(): Int = size
        }
    }

    private fun updatePTTEnabledState() {
        pttButton.isEnabled = pttEnabled
        pttButton.alpha = if (pttEnabled) 1f else 0.4f
    }

    private fun updateButtonAppearance() {
        val size = dpToPx(32f)
        val drawable = if (isStreaming) {
            createStopButtonDrawable(size)
        } else {
            createSendButtonDrawable(size)
        }
        sendButton.setImageDrawable(drawable)
        sendButton.visibility = View.VISIBLE
        updateSendButtonState()
    }

    private fun createSendButtonDrawable(size: Int): Drawable {
        return object : Drawable() {
            private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = getTextColor()
                style = Paint.Style.FILL
            }
            
            private val arrowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = getContrastColor()
                style = Paint.Style.STROKE
                strokeWidth = dpToPx(2.5f).toFloat()
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
                    moveTo(cx, cy + arrowSize * 0.5f)
                    lineTo(cx, cy - arrowSize * 0.5f)
                    moveTo(cx - arrowSize * 0.5f, cy - arrowSize * 0.1f)
                    lineTo(cx, cy - arrowSize * 0.6f)
                    lineTo(cx + arrowSize * 0.5f, cy - arrowSize * 0.1f)
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

    private fun createStopButtonDrawable(size: Int): Drawable {
        return object : Drawable() {
            private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = getTextColor()
                style = Paint.Style.FILL
            }
            
            private val stopPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = getContrastColor()
                style = Paint.Style.FILL
            }

            override fun draw(canvas: Canvas) {
                val bounds = bounds
                val cx = bounds.exactCenterX()
                val cy = bounds.exactCenterY()
                val radius = minOf(bounds.width(), bounds.height()) / 2f

                canvas.drawCircle(cx, cy, radius, circlePaint)

                val squareSize = radius * 0.7f
                val left = cx - squareSize / 2
                val top = cy - squareSize / 2
                val right = cx + squareSize / 2
                val bottom = cy + squareSize / 2
                val squareCornerRadius = dpToPx(2f).toFloat()
                
                canvas.drawRoundRect(left, top, right, bottom, squareCornerRadius, squareCornerRadius, stopPaint)
            }

            override fun setAlpha(alpha: Int) {
                circlePaint.alpha = alpha
                stopPaint.alpha = alpha
            }

            override fun setColorFilter(colorFilter: android.graphics.ColorFilter?) {
                circlePaint.colorFilter = colorFilter
                stopPaint.colorFilter = colorFilter
            }

            override fun getOpacity(): Int = android.graphics.PixelFormat.TRANSLUCENT
            override fun getIntrinsicWidth(): Int = size
            override fun getIntrinsicHeight(): Int = size
        }
    }

    private fun updateHeight() {
        if (width <= 0) return
        
        val widthSpec = MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY)
        val heightSpec = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        editText.measure(widthSpec, heightSpec)
        
        val measuredHeight = editText.measuredHeight
        val newHeight = measuredHeight.coerceIn(minHeightPx, maxHeightPx)

        if (newHeight != currentHeight) {
            currentHeight = newHeight
            val heightDp = pxToDp(newHeight.toFloat())
            onHeightChange(mapOf("height" to heightDp.toDouble()))
            requestLayout()
        }
    }

    private fun updateSendButtonState() {
        if (isStreaming) {
            sendButton.isEnabled = true
            sendButton.alpha = 1f
        } else {
            val hasText = !editText.text.isNullOrEmpty()
            sendButton.isEnabled = sendButtonEnabled && hasText
            sendButton.alpha = if (sendButton.isEnabled) 1f else 0.4f
        }
    }
    
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val width = MeasureSpec.getSize(widthMeasureSpec)
        val editTextWidthSpec = MeasureSpec.makeMeasureSpec(width, MeasureSpec.EXACTLY)
        val editTextHeightSpec = MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED)
        editText.measure(editTextWidthSpec, editTextHeightSpec)
        val contentHeight = editText.measuredHeight
        val finalHeight = contentHeight.coerceIn(minHeightPx, maxHeightPx)
        setMeasuredDimension(width, finalHeight)
    }
    
    override fun onLayout(changed: Boolean, left: Int, top: Int, right: Int, bottom: Int) {
        val width = right - left
        val height = bottom - top
        
        // Background fills entire view
        backgroundView.layout(0, 0, width, height)
        editText.layout(0, 0, width, height)
        
        // Button Y position - centered within bottom minHeight zone
        val buttonTop = height - (minHeightPx / 2) - (buttonSize / 2)
        val buttonBottom = buttonTop + buttonSize
        
        // PTT button on left
        val pttLeft = buttonPadding / 2
        pttButton.layout(pttLeft, buttonTop, pttLeft + buttonSize, buttonBottom)
        
        // Send button on right
        val sendLeft = width - buttonSize - buttonPadding / 2
        sendButton.layout(sendLeft, buttonTop, sendLeft + buttonSize, buttonBottom)
    }

    fun focus() {
        editText.requestFocus()
        showKeyboard()
    }

    fun blur() {
        editText.clearFocus()
        hideKeyboard()
    }

    fun clear() {
        editText.setText("")
        updateHeight()
        updateSendButtonState()
        onChangeText(mapOf("text" to ""))
    }

    private fun dpToPx(dp: Float): Int {
        return TypedValue.applyDimension(
            TypedValue.COMPLEX_UNIT_DIP,
            dp,
            resources.displayMetrics
        ).toInt()
    }

    private fun pxToDp(px: Float): Float {
        return px / resources.displayMetrics.density
    }

    private fun showKeyboard() {
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.showSoftInput(editText, InputMethodManager.SHOW_IMPLICIT)
    }

    private fun hideKeyboard() {
        val imm = context.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        imm.hideSoftInputFromWindow(editText.windowToken, 0)
    }

    private fun isDarkMode(): Boolean {
        val nightModeFlags = resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK
        return nightModeFlags == android.content.res.Configuration.UI_MODE_NIGHT_YES
    }

    private fun getTextColor(): Int {
        return if (isDarkMode()) Color.WHITE else Color.BLACK
    }
    
    private fun getContrastColor(): Int {
        return if (isDarkMode()) Color.BLACK else Color.WHITE
    }
    
    private fun getPlaceholderColor(): Int {
        return if (isDarkMode()) Color.parseColor("#AAAAAA") else Color.parseColor("#666666")
    }

    private fun getSolidBackgroundColor(): Int {
        // Theme-matched solid background
        // light: systemGray6Light = #F2F2F7
        // dark:  systemGray6Dark  = #1C1C1E
        return if (isDarkMode()) Color.parseColor("#1C1C1E") else Color.parseColor("#F2F2F7")
    }
}
