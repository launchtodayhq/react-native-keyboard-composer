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
    private val setImeAnimating: (Boolean) -> Unit,
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
    companion object {
        private const val DEBUG_LOGS = true
        private const val TAG = "KeyboardComposerNative"
    }

    private var wasAtBottom: Boolean = false
    private var isOpening: Boolean = false

    fun attach() {
        ViewCompat.setWindowInsetsAnimationCallback(
            scrollView,
            object : WindowInsetsAnimationCompat.Callback(DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                override fun onPrepare(animation: WindowInsetsAnimationCompat) {
                    if (animation.typeMask and WindowInsetsCompat.Type.ime() == 0) return
                    setImeAnimating(true)

                    val currentKeyboardHeight = getCurrentKeyboardHeight()
                    isOpening = currentKeyboardHeight == 0
                    // Treat as "at bottom" even for short content. IME padding can create
                    // a scroll range mid-animation, and we want to stay pinned to bottom.
                    wasAtBottom = !isPinned() && isNearBottom(scrollView)

                    // If we're about to pin (send just happened), do NOT let the IME close animation
                    // translate/drag the content. We'll pin after the keyboard closes.
                    if (!isOpening && isPinPendingOrDeferred()) {
                        wasAtBottom = false
                    }

                    if (DEBUG_LOGS) {
                        val childH = scrollView.getChildAt(0)?.height ?: -1
                        android.util.Log.w(
                            TAG,
                            "IME onPrepare opening=$isOpening keyboardH=$currentKeyboardHeight wasAtBottom=$wasAtBottom scrollY=${scrollView.scrollY} maxScroll=${getMaxScroll(scrollView)} childH=$childH svH=${scrollView.height}"
                        )
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
                    updateScrollPadding()
                    updateScrollButtonPosition()

                    if (wasAtBottom) {
                        val maxScroll = getMaxScroll(scrollView)
                        scrollView.scrollTo(0, maxScroll)
                    }

                    if (DEBUG_LOGS) {
                        android.util.Log.w(
                            TAG,
                            "IME onProgress kb=$keyboardHeight eff=$effectiveKeyboard safe=$safeAreaBottom wasAtBottom=$wasAtBottom scrollY=${scrollView.scrollY} maxScroll=${getMaxScroll(scrollView)}"
                        )
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

                    scrollView.getChildAt(0)?.translationY = 0f
                    if (wasAtBottom) {
                        scrollView.scrollY = maxScroll.coerceAtLeast(0)
                    } else if (currentScrollY > maxScroll && maxScroll >= 0) {
                        scrollView.scrollY = maxScroll
                    }

                    updateScrollButtonPosition()
                    postToUi(Runnable { checkAndUpdateScrollPosition() })

                    if (DEBUG_LOGS) {
                        android.util.Log.w(
                            TAG,
                            "IME onEnd kb=$keyboardHeight eff=$effectiveKeyboard wasAtBottom=$wasAtBottom scrollY=${scrollView.scrollY} maxScroll=$maxScroll"
                        )
                    }

                    setImeAnimating(false)
                    if (keyboardHeight == 0 && getPendingPinReady()) {
                        setPendingPinReady(false)
                        applyPinAfterSend(getPendingPinContentHeightAfter())
                    }
                }
            }
        )
    }
}


