package expo.modules.launchhq.reactnativekeyboardcomposer

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

/**
 * Expo module for KeyboardComposer.
 */
class KeyboardComposerModule : Module() {

    override fun definition() = ModuleDefinition {
        Name("KeyboardComposer")

        // KeyboardComposerView
        View(KeyboardComposerView::class) {
            Prop("placeholder") { view: KeyboardComposerView, value: String ->
                view.placeholderText = value
            }

            Prop("minHeight") { view: KeyboardComposerView, value: Float ->
                view.minHeightDp = value
            }

            Prop("maxHeight") { view: KeyboardComposerView, value: Float ->
                view.maxHeightDp = value
            }

            Prop("sendButtonEnabled") { view: KeyboardComposerView, value: Boolean ->
                view.sendButtonEnabled = value
            }

            Prop("editable") { view: KeyboardComposerView, value: Boolean ->
                view.editable = value
            }

            Prop("autoFocus") { view: KeyboardComposerView, value: Boolean ->
                view.autoFocus = value
            }

            Prop("blurTrigger") { view: KeyboardComposerView, value: Double ->
                if (value > 0) {
                    view.blur()
                }
            }

            Prop("isStreaming") { view: KeyboardComposerView, value: Boolean ->
                view.isStreaming = value
            }

            Prop("showPTTButton") { view: KeyboardComposerView, value: Boolean ->
                view.showPTTButton = value
            }

            Prop("pttEnabled") { view: KeyboardComposerView, value: Boolean ->
                view.pttEnabled = value
            }

            Prop("pttState") { view: KeyboardComposerView, value: String ->
                view.pttState = value
            }

            Prop("pttPressedScale") { view: KeyboardComposerView, value: Float ->
                view.pttPressedScale = value
            }

            Prop("pttPressedOpacity") { view: KeyboardComposerView, value: Float ->
                view.pttPressedOpacity = value
            }

            Events(
                "onChangeText",
                "onSend",
                "onStop",
                "onHeightChange",
                "onKeyboardHeightChange",
                "onComposerFocus",
                "onComposerBlur",
                "onPTTPress",
                "onPTTPressIn",
                "onPTTPressOut"
            )
        }

        // KeyboardAwareWrapper
        // Auto-named as "KeyboardComposer_KeyboardAwareWrapper"
        View(KeyboardAwareWrapper::class) {
            Prop("extraBottomInset") { view: KeyboardAwareWrapper, value: Float ->
                view.extraBottomInset = value
            }

            Prop("blurUnderlap") { view: KeyboardAwareWrapper, value: Float ->
                view.blurUnderlap = value
            }

            Prop("scrollToTopTrigger") { view: KeyboardAwareWrapper, value: Double ->
                view.scrollToTopTrigger = value
            }
        }
    }
}
