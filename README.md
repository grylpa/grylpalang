# Katalaveno

A Flutter vocabulary trainer that uses **spaced repetition via local notifications** and **AI-generated example sentences** (Google Gemini) to help you learn vocabulary in a target language. A separate **Sentence Bank** mode lets you study curated sentences with cached AI translations and TTS playback.

## Features

- Add words in either your **known** or **target** language; the app generates simple + conjugated example sentences via Gemini.
- Scheduled local notifications surface a few sentences at a time, progressively, over many days.
- **Prediction tab** — guess the target-language sentence from a prompt; AI scores your answer for meaning, not just exact match.
- **Sentence Bank** — load a YAML bank of sentences (bundled asset or remote URL), study with auto-advance, TTS, optional shuffle, and per-subject resume.
- Persistent on-disk MP3 cache for Google Translate TTS (used as a fallback for languages where the platform voice has weak prosody, e.g. Greek questions).
- All user data (settings, words, history, snapshots) is stored locally on device — no server backend.

## Gemini API key

You'll need a **Gemini API key** to use the AI features. There's no build-time configuration — the whole flow happens inside the app under **Settings → AI**:

- Tap **Get a free Gemini API key** to open Google AI Studio (a free personal key needs no credit card).
- Paste the key into the **Gemini API key** field, then tap **Test** to confirm it works.

## Sentence Bank format

The bundled [`assets/sentence_bank.yaml`](assets/sentence_bank.yaml) documents its own format in the header comments (subjects, meta-subjects, and the auto-mode timing/TTS options) — edit that file or point the app at your own YAML URL in Settings.

## Architecture

- **State management**: single `AppState` (`ChangeNotifier` + `provider`). All business logic lives there; UI uses `Consumer` / `Selector` / `context.watch|read`.
- **Persistence**: `AppStorage` wraps `SharedPreferencesAsync`. All domain models implement `toJson` / `fromJson`.
- **Spaced repetition**: an integer "global step" derived from which notification snapshots have already fired; each word has a `startStep` anchor.
- **AI**: `AiService` calls `gemini-2.5-flash` (falls back to `gemini-2.5-flash-lite` on rate limit) for sentence generation and prediction scoring.
- **Notifications**: `flutter_local_notifications`. Reschedules a 10-step window on every state change.

## Platforms

**Android** is the only platform target included in this repository (runtime notification permission on 13+, foreground service for Sentence Bank auto mode).

Other Flutter targets (iOS, web, desktop) are not included. To add one, run `flutter create --platforms=<platform> .` from the project root.

## License

TBD
