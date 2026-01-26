import ExpoModulesCore

public class KeyboardComposerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("KeyboardComposer")

    // Constants
    Constants([
      "defaultMinHeight": 48.0,
      "defaultMaxHeight": 120.0,
      "contentGap": 0.0 // Gap between last message and composer (points)
    ])

    // Composer View definition
    View(KeyboardComposerView.self) {
      // Props
      Prop("placeholder") { (view: KeyboardComposerView, value: String) in
        view.placeholder = value
      }

      Prop("text") { (view: KeyboardComposerView, value: String) in
        view.text = value
      }

      Prop("minHeight") { (view: KeyboardComposerView, value: CGFloat) in
        view.minHeight = value
      }

      Prop("maxHeight") { (view: KeyboardComposerView, value: CGFloat) in
        view.maxHeight = value
      }

      Prop("sendButtonEnabled") { (view: KeyboardComposerView, value: Bool) in
        view.sendButtonEnabled = value
      }

      Prop("editable") { (view: KeyboardComposerView, value: Bool) in
        view.editable = value
      }

      Prop("autoFocus") { (view: KeyboardComposerView, value: Bool) in
        view.autoFocus = value
      }

      Prop("blurTrigger") { (view: KeyboardComposerView, value: Double) in
        if value > 0 {
          view.blur()
        }
      }

      Prop("isStreaming") { (view: KeyboardComposerView, value: Bool) in
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

    // Second view in module - keyboard-aware wrapper
    // Auto-named as "KeyboardComposer_KeyboardAwareWrapper"
    View(KeyboardAwareWrapper.self) {
      Prop("pinToTopEnabled") { (view: KeyboardAwareWrapper, value: Bool) in
        view.pinToTopEnabled = value
      }

      Prop("extraBottomInset") { (view: KeyboardAwareWrapper, value: CGFloat) in
        view.extraBottomInset = value
      }

      // No-op on iOS (kept for cross-platform API parity; iOS handles headers via ScrollView contentInset).
      Prop("extraTopInset") { (_: KeyboardAwareWrapper, _: CGFloat) in
        // Intentionally unused
      }
      
      Prop("scrollToTopTrigger") { (view: KeyboardAwareWrapper, value: Double) in
        view.scrollToTopTrigger = value
      }
    }
    
  }
}
