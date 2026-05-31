import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_chapter.dart';
import '../models/book_entry.dart';
import '../services/auto_playlist_controller.dart';
import '../services/book_library_service.dart';
import '../services/sentence_bank_service.dart';
import '../state/app_state.dart';

/// Friendly language name → BCP-47 locale, for the target voice. Mirrors the
/// map in sentence_bank_tab so the same languages "just work" here.
String? _localeForLanguage(String name) {
  const map = <String, String>{
    'English': 'en-US',
    'Greek': 'el-GR',
    'Hebrew': 'he-IL',
    'German': 'de-DE',
    'French': 'fr-FR',
    'Spanish': 'es-ES',
    'Italian': 'it-IT',
    'Portuguese': 'pt-PT',
    'Russian': 'ru-RU',
    'Turkish': 'tr-TR',
    'Arabic': 'ar-SA',
    'Chinese': 'zh-CN',
    'Japanese': 'ja-JP',
    'Korean': 'ko-KR',
  };
  return map[name];
}

/// Best-effort mapping from a book's `language` field (often a 2-letter ISO
/// code from the EPUB OPF, e.g. "en" / "el") to a BCP-47 locale flutter_tts
/// can speak.
String _bookLocale(String raw) {
  final lower = raw.trim().toLowerCase();
  if (lower.isEmpty) return 'en-US';
  if (lower.contains('-') || lower.contains('_')) return raw.replaceAll('_', '-');
  const map = {
    'en': 'en-US', 'el': 'el-GR', 'he': 'he-IL', 'de': 'de-DE', 'fr': 'fr-FR',
    'es': 'es-ES', 'it': 'it-IT', 'pt': 'pt-PT', 'ru': 'ru-RU', 'tr': 'tr-TR',
    'ar': 'ar-SA', 'zh': 'zh-CN', 'ja': 'ja-JP', 'ko': 'ko-KR',
  };
  return map[lower] ?? lower;
}

/// Phase 2: a minimal reader. Downloads (or finds the local copy of) the EPUB,
/// parses chapters, shows them one at a time, and persists the chapter index
/// per book. Audio mode comes in Phase 3.
class BookReader extends StatefulWidget {
  final BookEntry book;
  /// If set, opens at this chapter rather than the saved chapter index — used
  /// by the Books tab's per-book Resume action so it lands in the chapter the
  /// audio was paused in even if the user has since navigated elsewhere.
  final int? initialChapterIndex;
  /// If true, starts the audio session automatically after the book loads,
  /// jumping to the saved resume ordinal if there is one.
  final bool autoStartAudio;
  const BookReader({
    super.key,
    required this.book,
    this.initialChapterIndex,
    this.autoStartAudio = false,
  });

  @override
  State<BookReader> createState() => _BookReaderState();
}

class _BookReaderState extends State<BookReader> {
  late BookLibraryService _library;
  List<BookChapter>? _chapters;
  int _chapterIndex = 0;
  bool _loading = true;
  String? _error;
  final ScrollController _scroll = ScrollController();

  // Audio mode state — only active when the user taps Play on a chapter.
  final AutoPlaylistController _audioPlaylist = AutoPlaylistController();
  final FlutterTts _audioTts = FlutterTts();
  bool _audioMode = false;
  bool _audioPrep = false;
  bool _audioPaused = false;
  // True while the Replay button is speaking the current chunk (via live TTS,
  // so the playlist stays paused at the same position).
  bool _replaying = false;
  // Monotonic session token — each replay invocation captures it on entry and
  // bails out if a newer invocation has bumped it (so a stale Future awaiting
  // _speakLive can't continue talking on top of a fresh one).
  int _replaySession = 0;
  int _prepDone = 0;
  String? _audioError;
  // Current chunk index + the chunk text and translation lists, so the play
  // view can show exactly what's being read at this moment.
  List<String> _chunks = const [];
  // Per-ordinal translation, populated lazily as we translate ahead of the
  // playhead. Entries are null until their batch is fetched.
  List<String?> _translations = const [];
  int _currentOrdinal = 0;
  // Saved audio position for the *current* chapter (null if there isn't one),
  // shown in the AppBar as "Resume chunk N".
  int? _resumeOrdinal;
  StreamSubscription<int>? _ordinalSub;
  StreamSubscription<PlayerState>? _playerStateSub;

  // Per-chunk audio file paths for this session — used to delete files behind
  // the playhead so the book audio cache doesn't grow unboundedly.
  final Map<int, ({String? source, String translation})> _chunkPaths = {};
  // Synth at most this many chunks ahead of the playhead. Combined with the
  // delete-behind logic the cache holds ~5-6 chunks at any time.
  static const int _kAudioLookAhead = 4;
  // Keep this many already-played chunks before deleting their files.
  static const int _kAudioKeepBehind = 1;
  // Translate in small batches just ahead of the playhead, instead of all at
  // once — so a 712-chunk chapter starts playing after a single batch (~5s)
  // instead of after translating every chunk first.
  static const int _kTranslateBatchSize = 10;

  @override
  void initState() {
    super.initState();
    _library = BookLibraryService(SharedPreferencesAsync());
    _load();
  }

  Future<void> _load() async {
    try {
      final path = await _library.ensureEpubFile(widget.book);
      final chapters = await _library.loadChapters(path);
      final saved = await _library.loadChapterIndex(widget.book.id);
      final audio = await _library.loadAudioPosition(widget.book.id);
      if (!mounted) return;
      // Prefer an explicitly-passed initial chapter (e.g. from the Books tab's
      // Resume action), else the saved last-read chapter.
      final wanted = widget.initialChapterIndex ?? saved;
      final chIdx = chapters.isEmpty ? 0 : wanted.clamp(0, chapters.length - 1);
      setState(() {
        _chapters = chapters;
        _chapterIndex = chIdx;
        _resumeOrdinal = (audio != null && audio.chapter == chIdx) ? audio.ordinal : null;
        _loading = false;
      });
      // Auto-start audio if requested (Resume from Books tab).
      if (widget.autoStartAudio && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _startAudio(fromOrdinal: _resumeOrdinal ?? 0);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  @override
  void dispose() {
    final ch = _chapters;
    if (ch != null && ch.isNotEmpty) {
      // Persist last-viewed chapter on the way out. We intentionally don't await:
      // dispose runs synchronously, and the prefs write completes regardless.
      _library.saveChapterIndex(widget.book.id, _chapterIndex);
      // Also snapshot the audio ordinal if a session is in flight, so leaving
      // the reader mid-playback doesn't lose the resume point.
      if (_audioMode) {
        _library.saveAudioPosition(widget.book.id, _chapterIndex, _currentOrdinal);
      }
    }
    _ordinalSub?.cancel();
    _playerStateSub?.cancel();
    _audioPlaylist.dispose();
    _audioTts.stop();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _gotoChapter(int idx) async {
    final chapters = _chapters;
    if (chapters == null || idx < 0 || idx >= chapters.length) return;
    // Switching chapters cancels any in-flight audio mode for the old chapter.
    if (_audioMode) await _stopAudio();
    final audio = await _library.loadAudioPosition(widget.book.id);
    if (!mounted) return;
    setState(() {
      _chapterIndex = idx;
      _resumeOrdinal = (audio != null && audio.chapter == idx) ? audio.ordinal : null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _library.saveChapterIndex(widget.book.id, idx);
  }

  // ── Audio mode ────────────────────────────────────────────────────────────

  Future<void> _startAudio({int fromOrdinal = 0}) async {
    final chapters = _chapters;
    if (chapters == null || chapters.isEmpty || _audioMode) return;
    final state = context.read<AppState>();
    final settings = state.settings;
    final apiKey = settings.aiApiKey.trim();
    if (apiKey.isEmpty) {
      setState(() => _audioError = 'Set a Gemini API key in Settings → AI first.');
      return;
    }

    final chunks = BookLibraryService.chunkText(
      chapters[_chapterIndex].text,
      settings.booksChunkUnit,
    );
    if (chunks.isEmpty) {
      setState(() => _audioError = 'Nothing to read in this chapter.');
      return;
    }
    final startAt = fromOrdinal.clamp(0, chunks.length - 1);

    setState(() {
      _audioMode = true;
      _audioPrep = true;
      _audioPaused = false;
      _audioError = null;
      _prepDone = 0;
      _chunks = chunks;
      // Lazy translation buffer — filled in small batches just ahead of the
      // playhead, instead of being computed upfront.
      _translations = List<String?>.filled(chunks.length, null);
      _currentOrdinal = startAt;
    });

    try {
      final sourceLocale = _bookLocale(widget.book.language);
      final targetLocale = _localeForLanguage(settings.targetLanguage) ?? 'en-US';

      await _audioPlaylist.beginDynamic(
        ordinalCount: chunks.length,
        repeatCount: settings.booksRepeatCount,
        sourcePauseSec: settings.booksSourcePauseSec,
        repeatDelaySec: settings.booksSourcePauseSec,
        postDelaySec: settings.booksBetweenChunksPauseSec,
        alternate: true,
      );

      _ordinalSub?.cancel();
      _ordinalSub = _audioPlaylist.currentOrdinalStream.listen((ord) {
        if (!mounted) return;
        setState(() => _currentOrdinal = ord);
        _library.saveAudioPosition(widget.book.id, _chapterIndex, ord);
        _evictAudioBehind(ord);
      });
      _playerStateSub?.cancel();
      _playerStateSub = _audioPlaylist.playerStateStream.listen((s) {
        if (!mounted) return;
        setState(() => _audioPaused = !s.playing);
        if (s.processingState == ProcessingState.completed) {
          _onChapterAudioCompleted();
        }
      });

      // Single streaming loop. The first iteration also translates + synths the
      // starting chunk (so playback can begin), then flips _audioPrep off and
      // calls playDynamic(). Subsequent iterations just keep the queue topped
      // up, paced to stay at most `_kAudioLookAhead` chunks ahead of playback.
      for (var i = startAt; i < chunks.length; i++) {
        while (mounted && _audioMode && (i - _currentOrdinal > _kAudioLookAhead)) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (!mounted || !_audioMode) return;
        await _ensureTranslation(i, apiKey: apiKey, settings: settings);
        if (!mounted || !_audioMode) return;
        await _prepareAndAppendChunk(
          ord: i,
          chunk: chunks[i],
          translation: _translations[i] ?? chunks[i],
          sourceLocale: sourceLocale,
          targetLocale: targetLocale,
        );
        if (!mounted || !_audioMode) return;
        if (i == startAt) {
          // First chunk ready — start playback and drop out of "preparing" UI.
          await _audioPlaylist.playDynamic();
          setState(() {
            _audioPrep = false;
            _prepDone = 1;
            _resumeOrdinal = null;
          });
        } else {
          setState(() => _prepDone = _prepDone + 1);
        }
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _audioPrep = false;
        _audioMode = false;
        _audioError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// Makes sure `_translations[ord]` is set, fetching a small batch of
  /// translations starting at [ord] from the AI cache / API on demand.
  Future<void> _ensureTranslation(int ord, {required String apiKey, required dynamic settings}) async {
    if (ord < _translations.length && _translations[ord] != null) return;
    final end = (ord + _kTranslateBatchSize).clamp(0, _chunks.length);
    final subset = _chunks.sublist(ord, end);
    final service = SentenceBankService(SharedPreferencesAsync());
    final fetched = await service.translateBatch(
      sentences: subset,
      sourceLang: widget.book.language.isEmpty ? 'English' : widget.book.language,
      targetLang: settings.targetLanguage,
      apiKey: apiKey,
    );
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < subset.length; i++) {
        _translations[ord + i] = fetched[i];
      }
    });
  }

  Future<void> _prepareAndAppendChunk({
    required int ord,
    required String chunk,
    required String translation,
    required String sourceLocale,
    required String targetLocale,
  }) async {
    final sourcePath = await _synthToFile(chunk, sourceLocale);
    final translationPath = await _synthToFile(translation, targetLocale);
    if (!mounted || !_audioMode) return;
    _chunkPaths[ord] = (source: sourcePath, translation: translationPath);
    await _audioPlaylist.appendChunk(
      ord: ord,
      text: translation,
      sourcePath: sourcePath,
      translationPath: translationPath,
    );
  }

  /// Deletes the audio files for chunks more than [_kAudioKeepBehind] behind
  /// the playhead. The player only moves forward in books mode, so removing
  /// these files is safe and keeps the on-disk audio cache tiny.
  void _evictAudioBehind(int currentOrd) {
    final cutoff = currentOrd - _kAudioKeepBehind;
    final stale = _chunkPaths.keys.where((k) => k < cutoff).toList();
    for (final ord in stale) {
      final p = _chunkPaths.remove(ord);
      if (p == null) continue;
      final s = p.source;
      if (s != null) {
        File(s).delete().then((_) {}, onError: (_) {});
      }
      File(p.translation).delete().then((_) {}, onError: (_) {});
    }
  }

  Future<void> _pauseOrResume() async {
    if (!_audioMode || _audioPrep) return;
    if (_audioPaused) {
      // If a replay is mid-speak, cut it off (bump session + stop TTS) before
      // resuming auto playback — otherwise the replay's `await` will continue
      // and start the next line on top of the resumed playlist.
      if (_replaying) {
        ++_replaySession;
        await _audioTts.stop();
        if (!mounted) return;
        setState(() => _replaying = false);
      }
      // Seek back to the start of the current chunk so Resume always restarts
      // it from the beginning, rather than continuing mid-clip from wherever
      // the pause happened to land.
      await _audioPlaylist.seekToOrdinal(_currentOrdinal);
      await _audioPlaylist.resume();
    } else {
      await _audioPlaylist.pause();
      // Pausing also nails down the saved position right now (the ordinal
      // stream may not have ticked since the last clip change).
      await _library.saveAudioPosition(widget.book.id, _chapterIndex, _currentOrdinal);
    }
    // _audioPaused gets updated by the playerState stream listener.
  }

  /// Re-speaks the current chunk's source and target via live TTS and returns
  /// to the paused state. Doesn't touch the playlist position, so pressing
  /// Resume afterwards picks up exactly where it was. Pressing Replay again
  /// (while already replaying) restarts the speak from the top.
  Future<void> _replayCurrentChunk() async {
    if (!_audioMode || _currentOrdinal >= _chunks.length) return;
    // Bump the session token first so any prior invocation still awaiting a
    // _speakLive sees mySession != _replaySession and bails before talking.
    final mySession = ++_replaySession;
    await _audioTts.stop();
    if (!mounted || mySession != _replaySession) return;

    if (!_audioPaused) {
      await _audioPlaylist.pause();
      await _library.saveAudioPosition(widget.book.id, _chapterIndex, _currentOrdinal);
    }
    if (!mounted || mySession != _replaySession) return;
    setState(() => _replaying = true);

    try {
      final state = context.read<AppState>();
      final settings = state.settings;
      final sourceLocale = _bookLocale(widget.book.language);
      final targetLocale = _localeForLanguage(settings.targetLanguage) ?? 'en-US';
      final src = _chunks[_currentOrdinal];
      final tr = (_currentOrdinal < _translations.length)
          ? _translations[_currentOrdinal]
          : null;

      await _speakLive(src, sourceLocale);
      if (!mounted || mySession != _replaySession) return;

      final pauseSec = settings.booksSourcePauseSec;
      if (pauseSec > 0) await Future.delayed(Duration(seconds: pauseSec));
      if (!mounted || mySession != _replaySession) return;

      if (tr != null && tr.isNotEmpty) {
        await _speakLive(tr, targetLocale);
      }
    } finally {
      // Only the *winning* invocation flips _replaying back off — stale ones
      // shouldn't touch it.
      if (mounted && mySession == _replaySession) {
        setState(() => _replaying = false);
      }
    }
  }

  /// Speaks [text] in [locale] via flutter_tts and awaits its completion.
  /// Honors the user-picked voice for that locale.
  Future<void> _speakLive(String text, String locale) async {
    final voiceVal = context.read<AppState>().settings.booksVoiceByLocale[locale] ?? '';
    final parts = voiceVal.split('__SEP__');
    final voiceName = parts.isNotEmpty ? parts[0] : '';
    final voiceLocale = (parts.length == 2 && parts[1].isNotEmpty) ? parts[1] : locale;

    await _audioTts.stop();
    await _audioTts.setLanguage(voiceName.isNotEmpty ? voiceLocale : locale);
    if (voiceName.isNotEmpty) {
      await _audioTts.setVoice({'name': voiceName, 'locale': voiceLocale});
    }
    await _audioTts.setSpeechRate(0.5);
    await _audioTts.setPitch(1.0);
    await _audioTts.awaitSpeakCompletion(true);
    await _audioTts.speak(text);
  }

  /// Skip back one chunk. The playlist's previous() seeks to the previous
  /// ordinal's first clip (or no-ops if already at chunk 0).
  Future<void> _skipBack() async {
    if (!_audioMode || _audioPrep) return;
    await _audioPlaylist.previous();
  }

  /// Skip forward one chunk. If the next chunk hasn't been appended yet
  /// (background prep hasn't reached it), this silently no-ops; just try again
  /// in a moment.
  Future<void> _skipForward() async {
    if (!_audioMode || _audioPrep) return;
    await _audioPlaylist.next();
  }

  /// Player reached the end of the current chapter's playlist. If there's a
  /// next chapter, advance to it and start a new audio session from chunk 0;
  /// otherwise stop and surface the resume marker (so the user can pick up at
  /// the start of this chapter next time if they want).
  bool _advancing = false; // guard so we don't double-fire on the completed event
  Future<void> _onChapterAudioCompleted() async {
    if (_advancing || !_audioMode) return;
    _advancing = true;
    try {
      final chapters = _chapters;
      if (chapters == null || _chapterIndex >= chapters.length - 1) {
        await _stopAudio();
        return;
      }
      // Stop the current session first (this saves the final ordinal, but
      // we'll overwrite it for the *next* chapter so reopening lands there).
      await _stopAudio();
      if (!mounted) return;
      await _gotoChapter(_chapterIndex + 1);
      if (!mounted) return;
      // Reset audio position to the new chapter's start so the resume marker
      // is consistent with where we actually are.
      await _library.saveAudioPosition(widget.book.id, _chapterIndex, 0);
      await _startAudio(fromOrdinal: 0);
    } finally {
      _advancing = false;
    }
  }

  Future<void> _stopAudio() async {
    // First: invalidate any in-flight replay and kill the live TTS so a stale
    // _speakLive await can't continue talking after the session ends.
    ++_replaySession;
    await _audioTts.stop();

    if (_audioMode) {
      await _library.saveAudioPosition(widget.book.id, _chapterIndex, _currentOrdinal);
    }
    await _ordinalSub?.cancel();
    _ordinalSub = null;
    await _playerStateSub?.cancel();
    _playerStateSub = null;
    await _audioPlaylist.stop();
    // Clean up the cached audio for this session — keep the cache small.
    for (final e in _chunkPaths.values) {
      final s = e.source;
      if (s != null) File(s).delete().then((_) {}, onError: (_) {});
      File(e.translation).delete().then((_) {}, onError: (_) {});
    }
    _chunkPaths.clear();
    if (!mounted) return;
    setState(() {
      _audioMode = false;
      _audioPrep = false;
      _audioPaused = false;
      _replaying = false;
      _resumeOrdinal = _currentOrdinal; // surface resume in the AppBar
    });
  }

  // Generic sample text spoken when the user taps the preview ▶ on a voice.
  static const String _kVoiceSample = 'This is what I sound like.';

  /// Opens a voice picker for both source and target. Each section groups its
  /// language's voices by regional locale (en-US / en-GB / en-AU …) under
  /// ExpansionTiles, voices are labeled "Voice 1 / 2 / 3" (no cryptic engine
  /// names), and each row has a ▶ preview button + a download/check action.
  Future<void> _showVoicePicker() async {
    final state = context.read<AppState>();
    final sourceLookup = _bookLocale(widget.book.language); // e.g. 'en-US'
    final targetLookup = _localeForLanguage(state.settings.targetLanguage) ?? 'en-US';
    final sourceLang = widget.book.language.isEmpty ? 'English' : widget.book.language;
    final targetLang = state.settings.targetLanguage;

    List raw;
    try {
      raw = (await _audioTts.getVoices) as List? ?? const [];
    } catch (_) {
      raw = const [];
    }
    if (!mounted) return;

    String baseOf(String locale) => locale.split(RegExp('[-_]')).first.toLowerCase();
    Map<String, List<Map>> groupVoicesFor(String lookupLocale) {
      final base = baseOf(lookupLocale);
      final matches = <Map>[
        for (final v in raw)
          if (v is Map && (v['locale']?.toString() ?? '').toLowerCase().startsWith(base)) v,
      ];
      final byLoc = <String, List<Map>>{};
      for (final v in matches) {
        byLoc.putIfAbsent((v['locale']?.toString() ?? '').toString(), () => []).add(v);
      }
      return byLoc;
    }

    // Order: device region first, then US/GB/AU, then alphabetical.
    List<String> orderLocales(Map<String, List<Map>> g, String base) {
      final regionPrefs = <String>[];
      final dev = WidgetsBinding.instance.platformDispatcher.locale;
      if (dev.languageCode.toLowerCase() == base && (dev.countryCode ?? '').isNotEmpty) {
        regionPrefs.add(dev.countryCode!.toLowerCase());
      }
      for (final r in const ['us', 'gb', 'au']) {
        if (!regionPrefs.contains(r)) regionPrefs.add(r);
      }
      int rank(String l) {
        final parts = l.toLowerCase().split(RegExp('[-_]'));
        final i = regionPrefs.indexOf(parts.length > 1 ? parts[1] : '');
        return i >= 0 ? i : regionPrefs.length;
      }
      return g.keys.toList()
        ..sort((a, b) {
          final r = rank(a).compareTo(rank(b));
          return r != 0 ? r : a.compareTo(b);
        });
    }

    final sourceGroups = groupVoicesFor(sourceLookup);
    final targetGroups = groupVoicesFor(targetLookup);
    final sourceLocales = orderLocales(sourceGroups, baseOf(sourceLookup));
    final targetLocales = orderLocales(targetGroups, baseOf(targetLookup));

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) {
        return StatefulBuilder(
          builder: (innerCtx, setSheet) {
            final picks = Map<String, String>.from(state.settings.booksVoiceByLocale);

            Future<void> pick(String lookupLocale, String voiceVal) async {
              picks[lookupLocale] = voiceVal;
              await state.saveSettingsOnly(
                state.settings.copyWith(booksVoiceByLocale: picks),
              );
              if (sheetCtx.mounted) setSheet(() {});
            }

            Widget automaticTile(String lookupLocale) {
              final current = picks[lookupLocale] ?? '';
              return ListTile(
                dense: true,
                title: const Text('Automatic'),
                trailing: current.isEmpty
                    ? const Icon(Icons.check)
                    : IconButton(
                        icon: const Icon(Icons.download_outlined),
                        tooltip: 'Use',
                        onPressed: () => pick(lookupLocale, ''),
                      ),
              );
            }

            Widget voiceTile(Map v, String lookupLocale, int index) {
              final name = (v['name'] ?? '').toString();
              final loc = (v['locale'] ?? '').toString();
              final id = '${name}__SEP__$loc';
              final selected = picks[lookupLocale] == id;
              return ListTile(
                dense: true,
                contentPadding: const EdgeInsets.only(left: 32, right: 16),
                leading: IconButton(
                  icon: const Icon(Icons.play_arrow_outlined),
                  tooltip: 'Preview',
                  onPressed: () => _previewVoice(v),
                ),
                title: Text('Voice ${index + 1}'),
                trailing: selected
                    ? const Icon(Icons.check)
                    : IconButton(
                        icon: const Icon(Icons.download_outlined),
                        tooltip: 'Use',
                        onPressed: () => pick(lookupLocale, id),
                      ),
              );
            }

            Widget section({
              required String title,
              required String lookupLocale,
              required Map<String, List<Map>> groups,
              required List<String> orderedLocales,
            }) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(title, style: Theme.of(context).textTheme.titleSmall),
                  ),
                  automaticTile(lookupLocale),
                  if (groups.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('No installed voices for this language.'),
                    ),
                  for (final loc in orderedLocales)
                    ExpansionTile(
                      title: Text('$loc  (${groups[loc]!.length})'),
                      children: [
                        for (var i = 0; i < groups[loc]!.length; i++)
                          voiceTile(groups[loc]![i], lookupLocale, i),
                      ],
                    ),
                ],
              );
            }

            return DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.7,
              maxChildSize: 0.95,
              builder: (_, ctrl) => ListView(
                controller: ctrl,
                children: [
                  section(
                    title: 'Source voice — $sourceLang',
                    lookupLocale: sourceLookup,
                    groups: sourceGroups,
                    orderedLocales: sourceLocales,
                  ),
                  const Divider(),
                  section(
                    title: 'Target voice — $targetLang',
                    lookupLocale: targetLookup,
                    groups: targetGroups,
                    orderedLocales: targetLocales,
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Speaks a generic sample with the given voice so the user can compare.
  Future<void> _previewVoice(Map v) async {
    try {
      await _audioPlaylist.stop();
      await _audioTts.stop();
      final loc = (v['locale']?.toString() ?? '').toString();
      if (loc.isNotEmpty) await _audioTts.setLanguage(loc);
      await _audioTts.setVoice({'name': (v['name']?.toString() ?? ''), 'locale': loc});
      await _audioTts.setSpeechRate(0.5);
      await _audioTts.setPitch(1.0);
      await _audioTts.speak(_kVoiceSample);
    } catch (_) {}
  }

  /// Synthesises [text] in [locale] to a cached WAV file via flutter_tts and
  /// returns the path. Honors the user-picked voice for [locale] (from
  /// `settings.booksVoiceByLocale`); the value is "name__SEP__voiceLocale" so
  /// e.g. an en-GB voice can be selected even when the lookup locale is en-US.
  /// The whole value is folded into the cache key.
  Future<String> _synthToFile(String text, String locale) async {
    final voiceVal = context.read<AppState>().settings.booksVoiceByLocale[locale] ?? '';
    final parts = voiceVal.split('__SEP__');
    final voiceName = parts.isNotEmpty ? parts[0] : '';
    final voiceLocale = (parts.length == 2 && parts[1].isNotEmpty) ? parts[1] : locale;

    final dir = await _ensureSynthDir();
    final key = sha1.convert(utf8.encode('$locale|$voiceVal|v3|$text')).toString();
    final file = File('${dir.path}/$key.wav');
    if (await file.exists()) return file.path;

    await _audioTts.stop();
    await _audioTts.setLanguage(voiceName.isNotEmpty ? voiceLocale : locale);
    if (voiceName.isNotEmpty) {
      await _audioTts.setVoice({'name': voiceName, 'locale': voiceLocale});
    }
    await _audioTts.setSpeechRate(0.5); // engine native rate
    await _audioTts.setPitch(1.0);
    await _audioTts.awaitSynthCompletion(true);
    await _audioTts.synthesizeToFile(text, file.path, true);
    if (!await file.exists()) {
      throw Exception('TTS produced no audio for "$locale".');
    }
    return file.path;
  }

  Directory? _synthDir;
  Future<Directory> _ensureSynthDir() async {
    if (_synthDir != null) return _synthDir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/book_audio');
    if (!await dir.exists()) await dir.create(recursive: true);
    _synthDir = dir;
    return dir;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // When audio mode is active (preparing or playing), the screen collapses to
    // just the now-playing chunk — that's what the user wants to focus on.
    if (_audioMode) return _buildAudioScaffold();
    return Scaffold(
      appBar: AppBar(
        // Tonal background + bumped title style so the book title and the
        // voice/play actions are easy to spot above the body text.
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
        elevation: 2,
        title: Text(
          widget.book.title,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        actions: [
          if (_chapters != null && _chapters!.isNotEmpty) ...[
            IconButton(
              iconSize: 30,
              tooltip: 'Pick TTS voice (source / target)',
              icon: const Icon(Icons.record_voice_over_outlined),
              onPressed: _showVoicePicker,
            ),
            IconButton(
              iconSize: 32,
              tooltip: _resumeOrdinal != null
                  ? 'Resume audio from chunk ${_resumeOrdinal! + 1}'
                  : 'Play this chapter as audio',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => _startAudio(fromOrdinal: _resumeOrdinal ?? 0),
            ),
            const SizedBox(width: 4),
          ],
        ],
      ),
      body: _buildBody(),
      bottomNavigationBar:
          (_chapters == null || _chapters!.isEmpty) ? null : _buildNavBar(),
    );
  }

  /// Minimal full-screen view shown while audio mode is active. No book text,
  /// no chapter nav — just the source + translation of the currently-spoken
  /// chunk, plus pause/stop controls.
  Widget _buildAudioScaffold() {
    final src = (_currentOrdinal < _chunks.length) ? _chunks[_currentOrdinal] : '';
    final tr = (_currentOrdinal < _translations.length)
        ? (_translations[_currentOrdinal] ?? '')
        : '';
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            children: [
              // Top: chunk position + a prominent Stop button — easy to spot,
              // hard to misread, in the error tint so its purpose is unambiguous.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _audioPrep
                        ? 'Preparing first clip…'
                        : '${_currentOrdinal + 1} / ${_chunks.length}',
                    style: theme.textTheme.labelMedium,
                  ),
                  FilledButton.tonalIcon(
                    onPressed: _stopAudio,
                    icon: const Icon(Icons.stop_circle, size: 22),
                    label: const Text('Stop'),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.colorScheme.errorContainer,
                      foregroundColor: theme.colorScheme.onErrorContainer,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      textStyle: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Center(
                  child: _audioPrep
                      ? Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              'Translating + synthesising the first chunk…',
                              style: theme.textTheme.bodySmall,
                              textAlign: TextAlign.center,
                            ),
                          ],
                        )
                      : SingleChildScrollView(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Text(
                                src,
                                style: theme.textTheme.headlineSmall?.copyWith(height: 1.45),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 20),
                              Text(
                                tr,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  height: 1.45,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                textAlign: TextAlign.center,
                              ),
                              // Replay button right under the texts so the
                              // bottom controls are well out of accidental
                              // tapping range when audio is playing.
                              const SizedBox(height: 24),
                              OutlinedButton.icon(
                                // Single behaviour: tap to (re)play the current
                                // chunk. If a replay is already going, the
                                // session token bump in _replayCurrentChunk
                                // cuts off the in-flight speech before the new
                                // one starts — no overlap, no toggle state.
                                onPressed: (!_audioPrep && _audioPaused)
                                    ? _replayCurrentChunk
                                    : null,
                                icon: const Icon(Icons.replay),
                                label: const Text('Replay this chunk'),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              // Bottom: previous chunk / pause-resume / next chunk.
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    IconButton.outlined(
                      onPressed: _audioPrep ? null : _skipBack,
                      tooltip: 'Previous chunk',
                      icon: const Icon(Icons.skip_previous),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _audioPrep ? null : _pauseOrResume,
                      icon: Icon(_audioPaused ? Icons.play_arrow : Icons.pause),
                      label: Text(_audioPaused ? 'Resume' : 'Pause'),
                    ),
                    const SizedBox(width: 12),
                    IconButton.outlined(
                      onPressed: _audioPrep ? null : _skipForward,
                      tooltip: 'Next chunk',
                      icon: const Icon(Icons.skip_next),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text('Could not open this book:\n$_error', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  _load();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    final chapters = _chapters!;
    if (chapters.isEmpty) {
      return const Center(child: Text('No readable chapters in this EPUB.'));
    }
    final ch = chapters[_chapterIndex];
    // Split the chapter into the same chunks audio mode uses, so each one can
    // be tapped to "play from here". Lets the user jump audio to any
    // sentence/paragraph without having to navigate by chunk number.
    final unit = context.watch<AppState>().settings.booksChunkUnit;
    final chunks = BookLibraryService.chunkText(ch.text, unit);
    final headerCount = (_audioError != null) ? 2 : 1;

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(8, 12, 16, 24),
      itemCount: headerCount + chunks.length,
      itemBuilder: (_, i) {
        if (_audioError != null && i == 0) {
          return Container(
            padding: const EdgeInsets.all(8),
            margin: const EdgeInsets.only(left: 8, right: 0, bottom: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(_audioError!, style: Theme.of(context).textTheme.labelSmall),
          );
        }
        if (i == headerCount - 1) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 0, 12),
            child: Text(ch.title, style: Theme.of(context).textTheme.headlineSmall),
          );
        }
        final ord = i - headerCount;
        final isResume = _resumeOrdinal == ord;
        return Container(
          color: isResume ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35) : null,
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: 'Play audio from here',
                icon: const Icon(Icons.play_circle_outline, size: 22),
                onPressed: () => _startAudio(fromOrdinal: ord),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 10, right: 0, bottom: 6),
                  child: SelectableText(
                    chunks[ord],
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.45),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNavBar() {
    final chapters = _chapters!;
    final atFirst = _chapterIndex <= 0;
    final atLast = _chapterIndex >= chapters.length - 1;
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      elevation: 4,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton.filledTonal(
                iconSize: 28,
                onPressed: atFirst ? null : () => _gotoChapter(_chapterIndex - 1),
                icon: const Icon(Icons.chevron_left),
                tooltip: 'Previous chapter',
              ),
              Expanded(
                child: TextButton(
                  onPressed: () => _pickChapter(chapters),
                  style: TextButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSecondaryContainer,
                    textStyle: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  child: Text(
                    '${_chapterIndex + 1} of ${chapters.length}: ${chapters[_chapterIndex].title}',
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              IconButton.filledTonal(
                iconSize: 28,
                onPressed: atLast ? null : () => _gotoChapter(_chapterIndex + 1),
                icon: const Icon(Icons.chevron_right),
                tooltip: 'Next chapter',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickChapter(List<BookChapter> chapters) async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.3,
        maxChildSize: 0.95,
        builder: (ctx, ctrl) => ListView.builder(
          controller: ctrl,
          itemCount: chapters.length,
          itemBuilder: (_, i) => ListTile(
            leading: Text('${i + 1}',
                style: Theme.of(ctx).textTheme.labelSmall),
            title: Text(chapters[i].title, overflow: TextOverflow.ellipsis),
            selected: i == _chapterIndex,
            onTap: () => Navigator.of(ctx).pop(i),
          ),
        ),
      ),
    );
    if (picked != null) _gotoChapter(picked);
  }
}
