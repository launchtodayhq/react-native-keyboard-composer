import UIKit

enum ComposerHeightCoordinator {
    static func updateIfNeeded(
        composerView: KeyboardComposerView,
        lastComposerHeight: inout CGFloat,
        keyboardHandler: KeyboardAwareScrollHandler
    ) {
        let currentHeight = composerView.bounds.height
        guard currentHeight > 0 else { return }
        guard abs(currentHeight - lastComposerHeight) > 0.5 else { return }

        let delta = currentHeight - lastComposerHeight
        handleHeightChange(
            newHeight: currentHeight,
            delta: delta,
            keyboardHandler: keyboardHandler
        )
        lastComposerHeight = currentHeight
    }

    private static func handleHeightChange(
        newHeight: CGFloat,
        delta: CGFloat,
        keyboardHandler: KeyboardAwareScrollHandler
    ) {
        let isNearBottom = keyboardHandler.isUserNearBottom()

        if delta > 0 && isNearBottom {
            keyboardHandler.adjustScrollForComposerGrowth(delta: delta)
        }

        keyboardHandler.setBaseInset(newHeight, preserveScrollPosition: !isNearBottom)
    }
}


