import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sentence_bank.dart';
import '../services/audio_utils.dart';
import '../services/auto_playlist_controller.dart';
import '../services/katalaveno_audio_handler.dart';
import '../services/google_translate_tts.dart';
import '../services/sentence_bank_foreground_service.dart';
import '../services/sentence_bank_service.dart';
import '../state/app_state.dart';
import '../widgets.dart';

/// Speech rate passed to flutter_tts for source-clip synthesis.
///
/// flutter_tts normalises this to 0.0–1.0 on both Android and iOS, where
/// **0.5 is the engine's default (native) rate**. 1.0 is roughly double speed
/// (unintelligible) and 0.0 is stopped — it is *not* a multiplier. Values below
/// 0.5 ask the engine to time-stretch, which can add artefacts on some voices.
/// Adjust here while experimenting; the synth cache invalidates automatically
/// when this value changes.
const double kSourceSpeechRate = 0.5;

/// Name of the auto-generated subject that mirrors the active-words notification
/// history into the Sentence Bank.
const String kActiveWordsSubject = 'Active words';

/// Maps a canonical English language name to a BCP-47 locale code for TTS.
String? _localeForLanguage(String languageName) {
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
  return map[languageName];
}

bool _ttsSupported() {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => true,
    TargetPlatform.iOS => true,
    TargetPlatform.macOS => true,
    TargetPlatform.windows => true,
    _ => false,
  };
}

class SentenceBankTab extends StatefulWidget {
  const SentenceBankTab({super.key});

  @override
  State<SentenceBankTab> createState() => _SentenceBankTabState();
}

class _SentenceBankTabState extends State<SentenceBankTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _tts = FlutterTts();
  final _googleTts = GoogleTranslateTts();
  final _autoPlaylist = AutoPlaylistController();
  StreamSubscription<int>? _autoOrdinalSub;
  Directory? _synthDir;
  List<String> _autoTranslations = [];
  bool _autoPreparing = false;
  int _prepDone = 0;
  int _prepTotal = 0;
  // Signature of the last built playlist; if unchanged we resume instead of
  // rebuilding (avoids the "Preparing audio…" delay on every play).
  String? _preparedSig;
  // Signature (subject/order/target language) the cached _autoTranslations were
  // computed for — so a voice change reuses them instead of re-translating.
  String? _translationsSig;
  // Languages where flutter_tts gives flat/wrong intonation for questions.
  // For these, we prefer the Google Translate audio endpoint.
  static const _googleTtsLanguages = {'el'};

  SentenceBank? _bank;
  String? _loadError;
  bool _loading = true;

  // Multi-selection of subjects (checkbox picker). Sentences played are the
  // de-duplicated union of all selected subjects (leaf + meta).
  final Set<String> _selectedSubjects = {};
  int _sentenceIndex = 0;
  List<String> _sortedSubjectNames = [];

  String? _sourceSentence;
  String? _translatedSentence;
  bool _showTranslation = false;
  bool _translating = false;

  // Batch translation progress for the current subject.
  int _batchDone = 0;
  int _batchTotal = 0;
  int _batchAttempt = 0; // 0 = first pass; >0 = auto-retry of rate-limited leftovers
  bool _batchRunning = false;

  // The single in-flight full-subject translation pass and its (order-
  // independent) signature. The background prefetch (translateAllUncached) and
  // the playlist build (translateBatch) both funnel through _withTranslationPass
  // so the same subject is never translated by two overlapping passes — which
  // wasted API calls and (before the cache mutex) could clobber results.
  Future<void>? _translationPass;
  String? _translationPassSig;

  // Guards the background "upgrade sentences translated by the weaker model"
  // pass so it never runs two at once.
  bool _upgradeRunning = false;
  // How many sentences ahead of the current one the upgrader scans each tick.
  static const int _kUpgradeLookAhead = 30;


  // Auto-mode (driven by the native playlist in AutoPlaylistController).
  bool _autoMode = false;
  bool _ttsPlaying = false; // tracks the manual single-sentence speaker button

  late SentenceBankService _service;
  int _lastReloadToken = -1;
  int _lastHistoryRevision = -1;
  bool _lastShuffle = false;
  // Signature of the playback-affecting settings; when it changes while auto
  // mode is running we rebuild the playlist so the change takes effect live.
  String _lastAutoCfg = '';
  bool _initialized = false;

  // When shuffle is on, this holds the permuted sentence indices.
  // _sentenceIndex is then a position within this list, not a raw sentence index.
  List<int>? _shuffledOrder;

  @override
  void initState() {
    super.initState();
    _tts.setCompletionHandler(_onTtsComplete);
    _tts.setCancelHandler(() {
      if (!mounted) return;
      setState(() => _ttsPlaying = false);
    });
    // Manual single-clip playback (speaker button) finishes → re-enable it.
    // Auto playback loops, so it never reaches `completed`.
    _autoPlaylist.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed && mounted && !_autoMode) {
        setState(() => _ttsPlaying = false);
      }
    });
    // Persistent media-control binding for this tab. Stays in the stack for the
    // life of the State so Bluetooth play/pause/skip work whether or not auto
    // mode is currently running. Book Reader's session binds on top of this
    // while it's active and pops off when it ends, restoring this fallback.
    katalavenoAudio.bind(
      owner: this,
      onPlay: () async {
        if (!_autoMode && _currentSentences().isNotEmpty) await _startAuto();
      },
      onPause: () async {
        if (_autoMode) _stopAuto();
      },
      onStop: () async {
        if (_autoMode) _stopAuto();
      },
      onSkipNext: () async {
        if (_autoMode) _autoNext();
      },
      onSkipPrev: () async {
        if (_autoMode) _autoPrevious();
      },
    );
  }

  // Completion of the manual single-sentence speaker button (flutter_tts).
  // Auto mode no longer uses this — it's driven entirely by the native playlist.
  void _onTtsComplete() {
    if (!mounted) return;
    setState(() => _ttsPlaying = false);
  }


  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final appState = context.read<AppState>();
      _lastReloadToken = appState.sentenceBankReloadToken;
      _lastHistoryRevision = appState.historyRevision;
      _initService();
    }
  }

  Future<void> _initService() async {
    final prefs = SharedPreferencesAsync();
    _service = SentenceBankService(prefs);
    await _loadBank();
  }

  Future<void> _loadBank() async {
    setState(() { _loading = true; _loadError = null; });
    try {
      final appState = context.read<AppState>();
      final url = appState.settings.sentenceBankUrl;
      final shuffle = appState.settings.sentenceBankShuffle;
      final bank = await _service.loadBank(url: url);
      if (!mounted) return;

      // Inject the "Active words" subject from notification history (and seed its
      // known translations) before computing the subject list, so it shows in the
      // picker and is translated/cache-hit without any AI call.
      await _injectActiveWords(bank, appState);
      if (!mounted) return;

      appState.updateSentenceBankYamlSourcePause(bank.autoSourcePause);
      appState.updateSentenceBankYamlTtsRepeatDelay(bank.ttsRepeatDelay);
      appState.updateSentenceBankYamlTtsRepeatCount(bank.ttsRepeatCount);
      final sorted = await _service.sortedSubjects(bank.subjectNames);
      // Restore the selection: keep the in-memory set (validated against the new
      // bank) if any, else the persisted set, else default to the first subject.
      final available = bank.subjectNames.toSet();
      Set<String> selection;
      if (_selectedSubjects.isNotEmpty) {
        selection = _selectedSubjects.where(available.contains).toSet();
      } else {
        final saved = await _service.loadSelectedSubjects();
        selection = {...?saved}.where(available.contains).toSet();
      }
      if (selection.isEmpty && sorted.isNotEmpty) selection = {sorted.first};
      if (!mounted) return;
      final preserving = setEquals(selection, _selectedSubjects);

      setState(() {
        _bank = bank;
        _sortedSubjectNames = sorted;
        _loading = false;
        _selectedSubjects
          ..clear()
          ..addAll(selection);
        if (!preserving) {
          _sentenceIndex = 0;
          _translatedSentence = null;
          _showTranslation = false;
        }
        if (shuffle) _generateShuffledOrder(); else _shuffledOrder = null;
        _sourceSentence = _currentSource();
      });

      // Restore the resume sentence (by text) only when the selection changed.
      if (!preserving) {
        await _service.saveSelectedSubjects(selection.toList());
        final resume = await _service.loadResumeSentence(_selectionSig());
        if (!mounted) return;
        setState(() {
          _seekToSentence(resume);
          _sourceSentence = _currentSource();
        });
      }
      _loadCachedTranslationForCurrent();

      _startBatchTranslation();

      final warning = _service.lastFetchWarning;
      if (warning != null && mounted) lpSnack(context, warning, 6000);
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadError = e.toString(); _loading = false; });
    }
  }

  /// New candidate active-words pairs taken from the current notification
  /// history: source = known-language text (l1), translation = target-language
  /// text (l2). De-duplicated by source, newest-first. These are fed into the
  /// persistent Active Words store (which accumulates beyond history's own cap).
  List<({String src, String tgt})> _historyActiveWordCandidates(AppState appState) {
    final seen = <String>{};
    final out = <({String src, String tgt})>[];
    for (final entry in appState.history) {
      for (final s in entry.sentences) {
        final l1 = s.l1.trim();
        final l2 = s.l2.trim();
        if (l1.isEmpty || l2.isEmpty || !seen.add(l1)) continue;
        out.add((src: l1, tgt: l2));
      }
    }
    return out;
  }

  /// Builds the "Active words" subject from the persistent store (merging in any
  /// new history sentences first) and seeds its known translations into the
  /// cache, so it shows in the picker and is cache-hit without any AI call.
  Future<void> _injectActiveWords(SentenceBank bank, AppState appState) async {
    final sourceLang = bank.language;
    final targetLang = appState.settings.targetLanguage;
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return;

    final stored = await _service.addActiveWords(
      incoming: _historyActiveWordCandidates(appState),
      targetLang: targetLang,
    );
    if (stored.isEmpty) {
      bank.subjects.remove(kActiveWordsSubject);
      return;
    }
    bank.subjects[kActiveWordsSubject] =
        LeafSubject(name: kActiveWordsSubject, sentences: [for (final e in stored) e.src]);
    await _service.seedTranslations(
      pairs: {for (final e in stored) e.src: e.tgt},
      sourceLang: sourceLang,
      targetLang: targetLang,
    );
  }

  /// On a history change, adds the new history sentences to the persistent
  /// Active Words store (capped, oldest evicted) and refreshes only that
  /// subject. Existing active words are kept even after they leave history.
  Future<void> _refreshActiveWords() async {
    final bank = _bank;
    if (bank == null || !mounted) return;
    final appState = context.read<AppState>();
    final sourceLang = bank.language;
    final targetLang = appState.settings.targetLanguage;
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return;

    final stored = await _service.addActiveWords(
      incoming: _historyActiveWordCandidates(appState),
      targetLang: targetLang,
    );
    if (!mounted) return;

    final existing = bank.subjects[kActiveWordsSubject];
    final oldSentences = existing is LeafSubject ? existing.sentences : const <String>[];
    final newSentences = [for (final e in stored) e.src];
    if (listEquals(oldSentences, newSentences)) return; // nothing actually changed

    // Seed only the entries that are new since last time.
    final oldSet = oldSentences.toSet();
    final newPairs = <String, String>{
      for (final e in stored)
        if (!oldSet.contains(e.src)) e.src: e.tgt,
    };
    if (newPairs.isNotEmpty) {
      await _service.seedTranslations(pairs: newPairs, sourceLang: sourceLang, targetLang: targetLang);
    }
    if (!mounted) return;

    final wasSelected = _selectedSubjects.contains(kActiveWordsSubject);
    // Capture the sentence currently in view so we can stay on it even though
    // newer entries are prepended (which shifts indices).
    final preservedSrc = wasSelected ? _currentSource() : null;

    setState(() {
      if (newSentences.isEmpty) {
        bank.subjects.remove(kActiveWordsSubject);
        if (wasSelected) {
          _selectedSubjects.remove(kActiveWordsSubject);
          _sentenceIndex = 0;
          _translatedSentence = null;
          _showTranslation = false;
          _shuffledOrder = null;
        }
      } else {
        bank.subjects[kActiveWordsSubject] = LeafSubject(name: kActiveWordsSubject, sentences: newSentences);
        if (wasSelected) {
          // Rebuild any shuffle order for the new length, then land back on the
          // sentence the user was viewing (by text), or the first if it's gone.
          if (_shuffledOrder != null) _generateShuffledOrder();
          final raw = preservedSrc == null ? -1 : newSentences.indexOf(preservedSrc);
          if (_shuffledOrder != null) {
            final pos = raw >= 0 ? _shuffledOrder!.indexOf(raw) : -1;
            _sentenceIndex = pos >= 0 ? pos : 0;
          } else {
            _sentenceIndex = raw >= 0 ? raw : 0;
          }
        }
      }
      _sourceSentence = _currentSource();
    });

    final sorted = await _service.sortedSubjects(bank.subjectNames);
    if (mounted) setState(() => _sortedSubjectNames = sorted);

    // If Active words is selected but not actively auto-playing, drop the cached
    // playlist so the next manual Play rebuilds with the new sentences. We avoid
    // touching a live auto session — it'll pick the changes up on its next start.
    if (wasSelected && !_autoMode) {
      _preparedSig = null;
      _translationsSig = null;
    }
  }

  /// The de-duplicated union of every selected subject's sentences, in stable
  /// bank order (so positions/shuffle stay consistent regardless of selection
  /// order). A sentence shared by a leaf and a meta that includes it appears once.
  List<String> _currentSentences() {
    final bank = _bank;
    if (bank == null || _selectedSubjects.isEmpty) return [];
    final seen = <String>{};
    final out = <String>[];
    for (final name in bank.subjectNames) {
      if (!_selectedSubjects.contains(name)) continue;
      for (final s in bank.sentencesFor(name)) {
        // Dedup accidental leaf/meta overlap on the raw entry, then honour an
        // author's `N,` repeat directive by emitting the sentence N times.
        if (seen.add(s)) {
          final reps = SbSentence.repeatCount(s);
          for (var i = 0; i < reps; i++) out.add(s);
        }
      }
    }
    return out;
  }

  /// Order-independent signature of the current selection — used as the key for
  /// position persistence and the translation-pass coalescer.
  String _selectionSig() => (_selectedSubjects.toList()..sort()).join('§');

  /// Persists the currently-viewed sentence (by text) as the resume point for
  /// this selection. Resume is remembered by sentence, never by index.
  void _saveResume() {
    final src = _currentSource();
    if (src != null && _selectedSubjects.isNotEmpty) {
      _service.saveResumeSentence(_selectionSig(), src);
    }
  }

  /// Moves the playhead to [sentence] (matched by text) if it's in the current
  /// list, honouring any active shuffle order. No-op if not found.
  void _seekToSentence(String? sentence) {
    if (sentence == null) return;
    final sents = _currentSentences();
    final raw = sents.indexOf(sentence);
    if (raw < 0) return;
    final order = _shuffledOrder;
    if (order != null) {
      final p = order.indexOf(raw);
      _sentenceIndex = p >= 0 ? p : 0;
    } else {
      _sentenceIndex = raw;
    }
  }

  /// Short summary of the selection for the picker button.
  String _selectionSummary() {
    final bank = _bank;
    if (bank == null || _selectedSubjects.isEmpty) return 'none';
    if (_selectedSubjects.length >= bank.subjectNames.length) return 'All';
    if (_selectedSubjects.length == 1) return _selectedSubjects.first;
    return '${_selectedSubjects.length} selected';
  }

  String? _currentSource() {
    final sents = _currentSentences();
    if (sents.isEmpty) return null;
    final order = _shuffledOrder;
    if (order != null && order.isNotEmpty) {
      return sents[order[_sentenceIndex % order.length]];
    }
    return sents[_sentenceIndex % sents.length];
  }

  void _generateShuffledOrder() {
    final sents = _currentSentences();
    if (sents.isEmpty) { _shuffledOrder = null; return; }
    final indices = List.generate(sents.length, (i) => i)..shuffle();
    _shuffledOrder = indices;
  }

  /// Applies a new subject selection: resets position/shuffle, persists the set,
  /// restores any saved position for that combination, and (re)translates.
  Future<void> _applySelection(Set<String> sel) async {
    _stopAuto();
    final shuffle = context.read<AppState>().settings.sentenceBankShuffle;
    setState(() {
      _selectedSubjects
        ..clear()
        ..addAll(sel);
      _sentenceIndex = 0;
      if (shuffle) _generateShuffledOrder(); else _shuffledOrder = null;
      _sourceSentence = _currentSource();
      _translatedSentence = null;
      _showTranslation = false;
      _batchDone = 0;
      _batchTotal = 0;
      _batchAttempt = 0;
    });
    await _service.saveSelectedSubjects(sel.toList());
    // Record each selected subject (by name) in the recency list so the picker
    // shows recently-used subjects first.
    for (final name in sel) {
      await _service.recordSubjectSelected(name);
    }
    if (!mounted) return;
    if (_bank != null) {
      final sorted = await _service.sortedSubjects(_bank!.subjectNames);
      if (mounted) setState(() => _sortedSubjectNames = sorted);
    }
    // Restore the resume sentence (by text) for this exact selection.
    final resume = await _service.loadResumeSentence(_selectionSig());
    if (!mounted) return;
    setState(() {
      _seekToSentence(resume);
      _sourceSentence = _currentSource();
    });
    _loadCachedTranslationForCurrent();
    _startBatchTranslation();
  }

  /// Opens the multi-select subject picker (bottom sheet with a "Check all" row
  /// and a checkbox per subject). Applies the new selection on close if changed.
  Future<void> _openSubjectPicker() async {
    final bank = _bank;
    if (bank == null) return;
    final all = _sortedSubjectNames;
    final working = {..._selectedSubjects};

    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final allChecked = working.length >= all.length && all.isNotEmpty;
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      children: [
                        Text('Select subjects', style: Theme.of(ctx).textTheme.titleMedium),
                        const Spacer(),
                        Text('${working.length}/${all.length}',
                            style: Theme.of(ctx).textTheme.labelMedium),
                      ],
                    ),
                  ),
                  CheckboxListTile(
                    dense: true,
                    title: const Text('Check all'),
                    // true = all, false = none, null = some (indeterminate dash).
                    value: allChecked ? true : (working.isEmpty ? false : null),
                    tristate: true,
                    onChanged: (_) => setSheet(() {
                      if (allChecked) {
                        working.clear();
                      } else {
                        working
                          ..clear()
                          ..addAll(all);
                      }
                    }),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: all.length,
                      itemBuilder: (_, i) {
                        final name = all[i];
                        final isMeta = bank.subjects[name] is MetaSubject;
                        return CheckboxListTile(
                          dense: true,
                          value: working.contains(name),
                          onChanged: (v) => setSheet(() {
                            if (v == true) {
                              working.add(name);
                            } else {
                              working.remove(name);
                            }
                          }),
                          secondary: Icon(
                            isMeta ? Icons.folder_outlined : Icons.list_alt_outlined,
                            color: Theme.of(ctx).colorScheme.primary,
                          ),
                          title: Text(name, overflow: TextOverflow.ellipsis),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(working),
                        child: const Text('Done'),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    if (result == null || !mounted) return;
    if (!setEquals(result, _selectedSubjects)) {
      await _applySelection(result);
    }
  }

  Future<void> _loadCachedTranslationForCurrent() async {
    final src = _sourceSentence;
    if (src == null || _bank == null) return;
    final state = context.read<AppState>();
    final cached = await _service.getCached(
      sentence: SbSentence.spoken(src),
      sourceLang: _bank!.language,
      targetLang: state.settings.targetLanguage,
    );
    if (!mounted) return;
    if (cached != null) setState(() => _translatedSentence = cached);
  }

  /// Order-independent signature of the current subject's translation work. The
  /// background prefetch translates the subject unordered; the playlist build
  /// translates the same set in play order — both share this sig so they
  /// recognise they'd be doing the same work.
  String _subjectTransSig(String targetLang) => '${_selectionSig()}|$_lastReloadToken|$targetLang';

  /// Registers [body] as the single in-flight translation pass for [sig]. If a
  /// pass for the same sig is already running, awaits it and skips [body]
  /// (returns true — the caller's work is already covered). Otherwise runs
  /// [body] and returns false.
  Future<bool> _withTranslationPass(String sig, Future<void> Function() body) async {
    if (_translationPassSig == sig && _translationPass != null) {
      await _translationPass;
      return true;
    }
    final completer = Completer<void>();
    _translationPass = completer.future;
    _translationPassSig = sig;
    try {
      await body();
      return false;
    } finally {
      completer.complete();
      if (identical(_translationPass, completer.future)) {
        _translationPass = null;
        _translationPassSig = null;
      }
    }
  }

  Future<void> _startBatchTranslation() async {
    if (_batchRunning || _bank == null) return;
    final sentences = _currentSentences();
    if (sentences.isEmpty) return;

    final state = context.read<AppState>();
    final sourceLang = _bank!.language;
    final targetLang = state.settings.targetLanguage;
    final apiKey = state.settings.aiApiKey;
    if (apiKey.trim().isEmpty) return;

    setState(() { _batchRunning = true; _batchDone = 0; _batchTotal = 0; _batchAttempt = 0; });

    try {
      // If the playlist build is already translating this subject, this awaits
      // it and skips — no second concurrent pass.
      await _withTranslationPass(_subjectTransSig(targetLang), () async {
        final failed = await _service.translateAllUncached(
          sentences: [for (final s in sentences) SbSentence.spoken(s)],
          sourceLang: sourceLang,
          targetLang: targetLang,
          apiKey: apiKey,
          onProgress: (done, total, attempt) {
            if (!mounted) return;
            setState(() { _batchDone = done; _batchTotal = total; _batchAttempt = attempt; });
            _loadCachedTranslationForCurrent();
          },
        );
        if (failed > 0 && mounted) {
          lpSnack(context, "$failed sentence${failed == 1 ? '' : 's'} couldn't be translated yet — tap Translate again to retry.", 6000);
        }
      });
    } catch (e) {
      if (mounted) lpSnack(context, e.toString().replaceFirst('Exception: ', ''), 5000);
    } finally {
      if (mounted) {
        setState(() { _batchRunning = false; _batchDone = 0; _batchTotal = 0; _batchAttempt = 0; });
        _loadCachedTranslationForCurrent();
      }
    }
  }

  /// Background quality pass: starting at the current sentence, scans the next
  /// [_kUpgradeLookAhead] sentences and re-translates — with the primary model
  /// only — any whose cached translation came from the weaker lite fallback (or
  /// predates model tracking). Upgrades land in the cache; the on-screen text
  /// refreshes if the current sentence is among them, and audio picks them up on
  /// the next playlist build. Best-effort and silent: a rate-limit just ends the
  /// run early and it retries on the next sentence advance.
  Future<void> _upgradeAheadInBackground() async {
    if (_upgradeRunning || _bank == null || !mounted) return;
    final state = context.read<AppState>();
    final apiKey = state.settings.aiApiKey;
    final sourceLang = _bank!.language;
    final targetLang = state.settings.targetLanguage;
    if (apiKey.trim().isEmpty || sourceLang.toLowerCase() == targetLang.toLowerCase()) return;

    final sents = _currentSentences();
    if (sents.isEmpty) return;
    final order = _shuffledOrder;
    final span = order?.length ?? sents.length;
    // The look-ahead window in play order, starting at the *next* sentence — the
    // current one is already built/playing (its upgrade wouldn't reach the live
    // audio anyway), and the manual Re-translate button covers it on demand. The
    // `span - 1` cap keeps the window from wrapping back onto the current one.
    final window = <String>[];
    for (var k = 0; k < _kUpgradeLookAhead && k < span - 1; k++) {
      final pos = _sentenceIndex + 1 + k;
      final idx = order != null ? order[pos % order.length] : pos % sents.length;
      if (idx >= 0 && idx < sents.length) window.add(SbSentence.spoken(sents[idx]));
    }
    if (window.isEmpty) return;

    _upgradeRunning = true;
    try {
      final needing = await _service.sentencesNeedingUpgrade(
        sentences: window,
        sourceLang: sourceLang,
        targetLang: targetLang,
      );
      for (final s in needing) {
        if (!mounted) return;
        try {
          final t = await _service.translate(
            sentence: s,
            sourceLang: sourceLang,
            targetLang: targetLang,
            apiKey: apiKey,
            force: true,
          );
          if (!mounted) return;
          // If we just upgraded the sentence currently on screen, refresh it.
          final curSpoken = _sourceSentence == null ? null : SbSentence.spoken(_sourceSentence!);
          if (t.trim() != s.trim() && s == curSpoken && _showTranslation) {
            setState(() => _translatedSentence = t);
          }
        } on TranslationException {
          // Rate-limited / quota — stop now, resume on the next advance.
          break;
        } catch (_) {
          // Skip this one; keep going with the rest of the window.
        }
      }
    } finally {
      _upgradeRunning = false;
    }
  }

  void _reshuffleAvoidingCurrent() {
    final order = _shuffledOrder;
    if (order == null || order.length < 2) { _generateShuffledOrder(); return; }
    final currentSentIdx = order[_sentenceIndex % order.length];
    _generateShuffledOrder();
    final newOrder = _shuffledOrder!;
    if (newOrder.first == currentSentIdx) {
      // Swap first with a random other position to avoid repeating the same sentence.
      final swapPos = 1 + (DateTime.now().millisecondsSinceEpoch % (newOrder.length - 1)).toInt();
      final tmp = newOrder[0]; newOrder[0] = newOrder[swapPos]; newOrder[swapPos] = tmp;
    }
  }

  void _nextSentence() {
    final sents = _currentSentences();
    if (sents.isEmpty) return;
    final wrapping = _shuffledOrder != null && (_sentenceIndex + 1) >= sents.length;
    if (wrapping) _reshuffleAvoidingCurrent();
    final newIndex = wrapping ? 0 : (_sentenceIndex + 1) % sents.length;
    setState(() {
      _sentenceIndex = newIndex;
      _sourceSentence = _currentSource();
      _translatedSentence = null;
      _showTranslation = false;
    });
    _loadCachedTranslationForCurrent();
    unawaited(_upgradeAheadInBackground());
    _saveResume();
  }

  void _previousSentence() {
    final sents = _currentSentences();
    if (sents.isEmpty) return;
    final newIndex = (_sentenceIndex - 1 + sents.length) % sents.length;
    setState(() {
      _sentenceIndex = newIndex;
      _sourceSentence = _currentSource();
      _translatedSentence = null;
      _showTranslation = false;
    });
    _loadCachedTranslationForCurrent();
    unawaited(_upgradeAheadInBackground());
    _saveResume();
  }

  void _autoPrevious() {
    if (!_autoMode || !mounted) return;
    // When the playlist failed to load (catastrophic prep failure), the
    // controller's previous() no-ops — fall back to manual sentence nav so the
    // user can still move forward/back without having to stop auto mode.
    if (_autoPlaylist.isLoaded) {
      _autoPlaylist.previous();
    } else {
      _previousSentence();
    }
  }

  void _autoNext() {
    if (!_autoMode || !mounted) return;
    if (_autoPlaylist.isLoaded) {
      _autoPlaylist.next();
    } else {
      _nextSentence();
    }
  }

  Future<String?> _getTranslation() async {
    final src = _sourceSentence;
    if (src == null) return null;
    if (_translatedSentence != null) return _translatedSentence;

    final state = context.read<AppState>();
    final sourceLang = _bank!.language;
    final targetLang = state.settings.targetLanguage;
    final apiKey = state.settings.aiApiKey;

    setState(() => _translating = true);
    try {
      final t = await _service.translate(
        sentence: SbSentence.spoken(src),
        sourceLang: sourceLang,
        targetLang: targetLang,
        apiKey: apiKey,
      );
      if (!mounted) return null;
      setState(() { _translatedSentence = t; _translating = false; });
      return t;
    } catch (e) {
      if (!mounted) return null;
      setState(() => _translating = false);
      lpSnack(context, e.toString().replaceFirst('Exception: ', ''), 5000);
      return null;
    }
  }

  Future<void> _onTranslateButton() async {
    // If the translation is already on screen, the button re-translates *just
    // this sentence* (repairs a bad cached translation) — no batch, no other
    // sentences touched.
    if (_showTranslation && _translatedSentence != null) {
      await _retranslateCurrent();
      return;
    }
    if (!_batchRunning) _startBatchTranslation();
    await _getTranslation();
    if (!mounted) return;
    setState(() => _showTranslation = true);
  }

  /// Forces a fresh AI translation of the currently-viewed sentence, overwriting
  /// its cached entry. Only this one sentence is affected.
  Future<void> _retranslateCurrent() async {
    final src = _sourceSentence;
    if (src == null || _bank == null) return;
    final state = context.read<AppState>();
    final apiKey = state.settings.aiApiKey;
    if (apiKey.trim().isEmpty) {
      lpSnack(context, 'Set your AI API key in Settings first.', 4000);
      return;
    }
    setState(() => _translating = true);
    final spokenSrc = SbSentence.spoken(src);
    try {
      final t = await _service.translate(
        sentence: spokenSrc,
        sourceLang: _bank!.language,
        targetLang: state.settings.targetLanguage,
        apiKey: apiKey,
        force: true,
      );
      if (!mounted) return;
      // If the model echoed the source back (quota/failure), keep what we had.
      if (t.trim() == spokenSrc.trim()) {
        setState(() => _translating = false);
        lpSnack(context, 'Could not re-translate right now — try again later.', 4000);
        return;
      }
      setState(() {
        _translatedSentence = t;
        _translating = false;
        _showTranslation = true;
      });
      // Invalidate the auto-mode caches so returning to Play rebuilds with the
      // new translation + audio instead of resuming the stale playlist. The
      // synth cache is keyed by translation text, so only this one new clip is
      // missing — the rebuild is otherwise all cache hits and quick.
      _preparedSig = null;
      _translationsSig = null;
      // Keep the in-memory ordered list consistent too, in case it's reused
      // before a full rebuild.
      final ordIdx = _orderedIndexOf(src);
      if (ordIdx != null && ordIdx < _autoTranslations.length) {
        _autoTranslations[ordIdx] = t;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _translating = false);
      lpSnack(context, e.toString().replaceFirst('Exception: ', ''), 5000);
    }
  }

  /// Index of [sentence] within the current play-ordered sentence list (the same
  /// ordering `_autoTranslations` follows), or null if not found.
  int? _orderedIndexOf(String sentence) {
    final sents = _currentSentences();
    final order = _shuffledOrder;
    for (var o = 0; o < sents.length; o++) {
      final idx = order != null ? order[o % order.length] : o;
      if (idx >= 0 && idx < sents.length && sents[idx] == sentence) return o;
    }
    return null;
  }

  // ── TTS ───────────────────────────────────────────────────────────────────

  Future<void> _speakTranslation() async {
    if (!_ttsSupported()) {
      lpSnack(context, 'TTS is not available on this platform.', 4000);
      return;
    }
    final translation = await _getTranslation();
    if (translation == null || !mounted) return;

    final settings = context.read<AppState>().settings;
    try {
      setState(() => _ttsPlaying = true);
      await _tts.stop();
      // Use the exact same clip the playlist would (Greek → Google MP3, others →
      // synthesized) so the manual speaker and auto mode always sound identical.
      final path = await _ensureClipFile(translation, settings.targetLanguage, settings.sentenceBankVoiceGender);
      await _autoPlaylist.playSingle(path);
      _preparedSig = null; // single playback clears the loaded playlist
    } catch (e) {
      if (!mounted) return;
      setState(() => _ttsPlaying = false);
      lpSnack(context, 'Audio playback failed.', 4000);
    }
  }

  /// Tries to select a voice matching [gender] for [locale].
  /// Returns true if a matching voice was found and set, false otherwise.
  Future<bool> _applyGenderedVoice(String? locale, String gender) async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List || raw.isEmpty) return false;

      final langPrefix = locale?.substring(0, 2).toLowerCase();

      // Region preference: the device's own region first (if it speaks the
      // source language — e.g. an en-GB phone), otherwise US → UK(GB) → AU.
      final regionPrefs = <String>[];
      final dev = WidgetsBinding.instance.platformDispatcher.locale;
      if (langPrefix != null && dev.languageCode.toLowerCase() == langPrefix) {
        final c = (dev.countryCode ?? '').toLowerCase();
        if (c.isNotEmpty) regionPrefs.add(c);
      }
      for (final r in const ['us', 'gb', 'au']) {
        if (!regionPrefs.contains(r)) regionPrefs.add(r);
      }

      // Score each voice: higher = better match.
      Map? best;
      int bestScore = -1;

      for (final v in raw) {
        final m = v as Map;
        final vLocale = (m['locale'] as String? ?? '').toLowerCase();
        final vGender = (m['gender'] as String? ?? '').toLowerCase();
        final vName = (m['name'] as String? ?? '').toLowerCase();

        // Must match the target language.
        if (langPrefix != null && !vLocale.startsWith(langPrefix)) continue;

        int score = 1; // any matching-language voice is a valid candidate

        // Region preference dominates (×100) so accent wins over the gender
        // heuristic, which only breaks ties within the same region.
        final rp = vLocale.split(RegExp('[-_]'));
        final vRegion = rp.length > 1 ? rp[1] : '';
        final ri = regionPrefs.indexOf(vRegion);
        if (ri >= 0) score += (regionPrefs.length - ri) * 100;

        // Explicit gender field (most reliable).
        if (vGender == gender) score += 10;

        // Android Google TTS: names like "el-gr-x-elm-local" (m=male, a=female)
        // or "en-us-x-sfg#male_1-local" / "#female".
        if (gender == 'male') {
          if (vName.contains('#male') || vName.contains('male_')) score += 8;
          if (RegExp(r'-x-\w*m\w*-').hasMatch(vName)) score += 5;
          if (vName.contains('male')) score += 4;
          // iOS: known male voice names (heuristic — male voices are usually men's names).
          if (vName.contains('nikos') || vName.contains('jorge') || vName.contains('thomas') ||
              vName.contains('daniel') || vName.contains('alex') || vName.contains('fred')) score += 6;
          // Penalise obvious female names.
          if (vName.contains('female') || vName.contains('#f') || vName.contains('melina') ||
              vName.contains('anna') || vName.contains('samantha') || vName.contains('victoria')) score -= 20;
        } else {
          if (vName.contains('#female') || vName.contains('female_')) score += 8;
          if (RegExp(r'-x-\w*a\w*-').hasMatch(vName)) score += 5;
          if (vName.contains('female')) score += 4;
          // iOS known female voice names.
          if (vName.contains('melina') || vName.contains('anna') || vName.contains('samantha') ||
              vName.contains('victoria') || vName.contains('karen') || vName.contains('moira')) score += 6;
          // Penalise obvious male names.
          if (vName.contains('#male') || vName.contains('male_') ||
              vName.contains('nikos') || vName.contains('daniel') || vName.contains('thomas')) score -= 20;
        }

        if (score > bestScore) {
          bestScore = score;
          best = m;
        }
      }

      // Only apply if we found something with a positive gender-match score.
      if (best != null && bestScore > 0) {
        await _tts.setVoice({'name': best['name'] as String, 'locale': (best['locale'] as String?) ?? ''});
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  // ── Auto mode ─────────────────────────────────────────────────────────────

  Future<void> _startAuto() async {
    if (_currentSentences().isEmpty) return;
    setState(() => _autoMode = true);
    // Media-control bindings live on the handler stack for the whole tab
    // lifetime (set up in initState), so we don't (re)bind here.
    await _buildOrResumePlaylist(play: true);
  }

  /// Resumes the loaded playlist if nothing changed; otherwise (re)builds every
  /// clip file and the native playlist. When [play] is false it builds but does
  /// not start playback — used by the voice picker so generation happens at
  /// selection time and the next Play is instant.
  Future<void> _buildOrResumePlaylist({required bool play}) async {
    final sents = _currentSentences();
    if (sents.isEmpty) return;
    final state = context.read<AppState>();
    final settings = state.settings;
    final order = _shuffledOrder;
    final ordered = [for (var o = 0; o < sents.length; o++) sents[order != null ? order[o % order.length] : o]];
    // What actually gets spoken/translated (hints dropped, options collapsed,
    // `N,` prefix removed). `ordered` keeps the raw text for display/identity.
    final orderedSpoken = [for (final r in ordered) SbSentence.spoken(r)];

    final sig = [
      _selectionSig(),
      _lastReloadToken,
      order?.join(','),
      settings.targetLanguage,
      _bank?.language,
      settings.sentenceBankSpeakSource,
      settings.sentenceBankSourceVoice,
      settings.sentenceBankVoiceGender,
      state.sentenceBankResolvedTtsRepeatCount,
      settings.sentenceBankSourcePauseOverride ?? _bank?.autoSourcePause,
      settings.sentenceBankTtsRepeatDelayOverride ?? _bank?.ttsRepeatDelay,
      _bank?.autoPostTtsDelay,
      settings.sentenceBankRepeatSourceBetween,
    ].join('¦');

    if (sig == _preparedSig && _autoPlaylist.isLoaded) {
      _autoOrdinalSub ??= _autoPlaylist.currentOrdinalStream.listen(_onAutoOrdinal);
      if (play) await _autoPlaylist.resumeAt(_sentenceIndex);
      return;
    }

    setState(() { _autoPreparing = true; _prepDone = 0; _prepTotal = 0; });
    try {
      // Translations depend only on subject/order/target language — not the
      // voice — so reuse the in-memory set across voice changes instead of
      // re-hitting the translator.
      final translationsSig =
          [_selectionSig(), _lastReloadToken, order?.join(','), settings.targetLanguage].join('¦');
      List<String> translations;
      if (translationsSig == _translationsSig && _autoTranslations.length == ordered.length) {
        translations = _autoTranslations;
      } else {
        Future<List<String>> doBatch() => _service.translateBatch(
              sentences: orderedSpoken,
              sourceLang: _bank!.language,
              targetLang: settings.targetLanguage,
              apiKey: settings.aiApiKey,
            );
        // Coalesce with any in-flight background prefetch for this subject so we
        // don't run two translation passes at once. If a prefetch pass was
        // already running, it has now finished and cached everything, so the
        // doBatch() below is pure cache hits (no API calls).
        late List<String> fetched;
        final coalesced = await _withTranslationPass(
          _subjectTransSig(settings.targetLanguage),
          () async { fetched = await doBatch(); },
        );
        translations = coalesced ? await doBatch() : fetched;
        if (!mounted) return;
        _autoTranslations = translations;
        // Only mark this set reusable if every sentence actually translated;
        // otherwise leave it unset so the failed ones retry on the next build.
        final anyFailed = [
          for (var i = 0; i < ordered.length; i++) translations[i].trim() == orderedSpoken[i].trim()
        ].any((f) => f);
        _translationsSig = anyFailed ? null : translationsSig;
      }

      // Pre-render every clip to a file so the native playlist survives lock:
      // translation per target language, gendered/voiced source per source language.
      final speakSource = settings.sentenceBankSpeakSource;
      final gender = settings.sentenceBankVoiceGender;
      final sourceVoice = settings.sentenceBankSourceVoice;
      final translationPaths = List<String>.filled(translations.length, '');
      final sourcePaths = List<String?>.filled(translations.length, null);
      // Two-pass: cheap cache-existence probe first (in parallel) so the
      // progress bar reflects *actual* work (synth/download) instead of marching
      // through every ordinal even when 126/130 are already on disk.
      final needsWork = <int>[];
      await Future.wait([
        for (var o = 0; o < translations.length; o++)
          () async {
            final failed = translations[o].trim() == orderedSpoken[o].trim();
            final clipLang = failed ? _bank!.language : settings.targetLanguage;
            final cached = await _cachedClipFile(
                translations[o], clipLang, gender, preferVoice: failed ? sourceVoice : '');
            if (cached != null) {
              translationPaths[o] = cached;
            } else {
              needsWork.add(o);
            }
            if (speakSource) {
              sourcePaths[o] =
                  await _cachedClipFile(orderedSpoken[o], _bank!.language, gender, preferVoice: sourceVoice);
            }
          }(),
      ]);
      needsWork.sort();
      // Source clips still missing after the cache probe — append them so
      // they're (re)synthesised below. Failures stay null (source is optional).
      final sourceMissing = <int>[
        if (speakSource)
          for (var o = 0; o < translations.length; o++)
            if (sourcePaths[o] == null) o,
      ];

      if (mounted) setState(() => _prepTotal = needsWork.length + sourceMissing.length);
      int failureCount = 0;

      for (final o in needsWork) {
        if (!mounted) return;
        final failed = translations[o].trim() == orderedSpoken[o].trim();
        final clipLang = failed ? _bank!.language : settings.targetLanguage;
        try {
          translationPaths[o] = await _ensureClipFile(
              translations[o], clipLang, gender, preferVoice: failed ? sourceVoice : '');
        } catch (_) {
          // Even after Google→local fallback this one couldn't be produced —
          // leave the path empty so the playlist controller skips this
          // ordinal entirely (no silence wait, no aborted prep).
          translationPaths[o] = '';
          failureCount++;
        }
        if (mounted) setState(() => _prepDone = _prepDone + 1);
      }
      for (final o in sourceMissing) {
        if (!mounted) return;
        sourcePaths[o] = await _ensureClipFileOrNull(
            orderedSpoken[o], _bank!.language, gender, preferVoice: sourceVoice);
        if (mounted) setState(() => _prepDone = _prepDone + 1);
      }
      if (!mounted) return;
      if (failureCount > 0 && mounted) {
        lpSnack(context, '$failureCount sentence(s) could not be synthesized — skipping them.', 4000);
      }

      _autoOrdinalSub?.cancel();
      _autoOrdinalSub = _autoPlaylist.currentOrdinalStream.listen(_onAutoOrdinal);

      // Synthesizing source clips drives the flutter_tts engine, which holds
      // Android audio focus. If it isn't released before the playlist player
      // starts (e.g. prep finished while the screen was locked), playback
      // begins silently — the symptom that "stop then play" used to clear.
      // Release it explicitly so the player wins focus on the first try.
      try { await _tts.stop(); } catch (_) {}

      await _autoPlaylist.start(
        translations: translations,
        translationPaths: translationPaths,
        sourcePaths: sourcePaths,
        repeatCount: state.sentenceBankResolvedTtsRepeatCount,
        sourcePauseSec: settings.sentenceBankSourcePauseOverride ?? _bank?.autoSourcePause ?? 1,
        repeatDelaySec: settings.sentenceBankTtsRepeatDelayOverride ?? _bank?.ttsRepeatDelay ?? 1,
        postDelaySec: _bank?.autoPostTtsDelay ?? 2,
        startOrdinal: _sentenceIndex,
        autoPlay: play && _autoMode,
        // When on, replay the source before every target repeat (source between
        // targets) instead of speaking the source once up front.
        alternate: settings.sentenceBankSpeakSource && settings.sentenceBankRepeatSourceBetween,
      );
      _preparedSig = sig;
      if (mounted) setState(() => _autoPreparing = false);
    } catch (e) {
      if (!mounted) return;
      // Keep auto mode on so the user can recover by pressing next (which now
      // falls back to manual sentence nav when no playlist is loaded) — they
      // shouldn't have to fish the phone out of their pocket to press stop.
      setState(() { _autoPreparing = false; });
      lpSnack(context, 'Could not prepare audio.', 4000);
    }
  }

  void _onAutoOrdinal(int ord) {
    if (!mounted) return;
    setState(() {
      _sentenceIndex = ord;
      _sourceSentence = _currentSource();
      _translatedSentence = ord < _autoTranslations.length ? _autoTranslations[ord] : null;
      _showTranslation = true;
    });
    // Remember the resume sentence as auto mode advances (in-pocket sessions).
    _saveResume();
    // As playback advances, upgrade any lite-translated sentences in the window
    // ahead so they're flash-quality on the next time through the subject.
    unawaited(_upgradeAheadInBackground());
  }

  void _stopAuto() {
    _tts.stop();
    _autoOrdinalSub?.cancel();
    _autoOrdinalSub = null;
    _autoPlaylist.stop();
    _saveAutoPosition();
    // Persistent media binding stays so a tap on Play (Bluetooth / lockscreen)
    // can restart auto mode after a stop.
    setState(() {
      _autoMode = false;
      _autoPreparing = false;
      _ttsPlaying = false;
    });
    SentenceBankForegroundService.stop();
  }

  void _saveAutoPosition() {
    _saveResume();
  }

  String _ttsLangCode(String languageName) {
    final locale = _localeForLanguage(languageName);
    return (locale ?? 'en').toLowerCase().split(RegExp('[-_]')).first;
  }

  Future<Directory> _ensureSynthDir() async {
    if (_synthDir != null) return _synthDir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/tts_synth_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    _synthDir = dir;
    return dir;
  }

  /// Produces a playable audio file for [text] in [languageName]. Greek-class
  /// languages prefer Google TTS (question intonation); on transient failure
  /// (the unofficial endpoint rate-limits or errors and the result isn't
  /// cached) we fall back to local flutter_tts with the target locale — worse
  /// intonation but still audible, far better than skipping the sentence.
  /// Throws only if every backend fails.
  Future<String> _ensureClipFile(String text, String languageName, String gender, {String preferVoice = ''}) async {
    final code = _ttsLangCode(languageName);
    if (_googleTtsLanguages.contains(code)) {
      try {
        return await _googleTts.ensureFile(text, code);
      } catch (_) {
        // Fall through to local synthesis below.
      }
    }
    return _synthToFile(text, _localeForLanguage(languageName), code, gender, preferVoice);
  }


  /// Like [_ensureClipFile] but returns null instead of throwing — used for the
  /// optional source clip so one failure just drops that source.
  Future<String?> _ensureClipFileOrNull(String text, String languageName, String gender, {String preferVoice = ''}) async {
    try {
      return await _ensureClipFile(text, languageName, gender, preferVoice: preferVoice);
    } catch (_) {
      return null;
    }
  }

  /// Returns the cached clip path for [text] if it already exists on disk; null
  /// otherwise. Never synthesizes or hits Google. Used to pre-classify the prep
  /// loop's work so the progress bar reflects actual misses instead of marching
  /// through every ordinal (cache hits and all).
  Future<String?> _cachedClipFile(String text, String languageName, String gender, {String preferVoice = ''}) async {
    try {
      final code = _ttsLangCode(languageName);
      if (_googleTtsLanguages.contains(code)) {
        return _googleTts.cachedFile(text, code);
      }
      final dir = await _ensureSynthDir();
      final voiceKey = preferVoice.isNotEmpty ? preferVoice : gender;
      final key = sha1.convert(utf8.encode('$code|$voiceKey|p7|r$kSourceSpeechRate|$text')).toString();
      final file = File('${dir.path}/$key.wav');
      return await file.exists() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Renders [text] to a WAV via flutter_tts, cached on disk so it's only
  /// synthesized once per (voice/gender, text). When [preferVoice] is a chosen
  /// voice ("name__SEP__locale"), that exact voice is used; otherwise it falls
  /// back to picking a voice by [gender].
  Future<String> _synthToFile(String text, String? locale, String code, String gender, String preferVoice) async {
    final dir = await _ensureSynthDir();
    final voiceKey = preferVoice.isNotEmpty ? preferVoice : gender;
    // Version token; bump to force re-synthesis (p1 = leading silence,
    // p2 = region-first Automatic voice, p3 = 500ms lead, p5 = 24kHz cap,
    // p6 = native rate, no downsampling, p7 = no pitch-shift fallback). The
    // current kSourceSpeechRate is folded into the key so changing it
    // auto-invalidates clips that were synthesised at a different rate.
    final key = sha1
        .convert(utf8.encode('$code|$voiceKey|p7|r$kSourceSpeechRate|$text'))
        .toString();
    final file = File('${dir.path}/$key.wav');
    if (await file.exists()) return file.path;
    await _evictSynthIfFull(dir);

    await _tts.stop();
    final parts = preferVoice.split('__SEP__');
    if (preferVoice.isNotEmpty && parts.length == 2) {
      if (parts[1].isNotEmpty) await _tts.setLanguage(parts[1]);
      await _tts.setVoice({'name': parts[0], 'locale': parts[1]});
      await _tts.setSpeechRate(kSourceSpeechRate);
      await _tts.setPitch(1.0);
    } else {
      if (locale != null) await _tts.setLanguage(locale);
      await _tts.setSpeechRate(kSourceSpeechRate);
      // Pick a gendered voice if one exists, but never pitch-shift to fake one:
      // the engine's pitch-shift adds grainy artefacts to every clip.
      await _applyGenderedVoice(locale, gender);
      await _tts.setPitch(1.0);
    }
    await _tts.awaitSynthCompletion(true);
    // flutter_tts.synthesizeToFile occasionally hangs on Android (the engine's
    // completion callback never fires), which would leave the whole prep stuck
    // with no way for the per-item catch to kick in. Wrap it in a hard timeout
    // so a hung synthesis becomes a normal per-item failure that gets skipped.
    try {
      await _tts.synthesizeToFile(text, file.path, true).timeout(const Duration(seconds: 8));
    } on TimeoutException {
      // Best-effort: cancel any in-flight engine work so the next call starts clean.
      try { await _tts.stop(); } catch (_) {}
      throw Exception('TTS synthesis timed out');
    }
    if (!await file.exists()) throw Exception('TTS synthesis produced no file');
    // Prepend 500ms silence — the audio path drops the first frames at a clip
    // boundary / cold start. Keeps the engine's native rate (mono).
    await _normalizeSynthWav(file);
    return file.path;
  }

  /// Prepends [padMs] of silence to a synthesized WAV (the audio path drops the
  /// first frames at a clip boundary / cold start). Keeps the engine's native
  /// sample rate — `parseWavPcm16` already collapses to one (mono) channel, and
  /// downsampling here used naive decimation (no anti-alias filter), which made
  /// the voice sound coarse. Best-effort: untouched if unparseable.
  Future<void> _normalizeSynthWav(File f, {int padMs = 500}) async {
    try {
      final parsed = parseWavPcm16(await f.readAsBytes());
      if (parsed == null) return;
      final sil = silencePcm16(parsed.rate, padMs);
      final combined = Int16List(sil.length + parsed.samples.length)
        ..setAll(0, sil)
        ..setAll(sil.length, parsed.samples);
      await f.writeAsBytes(pcm16MonoToWav(combined, parsed.rate), flush: true);
    } catch (_) {}
  }

  /// Same 10k cap + LRU eviction the Google/Gemini caches use, for the device
  /// synthesis cache.
  Future<void> _evictSynthIfFull(Directory dir, {int cap = 10000, int batch = 200}) async {
    try {
      final files = (await dir.list(followLinks: false).toList()).whereType<File>().toList();
      if (files.length < cap) return;
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      var deleted = 0;
      for (final fi in files) {
        if (deleted >= batch) break;
        try {
          await fi.delete();
          deleted++;
        } catch (_) {}
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    katalavenoAudio.unbind(this);
    _tts.stop();
    _autoOrdinalSub?.cancel();
    _autoPlaylist.dispose();
    if (_autoMode) SentenceBankForegroundService.stop();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final reloadToken = context.select<AppState, int>((s) => s.sentenceBankReloadToken);
    if (reloadToken != _lastReloadToken && !_loading) {
      _lastReloadToken = reloadToken;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _loadBank(); });
    }

    // History changed (e.g. a new active word's notification was tapped) →
    // refresh just the "Active words" subject, incrementally.
    final historyRevision = context.select<AppState, int>((s) => s.historyRevision);
    if (historyRevision != _lastHistoryRevision && !_loading) {
      _lastHistoryRevision = historyRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _refreshActiveWords(); });
    }

    final shuffle = context.select<AppState, bool>((s) => s.settings.sentenceBankShuffle);
    if (shuffle != _lastShuffle) {
      _lastShuffle = shuffle;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _sentenceIndex = 0;
          if (shuffle) _generateShuffledOrder(); else _shuffledOrder = null;
          _sourceSentence = _currentSource();
          _translatedSentence = null;
          _showTranslation = false;
        });
        // The play order is part of the playlist signature — rebuild so the
        // change takes effect while auto mode is running.
        if (_autoMode) _buildOrResumePlaylist(play: true);
      });
    }

    // Apply playback-affecting setting changes (speak-source, voice, gender,
    // target language, repeat count, pauses) live while auto mode is running.
    // The sig check inside _buildOrResumePlaylist no-ops if nothing relevant
    // actually changed.
    final autoCfg = context.select<AppState, String>((s) => [
          s.settings.sentenceBankSpeakSource,
          s.settings.sentenceBankSourceVoice,
          s.settings.sentenceBankVoiceGender,
          s.settings.targetLanguage,
          s.sentenceBankResolvedTtsRepeatCount,
          s.settings.sentenceBankSourcePauseOverride,
          s.settings.sentenceBankTtsRepeatDelayOverride,
          s.settings.sentenceBankRepeatSourceBetween,
        ].join('¦'));
    if (autoCfg != _lastAutoCfg) {
      _lastAutoCfg = autoCfg;
      if (_autoMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _autoMode) _buildOrResumePlaylist(play: true);
        });
      }
    }

    if (_loading) return const Center(child: CircularProgressIndicator());

    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48),
              const SizedBox(height: 12),
              Text('Failed to load sentence bank:\n$_loadError', textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(onPressed: _loadBank, icon: const Icon(Icons.refresh), label: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final bank = _bank!;
    final settings = context.select<AppState, ({String targetLang, int repeatCount})>(
      (s) => (targetLang: s.settings.targetLanguage, repeatCount: s.sentenceBankResolvedTtsRepeatCount),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 60),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top row: subject picker + source-voice picker.
          Row(
            children: [
              Expanded(child: _buildSubjectPicker(bank)),
              if (_ttsSupported()) ...[
                const SizedBox(width: 8),
                _buildVoiceButton(),
              ],
            ],
          ),
          SizedBox(height: 20,),
          const SizedBox(height: 4),
          // Sentence cards scroll in available space.
          Expanded(
            child: SingleChildScrollView(
              child: _buildSentenceCard(settings.targetLang),
            ),
          ),
          const SizedBox(height: 10),
          // Controls always at the same vertical position.
          _buildControls(settings.repeatCount),
        ],
      ),
    );
  }

  Widget _buildSubjectPicker(SentenceBank bank) {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Subjects',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: InkWell(
        onTap: _autoMode ? null : _openSubjectPicker,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _selectionSummary(),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _autoMode ? Theme.of(context).disabledColor : null,
                  ),
                ),
              ),
              Icon(Icons.arrow_drop_down,
                  color: _autoMode ? Theme.of(context).disabledColor : null),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens a picker of the device's installed voices for the source language
  /// (e.g. English US/UK/AU, male/female). The chosen voice is used to
  /// pre-render the source clips; changing it re-synthesizes them.
  Widget _buildVoiceButton() {
    return IconButton.outlined(
      tooltip: 'Source voice',
      icon: const Icon(Icons.record_voice_over_outlined),
      onPressed: _autoMode ? null : _showVoicePicker,
    );
  }

  Future<void> _showVoicePicker() async {
    final state = context.read<AppState>();
    final sourceLang = _bank?.language ?? 'English';
    final code = _ttsLangCode(sourceLang);

    List<dynamic> raw;
    try {
      raw = (await _tts.getVoices) as List? ?? const [];
    } catch (_) {
      raw = const [];
    }
    final matches = <Map>[
      for (final v in raw)
        if (v is Map && (v['locale'] as String? ?? '').toLowerCase().startsWith(code)) v,
    ]..sort((a, b) => '${a['locale']}'.compareTo('${b['locale']}'));

    final byLocale = <String, List<Map>>{};
    for (final v in matches) {
      byLocale.putIfAbsent((v['locale'] as String? ?? '').toString(), () => []).add(v);
    }

    // Order sections: device region first (if it speaks this language), then
    // US → UK(GB) → AU, then the rest alphabetically.
    final regionPrefs = <String>[];
    final dev = WidgetsBinding.instance.platformDispatcher.locale;
    if (dev.languageCode.toLowerCase() == code && (dev.countryCode ?? '').isNotEmpty) {
      regionPrefs.add(dev.countryCode!.toLowerCase());
    }
    for (final r in const ['us', 'gb', 'au']) {
      if (!regionPrefs.contains(r)) regionPrefs.add(r);
    }
    int regionRank(String locale) {
      final rp = locale.toLowerCase().split(RegExp('[-_]'));
      final i = regionPrefs.indexOf(rp.length > 1 ? rp[1] : '');
      return i >= 0 ? i : regionPrefs.length;
    }
    final orderedLocales = byLocale.keys.toList()
      ..sort((a, b) {
        final r = regionRank(a).compareTo(regionRank(b));
        return r != 0 ? r : a.compareTo(b);
      });

    if (!mounted) return;
    final current = state.settings.sentenceBankSourceVoice;
    await showDialog<void>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Source voice — $sourceLang'),
        children: [
          ListTile(
            dense: true,
            title: const Text('Automatic'),
            trailing: current.isEmpty
                ? const Icon(Icons.check)
                : IconButton(
                    icon: const Icon(Icons.download_outlined),
                    tooltip: 'Use & download',
                    onPressed: () { Navigator.pop(ctx); _selectVoiceAndGenerate(''); },
                  ),
          ),
          if (byLocale.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No installed voices found for this language.'),
            ),
          for (final loc in orderedLocales)
            ExpansionTile(
              title: Text('$loc  (${byLocale[loc]!.length})'),
              children: [
                for (var i = 0; i < byLocale[loc]!.length; i++)
                  Builder(builder: (_) {
                    final v = byLocale[loc]![i];
                    final id = '${v['name']}__SEP__$loc';
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 32, right: 16),
                      leading: IconButton(
                        icon: const Icon(Icons.play_arrow_outlined),
                        tooltip: 'Preview',
                        onPressed: () => _previewVoice(v),
                      ),
                      title: Text('Voice ${i + 1}'),
                      trailing: id == current
                          ? const Icon(Icons.check)
                          : IconButton(
                              icon: const Icon(Icons.download_outlined),
                              tooltip: 'Use & download',
                              onPressed: () { Navigator.pop(ctx); _selectVoiceAndGenerate(id); },
                            ),
                    );
                  }),
              ],
            ),
        ],
      ),
    );
  }

  /// Speaks a sample of the current source sentence in voice [v] (live, instant)
  /// so the user can compare voices before committing.
  Future<void> _previewVoice(Map v) async {
    try {
      await _autoPlaylist.stop();
      await _tts.stop();
      final loc = (v['locale'] as String? ?? '').toString();
      if (loc.isNotEmpty) await _tts.setLanguage(loc);
      await _tts.setVoice({'name': (v['name'] as String? ?? ''), 'locale': loc});
      await _tts.setSpeechRate(kSourceSpeechRate);
      await _tts.setPitch(1.0);
      await _tts.speak(_currentSource() ?? 'This is a sample sentence.');
    } catch (_) {}
  }

  /// Commits the device source voice [voiceId] ('' = automatic) and regenerates
  /// the audio immediately so the next Play is instant.
  Future<void> _selectVoiceAndGenerate(String voiceId) async {
    final state = context.read<AppState>();
    await state.saveSettingsOnly(state.settings.copyWith(sentenceBankSourceVoice: voiceId));
    _preparedSig = null; // force a rebuild with the new voice
    await _buildOrResumePlaylist(play: false);
    if (mounted) lpSnack(context, 'Voice ready.', 2500);
  }

  Widget _buildSentenceCard(String targetLang) {
    final src = _sourceSentence;
    if (src == null) return const Text('No sentences in this subject.', textAlign: TextAlign.center);

    final sents = _currentSentences();
    final total = sents.length;
    final idx = total > 0 ? (_sentenceIndex % total) + 1 : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            if (_batchRunning && _batchTotal > 0)
              Text('${_batchAttempt > 0 ? 'Retrying' : 'Translating'} $_batchDone/$_batchTotal…',
                  style: Theme.of(context).textTheme.labelSmall)
            else if (_batchRunning)
              Text('Preparing translations…', style: Theme.of(context).textTheme.labelSmall)
            else
              const SizedBox.shrink(),
            Text('$idx / $total', style: Theme.of(context).textTheme.labelSmall),
          ],
        ),
        // const SizedBox(height: 4),

        Card(
          elevation: 0,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0,0,0,0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _bank!.language,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                ),
                const SizedBox(height: 8),
                Text(SbSentence.display(src), style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
        ),

        if (_showTranslation) ...[
          const SizedBox(height: 6),
          Card(
            elevation: 0,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0,0,0,0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    targetLang,
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(height: 8),
                  _translating
                      ? const SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : Text(_translatedSentence ?? '', style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          ),
        ] else if (_translating) ...[
          const SizedBox(height: 6),
          const Center(child: CircularProgressIndicator()),
        ],
      ],
    );
  }

  Widget _navBtn({
    required IconData icon,
    required VoidCallback? onPressed,
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    return Expanded(
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          minimumSize: const Size(0, 56),
          padding: EdgeInsets.zero,
        ),
        child: Icon(icon, size: 36),
      ),
    );
  }

  Widget _buildControls(int repeatCount) {
    final ttsOk = _ttsSupported();

    final navRow = Row(
      children: [
        _navBtn(
          icon: Icons.skip_previous,
          onPressed: _autoMode ? _autoPrevious : _previousSentence,
        ),
        const SizedBox(width: 8),
        _navBtn(
          icon: Icons.skip_next,
          onPressed: _autoMode ? _autoNext : _nextSentence,
        ),
        const SizedBox(width: 8),
        _navBtn(
          icon: _autoMode ? Icons.stop_circle_outlined : Icons.play_circle_outline,
          onPressed: _autoMode ? _stopAuto : _startAuto,
          backgroundColor: _autoMode ? Theme.of(context).colorScheme.error : null,
          foregroundColor: _autoMode ? Theme.of(context).colorScheme.onError : null,
        ),
      ],
    );

    if (_autoMode) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _autoPreparing
                ? 'Preparing audio… $_prepDone/$_prepTotal'
                : 'Auto mode — playing',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          navRow,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_autoPreparing) ...[
          Row(
            children: [
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 12),
              Text('Preparing audio… $_prepDone/$_prepTotal',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _batchRunning ? null : _onTranslateButton,
                icon: (_translating || _batchRunning)
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.translate),
                label: Text(_batchRunning && _batchTotal > 0
                    ? '${_batchAttempt > 0 ? 'Retrying' : 'Translating'} $_batchDone/$_batchTotal'
                    : (_showTranslation && _translatedSentence != null ? 'Re-translate' : 'Translate')),
              ),
            ),
            if (ttsOk) ...[
              const SizedBox(width: 8),
              IconButton.outlined(
                tooltip: 'Speak translation',
                onPressed: _ttsPlaying ? null : _speakTranslation,
                icon: _ttsPlaying
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.volume_up),
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
        navRow,
      ],
    );
  }
}
