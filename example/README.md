# Keyboard Composer Example

A chat app example demonstrating the `@launchhq/react-native-keyboard-composer` library with smooth, native keyboard animations.

## Features

- 💬 Mock chat conversation with message bubbles
- ⌨️ Smooth keyboard animations (like iMessage)
- 📜 Smart scroll behavior with `KeyboardAwareWrapper`
- 📝 Auto-growing composer input
- 🌙 Dark mode support

## Running the Example

```bash
# Install dependencies
pnpm install

# Generate native projects
pnpm prebuild

# Run on iOS
pnpm ios

# Run on Android
pnpm android
```

## Local development (using the package source)

If you're developing the library and want the example to use the local source instead of the published npm package:

```bash
pnpm use:local
pnpm install
pnpm prebuild:local
pnpm android:local
# or pnpm ios:local
```

Notes:

- If you want editor/TypeScript path mapping to point at `../src`, you can temporarily copy `tsconfig.local.json` over `tsconfig.json`.
- After changing native Android/iOS code in the package, re-run `pnpm prebuild:local` and then `pnpm android:local` / `pnpm ios:local`.

## What This Demonstrates

1. **KeyboardComposer** - Native text input with smooth keyboard tracking
2. **KeyboardAwareWrapper** - Wraps your scroll view for intelligent keyboard behavior:
   - At bottom + keyboard opens → stays at bottom
   - Scrolled up + keyboard opens → keyboard opens over content (no forced scroll)
3. **LegendList** - High-performance list for chat messages
