import { NativeModule, requireNativeModule } from "expo";

import type { KeyboardComposerConstants } from "./KeyboardComposer.types";

declare class KeyboardComposerModuleType extends NativeModule<{}> {
  defaultMinHeight: number;
  defaultMaxHeight: number;
  contentGap: number;
}

// This call loads the native module object from the JSI.
const KeyboardComposerModule =
  requireNativeModule<KeyboardComposerModuleType>("KeyboardComposer");

// Export constants
export const constants: KeyboardComposerConstants = {
  defaultMinHeight: KeyboardComposerModule.defaultMinHeight,
  defaultMaxHeight: KeyboardComposerModule.defaultMaxHeight,
  contentGap: KeyboardComposerModule.contentGap,
};

export default KeyboardComposerModule;
