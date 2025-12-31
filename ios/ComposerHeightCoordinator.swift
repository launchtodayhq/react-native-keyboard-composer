import UIKit

enum ComposerHeightCoordinator {
    static func updateIfNeeded(
        composerView: KeyboardComposerView,
        lastComposerHeight: inout CGFloat,
        keyboardHandler: KeyboardAwareScrollHandler,
        contentGap: CGFloat
    ) {
        let currentHeight = composerView.bounds.height
        guard currentHeight > 0 else { return }
        guard abs(currentHeight - lastComposerHeight) > 0.5 else { return }

        let delta = currentHeight - lastComposerHeight
        handleHeightChange(
            newHeight: currentHeight,
            delta: delta,
            keyboardHandler: keyboardHandler,
            contentGap: contentGap
        )
        lastComposerHeight = currentHeight
    }

    private static func handleHeightChange(
        newHeight: CGFloat,
        delta: CGFloat,
        keyboardHandler: KeyboardAwareScrollHandler,
        contentGap: CGFloat
    ) {
        let isNearBottom = keyboardHandler.isUserNearBottom()

        if delta > 0 && isNearBottom {
            keyboardHandler.adjustScrollForComposerGrowth(delta: delta)
        }

        keyboardHandler.setBaseInset(newHeight + contentGap, preserveScrollPosition: !isNearBottom)
    }
}


