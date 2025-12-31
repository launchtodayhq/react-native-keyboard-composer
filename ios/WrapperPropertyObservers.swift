import Foundation
import UIKit

enum WrapperPropertyObservers {
    static func setup(
        wrapper: KeyboardAwareWrapper,
        onExtraBottomInsetChange: @escaping (_ oldValue: CGFloat, _ newValue: CGFloat) -> Void,
        onScrollToTopTrigger: @escaping () -> Void
    ) -> (NSKeyValueObservation, NSKeyValueObservation) {
        let extraObs = wrapper.observe(\.extraBottomInset, options: [.old, .new]) { _, change in
            guard let oldValue = change.oldValue,
                  let newValue = change.newValue,
                  oldValue != newValue else { return }
            onExtraBottomInsetChange(oldValue, newValue)
        }

        let triggerObs = wrapper.observe(\.scrollToTopTrigger, options: [.new]) { _, change in
            guard let newValue = change.newValue, newValue > 0 else { return }
            onScrollToTopTrigger()
        }

        return (extraObs, triggerObs)
    }
}


