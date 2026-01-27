package expo.modules.launchhq.reactnativekeyboardcomposer

import android.annotation.SuppressLint
import android.content.Context
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
import android.view.inputmethod.InputMethodManager
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageButton
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.viewevent.EventDispatcher
import expo.modules.kotlin.views.ExpoView

class KeyboardComposerView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
    companion object {
        private const val DEBUG_LOGS = true
        private const val TAG = "KeyboardComposerNative"
    }

    // MARK: - Event Dispatchers
    private val onChangeText by EventDispatcher()
    private val onSend by EventDispatcher()
    private val onStop by EventDispatcher()
    private val onHeightChange by EventDispatcher()
    private val onKeyboardHeightChange by EventDispatcher()
    private val onComposerFocus by EventDispatcher()
    private val onComposerBlur by EventDispatcher()

    // MARK: - Props
    var placeholderText: String = "Type a message..."
        set(value) {
            field = value
            editText.hint = value
        }

    var text: String
        set(value) {
            // Only update if text is actually different (prevents cursor jump on re-render)
            if (editText.text?.toString() != value) {
                editText.setText(value)
                editText.setSelection(value.length)
                updateHeight()
                updateSendButtonState()
            }
        }
        get() = editText.text?.toString() ?: ""

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

    internal var onNativeSend: (() -> Unit)? = null

    // MARK: - UI Elements
    private val editText: EditText
    private val sendButton: ImageButton
    private var currentHeight: Int = 0
    private var minHeightPx: Int = 0
    private var maxHeightPx: Int = 0

    init {
        minHeightPx = dpToPx(minHeightDp)
        maxHeightPx = dpToPx(maxHeightDp)
        currentHeight = minHeightPx
        
        setBackgroundColor(Color.TRANSPARENT)

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
            setPadding(dpToPx(16f), dpToPx(14f), dpToPx(56f), dpToPx(14f))
            
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

        setupEditTextTouchHandling()

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

        addView(editText, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
        
        val buttonSize = dpToPx(48f)
        val buttonMargin = dpToPx(2f)
        addView(sendButton, LayoutParams(buttonSize, buttonSize).apply {
            gravity = Gravity.BOTTOM or Gravity.END
            setMargins(0, 0, buttonMargin, buttonMargin)
        })

        updateButtonAppearance()
        updateSendButtonState()

        post {
            onHeightChange(mapOf("height" to minHeightDp.toDouble()))
            
            // Ensure placeholder is visible after layout
            if (editText.hint.isNullOrEmpty()) {
                editText.hint = placeholderText
            }
            
            // Re-apply hint and color after layout
            editText.setHintTextColor(getPlaceholderColor())
            editText.hint = placeholderText
            editText.requestLayout()
            editText.invalidate()
            
            // Second post to ensure layout is complete
            post {
                if (editText.width > 0 && editText.height > 0 && editText.text.isNullOrEmpty()) {
                    editText.setHintTextColor(getPlaceholderColor())
                    editText.invalidate()
                }
            }
        }

        editText.onFocusChangeListener = View.OnFocusChangeListener { _, hasFocus ->
            if (DEBUG_LOGS) {
                android.util.Log.w(TAG, "Composer EditText focus=$hasFocus shown=${editText.isShown} enabled=${editText.isEnabled} textLen=${editText.text?.length ?: 0}")
            }
        }
    }
    
    @SuppressLint("ClickableViewAccessibility")
    private fun setupEditTextTouchHandling() {
        editText.setOnTouchListener { v, event ->
            if (DEBUG_LOGS && event.action == MotionEvent.ACTION_DOWN) {
                android.util.Log.w(TAG, "Composer EditText ACTION_DOWN shown=${editText.isShown} enabled=${editText.isEnabled} hint='${editText.hint}'")
            }
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
        onNativeSend?.invoke()
        onSend(mapOf("text" to text))
        editText.setText("")
        hideKeyboard()
        post { updateHeight() }
        updateSendButtonState()
    }

    private fun handleStop() {
        performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        onStop(emptyMap())
    }

    private fun updateButtonAppearance() {
        val size = dpToPx(44f)
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
                color = getBackgroundColor()
                style = Paint.Style.STROKE
                strokeWidth = dpToPx(3f).toFloat()
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
                color = getBackgroundColor()
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
                val cornerRadius = dpToPx(3f).toFloat()
                
                canvas.drawRoundRect(left, top, right, bottom, cornerRadius, cornerRadius, stopPaint)
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
        editText.layout(0, 0, width, height)
        val buttonSize = dpToPx(48f)
        val buttonMargin = dpToPx(2f)
        val buttonLeft = width - buttonSize - buttonMargin
        val buttonTop = height - buttonSize - buttonMargin
        sendButton.layout(buttonLeft, buttonTop, buttonLeft + buttonSize, buttonTop + buttonSize)
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
        if (DEBUG_LOGS) {
            android.util.Log.w(TAG, "Composer showKeyboard requestFocus=${editText.hasFocus()} windowTokenNull=${editText.windowToken == null}")
        }
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
    
    private fun getPlaceholderColor(): Int {
        return if (isDarkMode()) Color.parseColor("#AAAAAA") else Color.parseColor("#666666")
    }

    private fun getBackgroundColor(): Int {
        return if (isDarkMode()) Color.parseColor("#1C1C1E") else Color.WHITE
    }
}
