package expo.modules.launchhq.reactnativekeyboardcomposer

import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import android.util.Log

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

            Events(
                "onChangeText",
                "onSend",
                "onStop",
                "onHeightChange",
                "onKeyboardHeightChange",
                "onComposerFocus",
                "onComposerBlur"
            )
        }

        // KeyboardAwareWrapper
        // Auto-named as "KeyboardComposer_KeyboardAwareWrapper"
        View(KeyboardAwareWrapper::class) {
            Prop("pinToTopEnabled") { view: KeyboardAwareWrapper, value: Boolean ->
                Log.w("KeyboardComposerNative", "Prop pinToTopEnabled -> $value")
                view.pinToTopEnabled = value
            }

            Prop("extraBottomInset") { view: KeyboardAwareWrapper, value: Float ->
                view.extraBottomInset = value
            }

            Prop("scrollToTopTrigger") { view: KeyboardAwareWrapper, value: Double ->
                view.scrollToTopTrigger = value
            }
        }
    }
}
