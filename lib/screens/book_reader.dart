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
  const BookReader({super.key, required this.book});

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
  int _prepDone = 0;
  int _prepTotal = 0;
  String? _audioError;
  // Current chunk index + the chunk text and translation lists, so the play
  // view can show exactly what's being read at this moment.
  List<String> _chunks = const [];
  List<String> _translations = const [];
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
      final chIdx = chapters.isEmpty ? 0 : saved.clamp(0, chapters.length - 1);
      setState(() {
        _chapters = chapters;
        _chapterIndex = chIdx;
        // If the saved audio position is for the chapter we're opening, surface
        // a "Resume chunk N" affordance.
        _resumeOrdinal = (audio != null && audio.chapter == chIdx) ? audio.ordinal : null;
        _loading = false;
      });
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
      // Forward-only: we only prep chunks from startAt onwards.
      _prepTotal = chunks.length - startAt;
      _chunks = chunks;
      _translations = const [];
      _currentOrdinal = startAt;
    });

    try {
      // 1) Translate everything in one batch (fast, cached) so we know the
      //    target text for every chunk before any audio is synthesised.
      final service = SentenceBankService(SharedPreferencesAsync());
      final translations = await service.translateBatch(
        sentences: chunks,
        sourceLang: widget.book.language.isEmpty ? 'English' : widget.book.language,
        targetLang: settings.targetLanguage,
        apiKey: apiKey,
      );
      if (!mounted || !_audioMode) return;
      setState(() => _translations = translations);

      // 2) Synth + append just the *first* chunk (from `startAt`), then start
      //    playback. The remaining chunks are synthesised in the background and
      //    appended to the playlist as they're ready — playback never has to
      //    wait for the whole chapter to be prepared.
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
      });

      // Prepare and append the starting chunk.
      await _prepareAndAppendChunk(
        ord: startAt,
        chunk: chunks[startAt],
        translation: translations[startAt],
        sourceLocale: sourceLocale,
        targetLocale: targetLocale,
      );
      if (!mounted || !_audioMode) return;
      setState(() {
        _audioPrep = false;
        _prepDone = 1;
        _resumeOrdinal = null;
      });
      await _audioPlaylist.playDynamic();

      // Background prep: synth and append the rest in reading order, but never
      // get more than `_kAudioLookAhead` chunks ahead of the playhead — this
      // caps how many audio files exist on disk at once.
      for (var i = startAt + 1; i < chunks.length; i++) {
        while (mounted && _audioMode && (i - _currentOrdinal > _kAudioLookAhead)) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (!mounted || !_audioMode) return;
        await _prepareAndAppendChunk(
          ord: i,
          chunk: chunks[i],
          translation: translations[i],
          sourceLocale: sourceLocale,
          targetLocale: targetLocale,
        );
        if (!mounted || !_audioMode) return;
        setState(() => _prepDone = _prepDone + 1);
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
      await _audioPlaylist.resume();
    } else {
      await _audioPlaylist.pause();
      // Pausing also nails down the saved position right now (the ordinal
      // stream may not have ticked since the last clip change).
      await _library.saveAudioPosition(widget.book.id, _chapterIndex, _currentOrdinal);
    }
    // _audioPaused gets updated by the playerState stream listener.
  }

  Future<void> _stopAudio() async {
    // Save the final ordinal so the user can resume here later.
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
        title: Text(widget.book.title, overflow: TextOverflow.ellipsis),
        actions: [
          if (_chapters != null && _chapters!.isNotEmpty) ...[
            IconButton(
              tooltip: 'Pick TTS voice (source / target)',
              icon: const Icon(Icons.record_voice_over_outlined),
              onPressed: _showVoicePicker,
            ),
            IconButton(
              tooltip: _resumeOrdinal != null
                  ? 'Resume audio from chunk ${_resumeOrdinal! + 1}'
                  : 'Play this chapter as audio',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () => _startAudio(fromOrdinal: _resumeOrdinal ?? 0),
            ),
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
    final tr = (_currentOrdinal < _translations.length) ? _translations[_currentOrdinal] : '';
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            children: [
              // Top: minimal info — chunk position + a stop button.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _audioPrep
                        ? 'Preparing… $_prepDone / $_prepTotal'
                        : '${_currentOrdinal + 1} / ${_chunks.length}',
                    style: theme.textTheme.labelSmall,
                  ),
                  IconButton(
                    onPressed: _stopAudio,
                    tooltip: 'Stop',
                    icon: const Icon(Icons.stop_circle_outlined),
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
                              'Translating + synthesising clips…',
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
                            ],
                          ),
                        ),
                ),
              ),
              // Bottom: pause/resume (disabled while prepping).
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FilledButton.icon(
                  onPressed: _audioPrep ? null : _pauseOrResume,
                  icon: Icon(_audioPaused ? Icons.play_arrow : Icons.pause),
                  label: Text(_audioPaused ? 'Resume' : 'Pause'),
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
    return SingleChildScrollView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_audioError != null)
            Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(_audioError!, style: Theme.of(context).textTheme.labelSmall),
            ),
          Text(ch.title, style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 12),
          SelectableText(
            ch.text,
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.55),
          ),
        ],
      ),
    );
  }

  Widget _buildNavBar() {
    final chapters = _chapters!;
    final atFirst = _chapterIndex <= 0;
    final atLast = _chapterIndex >= chapters.length - 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              onPressed: atFirst ? null : () => _gotoChapter(_chapterIndex - 1),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous chapter',
            ),
            TextButton(
              onPressed: () => _pickChapter(chapters),
              child: Text(
                '${_chapterIndex + 1} of ${chapters.length}: ${chapters[_chapterIndex].title}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              onPressed: atLast ? null : () => _gotoChapter(_chapterIndex + 1),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next chapter',
            ),
          ],
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
