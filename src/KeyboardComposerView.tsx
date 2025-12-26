import { requireNativeView } from "expo";
import { forwardRef, useCallback, useImperativeHandle } from "react";

import type {
  KeyboardComposerProps,
  KeyboardComposerRef,
  KeyboardComposerViewProps,
  TextEventPayload,
  HeightEventPayload,
} from "./KeyboardComposer.types";

// Get the native view component
const NativeView: React.ComponentType<KeyboardComposerViewProps> =
  requireNativeView("KeyboardComposer");

/**
 * KeyboardComposer - A native composer with pixel-perfect keyboard tracking.
 *
 * Uses native keyboard APIs for smooth keyboard animations that match
 * system apps like iMessage.
 *
 * @example
 * ```tsx
 * <KeyboardComposer
 *   placeholder="Type a message..."
 *   onSend={(text) => sendMessage(text)}
 *   onKeyboardHeightChange={(height) => setFooterHeight(height)}
 * />
 * ```
 */
const KeyboardComposerView = forwardRef<
  KeyboardComposerRef,
  KeyboardComposerProps
>((props, ref) => {
    const {
      onChangeText,
      onSend,
      onStop,
      onHeightChange,
      onKeyboardHeightChange,
      onComposerFocus,
      onComposerBlur,
      onPTTPress,
      onPTTPressIn,
      onPTTPressOut,
      ...rest
    } = props;

  // Expose methods to parent via ref (placeholder for future native method support)
    useImperativeHandle(ref, () => ({
      focus: () => {
      // TODO: Call native focus method
      },
      blur: () => {
      // TODO: Call native blur method
      },
      clear: () => {
      // TODO: Call native clear method
      },
    }));

    // Event handlers that unwrap nativeEvent
    const handleChangeText = useCallback(
      (event: { nativeEvent: TextEventPayload }) => {
        onChangeText?.(event.nativeEvent.text);
      },
      [onChangeText]
    );

    const handleSend = useCallback(
      (event: { nativeEvent: TextEventPayload }) => {
        onSend?.(event.nativeEvent.text);
      },
      [onSend]
    );

    const handleStop = useCallback(() => {
      onStop?.();
    }, [onStop]);

    const handleHeightChange = useCallback(
      (event: { nativeEvent: HeightEventPayload }) => {
        onHeightChange?.(event.nativeEvent.height);
      },
      [onHeightChange]
    );

    const handleKeyboardHeightChange = useCallback(
      (event: { nativeEvent: HeightEventPayload }) => {
        onKeyboardHeightChange?.(event.nativeEvent.height);
      },
      [onKeyboardHeightChange]
    );

    const handleComposerFocus = useCallback(() => {
      onComposerFocus?.();
    }, [onComposerFocus]);

    const handleComposerBlur = useCallback(() => {
      onComposerBlur?.();
    }, [onComposerBlur]);

    const handlePTTPress = useCallback(() => {
      onPTTPress?.();
    }, [onPTTPress]);

    const handlePTTPressIn = useCallback(() => {
      onPTTPressIn?.();
    }, [onPTTPressIn]);

    const handlePTTPressOut = useCallback(() => {
      onPTTPressOut?.();
    }, [onPTTPressOut]);

    return (
      <NativeView
        onChangeText={handleChangeText}
        onSend={handleSend}
        onStop={handleStop}
        onHeightChange={handleHeightChange}
        onKeyboardHeightChange={handleKeyboardHeightChange}
        onComposerFocus={handleComposerFocus}
        onComposerBlur={handleComposerBlur}
        onPTTPress={handlePTTPress}
        onPTTPressIn={handlePTTPressIn}
        onPTTPressOut={handlePTTPressOut}
        {...rest}
      />
    );
});

KeyboardComposerView.displayName = "KeyboardComposerView";

export default KeyboardComposerView;
