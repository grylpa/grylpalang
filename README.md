# Katalaveno

A Flutter vocabulary trainer that uses **spaced repetition via local notifications** and **AI-generated example sentences** (Google Gemini) to help you learn vocabulary in a target language. A separate **Sentence Bank** mode lets you study curated sentences with cached AI translations and TTS playback.

## Features

- Add words in either your **known** or **target** language; the app generates simple + conjugated example sentences via Gemini.
- Scheduled local notifications surface a few sentences at a time, progressively, over many days.
- **Prediction tab** — guess the target-language sentence from a prompt; AI scores your answer for meaning, not just exact match.
- **Sentence Bank** — load a YAML bank of sentences (bundled asset or remote URL), study with auto-advance, TTS, optional shuffle, and per-subject resume.
- Persistent on-disk MP3 cache for Google Translate TTS (used as a fallback for languages where the platform voice has weak prosody, e.g. Greek questions).
- All user data (settings, words, history, snapshots) is stored locally on device — no server backend.

## Quick start

```bash
flutter pub get
flutter run
```

You'll need a **Gemini API key** to use the AI features. Get one from [aistudio.google.com](https://aistudio.google.com/) and paste it into Settings → AI API Key.

## Commands

```bash
flutter analyze                          # lint
dart format --line-length 120 lib/       # format (120-char lines)
flutter build apk                        # Android release
flutter build linux                      # Linux desktop
```

Docs for the Sentence Bank YAML format live in [`docs/sentence_bank.md`](docs/sentence_bank.md).

## Architecture

- **State management**: single `AppState` (`ChangeNotifier` + `provider`). All business logic lives there; UI uses `Consumer` / `Selector` / `context.watch|read`.
- **Persistence**: `AppStorage` wraps `SharedPreferencesAsync`. All domain models implement `toJson` / `fromJson`.
- **Spaced repetition**: an integer "global step" derived from which notification snapshots have already fired; each word has a `startStep` anchor.
- **AI**: `AiService` calls `gemini-2.5-flash` (falls back to `gemini-2.5-flash-lite` on rate limit) for sentence generation and prediction scoring.
- **Notifications**: `flutter_local_notifications` (Android / iOS / Linux DBus). Reschedules a 10-step window on every state change.

## Platforms

- **Android** (primary target — runtime notification permission on 13+, foreground service for Sentence Bank auto mode)
- **Linux desktop** (DBus notifications)
- **Web** (notifications and file I/O are no-ops)
- **iOS / macOS / Windows** — Flutter targets generate, but not actively tested.

## License

MIT (or your preferred license — replace this line).
