# iOS keyboard “push-up” fix (pin-to-top enabled) — task list

Context: In the example app (and your customer flow), `pinToTopEnabled` is `true`. The bug shows up when:

- a streamed assistant message becomes **very tall** (fills most of the screen),
- but the scroll view is still **not actually scrollable** (no scroll range yet),
- then the keyboard opens and **overlays** the bottom content instead of pushing the content up.

This is a classic iOS timing/clamping issue: during the keyboard animation, `contentInset.bottom` changes and iOS can temporarily clamp `contentOffset` writes (especially when the scroll range transitions from 0 → >0). If pin-to-top is also active, the handler may additionally block keyboard-driven adjustments.

This doc lists the tasks to get the desired behavior **without** reintroducing regressions like “content pulls down before going up” on send.

---

## Goal / acceptance criteria

### Required behavior

1. **Short-but-tall content case**
   - If the content did not scroll before keyboard open, but would be covered by the keyboard once it opens, the system must **push content up** (by adjusting scroll offset) so the last message/composer gap remains visible.
   - When the keyboard closes, the content must return to its pre-keyboard position **without a second-phase snap**.

2. **Pin-to-top enabled**
   - During pin-to-top/runway streaming, opening the keyboard must not cause the pinned content to “fall back” into bottom mode, and must not cause a down-then-up jitter.

3. **No regressions**
   - No “pull down then up” when sending a message.
   - No scroll-to-bottom button flicker during transitions.

### How to validate quickly

Use the existing example screen in [example/App.tsx](example/App.tsx) with `pinToTopEnabled={true}`:

- Send a message to start streaming.
- Wait until the assistant text nearly fills the screen but does not scroll.
- Focus the composer to open the keyboard.
- Expected: content moves up smoothly; keyboard does not cover the last visible content.

---

## Anti-behaviors / guardrails (avoid these regressions)

These are failure modes we explicitly do **not** want to introduce while fixing the keyboard overlay case.

### Keyboard open/close

- Keyboard opens and bottom content is still covered even though a minimal offset adjustment would keep it visible.
- Two-phase motion on open (moves, then snaps again at completion) — often from inset/offset clamping.
- Two-phase motion on close (drops, then snaps) — often from competing “preserve position” + “scroll to bottom” actions.
- Keyboard open forces scroll-to-bottom when the user is clearly reading older content (scrolled up).
- Visible clamp/bounce where `contentOffset` briefly hits `0` and then corrects.

### Send / append sequencing

- “Pull down then up” on send (any intermediate re-bottom before pin/runway engages).
- Send triggers two competing offset changes (e.g. scroll-to-bottom and pin animation both run).
- Pin applies twice (contentSize observer + keyboard hide completion both execute).
- Pin anchors to the wrong start point because `messageStartY` is captured before layout/insets have settled.

### Pin-to-top / runway

- Pin state gets cleared just because `runwayInset` computes to `0` during keyboard inset changes (keyboard ≠ runway consumption).
- While pinned/enforced, keyboard open causes oscillation/jitter (pin correction fighting keyboard/inset animation).
- User drag while pinned feels sticky (enforcement keeps pulling them back); user interaction must disable enforcement cleanly.
- Runway becomes scrollable empty space (user can scroll into it).
- Pin reactivates unexpectedly after user intentionally scrolls away (should require explicit re-arm).

### Composer growth

- Composer height change causes a jump while user is at/near bottom (gap should remain stable).
- Composer height change adjusts scroll while user is not near bottom (should preserve reading position).

### Scroll-to-bottom button

- Button flickers on keyboard open/close (rapid show/hide due to transient near-bottom computations).
- Button position lags keyboard animation (moves after the keyboard rather than with it).

---

## Phase 0 — Repro harness + observability

1. Add a dedicated repro toggle in the example
   - Add a button (debug only) that:
     - inserts an assistant message sized to “just under scrollable”
     - then focuses the composer
   - Goal: make the bug reproducible in 5 seconds.

2. Add `#if DEBUG` logging in the scroll handler
   - In [ios/KeyboardAwareScrollHandler.swift](ios/KeyboardAwareScrollHandler.swift), add a compact logging helper that prints:
     - `contentSize.height`, `bounds.height`
     - `contentInset.bottom`, `adjustedContentInset.top`
     - `contentOffset.y`
     - computed `maxOffset` (current + projected)
     - pin state, `pinnedOffset`, `runwayInset`
   - Keep logs behind `#if DEBUG` and make them easy to grep.

Deliverable: you can confirm whether `contentOffset` is being clamped (common) and whether pin logic is blocking adjustment.

---

## Phase 1 — Fix keyboard-open for “short content becomes scrollable” (minimal risk)

This phase should not change the pin/runway model yet; it’s about iOS clamping.

1. Compute “should adjust” based on **projected post-keyboard** scroll range
   - Update `shouldAdjustScrollForKeyboard(...)` so it doesn’t only check current `isNearBottom`.
   - Instead compute:
     - `projectedBottomInset = baseBottomInset + keyboardHeight + composerKeyboardGap`
     - `projectedRawMaxOffset = contentSize.height - bounds.height + projectedBottomInset`
     - `projectedMaxOffset = max(0, projectedRawMaxOffset)`
   - If content currently doesn’t exceed viewport, return `projectedMaxOffset > 0` (i.e., keyboard would create a scroll range).

2. Re-apply scroll-to-bottom at keyboard animation completion
   - In `keyboardWillShow` and `keyboardWillChangeFrame`, if `shouldAdjust == true`, do:
     - set inset + attempt scroll in animation block (keep)
     - **also** call `scrollToBottom(animated: false)` in completion
   - Rationale: the completion runs after insets are “real”, so the offset won’t get clamped to 0.

Deliverable: in non-pinned scenarios and “not scrollable → becomes scrollable” scenarios, keyboard no longer overlays content.

---

## Phase 2 — Define pin-to-top ↔ keyboard-open policy (pick one)

Because your customers need “push up” even while pinned, you likely want **Policy B**.

- **Policy A (strict pin):** while pinned/enforced, keyboard-open never re-bottoms content; it preserves pinned offset even if overlay occurs.
- **Policy B (push-up always):** even while pinned/enforced, keyboard-open pushes content up to avoid overlay, and pin is restored cleanly on close.

Task: explicitly codify Policy B in the handler so state transitions are deterministic (avoid “fix one case, break send”).

---

## Phase 3 — Refactor pin/runway so keyboard inset changes don’t “turn off” pin

Current risk point in [ios/KeyboardAwareScrollHandler.swift](ios/KeyboardAwareScrollHandler.swift): `recomputeRunwayInset(baseInset:)` clears pin state when `runwayInset == 0`. That can happen because **keyboard increases baseInset**, not because runway was truly consumed by content growth.

Tasks:

1. Split “pin is active” from “runway is present”
   - Keep pin state (`pinnedOffset`) independent from whether runway currently computes to 0.
   - Only clear pin state when:
     - pin is explicitly disabled (`clearPinState`), or
     - user action indicates leaving pinned mode, or
     - runway has been consumed due to content growth *and* you decide pinned mode is no longer needed.

2. Change runway recomputation to never auto-clear pin during keyboard transitions
   - Keyboard open/close should only affect:
     - base inset
     - runway amount
   - It should not flip pin state to idle just because runway becomes 0.

Deliverable: opening the keyboard can’t accidentally reset you into bottom-aligned behavior.

---

## Phase 4 — Implement Policy B: “allow keyboard adjustment while pinned” safely

Your experimental `updates.swift` introduced the right idea (temporary allowance), but it caused new bugs because it wasn’t integrated cleanly with send/pin sequencing.

Tasks:

1. Add an explicit transient flag or state
   - Example: `allowKeyboardAdjustWhilePinned` or a dedicated pin substate.
   - Only enable it during keyboard opening when keyboard would cover content.

2. When enabled:
   - In `updateContentInset(preserveScrollPosition: true)`, do **not** snap back to `pinnedOffset` during the keyboard opening window.
   - In `scrollToBottom(...)`, when this flag is enabled and keyboard is open, define “bottom” as actual `maxOffset` (content above keyboard), not `pinnedOffset`.

3. Restoration on keyboard close
   - On `keyboardWillHide` completion, restore to the pinned target offset in **one phase**:
     - preserve scroll position during inset change
     - then set contentOffset to pinned target (no intermediate bottom scroll)
   - Make sure you don’t run both:
     - “scrollToBottom” and “restore pin”
     in the same close sequence.

Deliverable: keyboard open avoids overlay while pinned; keyboard close returns to pinned layout without a two-step down/up.

---

## Phase 5 — Fix the “send pulls down then up” class of regressions

This usually comes from mixing:

- keyboard hide inset animation,
- scroll-to-bottom,
- pin application animation,
- and offset preservation

Tasks:

1. Make send→pin sequencing single-source-of-truth
   - Currently, send triggers `requestPinForNextContentAppend()` and then contentSize KVO triggers pin.
   - Ensure that when keyboard is dismissing you either:
     - (A) defer pin until hide completes while preserving visual offset, or
     - (B) pin during hide but never allow an intermediate “bottom scroll”

2. Tighten the `.deferred(...)` logic
   - If keyboard is visible/hiding when content grows, set `.deferred(...)` and keep content stable.
   - Only run `applyPinAfterSend` once, and only in one place:
     - either contentSize observer (keyboard not visible), or
     - keyboard hide completion (deferred)

3. Add a guardrail: never run a pin animation if a keyboard open/close completion is also going to change contentOffset
   - If necessary, queue one action and cancel the other.

Deliverable: send feels like one continuous motion, not down-then-up.

---

## Phase 6 — Regression matrix (must-run before shipping)

Run these on a physical device:

1. Short content → open keyboard → close keyboard (no streaming)
2. Short-but-tall content (your bug) → open/close keyboard
3. Scrollable content at bottom → open/close keyboard
4. Scrollable content scrolled up → open/close keyboard (should not auto-scroll)
5. Pin enabled: send → keyboard hides → pin engages → stream grows
6. While pinned+streaming: open keyboard mid-stream → close keyboard
7. Composer auto-grows while keyboard open (type multi-line)
8. Rotate device while pinned and while keyboard is open

### Guardrails checklist (must also pass)

Confirm none of these regressions are present while running the matrix above:

- No keyboard overlay when content would be covered (push-up works).
- No two-phase snaps on keyboard open or close.
- No “pull down then up” on send.
- No pin state reset caused only by keyboard inset changes.
- No sticky pin enforcement during user drag.
- No scroll-to-bottom button flicker/lag during transitions.

---

## Recommended implementation order (to avoid thrash)

1. Phase 1 (projected shouldAdjust + completion re-apply) — minimal change, likely fixes your overlay case immediately.
2. Phase 3 (stop clearing pin due to runway=0 during keyboard changes) — stabilizes pin state.
3. Phase 4 (Policy B: temporary allowance) — solves pinned+keyboard overlay without fighting the pin model.
4. Phase 5 (send sequencing hardening) — prevents the down-then-up regression.

If you want, I can implement Phase 1 as a small patch in [ios/KeyboardAwareScrollHandler.swift](ios/KeyboardAwareScrollHandler.swift) first (very low risk), then we iterate with logs on the pinned behavior.
