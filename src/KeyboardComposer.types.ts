import type { StyleProp, ViewStyle } from "react-native";

// Event payloads from native
export type TextEventPayload = {
  text: string;
};

export type HeightEventPayload = {
  height: number;
};

export type PTTState = "available" | "talking" | "listening";

// Props for the native view
export type KeyboardComposerViewProps = {
  /** Placeholder text shown when empty */
  placeholder?: string;

  /** Controlled text value */
  text?: string;

  /** Minimum height of the composer */
  minHeight?: number;

  /** Maximum height before scrolling */
  maxHeight?: number;

  /** Whether the send button is enabled */
  sendButtonEnabled?: boolean;

  /** Whether the text input is editable */
  editable?: boolean;

  /** Whether to auto focus the input on mount */
  autoFocus?: boolean;

  /** Trigger to blur the input - change value to trigger blur */
  blurTrigger?: number;

  /** Whether the AI is currently streaming (shows stop button) */
  isStreaming?: boolean;

  /** Whether to show the PTT (Push-to-Talk) button */
  showPTTButton?: boolean;

  /** Whether the PTT button is enabled */
  pttEnabled?: boolean;

  /** PTT state controls appearance and behavior */
  pttState?: PTTState;

  /** Visual feedback when pressing the PTT button */
  pttPressedScale?: number;
  pttPressedOpacity?: number;

  /** Called when text changes */
  onChangeText?: (event: { nativeEvent: TextEventPayload }) => void;

  /** Called when send button is pressed */
  onSend?: (event: { nativeEvent: TextEventPayload }) => void;

  /** Called when stop button is pressed */
  onStop?: () => void;

  /** Called when composer height changes (for auto-grow) */
  onHeightChange?: (event: { nativeEvent: HeightEventPayload }) => void;

  /** Called when keyboard height changes (for list footer) */
  onKeyboardHeightChange?: (event: { nativeEvent: HeightEventPayload }) => void;

  /** Called when text input gains focus */
  onComposerFocus?: () => void;

  /** Called when text input loses focus */
  onComposerBlur?: () => void;

  /** Called when PTT button is tapped */
  onPTTPress?: () => void;

  /** Called when PTT button touch begins */
  onPTTPressIn?: () => void;

  /** Called when PTT button touch ends */
  onPTTPressOut?: () => void;

  /** Style for the container */
  style?: StyleProp<ViewStyle>;
};

// Simplified props for the wrapper component
export type KeyboardComposerProps = {
  /** Placeholder text shown when empty */
  placeholder?: string;

  /** Controlled text value */
  text?: string;

  /** Minimum height of the composer */
  minHeight?: number;

  /** Maximum height before scrolling */
  maxHeight?: number;

  /** Whether the send button is enabled */
  sendButtonEnabled?: boolean;

  /** Whether the text input is editable */
  editable?: boolean;

  /** Whether to auto focus the input on mount */
  autoFocus?: boolean;

  /** Trigger to blur the input - change value to trigger blur */
  blurTrigger?: number;

  /** Whether the AI is currently streaming (shows stop button) */
  isStreaming?: boolean;

  /** Whether to show the PTT (Push-to-Talk) button */
  showPTTButton?: boolean;

  /** Whether the PTT button is enabled */
  pttEnabled?: boolean;

  /** PTT state controls appearance and behavior */
  pttState?: PTTState;

  /** Visual feedback when pressing the PTT button */
  pttPressedScale?: number;
  pttPressedOpacity?: number;

  /** Called when text changes */
  onChangeText?: (text: string) => void;

  /** Called when send button is pressed with the text */
  onSend?: (text: string) => void;

  /** Called when stop button is pressed */
  onStop?: () => void;

  /** Called when composer height changes */
  onHeightChange?: (height: number) => void;

  /** Called when keyboard height changes */
  onKeyboardHeightChange?: (height: number) => void;

  /** Called when text input gains focus */
  onComposerFocus?: () => void;

  /** Called when text input loses focus */
  onComposerBlur?: () => void;

  /** Called when PTT button is tapped */
  onPTTPress?: () => void;

  /** Called when PTT button touch begins */
  onPTTPressIn?: () => void;

  /** Called when PTT button touch ends */
  onPTTPressOut?: () => void;

  /** Style for the container */
  style?: StyleProp<ViewStyle>;
};

// Ref methods exposed by the composer
export type KeyboardComposerRef = {
  focus: () => void;
  blur: () => void;
  clear: () => void;
};

// Module constants
export type KeyboardComposerConstants = {
  defaultMinHeight: number;
  defaultMaxHeight: number;
  contentGap: number;
};
