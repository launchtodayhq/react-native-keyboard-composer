# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Released

## [1.0.1] - 2026-03-08

### Added

- Composer: add `showSendButton` prop on iOS and Android to hide the built-in send/stop control while keeping core keyboard/composer behavior.
- Example: add a header toggle in `example/App.tsx` to demonstrate showing/hiding the built-in send button.

### Changed

- Package metadata: remove `expo-modules-core` from `peerDependencies` (keep as dev dependency) to avoid Expo Doctor peer-dependency warnings in consuming Expo apps.
- Docs: update `KeyboardComposer` API reference and add usage guidance for hiding the built-in send button.

### Fixed

- Expo 55 alignment: update project and example dependencies/configuration and remove script conflict flagged by Expo Doctor.

## [0.1.3] - 2026-02-04

### Changed

- Docs: note Android WIP/ScrollView-only support and document `text` prop in README.
- Android: adjust IME animation handling and padding/runway cleanup; add `text` prop; update stop button colors.
- iOS: add `text` prop; style stop button (white on black) and keep enabled state.
