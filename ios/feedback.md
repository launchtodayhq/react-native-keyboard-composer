Animation Issues

1. First message "reveal" animation feels wrong
   The current implementation in applyPinAfterSend applies an alpha fade (0.92) and translation (8pt down) to the entire scroll content container. For the first message, this creates an awkward flash/fade effect. ChatGPT doesn't do this - it simply positions the message at top with no fade.
2. Animation timing is too slow
   pinDuration is 0.38s which feels sluggish. ChatGPT's scroll-to-top animation is faster and more responsive (around 0.25s).
3. Cubic bezier curve may not match iOS system feel
   The custom timing curve (0.10, 0.90), (0.20, 1.00) is aggressive. ChatGPT likely uses simpler easeOut or spring animations.
   State Machine Complexity
4. Too many state flags for pin-to-top
   Six interdependent flags (isPinned, pendingPin, pendingPinReady, isPinAnimating, stickToPinned, userIsInteracting) make the logic hard to follow and prone to edge cases. This could be simplified into an enum-based state machine.
5. stickToPinned enforcement can fight user scroll
   The ensurePinnedOffset method snaps scroll position every frame during streaming, which can feel janky if there's any layout thrash.
   Code Quality
6. Debug logging is always on
   (Resolved) Remove logging in production builds (or gate behind #if DEBUG).
7. Hardcoded magic numbers throughout
   Values like 24, 16, 8, 10, 0.5, 1.5, 60, 100 are scattered without clear documentation of why those specific values.
8. DispatchQueue.main.asyncAfter usage
   Used in autoFocus with hardcoded 0.3s delay - this is fragile and could fail on slower devices.
   Missing Features vs ChatGPT
9. No streaming message animation
   ChatGPT animates individual tokens/words appearing. This library only handles scroll position, not the actual content reveal.
10. No smooth scroll velocity matching
    When keyboard opens, ChatGPT matches scroll velocity to keyboard animation. The current implementation just jumps to the target offset.
11. No gesture-based keyboard dismiss on scroll
    ChatGPT allows dismissing keyboard by scrolling down aggressively. This library only has explicit swipe gestures on the composer.
12. Missing "thinking" state
    ChatGPT shows a thinking indicator before streaming starts. The isStreaming prop only handles stop button visibility.
    Architecture
13. Tight coupling between wrapper and composer
    The wrapper has to "find" the composer view in the hierarchy which is fragile. A more explicit parent-child relationship would be cleaner.
14. Multiple keyboard observers
    Both KeyboardComposerView and KeyboardAwareWrapper have their own keyboard observers which could conflict.
    Which of these would you like me to address first? I'd suggest starting with the first message animation issue since that's what you specifically noticed.
