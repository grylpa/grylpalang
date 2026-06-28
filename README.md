# Katalaveno

A Flutter vocabulary trainer that uses **spaced repetition via local notifications** and **AI-generated example sentences** (Google Gemini) to help you learn vocabulary in a target language. A separate **Sentence Bank** mode lets you study curated sentences with cached AI translations and TTS playback, and a **Books** mode reads/plays public-domain books.

## Features

- Add words in either your **known** or **target** language; the app generates simple + conjugated example sentences via Gemini.
- Scheduled local notifications surface a few sentences at a time, progressively, over many days.
- **Prediction tab** — guess the target-language sentence from a prompt; AI scores your answer for meaning, not just exact match.
- **Sentence Bank** — study a curated YAML bank of sentences (bundled asset and/or remote URL, mergeable via `override_local`) with auto-advance, optional shuffle, per-subject resume, and a per-locale source-voice picker. An auto-generated **Active words** subject mirrors your tapped-notification history into the bank for study.
- **Books** — browse free public-domain books from Project Gutenberg, or import your own **EPUB / TXT** files, then read by chapter or listen with streaming sentence-by-sentence translation + TTS.
- **Background audio that survives a screen lock** — auto mode pre-builds the whole subject into one native playlist so playback keeps advancing with the screen off, with Bluetooth / lockscreen controls. The source line is rendered on-device in your chosen voice; the target line uses Google Translate's audio (better question intonation than the offline voice). All clips are cached on disk.
- All user data (settings, words, history, translations, snapshots) is stored locally on device — no server backend.

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
- **AI**: `AiService` calls `gemini-2.5-flash` (falls back to `gemini-2.5-flash-lite` on rate limit) for sentence generation, translation, and prediction scoring.
- **Notifications**: `flutter_local_notifications`. Reschedules a 10-step window on every state change.
- **Audio (Sentence Bank + Books)**: `AutoPlaylistController` builds one `just_audio` playlist — *source clip → pause → translation (×repeat) → pause* — played through a single shared player owned by `KatalavenoAudioHandler` (an `audio_service` handler) that hosts it in a media session keeping it advancing when the screen is locked and routing Bluetooth / lockscreen controls to app-level actions (the main isolate is suspended on lock, so a Dart-timer loop can't drive it). Source clips are synthesized on-device via `flutter_tts` (`synthesizeToFile`); target clips come from `GoogleTranslateTts`, a pure fetch/cache service for the Google audio endpoint. The playlist is rebuilt only when subject/voice/settings change, otherwise it resumes instantly. `MainActivity` extends `AudioServiceActivity`, and `main()` calls `AudioService.init(KatalavenoAudioHandler())`.
- **Translation cache**: serialized through a mutex with additive merges (no clobbering), tracks which Gemini model produced each entry, and a background pass upgrades weaker lite-model translations to the primary model.
- **Books**: `GutenbergService` (Gutendex catalog) + `BookLibraryService` (EPUB/TXT download & parse, position persistence) + `LocalBooksService` (device EPUB/TXT import). Local imports stay on device.

## Platforms

**Android** is the only platform target included in this repository (runtime notification permission on 13+; an `audio_service` media-session keeps Sentence Bank and Books auto mode playing when the screen is locked).

Other Flutter targets (iOS, web, desktop) are not included. To add one, run `flutter create --platforms=<platform> .` from the project root.

## Disclaimer

This project is a personal software experiment, is in its alpha stages and not ready for production.

It is not medical advice, cognitive training, therapy, diagnosis, or a proven method for preventing or treating any condition. Any references to memory, attention, learning, brain challenge, or similar ideas describe the design goals and personal motivation behind the project, not scientifically validated claims.

The software is provided as-is, with no warranty or guarantee of correctness, reliability, safety, availability, or fitness for any particular purpose. Use it at your own discretion.

Translations, generated sentences, explanations, and text-to-speech output may contain mistakes. They should be treated as learning aids, not authoritative language instruction.

## License

MIT. See [LICENSE](LICENSE).

## Privacy

See [PRIVACY.md](PRIVACY.md). The in-app copy lives at [`assets/legal/policies.md`](assets/legal/policies.md) (Settings → Policies).

## Attribution

Created by grylpa.

## Contact

info@grylpa.com
