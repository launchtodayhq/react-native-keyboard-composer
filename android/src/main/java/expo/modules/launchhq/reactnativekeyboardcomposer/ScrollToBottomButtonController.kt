package expo.modules.launchhq.reactnativekeyboardcomposer

import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.drawable.Drawable
import android.view.View
import android.view.ViewGroup
import android.widget.ImageButton

internal class ScrollToBottomButtonController(
    private val context: Context,
    private val parent: ViewGroup,
    private val buttonSizePx: Int,
    private val dpToPxInt: (Int) -> Int,
    private val dpToPxFloat: (Float) -> Float,
    private val isDarkMode: () -> Boolean,
    private val calculateTranslationY: () -> Float,
    private val onClick: () -> Unit
) {
    private var button: ImageButton? = null
    private var isVisible = false
    private var isAnimating = false

    fun getButtonView(): View? = button

    fun createIfNeeded() {
        if (button != null) return

        val created = ImageButton(context).apply {
            contentDescription = "Scroll to bottom"
            background = createScrollButtonDrawable(buttonSizePx)
            setImageDrawable(null)

            elevation = dpToPxInt(4).toFloat()

            outlineProvider = object : android.view.ViewOutlineProvider() {
                override fun getOutline(view: View, outline: android.graphics.Outline) {
                    outline.setOval(0, 0, view.width, view.height)
                }
            }
            clipToOutline = false

            alpha = 0f
            visibility = View.GONE

            setOnClickListener { onClick() }
        }

        val params = ViewGroup.LayoutParams(buttonSizePx, buttonSizePx)
        parent.addView(created, params)
        button = created
    }

    fun layout(parentWidth: Int, parentHeight: Int) {
        val b = button ?: return
        val left = (parentWidth - buttonSizePx) / 2
        val top = parentHeight - buttonSizePx
        b.layout(left, top, left + buttonSizePx, top + buttonSizePx)
        b.bringToFront()
    }

    fun updatePosition() {
        if (isAnimating) return
        val b = button ?: return
        b.translationY = calculateTranslationY()
    }

    fun show() {
        if (isVisible) return
        val b = button ?: return
        isVisible = true
        isAnimating = true

        val baseTranslationY = calculateTranslationY()
        b.translationY = baseTranslationY + dpToPxInt(12)
        b.alpha = 0f
        b.visibility = View.VISIBLE

        b.animate()
            .alpha(1f)
            .translationY(baseTranslationY)
            .setDuration(250)
            .setInterpolator(android.view.animation.DecelerateInterpolator())
            .setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    isAnimating = false
                    updatePosition()
                }
            })
            .start()
    }

    fun hide() {
        if (!isVisible) return
        val b = button ?: return
        isVisible = false
        isAnimating = true

        val currentTranslationY = b.translationY

        b.animate()
            .alpha(0f)
            .translationY(currentTranslationY + dpToPxInt(12))
            .setDuration(180)
            .setInterpolator(android.view.animation.AccelerateInterpolator())
            .setListener(object : AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: Animator) {
                    b.visibility = View.GONE
                    updatePosition()
                    isAnimating = false
                }
            })
            .start()
    }

    private fun createScrollButtonDrawable(size: Int): Drawable {
        return object : Drawable() {
            private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (isDarkMode()) Color.parseColor("#2C2C2E") else Color.WHITE
                style = Paint.Style.FILL
            }

            private val arrowPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (isDarkMode()) Color.WHITE else Color.BLACK
                style = Paint.Style.STROKE
                strokeWidth = dpToPxFloat(2.5f)
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
}


