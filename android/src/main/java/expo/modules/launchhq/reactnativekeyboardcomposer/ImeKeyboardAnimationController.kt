package expo.modules.launchhq.reactnativekeyboardcomposer

import android.widget.ScrollView
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsAnimationCompat
import androidx.core.view.WindowInsetsCompat

internal class ImeKeyboardAnimationController(
    private val scrollView: ScrollView,
    private val getSafeAreaBottom: () -> Int,
    private val getCurrentKeyboardHeight: () -> Int,
    private val setCurrentKeyboardHeight: (Int) -> Unit,
    private val applyComposerTranslation: () -> Unit,
    private val updateScrollButtonPosition: () -> Unit,
    private val updateScrollPadding: () -> Unit,
    private val getMaxScroll: (ScrollView) -> Int,
    private val isNearBottom: (ScrollView) -> Boolean,
    private val isPinned: () -> Boolean,
    private val isPinPendingOrDeferred: () -> Boolean,
    private val getPendingPinReady: () -> Boolean,
    private val setPendingPinReady: (Boolean) -> Unit,
    private val getPendingPinContentHeightAfter: () -> Int,
    private val applyPinAfterSend: (Int) -> Unit,
    private val postToUi: (Runnable) -> Unit,
    private val checkAndUpdateScrollPosition: () -> Unit
) {
    private var wasAtBottom: Boolean = false
    private var baseScrollY: Int = 0
    private var isOpening: Boolean = false
    private var closingStartTranslation: Int = 0
    private var maxKeyboardHeight: Int = 0

    fun attach() {
        ViewCompat.setWindowInsetsAnimationCallback(
            scrollView,
            object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                    if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return

                    val currentKeyboardHeight = getCurrentKeyboardHeight()
                    if (currentKeyboardHeight == 0) {
                        isOpening = true
                        wasAtBottom = !isPinned() && isNearBottom(scrollView)
                        baseScrollY = scrollView.scrollY
                    } else {
                        isOpening = false
                        wasAtBottom = !isPinned() && isNearBottom(scrollView)
                        closingStartTranslation = scrollView.getChildAt(0)?.translationY?.toInt() ?: 0
                        maxKeyboardHeight = currentKeyboardHeight
                        if (wasAtBottom) {
                            val maxEffectiveKeyboard = (maxKeyboardHeight - getSafeAreaBottom()).coerceAtLeast(0)
                            baseScrollY = scrollView.scrollY - maxEffectiveKeyboard
                        }
                    }

                    // If we're about to pin (send just happened), do NOT let the IME close animation
                    // translate/drag the content. We'll pin after the keyboard closes.
                    if (!isOpening && isPinPendingOrDeferred()) {
                        wasAtBottom = false
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
                    val imeAnimation =
                        runningAnimations.find { it.typeMask and WindowInsetsCompat.Type.ime() != 0 }
                            ?: return insets

                    val keyboardHeight = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
                    setCurrentKeyboardHeight(keyboardHeight)

                    val safeAreaBottom = getSafeAreaBottom()
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
                        scrollView.getChildAt(0)?.translationY = contentTranslation.toFloat()
                    }

                    return insets
                }

                override fun onEnd(animation: WindowInsetsAnimationCompat) {
                    if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return

                    val rootInsets = ViewCompat.getRootWindowInsets(scrollView)
                    val keyboardHeight = rootInsets?.getInsets(WindowInsetsCompat.Type.ime())?.bottom ?: 0
                    setCurrentKeyboardHeight(keyboardHeight)

                    val safeAreaBottom = getSafeAreaBottom()
                    val effectiveKeyboard = (keyboardHeight - safeAreaBottom).coerceAtLeast(0)

                    applyComposerTranslation()
                    updateScrollPadding()

                    val maxScroll = getMaxScroll(scrollView)
                    val currentScrollY = scrollView.scrollY

                    if (wasAtBottom) {
                        val desiredScrollY = baseScrollY + effectiveKeyboard
                        val finalScrollY = if (maxScroll <= 0) 0 else desiredScrollY.coerceAtLeast(0)
                        scrollView.scrollY = finalScrollY
                        val actualScrollY = scrollView.scrollY
                        val remainingTranslation = actualScrollY - desiredScrollY
                        scrollView.getChildAt(0)?.translationY = if (maxScroll <= 0) 0f else remainingTranslation.toFloat()
                    } else {
                        scrollView.getChildAt(0)?.translationY = 0f
                        if (currentScrollY > maxScroll && maxScroll >= 0) {
                            scrollView.scrollY = maxScroll
                        }
                    }

                    updateScrollButtonPosition()
                    postToUi(Runnable { checkAndUpdateScrollPosition() })

                    if (keyboardHeight == 0 && getPendingPinReady()) {
                        setPendingPinReady(false)
                        applyPinAfterSend(getPendingPinContentHeightAfter())
                    }
                }
            }
        )
    }
}


