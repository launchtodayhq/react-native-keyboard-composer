# @launchhq/react-native-keyboard-composer

A native keyboard-aware composer component for React Native with smooth keyboard animations. Perfect for chat applications and any UI that requires pixel-perfect keyboard synchronization.

## Features

- 🎯 **Pixel-perfect keyboard animations** - Uses native APIs for smooth 60fps keyboard tracking
- 📱 **iOS & Android only** - Native implementations for mobile platforms (no web support)
- ⌨️ **Auto-growing text input** - Composer expands as you type
- 🔄 **Scroll-to-bottom button** - Automatically appears when content exceeds viewport
- 🌙 **Dark mode support** - Automatically adapts to system theme
- 🎨 **Customizable** - Placeholder, height constraints, streaming state, and more

## Installation

```bash
npm install @launchhq/react-native-keyboard-composer
# or
yarn add @launchhq/react-native-keyboard-composer
```

For Expo managed projects, run:

```bash
npx expo prebuild
```

## Usage

### Basic Example

```tsx
import {
  KeyboardComposer,
  KeyboardAwareWrapper,
} from "@launchhq/react-native-keyboard-composer";

function ChatScreen() {
  const [composerHeight, setComposerHeight] = useState(48);

  return (
    <KeyboardAwareWrapper style={{ flex: 1 }} extraBottomInset={composerHeight}>
      <ScrollView>{/* Your chat messages */}</ScrollView>

      <View style={styles.composerContainer}>
        <KeyboardComposer
          placeholder="Type a message..."
          onSend={(text) => handleSend(text)}
          onHeightChange={(height) => setComposerHeight(height)}
          onComposerFocus={() => console.log("Focused")}
          onComposerBlur={() => console.log("Blurred")}
        />
      </View>
    </KeyboardAwareWrapper>
  );
}
```

### With AI Streaming

```tsx
import { KeyboardComposer } from "@launchhq/react-native-keyboard-composer";

function AIChat() {
  const [isStreaming, setIsStreaming] = useState(false);

  const handleSend = async (text: string) => {
    setIsStreaming(true);
    await streamAIResponse(text);
    setIsStreaming(false);
  };

  return (
    <KeyboardComposer
      placeholder="Ask anything..."
      isStreaming={isStreaming}
      onSend={handleSend}
      onStop={() => cancelStream()}
    />
  );
}
```

### Dismissing Keyboard Programmatically

```tsx
const [blurTrigger, setBlurTrigger] = useState(0);

// Call this to dismiss keyboard
const dismissKeyboard = () => setBlurTrigger(Date.now());

<KeyboardComposer
  blurTrigger={blurTrigger}
  // ...other props
/>;
```

## API Reference

### `<KeyboardComposer />`

The main composer input component.

| Prop                     | Type                       | Default               | Description                         |
| ------------------------ | -------------------------- | --------------------- | ----------------------------------- |
| `placeholder`            | `string`                   | `"Type a message..."` | Placeholder text                    |
| `minHeight`              | `number`                   | `48`                  | Minimum height in dp/points         |
| `maxHeight`              | `number`                   | `120`                 | Maximum height before scrolling     |
| `sendButtonEnabled`      | `boolean`                  | `true`                | Whether send button is enabled      |
| `editable`               | `boolean`                  | `true`                | Whether input is editable           |
| `autoFocus`              | `boolean`                  | `false`               | Auto-focus on mount                 |
| `blurTrigger`            | `number`                   | -                     | Change value to trigger blur        |
| `isStreaming`            | `boolean`                  | `false`               | Shows stop button when true         |
| `onChangeText`           | `(text: string) => void`   | -                     | Called when text changes            |
| `onSend`                 | `(text: string) => void`   | -                     | Called when send is pressed         |
| `onStop`                 | `() => void`               | -                     | Called when stop is pressed         |
| `onHeightChange`         | `(height: number) => void` | -                     | Called when height changes          |
| `onKeyboardHeightChange` | `(height: number) => void` | -                     | Called when keyboard height changes |
| `onComposerFocus`        | `() => void`               | -                     | Called when input gains focus       |
| `onComposerBlur`         | `() => void`               | -                     | Called when input loses focus       |
| `style`                  | `StyleProp<ViewStyle>`     | -                     | Container style                     |

### `<KeyboardAwareWrapper />`

Wrapper component that handles keyboard-aware scrolling.

| Prop                 | Type                   | Default | Description                               |
| -------------------- | ---------------------- | ------- | ----------------------------------------- |
| `extraBottomInset`   | `number`               | `0`     | Bottom inset (typically composer height)  |
| `scrollToTopTrigger` | `number`               | `0`     | Change value to scroll new content to top |
| `style`              | `StyleProp<ViewStyle>` | -       | Container style                           |
| `children`           | `ReactNode`            | -       | Should contain a ScrollView               |

### `constants`

Module constants for default values:

```tsx
import { constants } from "@launchhq/react-native-keyboard-composer";

console.log(constants.defaultMinHeight); // 48
console.log(constants.defaultMaxHeight); // 120
console.log(constants.contentGap); // 32
```

## How It Works

### iOS

Uses `keyboardLayoutGuide` (iOS 15+) with `CADisplayLink` for 60fps keyboard position tracking. Falls back to `keyboardWillShow`/`keyboardWillHide` notifications for older iOS versions.

### Android

Uses `WindowInsetsAnimationCompat` for frame-by-frame keyboard position updates. This provides smooth, synchronized animations between the keyboard and content.

## Platform Support

| Platform | Support                  |
| -------- | ------------------------ |
| iOS      | ✅ Native implementation |
| Android  | ✅ Native implementation |
| Web      | ❌ Not supported         |

## Requirements

- React Native 0.71+
- Expo SDK 48+ (for Expo projects)
- iOS 15+
- Android API 21+

## Contributing

Contributions are welcome! Please read our contributing guidelines before submitting a PR.

## License

MIT © [LaunchHQ](https://launchtoday.dev)
