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
        val contentGroup = child as? ViewGroup
        return maxOf(
            0,
            sv.paddingTop,
            child.paddingTop,
            if (contentGroup != null && contentGroup.childCount > 0) contentGroup.getChildAt(0).top else 0
        )
    }

    fun computeApplyPin(
        contentHeightAfter: Int,
        viewportH: Int,
        basePaddingBottom: Int,
        pendingPinMessageStartY: Int,
        sv: ScrollView,
        child: View
    ): ApplyPinResult {
        // IMPORTANT: use *unclamped* max scroll math so pin/runway works even when
        // content is shorter than the viewport. (Clamping to 0 causes pinnedScrollY to
        // be > maxScroll, which then gets clamped during keyboard open/close.)
        val rawBaseMax = contentHeightAfter - viewportH + basePaddingBottom

        // Respect the actual content container's top spacing (no magic numbers):
        // - contentContainerStyle.paddingTop typically lands on the inner content view's paddingTop
        // - some RN layouts may express this as first-child top offset
        // - also include ScrollView paddingTop as a fallback
        val topGap = computeTopGapPx(sv, child)

        val desiredPinned = pendingPinMessageStartY.coerceAtLeast(0)
        val pinnedTarget = (desiredPinned - topGap).coerceAtLeast(0)

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
        pinnedScrollY: Int
    ): Int {
        // Use *unclamped* base max so runway remains correct when content < viewport.
        val rawBaseMax = childHeight - viewportH + basePaddingBottom
        return (pinnedScrollY - rawBaseMax).coerceAtLeast(0)
    }
}


