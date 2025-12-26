import ExpoModulesCore

public class KeyboardComposerModule: Module {
  public func definition() -> ModuleDefinition {
    Name("KeyboardComposer")

    // Constants
    Constants([
      "defaultMinHeight": 48.0,
      "defaultMaxHeight": 120.0,
      "contentGap": 32.0 // Gap between last message and composer (points)
    ])

    // Composer View definition
    View(KeyboardComposerView.self) {
      // Props
      Prop("placeholder") { (view: KeyboardComposerView, value: String) in
        view.placeholder = value
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

      Prop("showPTTButton") { (view: KeyboardComposerView, value: Bool) in
        view.showPTTButton = value
      }

      Prop("pttEnabled") { (view: KeyboardComposerView, value: Bool) in
        view.pttEnabled = value
      }

      Prop("pttState") { (view: KeyboardComposerView, value: String) in
        view.pttState = value
      }

      Prop("pttPressedScale") { (view: KeyboardComposerView, value: CGFloat) in
        view.pttPressedScale = value
      }

      Prop("pttPressedOpacity") { (view: KeyboardComposerView, value: CGFloat) in
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

    // Second view in module - keyboard-aware wrapper
    // Auto-named as "KeyboardComposer_KeyboardAwareWrapper"
    View(KeyboardAwareWrapper.self) {
      Prop("extraBottomInset") { (view: KeyboardAwareWrapper, value: CGFloat) in
        view.extraBottomInset = value
      }
      
      Prop("scrollToTopTrigger") { (view: KeyboardAwareWrapper, value: Double) in
        view.scrollToTopTrigger = value
      }
    }
    
  }
}
