import UIKit

enum ViewHierarchyFinder {
    static func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    static func findComposerView(in view: UIView) -> KeyboardComposerView? {
        if let composer = view as? KeyboardComposerView {
            return composer
        }
        for subview in view.subviews {
            if let composer = findComposerView(in: subview) {
                return composer
            }
        }
        return nil
    }

    /// Walk up the superview chain until the direct child of `host` is found.
    static func findDirectChildContainer(for view: UIView, in host: UIView) -> UIView? {
        var container: UIView? = view
        while let parent = container?.superview, parent !== host {
            container = parent
        }
        return container
    }
}


