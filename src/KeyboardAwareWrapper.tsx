import { requireNativeView } from "expo";
import type { ReactNode } from "react";
import type { ViewStyle, StyleProp } from "react-native";

export interface KeyboardAwareWrapperProps {
  children?: ReactNode;
  style?: StyleProp<ViewStyle>;
  /**
   * Extra bottom inset (composer height + gap).
   * Keyboard height is automatically handled by native code.
   */
  extraBottomInset?: number;
  /**
   * Allow scroll content to render under the composer by this many dp.
   * This makes Android BlurView visibly blur actual content instead of just the background.
   */
  blurUnderlap?: number;
  /**
   * Trigger scroll to bottom when this value changes.
   * Use Date.now() or a counter to trigger.
   */
  scrollToTopTrigger?: number;
}

// Native view - auto-named as "KeyboardComposer_KeyboardAwareWrapper"
const NativeView: React.ComponentType<{
  style?: StyleProp<ViewStyle>;
  extraBottomInset?: number;
  blurUnderlap?: number;
  scrollToTopTrigger?: number;
  children?: ReactNode;
}> = requireNativeView("KeyboardComposer_KeyboardAwareWrapper");

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
  extraBottomInset = 0,
  blurUnderlap = 0,
  scrollToTopTrigger = 0,
}: KeyboardAwareWrapperProps) {
  return (
    <NativeView
      style={style}
      extraBottomInset={extraBottomInset}
      blurUnderlap={blurUnderlap}
      scrollToTopTrigger={scrollToTopTrigger}
    >
      {children}
    </NativeView>
  );
}

export default KeyboardAwareWrapper;
