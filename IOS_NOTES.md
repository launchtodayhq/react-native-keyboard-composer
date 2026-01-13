# iOS implementation notes — `@launchhq/react-native-keyboard-composer`

These are my “read-the-source” notes after carefully walking through every file in `ios/`.

## 1) Big picture

This library ships two native views via Expo Modules:

- **`KeyboardComposerView`**: the actual composer input (multiline, auto-growing) with a send/stop button and keyboard focus/blur events.
- **`KeyboardAwareWrapper`**: a host wrapper that finds your `UIScrollView` child, installs a **native scroll/keyboard handler**, and also animates the **composer container** (the React Native wrapper view that contains `KeyboardComposerView`) so it tracks the keyboard.

A key design choice: **iOS drives scroll insets natively** (via `UIScrollView.contentInset` + keyboard notifications) rather than relying on JS layout/padding. That’s what enables “system app” smoothness.

## 2) JS ↔ native boundary (what JS controls vs what native controls)

From JS you generally provide:

- The scroll view content (in your app)
- The composer UI host layout (in your app)
- `extraBottomInset`: *intended to be the composer height* (JS updates this from `onHeightChange`)
- `pinToTopEnabled` and `scrollToTopTrigger` to enable and arm “pin-to-top” behavior

Native iOS owns:

- Keyboard animation timing/curve
- Scroll view bottom inset calculations and scroll indicator inset
- “Scroll-to-bottom” floating button visibility + positioning (native)
- Pin-to-top + runway math + enforcement

## 3) File-by-file notes

### `ios/KeyboardComposerModule.swift`

- Declares Expo module name: **`KeyboardComposer`**.
- Exports constants:
  - `defaultMinHeight = 48`
  - `defaultMaxHeight = 120`
  - `contentGap = 0.0` (note: README talks about a gap; iOS constant currently exports 0)
- Exposes **two views**:
  - `KeyboardComposerView` (named as `KeyboardComposer` on the JS side via `requireNativeView("KeyboardComposer")`)
  - `KeyboardAwareWrapper` (auto-exported as `KeyboardComposer_KeyboardAwareWrapper`, and JS uses `requireNativeViewManager("KeyboardComposer", "KeyboardAwareWrapper")`)

### `ios/KeyboardComposerView.swift`

Responsibilities:

- Renders the composer UI with:
  - `UITextView` (multiline, auto-grow)
  - Placeholder label overlay
  - Send/Stop button (SF Symbols)
- Emits events:
  - `onChangeText`, `onSend`, `onStop`
  - `onHeightChange` (auto-growing height)
  - `onKeyboardHeightChange` (fed by the wrapper when keyboard metrics change)
  - `onComposerFocus`, `onComposerBlur`

Notable details:

- **Auto-grow**: uses `textView.sizeThatFits` with the current width; clamps to `[minHeight, maxHeight]`.
- **Scrolling inside the input** toggles on only if content exceeds `maxHeight`.
- **Send**:
  - Emits `onSend({ text })`
  - Posts `Notification.Name.keyboardComposerDidSend` so the wrapper can arm pin-to-top
  - Clears the text, resigns first responder, recomputes height
- **Gestures**: swipe down to dismiss keyboard; swipe up to focus.
- **Wrapper discovery**: in `didMoveToSuperview`, it walks up ancestors; if it finds a `KeyboardAwareWrapper`, it calls `wrapper.registerComposerView(self)`.
- **Keyboard height dispatch** is passive: wrapper calls `composerView.notifyKeyboardHeight(height)` and the composer emits `onKeyboardHeightChange`.

### `ios/KeyboardAwareWrapper.swift`

Responsibilities:

- Finds and attaches to a `UIScrollView` under its React subviews.
- Coordinates:
  - a `KeyboardAwareScrollHandler` (for scroll insets + pin-to-top)
  - a `ScrollToBottomButtonController`
  - translation/transform of the **composer container** (so the composer “rides” the keyboard)
- Exposes props as `@objc dynamic` so KVO works with React/Expo prop setting:
  - `pinToTopEnabled`
  - `extraBottomInset`
  - `scrollToTopTrigger`

How attachment works:

- Wrapper continuously tries to resolve:
  - **the scroll view** (first `UIScrollView` in subtree)
  - **the composer view** (`KeyboardComposerView`) and its **direct-child container** (the view directly under the wrapper that contains the composer)
- Once it has a scroll view, it sets the scroll handler base inset to the composer height and `attach(to:)`.

Keyboard integration:

- Wrapper sets `keyboardHandler.onKeyboardMetricsChanged = { height, duration, curve in ... }`.
- On each keyboard metrics update, wrapper:
  - stores `currentKeyboardHeight`
  - runs `animateComposerAndButton(duration:curve:)`
  - calls `composerView?.notifyKeyboardHeight(height)`

Composer translation strategy:

- Wrapper does **not** rely on JS bottom padding.
- It translates the composer container by:
  - Keyboard open: `-(keyboardHeight + COMPOSER_KEYBOARD_GAP)`
  - Keyboard closed: `-max(safeAreaBottom, MIN_BOTTOM_PADDING)`

Scroll-to-bottom button strategy:

- Button is installed once, constrained relative to wrapper’s bottom.
- Button has:
  - a **base offset** (composer height + safe-area/min padding + a small gap)
  - a **keyboard transform** applied during keyboard animations

Handling composer height changes:

- Fabric/Expo prop updates can bypass Swift `didSet`, so the wrapper uses **KVO** for `extraBottomInset` and also measures the actual composer height in `layoutSubviews`.
- `ComposerHeightCoordinator.updateIfNeeded(...)` computes delta and updates the scroll handler base inset.

Touch routing / runway:

- `hitTest(_:with:)` is overridden so:
  - the wrapper doesn’t steal taps meant for the composer or the scroll-to-bottom button
  - taps in the “empty runway area” below the bottom content are routed to the scroll view (so the user can scroll / interact naturally)

### `ios/KeyboardAwareScrollHandler.swift`

This is the **core iOS brain**.

Responsibilities:

- Owns a single scroll view and drives:
  - `contentInset.bottom`
  - `verticalScrollIndicatorInsets.bottom`
  - scroll-to-bottom behavior when the keyboard opens/closes
  - interactive keyboard dismissal behavior
  - pin-to-top + runway logic

Keyboard tracking:

- Listens to:
  - `keyboardWillShow`
  - `keyboardWillHide`
  - `keyboardWillChangeFrame`
- Emits the “single source of truth” keyboard metrics via `onKeyboardMetricsChanged(height, duration, curve)`.
- Uses the keyboard’s exact curve (`curve << 16`) to match system animation.

Inset math (high level):

- `baseBottomInset` is treated as **composer height only** (no safe area).
- When keyboard is open:
  - `contentInset.bottom = baseBottomInset + keyboardHeight + composerKeyboardGap + runwayInset`
  - indicator inset stops just above the composer, not above runway
- When keyboard is closed:
  - `contentInset.bottom = baseBottomInset + max(safeAreaBottom, minBottomPadding) + runwayInset`

Scroll-to-bottom behavior:

- On initial keyboard show, it decides whether to auto-scroll based on `shouldAdjustScrollForKeyboard`:
  - If user is “near bottom” (dynamic threshold depends on keyboard height), then open keyboard keeps last message visible.
  - If user is not near bottom, keyboard opens over content (no forced scroll).

Interactive dismissal:

- Sets `scrollView.keyboardDismissMode = .interactive`.
- Also implements a velocity-based “pull down to dismiss” in `scrollViewWillEndDragging`.

Pin-to-top + runway (key idea):

- The goal is: when a user sends a message, the next append is **pinned near the top**, and a **non-scrollable runway** is created below so streaming content can grow without moving the pinned anchor.

State machine:

- `PinState`:
  - `idle`
  - `armed(messageStartY)`
  - `deferred(messageStartY, contentHeightAfter)` (used when keyboard is hiding)
  - `animating(targetOffset)`
  - `pinned(targetOffset, enforce)` (enforce toggles off during user interaction)

How a pin is armed:

- `requestPinForNextContentAppend()` stores `messageStartY = scrollView.contentSize.height` and sets state to `.armed`.
- The actual pin executes on the next **contentSize growth** observation.

How the runway is computed:

- Compute the desired pinned scroll offset:
  - `desiredPinnedOffset = messageStartY - topPadding - adjustedContentInset.top`
- Compute the “raw” max offset with only base insets (unclamped):
  - `rawMaxOffset = contentHeightAfter - viewportH + baseInset`
- Choose runway so the max offset equals the pinned offset:
  - `runwayInset = max(0, desiredPinnedOffset - rawMaxOffset)`

Why this works:

- With runway, the scroll view’s **effective bottom** lands at the pinned offset, making the runway non-scrollable empty space.
- As streaming grows content, the runway shrinks (“consumed runway”). When runway reaches 0, pin state clears back to idle.

Pin enforcement & user interaction:

- While pinned with `enforce=true`, the handler gently corrects drift beyond a threshold (to avoid jitter).
- On user drag, enforce is turned off so the user can scroll away without fighting the handler.

Reveal animation:

- The pin scroll itself is animated with a `UIViewPropertyAnimator`.
- Optionally applies a subtle alpha/translation “reveal” to the content container, but avoids doing that for the very first message (to prevent a flash).

### `ios/ComposerHeightCoordinator.swift`

- Observes **actual** composer height (from `composerView.bounds.height`) and compares to `lastComposerHeight`.
- If height increased and user is near bottom, it calls `keyboardHandler.adjustScrollForComposerGrowth(delta:)`.
- Always updates the scroll handler base inset via `keyboardHandler.setBaseInset(newHeight, preserveScrollPosition: !isNearBottom)`.

### `ios/ScrollToBottomButtonController.swift`

- Lightweight controller for a floating circular button.
- Knows how to:
  - create/install the button
  - attach constraints
  - update base bottom offset
  - show/hide with a small translation + alpha animation
- Wrapper passes in the current “keyboard transform” so the button animates in sync.

### `ios/WrapperPropertyObservers.swift`

- Provides KVO observers for:
  - `extraBottomInset`
  - `scrollToTopTrigger`
  - `pinToTopEnabled`
- This exists because Expo/React sets props via Obj-C KVC and **Swift `didSet` won’t reliably fire**.

### `ios/ViewHierarchyFinder.swift`

- Generic recursive finders:
  - first `UIScrollView`
  - first `KeyboardComposerView`
  - and a helper to find the direct-child container under a host.

### `ios/WrapperAttachmentCoordinator.swift`

- A helper to attach scroll handler + composer container using `ViewHierarchyFinder`.
- Currently appears **unused** by `KeyboardAwareWrapper` (wrapper re-implements similar logic inline).

### `ios/KeyboardComposer.podspec`

- iOS/tvOS min version: 15.1
- Swift 5.9
- Depends on `ExpoModulesCore`
- `static_framework = true`

## 4) End-to-end flows (mental models)

### A) Keyboard opens

1. `KeyboardAwareScrollHandler` gets `keyboardWillShow` and emits metrics.
2. Wrapper receives metrics via `onKeyboardMetricsChanged` and animates:
   - composer container translation (above keyboard)
   - scroll-to-bottom button transform
3. Scroll handler updates `contentInset.bottom` and may auto-scroll to bottom if “near bottom”.

### B) User types and composer grows

1. Composer measures itself and fires `onHeightChange(height)`.
2. JS typically stores this height and passes it back to wrapper as `extraBottomInset`.
3. On iOS, wrapper also measures actual composer height in `layoutSubviews` and uses `ComposerHeightCoordinator` to:
   - update scroll handler base inset
   - adjust scroll when near bottom so the last message stays visible

### C) Send message with pin-to-top enabled

1. Composer emits `onSend` and posts `.keyboardComposerDidSend`.
2. Wrapper receives notification and calls `keyboardHandler.requestPinForNextContentAppend()`.
3. When the next message is appended (contentSize grows), the scroll handler computes:
   - `desiredPinnedOffset`
   - `runwayInset`
4. Scroll handler animates contentOffset to the pinned position and begins enforcing drift.

### D) Streaming grows content

1. contentSize grows repeatedly.
2. If pinned and runway > 0, the handler recomputes runway and schedules gentle pinned-offset corrections.
3. When runway reaches 0, handler clears pin state back to idle.

## 5) Notable gotchas / things to be aware of

- `contentGap` constant exported by iOS module is `0.0`, but iOS handler uses other “gaps” internally (min padding, composerKeyboardGap, etc.). If JS expects `constants.contentGap` to reflect actual spacing, it currently won’t.
- The wrapper and scroll handler both have “gap” constants; iOS uses `COMPOSER_KEYBOARD_GAP = 10` while Android is `8`.
- `WrapperAttachmentCoordinator.swift` and `ViewHierarchyFinder.swift` look like refactor leftovers (present but not used by the wrapper).

---

If you want, I can also:

- reconcile `constants.contentGap` with iOS/Android behavior (and update README / native constants to match), or
- refactor the wrapper to use `WrapperAttachmentCoordinator`/`ViewHierarchyFinder` (or delete the unused files), or
- write a short “how to debug pin/runway” section with log points and reproduction steps.
