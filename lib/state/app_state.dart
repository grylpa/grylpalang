import 'dart:async';
import 'dart:convert';
// import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../main.dart';
import '../models/app_settings.dart';
import '../models/history_entry.dart';
import '../models/notification_snapshot.dart';
import '../models/scheduled_sentence.dart';
import '../models/word_entry.dart';
import '../models/word_sentence.dart';
import '../models/word_type.dart';
import '../services/ai_service.dart';
import '../services/app_storage.dart';
import '../services/google_translate_tts.dart';
import '../services/notification_service.dart';
import '../services/sentence_bank_service.dart';
import '../widgets.dart';

class AppState extends ChangeNotifier {
  late AppStorage _storage;
  AppSettings _settings = AppSettings.defaults();
  List<WordEntry> _words = [];
  // List<WordEntry> _active = [];
  bool paused = false;
  int lastTokenScrolledTo = -1;
  bool initialized = false;

  List<int> _predictionQueue = [];
  int _predictionQueuePos = 0;
  int _predictionSeed = 0;

  // History of tapped notifications (newest first).
  final List<HistoryEntry> _history = [];

  List<HistoryEntry> get history => List.unmodifiable(_history);

  // Bumped whenever the *content* of history changes (a new tapped sentence is
  // added, or history is cleared). The Sentence Bank tab watches this to refresh
  // its auto-generated "Active words" subject incrementally.
  int historyRevision = 0;

  // Limit: maximum sentences kept in history (across all entries).
  static const int kMaxHistorySentences = 20;

  // Global progress index, derived from snapshots and time.
  //
  // We treat each notification snapshot as belonging to an integer "step".
  // The current step is 1 + the largest step whose planned fire time is in
  // the past. If nothing has fired yet, it's 0.
  int get _currentStep {
    if (_snapshots.isEmpty) return 0;

    final now = DateTime.now();
    final firedSteps = _snapshots.where((s) => !s.firedAt.isAfter(now)).map((s) => s.step).toList();

    if (firedSteps.isEmpty) return 0;
    return firedSteps.reduce(max) + 1;
  }

  int get currentStep => _currentStep;

  bool showApiKey = false;

  int sentenceBankReloadToken = 0;

  /// Bumped to ask the Settings screen to expand its "AI engine" card and scroll
  /// it into view (used at startup when no API key is set so the user is pointed
  /// straight at where to paste one). SettingsScreen watches this via select.
  int aiEngineFocusToken = 0;
  void requestAiEngineFocus() {
    aiEngineFocusToken++;
    notifyListeners();
  }

  /// The auto_source_pause value from the currently loaded YAML bank (default 1).
  /// Updated by SentenceBankTab whenever a bank is loaded.
  int sentenceBankYamlSourcePause = 1;
  void updateSentenceBankYamlSourcePause(int value) {
    sentenceBankYamlSourcePause = value;
    notifyListeners();
  }

  /// The tts_repeat_delay value from the currently loaded YAML bank (default 1).
  /// Updated by SentenceBankTab whenever a bank is loaded.
  int sentenceBankYamlTtsRepeatDelay = 1;
  void updateSentenceBankYamlTtsRepeatDelay(int value) {
    sentenceBankYamlTtsRepeatDelay = value;
    notifyListeners();
  }

  /// The tts_repeat_count value from the currently loaded YAML bank (default 2).
  /// Updated by SentenceBankTab whenever a bank is loaded.
  int sentenceBankYamlTtsRepeatCount = 2;
  void updateSentenceBankYamlTtsRepeatCount(int value) {
    sentenceBankYamlTtsRepeatCount = value;
    notifyListeners();
  }

  /// Resolved repeat count: override if set, else YAML value.
  int get sentenceBankResolvedTtsRepeatCount =>
      _settings.sentenceBankTtsRepeatCountOverride ?? sentenceBankYamlTtsRepeatCount;

  void triggerSentenceBankReload() {
    sentenceBankReloadToken++;
    notifyListeners();
  }

  Future<void> clearSentenceBankTranslationCache() async {
    // Route through the service so the clear is serialized with the same mutex
    // that guards translation-cache writes — otherwise a clear could interleave
    // with an in-flight read-merge-write and leave the cache in a half state.
    await SentenceBankService(SharedPreferencesAsync()).clearTranslationCache();
  }

  Future<void> clearGoogleTtsAudioCache() async {
    await GoogleTranslateTts.clearAllCachedAudio();
  }

  int _notificationTapToken = 0;

  // Snapshots of notifications (content + planned fire time).
  List<NotificationSnapshot> _snapshots = [];

  static const int _kMaxScheduledAhead = 10;

  AppSettings get settings => _settings;

  List<WordEntry> get words => List.unmodifiable(_words);

  int get notificationTapToken => _notificationTapToken;

  List<NotificationSnapshot> get snapshots => List.unmodifiable(_snapshots);

  NavigatorState? _nav;
  void attachNavigator(NavigatorState? nav) { _nav = nav; }

  // ---------------------------------------------------------
  // Global step helpers
  // ---------------------------------------------------------

  int get _minStepGlobal {
    final active = _words.where((w) => w.active && w.totalSteps > 0).toList();
    if (active.isEmpty) return 0;
    return active.map((w) => w.startStep).reduce(min);
  }

  int get _maxStepGlobalExclusive {
    final active = _words.where((w) => w.active && w.totalSteps > 0).toList();
    if (active.isEmpty) return 0;
    return active.map((w) => w.startStep + w.totalSteps).reduce(max);
  }

  int get maxGlobalStepExclusive => _maxStepGlobalExclusive;

  /// Number of global steps that can have at least one sentence.
  int get maxSteps => _maxStepGlobalExclusive - _minStepGlobal;

  /// Remaining exposures for a given word, based on per-word startStep.
  int remainingSentencesFor(WordEntry w) {
    final exposures = max(0, min(w.totalSteps, _currentStep - w.startStep));
    return max(0, w.totalSteps - exposures);
  }

  /// All sentences for a given global step.
  List<ScheduledSentence> sentencesForGlobalStep(int step) {
    final list = <ScheduledSentence>[];
    for (final w in _words.where((w) => w.active)) {
      final idx = step - w.startStep;
      if (idx >= 0 && idx < w.sentences.length) {
        list.add(ScheduledSentence(word: w, index: idx, data: w.sentences[idx]));
      }
    }
    return list;
  }

  Future<void> init() async {
    // final sw = Stopwatch()..start();
    //final prefs = await SharedPreferences.getInstance();
    final prefs = SharedPreferencesAsync();
    // debugPrint("#### hack after sharedPreferences.getInstance() ${sw.elapsed}");
    _storage = AppStorage(prefs);
    final results = await Future.wait([
      _storage.loadSettings(),
      _storage.loadWords(),
      _storage.loadHistory(),
      _storage.loadSnapshots(),
    ]);

    _settings = results[0] as AppSettings;
    _words = results[1] as List<WordEntry>;
    var loadedHistory = results[2] as List<HistoryEntry>;
    _snapshots = results[3] as List<NotificationSnapshot>;

    for (int ihe = 0 ; ihe < loadedHistory.length ; ihe++) {
      loadedHistory[ihe].removeDuplicateMainWords();
    }

    _history.clear();
    for (HistoryEntry he in loadedHistory) {
      if (he.isValid()) {
        int idx = _history.indexWhere((entry) => _sameSentences(entry.sentences, he.sentences));
        if (idx < 0) {
          _history.add(he);
          // debugPrint("adding ${jsonEncode(he)}");
        }
      }
    }
    // debugPrint("changed hist len from ${loadedHistory.length} to ${_history.length}");
    // _settings = await _storage.loadSettings();
    // _words = await _storage.loadWords();
    // _snapshots = await _storage.loadSnapshots(); // still used for scheduling
    // _active = _words.where((w) => w.active).toList();
    // _history = await _storage.loadHistory(); // tapped notifications history
    // debugPrint("#### hack after storage loads ${sw.elapsed}");
    _sortHistoryNewestFirst();

    // On Android, when the app is launched by tapping a notification
    // while it was terminated, we must query the launch details *before*
    // initializing the plugin; otherwise the information can be lost.
    final launchPayload = await NotificationService.instance.getLaunchPayload();

    await NotificationService.instance.init(onTap: _handleNotificationTap);

    if (launchPayload != null) {
      _handleNotificationTap(launchPayload);
    }
    else {
      debugPrint("got null payload from getLaunchPayload");
    }

    await _rescheduleAll();
    // await Future.delayed(Duration(seconds: 15));
    // _notificationTapToken++;
    initialized = true;
    notifyListeners();
  }

  String? _highlightHistoryFingerprint;
  String? get highlightHistoryFingerprint => _highlightHistoryFingerprint;

  bool scrolledToHighlight = false;

  Timer? _historySaveDebounce;
  void _scheduleHistorySave() {
    _historySaveDebounce?.cancel();
    _historySaveDebounce = Timer(const Duration(milliseconds: 400), () {
      _storage.saveHistory(_history);
    });
  }

  void _markHistoryHighlight(String fp) {//, {Duration keepFor = const Duration(seconds: 4)}) {
    _highlightHistoryFingerprint = fp;
    scrolledToHighlight = false;
    notifyListeners();
  }

  void resetHistoryHighlight({bool silent = false}) {
    // _highlightClearTimer?.cancel();
    _highlightHistoryFingerprint = null;
    if (!silent) notifyListeners();
  }

  bool _sameSentences(List<WordSentence> a, List<WordSentence> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;

    for (var i = 0; i < a.length; i++) {
      final sa = a[i];
      final sb = b[i];
      if (sa.l1.toLowerCase().trim() != sb.l1.toLowerCase().trim() || sa.l2.toLowerCase().trim() != sb.l2.toLowerCase().trim()) {
        return false;
      }
    }
    return true;
  }

  void _sortHistoryNewestFirst() { _history.sort((a, b) => b.tappedAt.compareTo(a.tappedAt)); }

  void _addSentencesToHistory(List<WordSentence> sentences, int atIndex) {
    if (sentences.isEmpty) return;
    for (int iws = 0 ; iws < sentences.length ; iws++) {
      WordSentence ws = sentences[iws];
      String cleaned = removeDuplicateMainWord(sentences[iws].l2);
      if (cleaned != ws.l2)
        sentences[iws] = WordSentence(l2: cleaned, l1: ws.l1, word: ws.word, translatedWord: ws.translatedWord);
    }
    if (atIndex == 0) {
      int idx = _history.indexWhere((entry) => _sameSentences(entry.sentences, sentences));
      if (idx >= 0) {
        _history.removeAt(idx);
      }
    }
    if (!_history.any((entry) => _sameSentences(entry.sentences, sentences))) {
      final entry = HistoryEntry(tappedAt: DateTime.now(), sentences: sentences);
      atIndex = min(_history.length, atIndex);
      _history.insert(atIndex, entry); // Newest at top
      _trimHistorySentences();
      historyRevision++;
    }
  }

  void _trimHistorySentences() {
    if (_history.length > kMaxHistorySentences) {
      _history.removeRange(kMaxHistorySentences, _history.length);
    }
    // int total = 0;
    // final kept = <HistoryEntry>[];
    //
    // for (final entry in _history) {
    //   final count = entry.sentences.length;
    //   if (total >= kMaxHistorySentences) break;
    //   kept.add(entry);
    //   total += count;
    // }
    //
    // _history = kept;
  }

  // ---------------------------------------------------------
  // Notification tap handling
  // ---------------------------------------------------------

  void _handleNotificationTap(String payload) {
    if (payload.isEmpty) {
      debugPrint("got empty payload");
    } else {
      debugPrint('🔔 _handleNotificationTap called, payload length=${payload.length}');
      // debugPrint('🔔 _handleNotificationTap called, payload=$payload');
      try {
        final data = jsonDecode(payload) as Map<String, dynamic>;
        final step = (data['step'] as num?)?.toInt();
        debugPrint('🔔 tap step=$step payloadLen=${payload.length}');
        final rawList = (data['sentences'] as List?) ?? [];
        final sentences = rawList.map((e) => WordSentence.fromJson((e as Map).cast<String, dynamic>())).toList();
        _addSentencesToHistory(sentences,0);

        final fp = fingerprintSentences(sentences);
        final existingIndex = _history.indexWhere((e) => e.fingerprint == fp);
        if (existingIndex >= 0) {
          if (existingIndex > 0) {
            final elm = _history.removeAt(existingIndex);
            _history.insert(0, elm);
          }
          _markHistoryHighlight(fp);
        }
        _scheduleHistorySave();
        // _storage.saveHistory(_history);
        notifyListeners();
      } catch (e, st) {
        debugPrint('⚠️ Failed to parse notification payload: $e\n$st');
        // Legacy payload (step as string) or malformed; just ignore.
      }
    }
    _nav?.popUntil((route) => route.isFirst);
    _notificationTapToken++; // notify MainScaffold to jump to history tab
    notifyListeners();
    rootNavKey.currentState?.popUntil((route) => route.isFirst);
  }

  // ---------------------------------------------------------
  // Persistence / settings
  // ---------------------------------------------------------

  Future<void> _persist() async {
    // NOTE: do NOT clear the whole SharedPreferences store here. Each save below
    // overwrites its own key, and the store is shared with other features
    // (sentence-bank translation cache, active-words store, positions, …). A
    // blanket clear wiped all of those on every settings change, forcing the
    // entire sentence bank to re-translate (and burn API quota) repeatedly.
    await _storage.saveSettings(_settings);
    await _storage.saveWords(_words);
    await _storage.saveSnapshots(_snapshots);
    debugPrint("saved all settings, words and snapshots");
  }

  Future<void> updateSettings(AppSettings s) async {
    _settings = s;
    await _persist();
    await _rescheduleAll(firstOffset: const Duration(seconds: 30));
    notifyListeners();
  }

  /// Persists settings without touching the notification schedule.
  Future<void> saveSettingsOnly(AppSettings s) async {
    _settings = s;
    await _persist();
    notifyListeners();
  }

  // ---------------------------------------------------------
  // Connector words management
  // ---------------------------------------------------------

  Future<void> addConnectorWord(String w) async {
    final trimmed = w.trim();
    if (trimmed.isEmpty) return;
    final set = {..._settings.connectorWords, trimmed};
    await updateSettings(_settings.copyWith(connectorWords: set.toList()));
  }

  Future<void> removeConnectorWord(String w) async {
    final newList = [..._settings.connectorWords]..remove(w);
    await updateSettings(_settings.copyWith(connectorWords: newList));
  }

  // ---------------------------------------------------------
  // Word management + AI
  // ---------------------------------------------------------

  Future<void> addWordWithAi({
    String? wordL1, // known language
    String? wordL2, // target language (Greek or phonetic)
    required WordType type,
  }) async {
    final l1 = (wordL1 ?? '').trim();
    final l2 = (wordL2 ?? '').trim();

    if (l1.isEmpty && l2.isEmpty) {
      throw Exception('Enter a word in either known or target language.');
    }
    if (l1.isNotEmpty && l2.isNotEmpty) {
      throw Exception('Please fill only one of the two fields, not both.');
    }

    final s = _settings;
    if (s.aiApiKey.trim().isEmpty) {
      throw Exception('AI API key is empty (set it in Settings).');
    }

    // Option A: one Gemini request does (a) translate/normalize into final L2 word and (b) generate the sentences.
    final combined = await AiService.generateWordAndSentences(apiKey: s.aiApiKey, wordL1: l1.isEmpty ? null : l1, wordL2: l2.isEmpty ? null : l2, type: type, knownLanguage: s.knownLanguage, targetLanguage: s.targetLanguage, simpleCount: s.simpleCount, conjugatedCount: s.conjugatedCount, connectorWords: s.connectorWords);
    final baseWord = combined.wordL2;
    final generated = combined.sentences;

    final id = '${DateTime.now().millisecondsSinceEpoch}-${_words.length}';
    final entry = WordEntry(
      id: id,
      wordL2: baseWord,
      wordL1: combined.wordL1,
      type: type,
      createdAt: DateTime.now(),
      active: true,
      sentences: generated,
      startStep: _currentStep, // per-word progress anchor
    );

    _words.add(entry);
    await _persist();
    await _rescheduleAll(firstOffset: const Duration(seconds: 30));
    notifyListeners();
  }

  Future<void> toggleWordActive(WordEntry w) async {
    final idx = _words.indexWhere((x) => x.id == w.id);
    if (idx == -1) return;
    final old = _words[idx];
    _words[idx] = WordEntry(
      id: old.id,
      wordL2: old.wordL2,
      wordL1: old.wordL1,
      type: old.type,
      createdAt: old.createdAt,
      active: !old.active,
      sentences: old.sentences,
      startStep: old.startStep,
    );
    await _persist();
    await _rescheduleAll();
    notifyListeners();
  }

  Future<void> deleteWord(WordEntry w) async {
    _words.removeWhere((x) => x.id == w.id);
    await _persist();
    await _rescheduleAll();
    notifyListeners();
  }

  Future<void> addMoreForWord(WordEntry w, {int extra = 10}) async {
    final idx = _words.indexWhere((x) => x.id == w.id);
    if (idx == -1) return;

    final old = _words[idx];

    // Generate new sentences (all in the "conjugated" bucket)
    final more = await AiService.generateSentences(
      apiKey: _settings.aiApiKey,
      word: old.wordL2,
      knownWord: old.wordL1,
      type: old.type,
      knownLanguage: _settings.knownLanguage,
      targetLanguage: _settings.targetLanguage,
      simpleCount: 0,
      conjugatedCount: extra,
      connectorWords: _settings.connectorWords,
    );

    // --- KEY PART: preserve the *old* exposure count ---

    // total steps before adding
    final tOld = old.totalSteps;

    // raw exposures given the global step & old startStep
    final rawExposures = _currentStep - old.startStep;

    // clamp to [0, tOld]
    final exposuresOld = rawExposures <= 0 ? 0 : (rawExposures > tOld ? tOld : rawExposures);

    // build the new sentence list
    final newSentences = [...old.sentences, ...more];

    // keep the same exposuresOld, but possibly shift startStep so that
    // min(tNew, _currentStep - newStartStep) == exposuresOld
    final newStartStep = _currentStep - exposuresOld;

    _words[idx] = WordEntry(
      id: old.id,
      wordL2: old.wordL2,
      wordL1: old.wordL1,
      type: old.type,
      createdAt: old.createdAt,
      active: old.active,
      sentences: newSentences,
      startStep: newStartStep,
    );

    await _persist();
    await _rescheduleAll();
    notifyListeners();
  }

  // ---------------------------------------------------------
  // History / snapshots
  // ---------------------------------------------------------

  /// Reschedule all future notifications from the *time-driven* currentStep.
  ///
  /// currentStep is advanced based on which snapshots have firedAt <= now,
  /// i.e. by "notifications that should already have fired", regardless of taps.
  Future<void> _rescheduleAll({Duration firstOffset = Duration.zero}) async {
    if (kIsWeb) return;
    // Cancel all currently scheduled notifications; we'll schedule a fresh window.
    await NotificationService.instance.cancelAll();

    final active = _words.where((w) => w.active && w.totalSteps > 0).toList();
    if (active.isEmpty) {
      _snapshots = [];
      await _storage.saveSnapshots(_snapshots);
      return;
    }

    final maxExclusive = _maxStepGlobalExclusive;
    if (_currentStep >= maxExclusive) {
      _snapshots = [];
      await _storage.saveSnapshots(_snapshots);
      return;
    }

    const int kMaxHistorySteps = 200;
    // Keep at most the last kMaxHistorySteps *fired* snapshots (steps < _currentStep).
    // Any snapshots for steps >= _currentStep belong to future notifications
    // and will be rebuilt below.
    final nowStep = _currentStep;
    _snapshots.removeWhere((snap) => snap.step < nowStep - kMaxHistorySteps || snap.step >= nowStep);

    final now = DateTime.now();
    final interval = _settings.interval;

    // This will be the base offset for the first scheduled notification.
    // If firstOffset != Duration.zero, we are coming from Settings "Save" and
    // want that behavior to win (e.g. first in 30s). Only when firstOffset is
    // zero (normal startup) do we derive from last fired.
    Duration scheduleOffset = firstOffset;

    if (scheduleOffset == Duration.zero) {
      // Look for the most recent fired snapshot (step < _currentStep)
      DateTime? lastFiredAt;
      for (final snap in _snapshots) {
        if (!snap.firedAt.isAfter(now)) {
          if (lastFiredAt == null || snap.firedAt.isAfter(lastFiredAt)) {
            lastFiredAt = snap.firedAt;
          }
        }
      }

      if (lastFiredAt != null) {
        final elapsed = now.difference(lastFiredAt); // how long since last
        if (elapsed < interval) {
          // We haven't reached the original next time yet.
          // Next = lastFiredAt + interval, so time until next = interval - elapsed.
          scheduleOffset = interval - elapsed;
        } else {
          // We are already past the ideal next time.
          scheduleOffset = Duration(seconds: 30);
        }
      }
    }

    if (scheduleOffset > Duration.zero && scheduleOffset < const Duration(seconds: 30)) {
      scheduleOffset = const Duration(seconds: 30);
    }

    final noTranslation = noTranslationTextFor(settings.knownLanguage);

    final List<NotificationSnapshot> newSnapshots = [..._snapshots];

    final startStep = _currentStep;
    // final numToAddAhead = defaultTargetPlatform == TargetPlatform.linux ? 1 : _kMaxScheduledAhead;
    final numToAddAhead = _kMaxScheduledAhead;
    final endStepExclusive = min(maxExclusive, startStep + numToAddAhead);

    DateTime fireTime = now.add(scheduleOffset);
    bool startAtExactly = scheduleOffset > Duration.zero;

    for (var step = startStep; step < endStepExclusive; step++) {
      final items = sentencesForGlobalStep(step);
      if (items.isEmpty) continue;

      if (!startAtExactly) {
        bool tryNextTime = false;
        do {
          fireTime = fireTime.add(interval);
          tryNextTime = _settings.useDnd && isTODBetween(TimeOfDay.fromDateTime(fireTime), _settings.dndStartTime, _settings.dndEndTime);
        } while (tryNextTime);
      }
      startAtExactly = false;

      final sentences = items.map((s) => s.data).toList();

      // Pad to at least 4 by pulling extra sentences from the same words,
      // cycling round-robin so each word contributes different sentences.
      final displaySentences = List<WordSentence>.from(sentences);
      if (displaySentences.length < 4 && displaySentences.isNotEmpty) {
        final wordEntries = items.map((e) => e.word).toList();
        final nextIndices = items.map((e) => (e.index + 1) % e.word.sentences.length).toList();
        var wi = 0;
        while (displaySentences.length < 4) {
          final wordIdx = wi % wordEntries.length;
          displaySentences.add(wordEntries[wordIdx].sentences[nextIndices[wordIdx]]);
          nextIndices[wordIdx] = (nextIndices[wordIdx] + 1) % wordEntries[wordIdx].sentences.length;
          wi++;
        }
      }

      final buf = StringBuffer();
      var shown = 0;
      for (final s in displaySentences) {
        if (buf.isNotEmpty) buf.writeln();
        var (titleText, expandedText) = prepareSentenceToShow(sentences, s, noTranslation);
        // final cleaned = sentenceCleanup(s.l2);
        // buf.write('- ${cleaned["clean"]}');
        buf.write('- $titleText');
        // buf.write('- ${cleaned["cloze"]}');
        if (_settings.showTranslation && s.l1.isNotEmpty) {
          buf.writeln();
          // buf.write('  (${s.l1})');
          buf.write('  ($expandedText)');
        }
        shown++;
        if (shown >= 4) break;
      }
      if (sentences.length > shown) {
        buf.writeln();
        buf.write('… more in the app');
      }

      // Replace any previous snapshot for this step (if rescheduling).
      newSnapshots.removeWhere((snap) => snap.step == step);
      newSnapshots.add(NotificationSnapshot(step: step, firedAt: fireTime));

      final payload = jsonEncode({
        'step': step,
        'sentences': displaySentences.map((s) => s.toJson()).toList(),
      });
      _addSentencesToHistory(displaySentences, 1);

      final notifId = 100000 + step;
      await NotificationService.instance.scheduleNotification(
        id: notifId,
        fireTime: fireTime,
        title: null,
        body: buf.toString(),
        payload: payload,
      );
    }
    notifyListeners();
    // _sortHistoryNewestFirst();
    // _storage.saveHistory(_history);
    _scheduleHistorySave();

    _snapshots = newSnapshots;
    await _storage.saveSnapshots(_snapshots);
  }

  Future<void> handleLaunchPayloadIfAny() async {
    final payload = await NotificationService.instance.getLaunchPayload();
    if (payload != null) {
      _handleNotificationTap(payload);
    }
  }

  /// Called periodically by the dashboard timer so that any time-based
  /// progress (snapshots whose firedAt has passed) is reflected in the UI.
  ///
  /// With the no-global-steps refactor, _currentStep is now derived from
  /// snapshots and time, so this just prunes old snapshots by time and
  /// triggers a rebuild.
  void refreshFromTime() {
    if (_snapshots.isEmpty) return;

    final now = DateTime.now();

    // Split into past and future snapshots.
    final past = _snapshots.where((s) => !s.firedAt.isAfter(now)).toList()
      ..sort((a, b) => b.firedAt.compareTo(a.firedAt)); // newest first

    final future = _snapshots.where((s) => s.firedAt.isAfter(now)).toList()
      ..sort((a, b) => a.firedAt.compareTo(b.firedAt)); // soonest first

    const int kMaxHistoryPast = 200;
    // Keep at most the last kMaxHistoryPast past snapshots for history.
    if (past.length > kMaxHistoryPast) {
      past.removeRange(kMaxHistoryPast, past.length);
    }

    _snapshots = [...past, ...future];
    _storage.saveSnapshots(_snapshots);

    notifyListeners();
  }

  Future<void> onAppResumed() async {
    paused = false;
    await _rescheduleAll();
  }

  List<WordSentence> _allGeneratedSentencesFlattened() {
    final out = <WordSentence>[];
    for (final w in _words) {
      // Include inactive? Your call. I’d keep only active:
      if (!w.active) continue;
      out.addAll(w.sentences);
    }
    return out;
  }

  WordSentence? pickPredictionSentenceNonRepeating() {
    final all = _allGeneratedSentencesFlattened();
    if (all.isEmpty) return null;

    // Build / rebuild queue if needed
    if (_predictionQueue.isEmpty || _predictionQueuePos >= _predictionQueue.length) {
      _predictionQueue = List<int>.generate(all.length, (i) => i);
      _predictionSeed++;
      _predictionQueue.shuffle(Random(DateTime.now().microsecondsSinceEpoch ^ _predictionSeed));
      _predictionQueuePos = 0;
    }

    final idx = _predictionQueue[_predictionQueuePos++];
    return all[idx];
  }

  /// Evaluates the user's prediction. Returns the text to show plus [ok]: true
  /// only when the AI actually produced a verdict. On any failure (empty input,
  /// AI busy/quota, no key, network) [ok] is false so the caller can leave the
  /// Check button enabled for a retry instead of locking it.
  Future<({String text, bool ok})> evaluatePrediction({
    required WordSentence sentence,
    required String userAnswer,
  }) async {
    final expectedL2 = (sentenceCleanup(sentence.l2)["clean"] ?? sentence.l2).trim();
    final promptL1 = sentence.l1.trim();
    final user = userAnswer.trim();

    final knownLang = _settings.knownLanguage;
    final targetLang = _settings.targetLanguage;

    if (user.isEmpty) {
      return (text: 'Type something first 🙂\n\nExpected $targetLang:\n$expectedL2', ok: false);
    }

    // AI-based evaluation (preferred).
    try {
      final res = await AiService.evaluatePrediction(
        apiKey: _settings.aiApiKey,
        knownLanguage: knownLang,
        targetLanguage: targetLang,
        promptL1: promptL1,
        expectedL2: expectedL2,
        userAnswer: user,
        // Word-of-interest: sentence.word is L2, sentence.translatedWord is L1.
        wordOfInterestL2: sentence.word.trim(),
        wordOfInterestL1: sentence.translatedWord.trim(),
      );

      final verdict = (res['verdict']?.toString() ?? '').trim();
      final scoreNum = (res['score'] is num) ? (res['score'] as num).toDouble() : double.tryParse(res['score']?.toString() ?? '');
      final score = (scoreNum ?? 0.0).clamp(0.0, 1.0);
      final shortFb = (res['feedback_short']?.toString() ?? '').trim();
      final detailFb = (res['feedback_detail']?.toString() ?? '').trim();
      final targetFb = (res['target_word']?.toString() ?? '').trim();
      final normUser = (res['normalized_user_l2']?.toString() ?? '').trim();

      final emoji = switch (verdict) {
        'correct' => '✅',
        'mostly_correct' => '🟢',
        'partially_correct' => '🟡',
        _ => '❌',
      };

      final lines = <String>[];
      lines.add('$emoji ${(score * 100).round()}% — ${shortFb.isEmpty ? verdict : shortFb}');
      if (targetFb.isNotEmpty) {
        lines.add('');
        lines.add('Anchor: $targetFb');
      }
      if (detailFb.isNotEmpty) {
        lines.add('');
        lines.add(detailFb);
      }
      if (normUser.isNotEmpty && _norm(normUser) != _norm(user)) {
        lines.add('');
        lines.add('Interpreted your answer as $targetLang:\n$normUser');
      }
      lines.add('');
      lines.add('Expected $targetLang:\n$expectedL2');
      return (text: lines.join('\n'), ok: true);
    } on AiException catch (e) {
      return (text: 'Could not evaluate with AI: ${e.message}', ok: false);
    } catch (e) {
      // If AI fails (no key / network), fail softly with an actionable message.
      if ((_settings.aiApiKey).trim().isEmpty) {
        return (text: '⚠️ AI evaluation needs an API key.\nGo to Settings → AI API Key.\n\nExpected $targetLang:\n$expectedL2', ok: false);
      }
      return (text: '⚠️ Could not evaluate with AI (${e.toString()}).\n\nExpected $targetLang:\n$expectedL2', ok: false);
    }
  }

  String _norm(String s) {
    // Lower, trim, collapse whitespace. Keep Greek as-is.
    return s.toLowerCase()
        .replaceAll(RegExp(r"[_\-.,/\\()\[\]{}:;'|]+"),' ',)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> clearAllHistory() async {
    _history.clear();
    resetHistoryHighlight(silent: true);
    await _storage.saveHistory(_history);
    _notificationTapToken++;
    historyRevision++;
    notifyListeners();
  }

  Future<void> clearAllPendingSentences() async {
    await NotificationService.instance.cancelAll();
    _snapshots.clear();
    await _storage.saveSnapshots(_snapshots);
    _words = _words.map((w) => WordEntry(
      id: w.id,
      wordL2: w.wordL2,
      wordL1: w.wordL1,
      type: w.type,
      createdAt: w.createdAt,
      active: w.active,
      sentences: w.sentences,
      startStep: 0,
    )).toList();
    await _storage.saveWords(_words);

    _predictionQueue = [];
    _predictionQueuePos = 0;
    _predictionSeed = 0;

    await _rescheduleAll(firstOffset: const Duration(seconds: 5));
    notifyListeners();
  }

  Future<void> clearAllPendingSentencesAndRegenerate() async {
    // 1) Cancel currently scheduled OS notifications
    await NotificationService.instance.cancelAll();

    // 2) Clear snapshots (pending schedule window) and persist
    _snapshots = [];
    await _storage.saveSnapshots(_snapshots);

    // 3) Clear cached sentences per word (THIS is the key missing part)
    _words = _words.map((w) => WordEntry(
      id: w.id,
      wordL2: w.wordL2,
      wordL1: w.wordL1,
      type: w.type,
      createdAt: w.createdAt,
      active: w.active,
      sentences: const [],
      startStep: _currentStep, // reset anchor to "now"
    )).toList();
    await _storage.saveWords(_words);

    // 4) Regenerate sentences for every active word using current settings
    final s = _settings;
    final newWords = <WordEntry>[];

    for (final w in _words) {
      if (!w.active) {
        newWords.add(w);
        continue;
      }

      final generated = await AiService.generateSentences(
        apiKey: s.aiApiKey,
        word: w.wordL2,
        knownWord: w.wordL1,
        type: w.type,
        knownLanguage: s.knownLanguage,
        targetLanguage: s.targetLanguage,
        simpleCount: s.simpleCount,
        conjugatedCount: s.conjugatedCount,
        connectorWords: s.connectorWords,
      );

      newWords.add(WordEntry(
        id: w.id,
        wordL2: w.wordL2,
        wordL1: w.wordL1,
        type: w.type,
        createdAt: w.createdAt,
        active: w.active,
        sentences: generated,
        startStep: _currentStep,
      ));
    }

    _words = newWords;
    await _storage.saveWords(_words);

    // 5) Reschedule using fresh regenerated sentences
    await _rescheduleAll(firstOffset: const Duration(seconds: 5));

    notifyListeners();
  }

  (String, String) prepareSentenceToShow(List<WordSentence> sentences, WordSentence s, String noTranslation) {
    final localSeed = fingerprintSentences(sentences).hashCode ^ s.l2.hashCode ^ s.l1.hashCode;
    final random = Random(localSeed);

    String expandedText = s.l1.isEmpty ? noTranslation : s.l1;
    String cleanedL2 = normalizeMarkersWithConnectorPolicy(s.l2, settings.connectorWords);
    cleanedL2 = removeDuplicateMainWord(cleanedL2);
    final cleaned = sentenceCleanup(cleanedL2);
    String titleText = cleaned["clean"] ?? cleanedL2;

    final hasCloze = cleaned["cloze"] != null && cleaned["clean"] != cleaned["cloze"];
    final modes = [
      if (_settings.modeReverse && s.l1.isNotEmpty) 'reverse',
      if (_settings.modeCloze && hasCloze) 'cloze',
      if (_settings.modeClean) 'clean',
    ];
    final pick = modes.isEmpty ? 'clean' : modes[random.nextInt(modes.length)];

    if (pick == 'reverse') {
      expandedText = titleText;
      titleText = s.l1;
    } else if (pick == 'cloze') {
      expandedText = "${cleaned["clean"]}\n$expandedText";
      titleText = "${cleaned["cloze"]}  (${s.translatedWord})";
    }
    return (titleText, expandedText);
  }
}
