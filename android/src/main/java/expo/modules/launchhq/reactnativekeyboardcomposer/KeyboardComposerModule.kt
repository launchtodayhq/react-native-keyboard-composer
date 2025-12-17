package expo.modules.launchhq.reactnativekeyboardcomposer

import android.util.Log
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition

/**
 * Expo module for KeyboardComposer.
 */
class KeyboardComposerModule : Module() {

    companion object {
        private const val TAG = "KeyboardComposerModule"
    }

    override fun definition() = ModuleDefinition {
        Name("KeyboardComposer")

        OnCreate {
            Log.d(TAG, "KeyboardComposerModule created")
        }

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
        View(KeyboardAwareWrapper::class) {
            Prop("extraBottomInset") { view: KeyboardAwareWrapper, value: Float ->
                view.extraBottomInset = value
            }

            Prop("scrollToTopTrigger") { view: KeyboardAwareWrapper, value: Double ->
                view.scrollToTopTrigger = value
            }
        }
    }
}
