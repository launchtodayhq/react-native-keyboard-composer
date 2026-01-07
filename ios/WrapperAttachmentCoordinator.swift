import UIKit

enum WrapperAttachmentCoordinator {
    static func attachIfNeeded(
        host: UIView,
        getHasAttached: @escaping () -> Bool,
        setHasAttached: @escaping (Bool) -> Void,
        getComposerView: @escaping () -> KeyboardComposerView?,
        setComposerView: @escaping (KeyboardComposerView?) -> Void,
        setComposerContainer: @escaping (UIView?) -> Void,
        getExtraBottomInset: @escaping () -> CGFloat,
        setLastComposerHeight: @escaping (CGFloat) -> Void,
        updateComposerTransform: @escaping () -> Void,
        setBaseInset: @escaping (CGFloat) -> Void,
        attachScrollHandler: @escaping (UIScrollView) -> Void,
        scheduleRetry: @escaping (@escaping () -> Void) -> Void
    ) {
        guard !getHasAttached() else { return }

        let scrollView = ViewHierarchyFinder.findScrollView(in: host)
        let composer = ViewHierarchyFinder.findComposerView(in: host)

        if let sv = scrollView {
            let composerHeight = getComposerView()?.bounds.height ?? getExtraBottomInset()
            setBaseInset(composerHeight)
            attachScrollHandler(sv)
            setHasAttached(true)
        }

        if let comp = composer {
            setComposerView(comp)
            setComposerContainer(ViewHierarchyFinder.findDirectChildContainer(for: comp, in: host))
            setLastComposerHeight(comp.bounds.height)
            updateComposerTransform()
        }

        if scrollView == nil {
            scheduleRetry {
                attachIfNeeded(
                    host: host,
                    getHasAttached: getHasAttached,
                    setHasAttached: setHasAttached,
                    getComposerView: getComposerView,
                    setComposerView: setComposerView,
                    setComposerContainer: setComposerContainer,
                    getExtraBottomInset: getExtraBottomInset,
                    setLastComposerHeight: setLastComposerHeight,
                    updateComposerTransform: updateComposerTransform,
                    setBaseInset: setBaseInset,
                    attachScrollHandler: attachScrollHandler,
                    scheduleRetry: scheduleRetry
                )
            }
        }
    }
}


