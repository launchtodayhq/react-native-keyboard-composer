package expo.modules.launchhq.reactnativekeyboardcomposer

import android.view.View
import android.view.ViewGroup
import android.widget.ScrollView

internal object PinToTopRunway {
    data class ApplyPinResult(
        val isPinned: Boolean,
        val pinnedScrollY: Int,
        val runwayInsetPx: Int
    )

    fun computeTopGapPx(sv: ScrollView, child: View): Int {
        // IMPORTANT:
        // Only ScrollView paddingTop affects the scroll coordinate system.
        // Content paddingTop / first-child offsets are part of the content layout and should NOT be
        // subtracted here, otherwise we double-apply top spacing and the pinned message sits too low
        // (larger gap than the "normal" first message).
        //
        // iOS uses `adjustedContentInset.top` (coordinate system) + a small visual topPadding.
        // On Android ScrollView, the equivalent coordinate-system inset is `sv.paddingTop`.
        return sv.paddingTop.coerceAtLeast(0)
    }

    fun computeApplyPin(
        contentHeightAfter: Int,
        viewportH: Int,
        basePaddingBottom: Int,
        topPaddingPx: Int,
        pendingPinMessageStartY: Int,
        sv: ScrollView,
        child: View
    ): ApplyPinResult {
        // IMPORTANT: use *unclamped* max scroll math so pin/runway works even when
        // content is shorter than the viewport. (Clamping to 0 causes pinnedScrollY to
        // be > maxScroll, which then gets clamped during keyboard open/close.)
        // IMPORTANT: Android ScrollView's scroll range includes paddingTop + paddingBottom.
        // If we ignore paddingTop here, the "runway" becomes scrollable and the user can
        // scroll past the pinned target (breaking the pinned-at-top illusion when returning to bottom).
        val rawBaseMax = contentHeightAfter - viewportH + sv.paddingTop + basePaddingBottom

        // Respect the actual content container's top spacing (no magic numbers):
        // - contentContainerStyle.paddingTop typically lands on the inner content view's paddingTop
        // - some RN layouts may express this as first-child top offset
        // - also include ScrollView paddingTop as a fallback
        val topGap = computeTopGapPx(sv, child)

        val desiredPinned = pendingPinMessageStartY.coerceAtLeast(0)
        val pinnedTarget = (desiredPinned - topGap - topPaddingPx).coerceAtLeast(0)

        // We want maxScroll == pinnedTarget, where:
        // maxScroll = max(0, rawBaseMax + runwayInsetPx)
        // => runwayInsetPx = pinnedTarget - rawBaseMax
        val neededRunway = (pinnedTarget - rawBaseMax).coerceAtLeast(0)

        return ApplyPinResult(
            isPinned = neededRunway > 0,
            pinnedScrollY = pinnedTarget,
            runwayInsetPx = neededRunway
        )
    }

    fun computeRunwayInsetPx(
        childHeight: Int,
        viewportH: Int,
        basePaddingBottom: Int,
        pinnedScrollY: Int,
        scrollPaddingTop: Int
    ): Int {
        // Use *unclamped* base max so runway remains correct when content < viewport.
        val rawBaseMax = childHeight - viewportH + scrollPaddingTop + basePaddingBottom
        return (pinnedScrollY - rawBaseMax).coerceAtLeast(0)
    }
}


