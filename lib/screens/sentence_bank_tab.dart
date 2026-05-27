import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/sentence_bank.dart';
import '../services/auto_playlist_controller.dart';
import '../services/google_translate_tts.dart';
import '../services/sentence_bank_foreground_service.dart';
import '../services/sentence_bank_service.dart';
import '../state/app_state.dart';
import '../widgets.dart';

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
  late final _autoPlaylist = AutoPlaylistController(_googleTts);
  StreamSubscription<int>? _autoOrdinalSub;
  List<String> _autoTranslations = [];
  bool _autoPreparing = false;
  // Languages where flutter_tts gives flat/wrong intonation for questions.
  // For these, we prefer the Google Translate audio endpoint.
  static const _googleTtsLanguages = {'el'};

  SentenceBank? _bank;
  String? _loadError;
  bool _loading = true;

  String? _selectedSubject;
  int _sentenceIndex = 0;
  List<String> _sortedSubjectNames = [];

  String? _sourceSentence;
  String? _translatedSentence;
  bool _showTranslation = false;
  bool _translating = false;

  // Batch translation progress for the current subject.
  int _batchDone = 0;
  int _batchTotal = 0;
  bool _batchRunning = false;

  // Voice strategy: null = not checked yet, true = real gendered voice available
  // for the target language (use it for both), false = use pitch for both.
  bool? _useRealVoice;

  // Auto-mode
  bool _autoMode = false;
  Timer? _autoTimer;
  bool _ttsPlaying = false;
  bool _autoSpeakingSource = false; // true while speaking the source sentence in auto mode
  bool _announcingRetry = false;    // true while speaking the "retrying translation" announcement
  int _ttsRepeatsDone = 0; // how many times we've played the translation TTS this sentence

  late SentenceBankService _service;
  int _lastReloadToken = -1;
  bool _lastShuffle = false;
  bool _initialized = false;

  // When shuffle is on, this holds the permuted sentence indices.
  // _sentenceIndex is then a position within this list, not a raw sentence index.
  List<int>? _shuffledOrder;

  @override
  void initState() {
    super.initState();
    _tts.setCompletionHandler(_onTtsComplete);
    _googleTts.onComplete = _onTtsComplete;
    _tts.setCancelHandler(() {
      if (!mounted) return;
      setState(() => _ttsPlaying = false);
    });
  }

  void _onTtsComplete() {
    if (!mounted) return;
    setState(() => _ttsPlaying = false);
    if (!_autoMode) return;
    if (_announcingRetry) {
      // Retry announcement finished — the backoff timer is already running.
      setState(() => _announcingRetry = false);
      return;
    }
    if (_autoSpeakingSource) {
      // Source TTS finished — pause then reveal translation.
      setState(() => _autoSpeakingSource = false);
      _autoTimer?.cancel();
      final override = context.read<AppState>().settings.sentenceBankSourcePauseOverride;
      final pause = override ?? _bank?.autoSourcePause ?? 1;
      _autoTimer = Timer(Duration(seconds: pause), _autoRevealTranslation);
    } else {
      // Translation TTS finished — check if we need to repeat.
      final repeatCount = context.read<AppState>().sentenceBankResolvedTtsRepeatCount;
      if (_ttsRepeatsDone < repeatCount - 1) {
        // More repeats needed — wait tts_repeat_delay then speak again.
        _autoTimer?.cancel();
        final override = context.read<AppState>().settings.sentenceBankTtsRepeatDelayOverride;
        final delay = override ?? _bank?.ttsRepeatDelay ?? 1;
        _autoTimer = Timer(Duration(seconds: delay), () {
          if (!_autoMode || !mounted) return;
          _ttsRepeatsDone++;
          _speakTranslation();
        });
      } else {
        _scheduleNextInAuto();
      }
    }
  }

  /// Speaks [text] using Google Translate's audio endpoint when the locale's
  /// language is in [_googleTtsLanguages] (e.g. Greek — flutter_tts gives flat
  /// intonation on questions). Falls back to flutter_tts on any failure.
  /// Returns true if Google TTS was used and started playing successfully.
  Future<bool> _speakViaGoogleIfPreferred(String text, String? locale) async {
    if (locale == null) return false;
    final lang = locale.toLowerCase().split(RegExp('[-_]')).first;
    if (!_googleTtsLanguages.contains(lang)) return false;
    if (!_googleTts.canSpeak(text)) return false;
    try {
      await _tts.stop();
      await _googleTts.speak(text, lang);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      _lastReloadToken = context.read<AppState>().sentenceBankReloadToken;
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

      context.read<AppState>().updateSentenceBankYamlSourcePause(bank.autoSourcePause);
      context.read<AppState>().updateSentenceBankYamlTtsRepeatDelay(bank.ttsRepeatDelay);
      context.read<AppState>().updateSentenceBankYamlTtsRepeatCount(bank.ttsRepeatCount);
      final sorted = await _service.sortedSubjects(bank.subjectNames);
      // Keep the in-memory subject if still valid; otherwise restore from the
      // dedicated last-subject key, then fall back to recency-sorted first.
      final currentSubject = _selectedSubject;
      final lastSubject = currentSubject == null
          ? await _service.loadLastSubject(bank.subjectNames)
          : null;
      final subject = (currentSubject != null && bank.subjectNames.contains(currentSubject))
          ? currentSubject
          : lastSubject ?? sorted.firstOrNull;
      final preservingSubject = subject == currentSubject;

      setState(() {
        _bank = bank;
        _sortedSubjectNames = sorted;
        _loading = false;
        if (subject != null) {
          _selectedSubject = subject;
          if (!preservingSubject) {
            _sentenceIndex = 0;
            _sourceSentence = _currentSentences().firstOrNull;
            _translatedSentence = null;
            _showTranslation = false;
          }
          if (shuffle) _generateShuffledOrder(); else _shuffledOrder = null;
        }
      });

      // Persist the auto-selected subject so the next cold start restores it.
      if (subject != null && currentSubject == null) {
        _service.recordSubjectSelected(subject);
      }

      // Restore saved position only when switching to a different subject.
      if (subject != null && !preservingSubject) {
        final pos = await _service.loadPosition(subject);
        if (!mounted) return;
        final sents = bank.sentencesFor(subject);
        if (sents.isNotEmpty && pos > 0) {
          setState(() {
            final order = _shuffledOrder;
            if (order != null) {
              final p = order.indexOf(pos % sents.length);
              _sentenceIndex = p >= 0 ? p : 0;
            } else {
              _sentenceIndex = pos % sents.length;
            }
            _sourceSentence = _currentSource();
          });
        }
        _loadCachedTranslationForCurrent();
      } else if (subject != null) {
        _loadCachedTranslationForCurrent();
      }

      _startBatchTranslation();

      final warning = _service.lastFetchWarning;
      if (warning != null && mounted) lpSnack(context, warning, 6000);
    } catch (e) {
      if (!mounted) return;
      setState(() { _loadError = e.toString(); _loading = false; });
    }
  }

  List<String> _currentSentences() {
    final subj = _selectedSubject;
    if (subj == null || _bank == null) return [];
    return _bank!.sentencesFor(subj);
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

  void _selectSubject(String? name) {
    if (name == null) return;
    _stopAuto();
    final shuffle = context.read<AppState>().settings.sentenceBankShuffle;
    setState(() {
      _selectedSubject = name;
      _sentenceIndex = 0;
      if (shuffle) _generateShuffledOrder(); else _shuffledOrder = null;
      _sourceSentence = _currentSource();
      _translatedSentence = null;
      _showTranslation = false;
      _batchDone = 0;
      _batchTotal = 0;
    });
    // Record selection and refresh sorted list.
    _service.recordSubjectSelected(name).then((_) async {
      if (!mounted || _bank == null) return;
      final sorted = await _service.sortedSubjects(_bank!.subjectNames);
      if (mounted) setState(() => _sortedSubjectNames = sorted);
    });
    // Restore saved position for this subject.
    _service.loadPosition(name).then((pos) {
      if (!mounted) return;
      final sents = _currentSentences();
      if (sents.isNotEmpty && pos > 0) {
        setState(() {
          final order = _shuffledOrder;
          if (order != null) {
            final p = order.indexOf(pos % sents.length);
            _sentenceIndex = p >= 0 ? p : 0;
          } else {
            _sentenceIndex = pos % sents.length;
          }
          _sourceSentence = _currentSource();
        });
      }
      _loadCachedTranslationForCurrent();
    });
    _startBatchTranslation();
  }

  Future<void> _loadCachedTranslationForCurrent() async {
    final src = _sourceSentence;
    if (src == null || _bank == null) return;
    final state = context.read<AppState>();
    final cached = await _service.getCached(
      sentence: src,
      sourceLang: _bank!.language,
      targetLang: state.settings.targetLanguage,
    );
    if (!mounted) return;
    if (cached != null) setState(() => _translatedSentence = cached);
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

    setState(() { _batchRunning = true; _batchDone = 0; _batchTotal = 0; });

    try {
      final failed = await _service.translateAllUncached(
        sentences: sentences,
        sourceLang: sourceLang,
        targetLang: targetLang,
        apiKey: apiKey,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() { _batchDone = done; _batchTotal = total; });
          _loadCachedTranslationForCurrent();
        },
      );
      if (failed > 0 && mounted) {
        lpSnack(context, '$failed sentence${failed == 1 ? '' : 's'} could not be translated — tap "Clear translations" in Settings to retry.', 8000);
      }
    } catch (e) {
      if (mounted) lpSnack(context, 'Batch translation error: $e', 6000);
    } finally {
      if (mounted) {
        setState(() { _batchRunning = false; _batchDone = 0; _batchTotal = 0; });
        _loadCachedTranslationForCurrent();
      }
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
    final subject = _selectedSubject;
    if (subject != null) {
      final order = _shuffledOrder;
      _service.savePosition(subject, order != null ? order[newIndex % order.length] : newIndex);
    }
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
    final subject = _selectedSubject;
    if (subject != null) {
      final order = _shuffledOrder;
      _service.savePosition(subject, order != null ? order[newIndex % order.length] : newIndex);
    }
  }

  void _autoPrevious() {
    if (!_autoMode || !mounted) return;
    _autoPlaylist.previous();
  }

  void _autoNext() {
    if (!_autoMode || !mounted) return;
    _autoPlaylist.next();
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
        sentence: src,
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
      lpSnack(context, 'Translation failed: $e', 6000);
      return null;
    }
  }

  Future<void> _onTranslateButton() async {
    if (!_batchRunning) _startBatchTranslation();
    await _getTranslation();
    if (!mounted) return;
    setState(() => _showTranslation = true);
  }

  // ── TTS ───────────────────────────────────────────────────────────────────

  /// Returns true if a real gendered voice exists for the *target* language.
  /// Result is cached for the session so it's only probed once.
  Future<bool> _resolveVoiceStrategy(String? targetLocale, String gender) async {
    if (_useRealVoice != null) return _useRealVoice!;
    _useRealVoice = await _applyGenderedVoice(targetLocale, gender);
    // If we applied a voice above, undo it — we just wanted the boolean result.
    // The actual voice will be applied again before speaking.
    return _useRealVoice!;
  }

  Future<void> _speakTranslation() async {
    if (!_ttsSupported()) {
      lpSnack(context, 'TTS is not available on this platform.', 4000);
      return;
    }
    final translation = await _getTranslation();
    if (translation == null) return;
    if (!mounted) return;

    final settings = context.read<AppState>().settings;
    final locale = _localeForLanguage(settings.targetLanguage);
    final gender = settings.sentenceBankVoiceGender;

    try {
      setState(() => _ttsPlaying = true);
      if (await _speakViaGoogleIfPreferred(translation, locale)) return;

      await _tts.stop();
      if (locale != null) await _tts.setLanguage(locale);
      await _tts.setSpeechRate(0.45);

      // Use a real voice only if the target language actually has one —
      // so source and target always sound like the same "gender strategy".
      final useReal = await _resolveVoiceStrategy(locale, gender);
      if (useReal) {
        await _applyGenderedVoice(locale, gender);
        await _tts.setPitch(1.0);
      } else {
        await _tts.setPitch(gender == 'male' ? (_bank?.ttsPitchLow ?? 0.85) : (_bank?.ttsPitchHigh ?? 1.1));
      }

      await _tts.speak(translation);
    } catch (e) {
      if (!mounted) return;
      setState(() => _ttsPlaying = false);
      lpSnack(context, 'TTS failed: $e', 6000);
    }
  }

  /// Tries to select a voice matching [gender] for [locale].
  /// Returns true if a matching voice was found and set, false otherwise.
  Future<bool> _applyGenderedVoice(String? locale, String gender) async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List || raw.isEmpty) return false;

      final langPrefix = locale?.substring(0, 2).toLowerCase();

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

        int score = 0;

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

  Future<void> _speakSource() async {
    final src = _sourceSentence;
    if (src == null || !_ttsSupported()) return;
    final settings = context.read<AppState>().settings;
    final sourceLang = _bank?.language ?? '';
    final sourceLocale = _localeForLanguage(sourceLang);
    final targetLocale = _localeForLanguage(settings.targetLanguage);
    final gender = settings.sentenceBankVoiceGender;
    try {
      await _tts.stop();
      if (sourceLocale != null) await _tts.setLanguage(sourceLocale);
      await _tts.setSpeechRate(0.45);
      // Mirror the same voice strategy as the target language for consistency.
      final useReal = await _resolveVoiceStrategy(targetLocale, gender);
      if (useReal) {
        await _applyGenderedVoice(sourceLocale, gender);
        await _tts.setPitch(1.0);
      } else {
        await _tts.setPitch(gender == 'male' ? (_bank?.ttsPitchLow ?? 0.85) : (_bank?.ttsPitchHigh ?? 1.1));
      }
      setState(() { _ttsPlaying = true; _autoSpeakingSource = true; });
      await _tts.speak(src);
    } catch (e) {
      setState(() { _ttsPlaying = false; _autoSpeakingSource = false; });
    }
  }

  // ── Auto mode ─────────────────────────────────────────────────────────────

  Future<void> _startAuto() async {
    final sents = _currentSentences();
    if (sents.isEmpty) return;
    final state = context.read<AppState>();
    final settings = state.settings;

    // Build the sentence list in play order (shuffle order if on).
    final order = _shuffledOrder;
    final ordered = [for (var o = 0; o < sents.length; o++) sents[order != null ? order[o % order.length] : o]];

    setState(() { _autoMode = true; _autoPreparing = true; });
    if (mounted) lpSnack(context, 'Preparing audio…', 4000);

    try {
      // Translate the whole subject (cached entries return instantly).
      final translations = await _service.translateBatch(
        sentences: ordered,
        sourceLang: _bank!.language,
        targetLang: settings.targetLanguage,
        apiKey: settings.aiApiKey,
      );
      if (!mounted || !_autoMode) return;
      _autoTranslations = translations;

      final locale = _localeForLanguage(settings.targetLanguage);
      final lang = (locale ?? 'el').toLowerCase().split(RegExp('[-_]')).first;

      _autoOrdinalSub?.cancel();
      _autoOrdinalSub = _autoPlaylist.currentOrdinalStream.listen(_onAutoOrdinal);

      await _autoPlaylist.start(
        translations: translations,
        langCode: lang,
        repeatCount: state.sentenceBankResolvedTtsRepeatCount,
        preDelaySec: 0,
        repeatDelaySec: settings.sentenceBankTtsRepeatDelayOverride ?? _bank?.ttsRepeatDelay ?? 1,
        postDelaySec: _bank?.autoPostTtsDelay ?? 2,
        startOrdinal: _sentenceIndex,
      );
      if (mounted) setState(() => _autoPreparing = false);
    } catch (e) {
      if (!mounted) return;
      setState(() { _autoPreparing = false; _autoMode = false; });
      lpSnack(context, 'Could not start auto mode: $e', 6000);
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
  }

  void _stopAuto() {
    _autoTimer?.cancel();
    _autoTimer = null;
    _tts.stop();
    _googleTts.stop();
    _autoOrdinalSub?.cancel();
    _autoOrdinalSub = null;
    _autoPlaylist.stop();
    _saveAutoPosition();
    setState(() {
      _autoMode = false;
      _autoPreparing = false;
      _ttsPlaying = false;
      _autoSpeakingSource = false;
      _ttsRepeatsDone = 0;
    });
    SentenceBankForegroundService.stop();
  }

  void _saveAutoPosition() {
    final subject = _selectedSubject;
    if (subject == null) return;
    final sents = _currentSentences();
    if (sents.isEmpty) return;
    final order = _shuffledOrder;
    final actual = order != null ? order[_sentenceIndex % order.length] : _sentenceIndex % sents.length;
    _service.savePosition(subject, actual);
  }

  void _scheduleTranslationReveal() {
    _autoTimer?.cancel();
    final speakSource = context.read<AppState>().settings.sentenceBankSpeakSource;
    if (speakSource && _ttsSupported()) {
      // Speak source immediately — no initial delay.
      // Completion handler waits autoSourcePause then calls _autoRevealTranslation.
      _speakSource();
    } else {
      final delay = _bank?.autoShowDelay ?? 3;
      _autoTimer = Timer(Duration(seconds: delay), _autoRevealTranslation);
    }
  }

  Future<void> _autoRevealTranslation() async {
    if (!_autoMode || !mounted) return;

    // Retry on transient failures (e.g. 429) so a walking user doesn't get
    // skipped sentences. Backoff: 15s, 30s, 60s, 120s. Bail out if auto stops.
    String? translation;
    const backoffs = [3, 6, 12, 24];
    for (var attempt = 0; attempt <= backoffs.length; attempt++) {
      translation = await _getTranslation();
      if (!mounted || !_autoMode) return;
      if (translation != null) break;
      if (attempt == backoffs.length) break;
      await _announceRetry();
      if (!mounted || !_autoMode) return;
      _autoTimer?.cancel();
      final waited = await _waitInAuto(backoffs[attempt]);
      if (!waited) return; // auto cancelled or unmounted
    }

    setState(() { _showTranslation = true; });
    _ttsRepeatsDone = 0; // reset for this sentence

    if (translation != null && _ttsSupported()) {
      await _speakTranslation();
    } else {
      _scheduleNextInAuto();
    }
  }

  /// Speaks "Retrying translation" in the source-language TTS so a walking
  /// user knows the silence is because of a transient failure, not a stuck app.
  Future<void> _announceRetry() async {
    if (!_ttsSupported()) return;
    final sourceLocale = _localeForLanguage(_bank?.language ?? '');
    try {
      await _tts.stop();
      if (sourceLocale != null) await _tts.setLanguage(sourceLocale);
      await _tts.setSpeechRate(0.45);
      await _tts.setPitch(1.0);
      if (!mounted || !_autoMode) return;
      setState(() { _announcingRetry = true; _ttsPlaying = true; });
      await _tts.speak('Retrying translation');
    } catch (_) {
      if (!mounted) return;
      setState(() { _announcingRetry = false; _ttsPlaying = false; });
    }
  }

  /// Sleeps for [seconds] while in auto mode. Returns false if auto mode
  /// was cancelled or the widget was unmounted during the wait.
  Future<bool> _waitInAuto(int seconds) async {
    final completer = Completer<bool>();
    _autoTimer = Timer(Duration(seconds: seconds), () {
      if (!completer.isCompleted) completer.complete(mounted && _autoMode);
    });
    final ok = await completer.future;
    return ok;
  }

  void _scheduleNextInAuto() {
    if (!_autoMode || !mounted) return;
    _autoTimer?.cancel();
    final delay = _bank?.autoPostTtsDelay ?? 2;
    _autoTimer = Timer(Duration(seconds: delay), _autoAdvance);
  }

  void _autoAdvance() {
    if (!_autoMode || !mounted) return;
    _nextSentence();
    _scheduleTranslationReveal();
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _tts.stop();
    _googleTts.dispose();
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
      });
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
    final settings = context.select<AppState, ({String targetLang, String gender, int repeatCount})>(
      (s) => (targetLang: s.settings.targetLanguage, gender: s.settings.sentenceBankVoiceGender, repeatCount: s.sentenceBankResolvedTtsRepeatCount),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 60),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top row: subject picker + gender toggle.
          Row(
            children: [
              Expanded(child: _buildSubjectPicker(bank)),
              if (_ttsSupported()) ...[
                const SizedBox(width: 8),
                _buildGenderToggle(settings.gender),
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
        labelText: 'Subject',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: _selectedSubject,
          isExpanded: true,
          isDense: true,
          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHigh,
          items: _sortedSubjectNames.map((name) {
            final isMeta = bank.subjects[name] is MetaSubject;
            return DropdownMenuItem(
              value: name,
              child: Row(
                children: [
                  Icon(
                    isMeta ? Icons.folder_outlined : Icons.list_alt_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(name, overflow: TextOverflow.ellipsis)),
                ],
              ),
            );
          }).toList(),
          onChanged: _autoMode ? null : _selectSubject,
        ),
      ),
    );
  }

  /// A compact single icon button that toggles between lower and higher pitch voice.
  Widget _buildGenderToggle(String gender) {
    final isLow = gender == 'male';
    final state = context.read<AppState>();
    final color = isLow
        ? Theme.of(context).colorScheme.primary
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return IconButton.outlined(
      tooltip: isLow ? 'Voice: Lower pitch (tap to switch)' : 'Voice: Higher pitch (tap to switch)',
      icon: Icon(Icons.graphic_eq, color: color),
      style: isLow
          ? IconButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              side: BorderSide(color: Theme.of(context).colorScheme.primary),
            )
          : null,
      onPressed: () {
        setState(() => _useRealVoice = null); // re-probe on next speech
        final s = state.settings;
        state.updateSettings(s.copyWith(sentenceBankVoiceGender: isLow ? 'female' : 'male'));
      },
    );
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
              Text('Translating $_batchDone/$_batchTotal…', style: Theme.of(context).textTheme.labelSmall)
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
                Text(src, style: Theme.of(context).textTheme.titleMedium),
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
            _autoPreparing ? 'Preparing audio…' : 'Auto mode — playing (works when locked)',
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
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_showTranslation && !_batchRunning) ? null : _onTranslateButton,
                icon: (_translating || _batchRunning)
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.translate),
                label: Text(_batchRunning && _batchTotal > 0
                    ? 'Translating $_batchDone/$_batchTotal'
                    : 'Translate'),
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
