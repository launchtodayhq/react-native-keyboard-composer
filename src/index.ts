// Main component export
export { default as KeyboardComposer } from "./KeyboardComposerView";

// Native keyboard-aware wrapper for scroll views
export {
  KeyboardAwareWrapper,
  type KeyboardAwareWrapperProps,
} from "./KeyboardAwareWrapper";

// Module with constants
export {
  default as KeyboardComposerModule,
  constants,
} from "./KeyboardComposerModule";

// Types
export type {
  KeyboardComposerProps,
  KeyboardComposerRef,
  KeyboardComposerViewProps,
  KeyboardComposerConstants,
  TextEventPayload,
  HeightEventPayload,
} from "./KeyboardComposer.types";
