import { requireNativeView } from "expo";
import { forwardRef, useCallback, useImperativeHandle, useRef } from "react";

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
    ...rest
  } = props;

  const nativeRef = useRef<any>(null);

  // Expose methods to parent via ref
  useImperativeHandle(ref, () => ({
    focus: () => {
      // Native focus method would be called here
    },
    blur: () => {
      // Native blur method would be called here
    },
    clear: () => {
      // Native clear method would be called here
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

  return (
    <NativeView
      ref={nativeRef}
      onChangeText={handleChangeText}
      onSend={handleSend}
      onStop={handleStop}
      onHeightChange={handleHeightChange}
      onKeyboardHeightChange={handleKeyboardHeightChange}
      onComposerFocus={handleComposerFocus}
      onComposerBlur={handleComposerBlur}
      {...rest}
    />
  );
});

KeyboardComposerView.displayName = "KeyboardComposerView";

export default KeyboardComposerView;
