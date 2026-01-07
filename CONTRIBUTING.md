# Contributing to @launchhq/react-native-keyboard-composer

Thank you for your interest in contributing! This guide will help you get started.

## Development Setup

### Prerequisites

- Node.js 18+
- pnpm 10+
- Xcode 15+ (for iOS development)
- Android Studio (for Android development)
- React Native development environment set up

### Getting Started

1. **Clone the repository**

   ```bash
   git clone https://github.com/launchtodayhq/react-native-keyboard-composer.git
   cd react-native-keyboard-composer
   ```

2. **Install dependencies**

   ```bash
   pnpm install
   ```

3. **Run the example app**

   ```bash
   cd example
   pnpm install
   pnpm prebuild
   pnpm ios    # or pnpm android
   ```

## Consumer vs Local Development (important)

This repo supports two distinct workflows:

### 1) Consumer workflow (what users do)

In a normal app, you install the package from npm and rebuild native code:

```bash
pnpm add @launchhq/react-native-keyboard-composer
npx expo prebuild --clean
npx expo run:ios
# or
npx expo run:android
```

### 2) Local development workflow (what contributors do)

When developing this library, there are **two different kinds of changes**:

- **JS/TS-only changes** (`src/`, `build/`):
  - You can often iterate with Metro (no native rebuild required).
- **Native changes** (`android/`, `ios/`):
  - You **must** ensure the example app is consuming the local package (not the published npm copy),
    and then you must rerun prebuild + rebuild the native app.

#### Example app: running against published vs local

From `example/`:

**Published (default / consumer-like):**

```bash
pnpm use:published
pnpm install
pnpm prebuild
pnpm android
# or pnpm ios
```

**Local (for native development):**

```bash
pnpm use:local
pnpm install
pnpm prebuild:local
pnpm android:local
# or pnpm ios:local
```

Notes:

- `pnpm use:local` switches `@launchhq/react-native-keyboard-composer` to `file:..` so Expo autolinking compiles your local `android/` + `ios/` code.
- `USE_LOCAL_KEYBOARD_COMPOSER=1` toggles the example's Metro + autolinking configuration for local development.

## Project Structure

```
react-native-keyboard-composer/
├── src/                    # TypeScript source files
│   ├── index.ts           # Main exports
│   ├── KeyboardComposerView.tsx
│   ├── KeyboardAwareWrapper.tsx
│   └── KeyboardComposer.types.ts
├── ios/                    # iOS native code (Swift)
│   ├── KeyboardComposerModule.swift
│   ├── KeyboardComposerView.swift
│   ├── KeyboardAwareWrapper.swift
│   └── KeyboardAwareScrollHandler.swift
├── android/                # Android native code (Kotlin)
│   └── src/main/java/expo/modules/.../
│       ├── KeyboardComposerModule.kt
│       ├── KeyboardComposerView.kt
│       └── KeyboardAwareWrapper.kt
├── example/                # Example app for testing
└── docs/                   # Additional documentation
```

## Development Workflow

### Making Changes

1. **Create a feature branch**

   ```bash
   git checkout -b feature/your-feature-name
   ```

2. **Make your changes**

   - TypeScript changes go in `src/`
   - iOS native changes go in `ios/`
   - Android native changes go in `android/`

3. **Test on both platforms**

   Always test changes on both iOS and Android before submitting a PR.

4. **Update documentation**

   If your change affects the public API, update the README.md.

### Native Code Guidelines

#### iOS (Swift)

- Follow Swift naming conventions
- Use `CGFloat` for dimensions
- Log with emoji prefixes for easy debugging: `print("🎯 [Component] message")`
- Keep keyboard tracking at 60fps using `CADisplayLink`

#### Android (Kotlin)

- Follow Kotlin naming conventions
- Use `dp` for dimensions (convert with `dpToPx()`)
- Log with tags: `Log.d(TAG, "📐 message")`
- Use `WindowInsetsAnimationCompat` for keyboard tracking

### Constants

When adding spacing/dimension constants, ensure parity across platforms:

| Constant                | iOS (points) | Android (dp) |
| ----------------------- | ------------ | ------------ |
| `CONTENT_GAP`           | 24           | 24           |
| `COMPOSER_KEYBOARD_GAP` | 8            | 8            |

## Pull Request Guidelines

### Before Submitting

- [ ] Test on iOS simulator/device
- [ ] Test on Android emulator/device
- [ ] Update README if API changed
- [ ] Add screenshots/videos showing the change
- [ ] Ensure no linting errors

### PR Title Format

Use conventional commit format:

- `feat: add new feature`
- `fix: resolve bug with keyboard`
- `docs: update README`
- `refactor: improve code structure`
- `chore: update dependencies`

### Screenshots/Videos Required

All PRs that affect UI or behavior must include:

1. **Before** - Screenshot/video of current behavior
2. **After** - Screenshot/video of new behavior
3. **Both platforms** - Show iOS and Android if applicable

## Testing

### Manual Testing Checklist

- [ ] Keyboard opens/closes smoothly
- [ ] Composer animates with keyboard
- [ ] Auto-grow works correctly
- [ ] Send button works
- [ ] Stop button works (streaming mode)
- [ ] Scroll behavior is correct (at bottom vs scrolled up)
- [ ] Dark mode works
- [ ] Works on different screen sizes

### Testing the Example App

The example app in `example/` is the primary way to test changes:

```bash
cd example
pnpm ios    # Test on iOS
pnpm android # Test on Android
```

## Reporting Issues

When reporting bugs, please include:

1. **Platform** - iOS/Android and version
2. **Device** - Simulator/emulator or physical device
3. **Steps to reproduce**
4. **Expected behavior**
5. **Actual behavior**
6. **Screenshots/videos** if applicable

## Code of Conduct

Be respectful and constructive in all interactions. We're all here to build something great together.

## Questions?

Open an issue or reach out to the maintainers. We're happy to help!
