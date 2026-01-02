import type { ReactNode } from "react";
import type { ViewStyle, StyleProp } from "react-native";
import { requireNativeViewManager } from "expo-modules-core";

export interface KeyboardAwareWrapperProps {
  children?: ReactNode;
  style?: StyleProp<ViewStyle>;
  /**
   * Enables ChatGPT-style pin-to-top behavior (runway below the pinned user message).
   *
   * NOTE: If omitted, native defaults apply (to preserve existing behavior).
   */
  pinToTopEnabled?: boolean;
  /**
   * Extra bottom inset (composer height + gap).
   * Keyboard height is automatically handled by native code.
   */
  extraBottomInset?: number;
  /**
   * Trigger scroll to bottom when this value changes.
   * Use Date.now() or a counter to trigger.
   */
  scrollToTopTrigger?: number;
}

// Native view (ExpoModulesCore):
// Module name: "KeyboardComposer"
// View name: "KeyboardAwareWrapper" (exported as "KeyboardComposer_KeyboardAwareWrapper" internally)
type NativeKeyboardAwareWrapperProps = {
  style?: StyleProp<ViewStyle>;
  pinToTopEnabled?: boolean;
  extraBottomInset?: number;
  scrollToTopTrigger?: number;
  children?: ReactNode;
};

const NativeView = (
  requireNativeViewManager as unknown as (
    moduleName: string,
    viewName?: string
  ) => React.ComponentType<NativeKeyboardAwareWrapperProps>
)("KeyboardComposer", "KeyboardAwareWrapper");

/**
 * Native wrapper that handles keyboard adjustments for ScrollView children.
 *
 * Behavior (matching iOS):
 * - When scrolled to bottom + keyboard opens → auto-scroll to keep content at bottom
 * - When NOT at bottom + keyboard opens → keyboard opens over content (no scroll)
 *
 * @example
 * ```tsx
 * <KeyboardAwareWrapper extraBottomInset={composerHeight + gap}>
 *   <ScrollView>...</ScrollView>
 * </KeyboardAwareWrapper>
 * ```
 */
export function KeyboardAwareWrapper({
  children,
  style,
  pinToTopEnabled,
  extraBottomInset = 0,
  scrollToTopTrigger = 0,
}: KeyboardAwareWrapperProps) {
  return (
    <NativeView
      style={style}
      {...(pinToTopEnabled === undefined ? {} : { pinToTopEnabled })}
      extraBottomInset={extraBottomInset}
      scrollToTopTrigger={scrollToTopTrigger}
    >
      {children}
    </NativeView>
  );
}

export default KeyboardAwareWrapper;
