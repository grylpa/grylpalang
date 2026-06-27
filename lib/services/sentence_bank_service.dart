import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:yaml/yaml.dart';

import '../models/sentence_bank.dart';
import 'ai_service.dart';

/// Builds the daily-quota message with the reset time (midnight US-Pacific, the
/// Gemini free-tier reset) expressed in the device's local timezone.
String _dailyQuotaMessage() {
  try {
    final la = tz.getLocation('America/Los_Angeles');
    final nowLa = tz.TZDateTime.now(la);
    final local = tz.TZDateTime(la, nowLa.year, nowLa.month, nowLa.day + 1).toLocal();
    final now = DateTime.now();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final dayDiff = DateTime(local.year, local.month, local.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    final when = dayDiff <= 0 ? ' today' : (dayDiff == 1 ? ' tomorrow' : '');
    return 'Daily Gemini quota reached — resets around $hh:$mm$when.';
  } catch (_) {
    return 'Daily Gemini quota reached — try again later.';
  }
}

/// A translation failure with a user-readable [message]. [daily] marks the
/// free-tier daily-quota exhaustion, where retrying further chunks is pointless.
class TranslationException implements Exception {
  final String message;
  final bool daily;
  TranslationException(this.message, {this.daily = false});
  @override
  String toString() => message;
}

/// Turns a failed Gemini response into a message that means something to a user.
TranslationException _translationError(int status, String body) {
  if (status == 429) {
    final daily = AiService.isDailyQuota(body);
    return TranslationException(
      daily ? _dailyQuotaMessage() : 'Gemini is busy right now — wait a moment and try again.',
      daily: daily,
    );
  }
  return TranslationException('Translation failed — please try again later.');
}

/// Loads, parses, and manages translations for the Sentence Bank.
class SentenceBankService {
  static const String _kAssetPath = 'assets/sentence_bank.yaml';
  static const String _kTranslationCacheKey = 'sentenceBankTranslations';
  // Parallel map (same keys as the translation cache) recording which Gemini
  // model produced each translation, so we can later upgrade ones done by the
  // weaker fallback model. Stored separately to avoid changing the translation
  // cache's flat String→String shape.
  static const String _kTranslationModelsKey = 'sentenceBankTranslationModels';
  static const String _kCachedYamlKey = 'sentenceBankCachedYaml';

  /// True if [modelVersion] (from a Gemini response's `modelVersion` field) is
  /// the weaker lite fallback — those translations are the upgrade candidates.
  static bool isWeakModel(String? modelVersion) =>
      modelVersion != null && modelVersion.toLowerCase().contains('lite');

  final SharedPreferencesAsync _prefs;

  SentenceBankService(this._prefs);

  // ── Loading ──────────────────────────────────────────────────────────────

  /// Load the sentence bank. With no [url] the bundled local asset is used.
  /// With a [url], the cloud file is fetched (and cached) and combined with the
  /// local asset according to the cloud's `override_local` flag:
  ///   • `override_local: 1` → the cloud file completely replaces the local one.
  ///   • `override_local: 0` (or absent → falls back to the local value) → the
  ///     cloud file is appended onto the local one (subjects merged, sentences
  ///     unioned).
  /// For every scalar setting (language, timings, …): the cloud value wins when
  /// present, otherwise the local value is kept. (The Settings screen still
  /// overrides everything at the tab level via its override fields.)
  Future<SentenceBank> loadBank({String url = ''}) async {
    final localYaml = await rootBundle.loadString(_kAssetPath);
    final localParsed = loadYaml(localYaml);
    final localMap = (localParsed is Map) ? _toPlainMap(localParsed) : <String, dynamic>{};

    if (url.trim().isEmpty) {
      return SentenceBank.fromYaml(localMap);
    }

    final cloudYaml = await _fetchFromUrl(url.trim());
    // If the fetch failed and _fetchFromUrl fell back to the bundled asset,
    // there's nothing to merge — using it as "cloud" would duplicate everything.
    if (cloudYaml == localYaml) return SentenceBank.fromYaml(localMap);

    // A bad cloud file must never brick the Sentence Bank — fall back to the
    // bundled bank and surface a warning (shown as a snackbar by the tab)
    // instead of throwing a fatal load error.
    try {
      final cloudParsed = loadYaml(cloudYaml);
      if (cloudParsed is! Map) {
        lastFetchWarning = 'Sentence bank file is not valid YAML — using built-in bank.';
        return SentenceBank.fromYaml(localMap);
      }
      final cloudMap = _toPlainMap(cloudParsed);

      // override_local: cloud value if present, else local value (default 0).
      final overrideRaw = cloudMap.containsKey('override_local')
          ? cloudMap['override_local']
          : localMap['override_local'];
      if (_truthy(overrideRaw)) {
        return SentenceBank.fromYaml(cloudMap);
      }
      return SentenceBank.fromYaml(_mergeBankMaps(localMap, cloudMap));
    } catch (e) {
      lastFetchWarning = 'Sentence bank error (${_shortError(e)}) — using built-in bank.';
      return SentenceBank.fromYaml(localMap);
    }
  }

  /// Trims a YamlException to its first line (e.g. the "line N, column M …"
  /// message) so the snackbar stays readable.
  static String _shortError(Object e) => e.toString().split('\n').first.trim();

  static bool _truthy(dynamic v) =>
      v == 1 || v == true || (v is String && (v.trim() == '1' || v.trim().toLowerCase() == 'true'));

  /// Recursively converts a (possibly immutable Yaml*) structure into plain,
  /// mutable Dart maps/lists with String keys.
  static Map<String, dynamic> _toPlainMap(Map src) =>
      {for (final e in src.entries) e.key.toString(): _toPlainValue(e.value)};

  static dynamic _toPlainValue(dynamic v) {
    if (v is Map) return _toPlainMap(v);
    if (v is List) return [for (final e in v) _toPlainValue(e)];
    return v;
  }

  /// Combines [local] and [cloud] bank maps: scalar keys take the cloud value
  /// when present (else local); `subjects` are merged name-by-name (same-named
  /// leaf subjects union their sentences, meta subjects union their includes).
  static Map<String, dynamic> _mergeBankMaps(Map<String, dynamic> local, Map<String, dynamic> cloud) {
    final out = <String, dynamic>{};
    final scalarKeys = {...local.keys, ...cloud.keys}..remove('subjects');
    for (final k in scalarKeys) {
      out[k] = cloud.containsKey(k) ? cloud[k] : local[k];
    }
    final localSubs = (local['subjects'] is Map) ? (local['subjects'] as Map).cast<String, dynamic>() : const {};
    final cloudSubs = (cloud['subjects'] is Map) ? (cloud['subjects'] as Map).cast<String, dynamic>() : const {};
    final mergedSubs = <String, dynamic>{...localSubs};
    for (final e in cloudSubs.entries) {
      mergedSubs[e.key] = mergedSubs.containsKey(e.key) ? _mergeSubject(mergedSubs[e.key], e.value) : e.value;
    }
    out['subjects'] = mergedSubs;
    return out;
  }

  static dynamic _mergeSubject(dynamic local, dynamic cloud) {
    if (local is! Map || cloud is! Map) return cloud;
    List unionLists(String key) {
      final seen = <String>{};
      final merged = <dynamic>[];
      for (final s in [...((local[key] as List?) ?? const []), ...((cloud[key] as List?) ?? const [])]) {
        final asKey = s?.toString() ?? '';
        if (asKey.trim().isEmpty || !seen.add(asKey)) continue;
        merged.add(s);
      }
      return merged;
    }

    if (local.containsKey('sentences') && cloud.containsKey('sentences')) {
      return {'sentences': unionLists('sentences')};
    }
    if (local.containsKey('includes') && cloud.containsKey('includes')) {
      return {'includes': unionLists('includes')};
    }
    // Mismatched shapes (leaf vs meta) — the cloud definition wins.
    return cloud;
  }

  /// Non-null if the last [_fetchFromUrl] call fell back to cache or asset.
  String? lastFetchWarning;

  /// Normalizes common GitHub URLs into a fetchable *raw* URL:
  ///  - A Gist **page** URL (`gist.github.com/USER/ID`) → its raw endpoint
  ///    (`gist.githubusercontent.com/USER/ID/raw`). Fetching the page URL would
  ///    download HTML, not the file.
  ///  - A `github.com/.../blob/...` page URL → `raw.githubusercontent.com/...`.
  ///  - Strips the commit hash from raw Gist URLs so we always get the latest.
  static String _normalizeUrl(String url) {
    final u = url.trim();

    // Gist page → raw. Captures an optional "user/" then the hex gist id.
    final gistPage = RegExp(r'^https?://gist\.github\.com/((?:[^/?#]+/)?[0-9a-fA-F]+)/?(?:[?#].*)?$');
    final gm = gistPage.firstMatch(u);
    if (gm != null) {
      return 'https://gist.githubusercontent.com/${gm.group(1)}/raw';
    }

    // github.com blob page → raw.githubusercontent.com
    final blob = RegExp(r'^https?://github\.com/([^/]+/[^/]+)/blob/(.+)$');
    final bm = blob.firstMatch(u);
    if (bm != null) {
      return 'https://raw.githubusercontent.com/${bm.group(1)}/${bm.group(2)}';
    }

    // Already a raw Gist URL with a pinned commit hash → drop it for the latest.
    return u.replaceFirstMapped(
      RegExp(r'(gist\.githubusercontent\.com/.+/raw/)[0-9a-f]{40}/'),
      (m) => m.group(1)!,
    );
  }

  Future<String> _fetchFromUrl(String url) async {
    lastFetchWarning = null;

    // Normalize Gist URLs and append a cache-buster so CDNs never serve a stale copy.
    final normalized = _normalizeUrl(url.trim());
    final uri = Uri.parse(normalized);
    final bustUrl = uri.replace(queryParameters: {
      ...uri.queryParameters,
      '_cb': DateTime.now().millisecondsSinceEpoch.toString(),
    }).toString();

    try {
      final resp = await http.get(Uri.parse(bustUrl), headers: const {
        // Some hosts/CDNs block or stale-serve a request with no browser UA, and
        // we want the freshest copy — mirror what a browser sends.
        'User-Agent': 'Mozilla/5.0 (Android; Flutter) Katalaveno/1.0',
        'Accept': 'text/yaml, text/plain, */*',
        'Cache-Control': 'no-cache',
        'Pragma': 'no-cache',
      }).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final body = resp.body;
        // Only cache (and use) the fetched file if it actually parses. Caching a
        // broken file would poison every later load — and re-fetching a fixed
        // file later would otherwise keep failing back onto the bad cache.
        if (_isValidBankYaml(body)) {
          await _prefs.setString(_kCachedYamlKey, body);
          return body;
        }
        lastFetchWarning = 'Sentence bank file has a YAML error — using the previous version.';
      } else {
        lastFetchWarning = 'HTTP ${resp.statusCode} — showing cached version.';
      }
    } catch (e) {
      lastFetchWarning = 'Fetch failed (${_shortError(e)}) — showing cached version.';
    }

    // Fall back to the last *valid* cached YAML, else the bundled asset.
    final cached = await _prefs.getString(_kCachedYamlKey);
    if (cached != null && cached.isNotEmpty && _isValidBankYaml(cached)) return cached;
    lastFetchWarning = '${lastFetchWarning ?? 'Fetch failed.'} Using built-in bank.';
    return await rootBundle.loadString(_kAssetPath);
  }

  /// True if [yaml] parses to a YAML mapping (a usable sentence-bank document).
  bool _isValidBankYaml(String yaml) {
    try {
      return loadYaml(yaml) is Map;
    } catch (_) {
      return false;
    }
  }

  // ── Translation cache ─────────────────────────────────────────────────────

  Future<Map<String, String>> _loadCache() => _loadStringMap(_kTranslationCacheKey);
  Future<Map<String, String>> _loadModels() => _loadStringMap(_kTranslationModelsKey);

  Future<Map<String, String>> _loadStringMap(String prefsKey) async {
    final raw = await _prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return {};
    final out = <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        // Per-entry filter: a single non-string value would make a blanket
        // `.cast<String, String>()` throw on first access and lose the entire
        // map. Keep every well-typed pair, drop only the bad ones.
        decoded.forEach((k, v) {
          if (k is String && v is String) out[k] = v;
        });
      }
    } catch (_) {
      // Malformed JSON at the top level — nothing recoverable.
    }
    return out;
  }

  // Serializes every read-merge-write (and clear) of the translation cache
  // across *all* SentenceBankService instances — the Sentence Bank tab plus the
  // transient one the Book Reader creates. Each write previously did a full
  // read-modify-write of the whole map; two overlapping writers would each load
  // a snapshot and the later save would clobber the earlier one's additions,
  // silently dropping already-translated sentences and forcing them to be
  // re-fetched. The mutex makes every mutation an atomic read-merge-write so
  // additions only ever accumulate.
  static Future<void> _cacheMutex = Future<void>.value();

  static Future<T> _locked<T>(Future<T> Function() action) async {
    final prior = _cacheMutex;
    final completer = Completer<void>();
    _cacheMutex = completer.future; // never completed with an error, so awaiting is safe
    await prior;
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  /// Additively merges [additions] into the persisted cache (and, when given,
  /// [models] into the parallel model-provenance map): under the mutex, re-reads
  /// the latest on-disk maps, layers the new entries on top, and writes back.
  /// Never removes entries a concurrent writer added.
  Future<void> _mergeIntoCache(Map<String, String> additions, {Map<String, String>? models}) async {
    final hasModels = models != null && models.isNotEmpty;
    if (additions.isEmpty && !hasModels) return;
    await _locked(() async {
      if (additions.isNotEmpty) {
        final current = await _loadCache();
        current.addAll(additions);
        await _prefs.setString(_kTranslationCacheKey, jsonEncode(current));
      }
      if (hasModels) {
        final current = await _loadModels();
        current.addAll(models);
        await _prefs.setString(_kTranslationModelsKey, jsonEncode(current));
      }
    });
  }

  Future<void> clearTranslationCache() async {
    await _locked(() async {
      await _prefs.remove(_kTranslationCacheKey);
      await _prefs.remove(_kTranslationModelsKey);
    });
  }

  /// Among [sentences], returns those whose cached translation should be
  /// upgraded with the primary model — i.e. it was produced by the weaker lite
  /// fallback, or predates model tracking (no recorded model). Sentences not yet
  /// translated are skipped (the normal translate flow handles those).
  Future<List<String>> sentencesNeedingUpgrade({
    required List<String> sentences,
    required String sourceLang,
    required String targetLang,
  }) async {
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return const [];
    final cache = await _loadCache();
    final models = await _loadModels();
    final out = <String>[];
    final seen = <String>{};
    for (final s in sentences) {
      final key = _cacheKey(sourceLang, targetLang, s);
      if (!cache.containsKey(key) || !seen.add(key)) continue;
      final m = models[key];
      if (m == null || isWeakModel(m)) out.add(s);
    }
    return out;
  }

  /// Tag recorded for translations we already know (not produced by the AI),
  /// e.g. Active Words sentences that carry both languages. Non-weak, so the
  /// background upgrader leaves them alone.
  static const String _seededModelTag = 'seeded';

  /// Seeds the translation cache with known source→target [pairs] that don't
  /// need the AI. Overwrites any existing entry (the seeded value is
  /// authoritative) and records a non-weak model so the upgrader skips them.
  Future<void> seedTranslations({
    required Map<String, String> pairs,
    required String sourceLang,
    required String targetLang,
  }) async {
    if (pairs.isEmpty || sourceLang.toLowerCase() == targetLang.toLowerCase()) return;
    final additions = <String, String>{};
    final models = <String, String>{};
    pairs.forEach((src, tgt) {
      if (src.trim().isEmpty || tgt.trim().isEmpty) return;
      final key = _cacheKey(sourceLang, targetLang, src);
      additions[key] = tgt;
      models[key] = _seededModelTag;
    });
    await _mergeIntoCache(additions, models: models);
  }

  static String _cacheKey(String sourceLang, String targetLang, String sentence) =>
      '$sourceLang|$targetLang|$sentence';

  // ── Active Words store ─────────────────────────────────────────────────────
  //
  // The "Active words" subject accumulates sentences pulled from notification
  // history over time, independent of history's own small rolling cap. Persisted
  // per target language (its `tgt` text is language-specific), newest-first,
  // capped — oldest evicted first.

  static String _activeWordsKey(String targetLang) => 'sentenceBankActiveWords_$targetLang';

  // The active-words sentences carry `[[word]]` cloze markers and inline
  // "(singular)"/"(plural)" grammar hints (used by the notification/prediction
  // UI). For the Sentence Bank we always drop the cloze markers, but only strip
  // the number hints from the SOURCE — the ready translation keeps its hint,
  // since for some sentences the target form's plurality is conveyed by it.
  // None of this touches the original word/history data.
  static final RegExp _clozeMarkerRe = RegExp(r'\[\[([^\[\]]+)\]\]');
  static final RegExp _numberHintRe = RegExp(r'\s*\((?:singular|plural)\)', caseSensitive: false);

  static String _cleanForBank(String s, {required bool stripNumberHints}) {
    var out = s.replaceAllMapped(_clozeMarkerRe, (m) => m.group(1)!);
    if (stripNumberHints) out = out.replaceAll(_numberHintRe, '');
    return out.replaceAll(RegExp(r'\s{2,}'), ' ').trim();
  }

  static bool _samePairs(List<({String src, String tgt})> a, List<({String src, String tgt})> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].src != b[i].src || a[i].tgt != b[i].tgt) return false;
    }
    return true;
  }

  /// The stored Active Words for [targetLang], newest-first (`src` = known-language
  /// sentence, `tgt` = its target-language translation).
  Future<List<({String src, String tgt})>> loadActiveWords(String targetLang) async {
    final raw = await _prefs.getString(_activeWordsKey(targetLang));
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List;
      return [
        for (final e in list)
          if (e is Map && e['s'] is String && e['t'] is String) (src: e['s'] as String, tgt: e['t'] as String),
      ];
    } catch (_) {
      return [];
    }
  }

  /// Merges [incoming] (newest-first) into the Active Words store: entries whose
  /// `src` isn't already stored are prepended, the list is capped at [cap]
  /// (oldest dropped from the tail), and the result is persisted and returned.
  /// Existing entries are never removed just because they aged out of history.
  Future<List<({String src, String tgt})>> addActiveWords({
    required List<({String src, String tgt})> incoming,
    required String targetLang,
    int cap = 200,
  }) async {
    return _locked(() async {
      // Strip cloze markers from anything already stored (migrates entries saved
      // before stripping existed) and track whether that changed the store.
      final rawCurrent = await loadActiveWords(targetLang);
      final current = [
        for (final e in rawCurrent)
          (src: _cleanForBank(e.src, stripNumberHints: true), tgt: _cleanForBank(e.tgt, stripNumberHints: false))
      ];
      var changed = !_samePairs(rawCurrent, current);

      final existing = {for (final e in current) e.src};
      final seen = <String>{};
      final newOnes = <({String src, String tgt})>[];
      for (final e in incoming) {
        final s = _cleanForBank(e.src, stripNumberHints: true);
        final t = _cleanForBank(e.tgt, stripNumberHints: false);
        if (s.isEmpty || t.isEmpty || existing.contains(s) || !seen.add(s)) continue;
        newOnes.add((src: s, tgt: t));
      }
      if (newOnes.isNotEmpty) changed = true;

      final merged = [...newOnes, ...current];
      final capped = merged.length > cap ? merged.sublist(0, cap) : merged;
      if (changed) {
        await _prefs.setString(
            _activeWordsKey(targetLang), jsonEncode([for (final e in capped) {'s': e.src, 't': e.tgt}]));
      }
      return capped;
    });
  }

  // ── Subject history ───────────────────────────────────────────────────────

  static const String _kSubjectHistoryKey = 'sentenceBankSubjectHistory';
  static const String _kLastSubjectKey = 'sentenceBankLastSubject';
  static const String _kSelectedSubjectsKey = 'sentenceBankSelectedSubjects';

  /// Persists the multi-selection of subjects (checkbox picker).
  Future<void> saveSelectedSubjects(List<String> subjects) async {
    await _prefs.setString(_kSelectedSubjectsKey, jsonEncode(subjects));
  }

  /// Loads the saved multi-selection, or null if none was ever saved.
  Future<List<String>?> loadSelectedSubjects() async {
    final raw = await _prefs.getString(_kSelectedSubjectsKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return null;
    }
  }

  /// Returns subjects sorted by recency: most recently selected first,
  /// then any subjects not yet in history in their original order.
  Future<List<String>> sortedSubjects(List<String> all) async {
    final history = await _loadSubjectHistory();
    final historySet = history.toSet();
    return [
      ...history.where(all.contains),
      ...all.where((s) => !historySet.contains(s)),
    ];
  }

  /// Returns the last explicitly selected subject that still exists in [all],
  /// or null if none was saved or it no longer exists.
  Future<String?> loadLastSubject(List<String> all) async {
    final saved = await _prefs.getString(_kLastSubjectKey);
    if (saved == null || !all.contains(saved)) return null;
    return saved;
  }

  Future<List<String>> _loadSubjectHistory() async {
    final raw = await _prefs.getString(_kSubjectHistoryKey);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return [];
    }
  }

  Future<void> recordSubjectSelected(String subject) async {
    await _prefs.setString(_kLastSubjectKey, subject);
    final history = await _loadSubjectHistory();
    history.remove(subject);
    history.insert(0, subject);
    await _prefs.setString(_kSubjectHistoryKey, jsonEncode(history));
  }

  // ── Position persistence ──────────────────────────────────────────────────
  //
  // The resume point is remembered by the *sentence text itself*, keyed by the
  // selection (a name-based key), not by a numeric index — so it survives the
  // sentence list changing (e.g. Active Words growing, a subject edited).

  static const String _kResumeKey = 'sentenceBankResumeSentence';

  /// The sentence the user was last on for [selectionKey], or null.
  Future<String?> loadResumeSentence(String selectionKey) async {
    final raw = await _prefs.getString(_kResumeKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>()[selectionKey] as String?;
    } catch (_) {
      return null;
    }
  }

  Future<void> saveResumeSentence(String selectionKey, String sentence) async {
    final raw = await _prefs.getString(_kResumeKey);
    final map = <String, String>{};
    if (raw != null) {
      try {
        map.addAll((jsonDecode(raw) as Map).map((k, v) => MapEntry(k.toString(), v.toString())));
      } catch (_) {}
    }
    map[selectionKey] = sentence;
    await _prefs.setString(_kResumeKey, jsonEncode(map));
  }

  /// Returns a cached translation without making any network calls. Returns null if not cached.
  Future<String?> getCached({
    required String sentence,
    required String sourceLang,
    required String targetLang,
  }) async {
    final cache = await _loadCache();
    return cache[_cacheKey(sourceLang, targetLang, sentence)];
  }

  /// Translate [sentence] from [sourceLang] to [targetLang].
  /// Returns the cached translation if available; otherwise calls the AI and
  /// caches the result. When [force] is true the cache is bypassed and the fresh
  /// result overwrites any existing entry — used by the manual "re-translate
  /// this sentence" button to repair a bad cached translation.
  Future<String> translate({
    required String sentence,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
    bool force = false,
  }) async {
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return sentence;

    final key = _cacheKey(sourceLang, targetLang, sentence);
    if (!force) {
      final cache = await _loadCache();
      if (cache.containsKey(key)) return cache[key]!;
    }

    final result = await _translateViaAi(
      sentence: sentence,
      sourceLang: sourceLang,
      targetLang: targetLang,
      apiKey: apiKey,
      // A forced (manual) re-translate must come from the primary model — never
      // the weaker lite fallback, whose output is what poisoned the cache to
      // begin with. If the primary is rate-limited the call throws and the UI
      // says "try later" rather than caching a worse translation.
      allowFallback: !force,
    );

    // Only cache a real translation — a result equal to the source means the AI
    // failed/echoed; caching it would poison the cache (and get spoken by the
    // target-language TTS). Leave it uncached so it retries next time. Record
    // the model alongside it so the upgrader can later spot lite ones.
    if (result.text.trim() != sentence.trim()) {
      await _mergeIntoCache({key: result.text}, models: {key: result.model ?? ''});
    }
    return result.text;
  }

  /// Fetches AI translations for [unique] sentences (already de-duplicated and
  /// known to be uncached), in chunks, persisting each chunk's successes via an
  /// additive merge. Returns a parallel list of results (the source text where a
  /// translation failed). When [graceful] is false a chunk error propagates to
  /// the caller (so the manual button can report it); otherwise the chunk falls
  /// back to source so auto mode keeps playing.
  Future<List<String>> _fetchUnique({
    required List<String> unique,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
    required bool graceful,
    int chunkSize = 30,
    void Function(int done, int total)? onProgress,
  }) async {
    final out = List<String>.filled(unique.length, '');
    var done = 0;
    // Chunk requests — sending a whole large subject at once overflows the model
    // and the tail comes back untranslated.
    for (var start = 0; start < unique.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, unique.length);
      final chunk = unique.sublist(start, end);
      List<String> fetched;
      String? model;
      try {
        final res = await _translateBatchViaAi(
          sentences: chunk,
          sourceLang: sourceLang,
          targetLang: targetLang,
          apiKey: apiKey,
        );
        fetched = res.translations;
        model = res.model;
      } catch (e) {
        // A daily-quota failure means every remaining chunk will fail too, so
        // the manual run stops and reports it. Any other error (transient 5xx,
        // a bad chunk) only fails this chunk — skip it and keep going so the
        // rest of a large run still completes. Auto mode ([graceful]) never
        // throws: it falls back to source so playback continues.
        if (!graceful && e is TranslationException && e.daily) rethrow;
        fetched = [...chunk];
      }
      final additions = <String, String>{};
      final modelAdditions = <String, String>{};
      for (var c = 0; c < chunk.length; c++) {
        final tr = c < fetched.length ? fetched[c] : chunk[c];
        out[start + c] = tr;
        // Don't cache failures (translation == source); leave them to retry.
        if (tr.trim() != chunk[c].trim()) {
          final key = _cacheKey(sourceLang, targetLang, chunk[c]);
          additions[key] = tr;
          modelAdditions[key] = model ?? '';
        }
      }
      await _mergeIntoCache(additions, models: modelAdditions);
      done += chunk.length;
      onProgress?.call(done, unique.length);
    }
    return out;
  }

  /// Translate a batch of sentences, returning cached ones immediately and
  /// fetching the rest. Each distinct uncached sentence is fetched only once,
  /// even if it appears multiple times in [sentences].
  Future<List<String>> translateBatch({
    required List<String> sentences,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
  }) async {
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return sentences;

    final cache = await _loadCache();
    final results = List<String?>.filled(sentences.length, null);
    final perIndexKey = [for (final s in sentences) _cacheKey(sourceLang, targetLang, s)];

    // Collect each distinct uncached sentence once.
    final unique = <String>[];
    final keyToUnique = <String, int>{};
    for (var i = 0; i < sentences.length; i++) {
      final key = perIndexKey[i];
      if (cache.containsKey(key)) {
        results[i] = cache[key];
      } else if (!keyToUnique.containsKey(key)) {
        keyToUnique[key] = unique.length;
        unique.add(sentences[i]);
      }
    }

    if (unique.isNotEmpty) {
      final fetched = await _fetchUnique(
        unique: unique,
        sourceLang: sourceLang,
        targetLang: targetLang,
        apiKey: apiKey,
        graceful: true,
      );
      for (var i = 0; i < sentences.length; i++) {
        results[i] ??= fetched[keyToUnique[perIndexKey[i]]!];
      }
    }

    return [for (var i = 0; i < sentences.length; i++) results[i] ?? sentences[i]];
  }

  /// Translate every sentence in [sentences] that is not already cached.
  /// Sends up to [chunkSize] uncached sentences per AI request.
  /// [onProgress] is called after each chunk with (done, total) where total is
  /// the number of sentences that actually needed fetching.
  /// Returns the number of sentences that could not be translated (translation
  /// equalled the source, indicating an API failure).
  Future<int> translateAllUncached({
    required List<String> sentences,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
    int chunkSize = 30,
    void Function(int done, int total, int attempt)? onProgress,
  }) async {
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return 0;

    // Try the whole set, then automatically retry whatever is still missing a
    // couple more times before asking the user to tap again — transient 5xx /
    // "busy" errors usually clear. Successes are cached, so each pass only
    // targets the leftovers. A daily-quota failure throws straight out (no point
    // retrying today). [attempt] (0-based) is passed to onProgress so the UI can
    // label retries differently.
    const maxAttempts = 3;
    var failed = 0;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final cache = await _loadCache();

      // Collect each distinct uncached sentence once (a sentence repeated in the
      // subject is translated a single time).
      final unique = <String>[];
      final seen = <String>{};
      for (final s in sentences) {
        final key = _cacheKey(sourceLang, targetLang, s);
        if (cache.containsKey(key) || !seen.add(key)) continue;
        unique.add(s);
      }

      if (unique.isEmpty) {
        onProgress?.call(0, 0, attempt);
        return 0;
      }

      // Report the total up front so the UI shows "0/N" during the first chunk
      // instead of nothing until the first chunk finishes.
      onProgress?.call(0, unique.length, attempt);

      final fetched = await _fetchUnique(
        unique: unique,
        sourceLang: sourceLang,
        targetLang: targetLang,
        apiKey: apiKey,
        graceful: false,
        chunkSize: chunkSize,
        onProgress: onProgress == null ? null : (done, total) => onProgress(done, total, attempt),
      );

      failed = 0;
      for (var u = 0; u < unique.length; u++) {
        if (fetched[u].trim() == unique[u].trim()) failed++;
      }
      if (failed == 0) return 0;
      if (attempt < maxAttempts - 1) await Future.delayed(const Duration(seconds: 2));
    }
    return failed;
  }

  // ── AI translation ────────────────────────────────────────────────────────

  Future<({String text, String? model})> _translateViaAi({
    required String sentence,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
    bool allowFallback = true,
  }) async {
    if (apiKey.trim().isEmpty) throw Exception('AI API key is empty (set it in Settings).');

    final prompt = '''
Translate the following sentence from $sourceLang to $targetLang.
Return ONLY the translated sentence, no explanation, no quotes.

Sentence: $sentence
''';

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {'temperature': 0.1},
    };

    final resp = await AiService.queryModel(apiKey, body, allowFallback: allowFallback);
    if (resp.statusCode != 200) throw _translationError(resp.statusCode, resp.body);

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) throw Exception('AI returned no candidates.');
    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) throw Exception('AI returned no content.');
    final model = decoded['modelVersion'] as String?;
    return (text: (parts.first['text'] as String? ?? sentence).trim(), model: model);
  }

  Future<({List<String> translations, String? model})> _translateBatchViaAi({
    required List<String> sentences,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) throw Exception('AI API key is empty (set it in Settings).');

    final numberedList = sentences.asMap().entries.map((e) => '${e.key + 1}. ${e.value}').join('\n');

    final prompt = '''
Translate the following numbered sentences from $sourceLang to $targetLang.
Return ONLY a JSON array of objects, one per sentence, each {"n": <the sentence number>, "t": <its translation>}.
Keep the same "n" the sentence was given. Do not merge, drop, or reorder sentences.
No extra keys, no explanation, no markdown.

Sentences:
$numberedList
''';

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
      'generationConfig': {
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'n': {'type': 'integer'},
              't': {'type': 'string'},
            },
            'required': ['n', 't'],
          },
        },
        'temperature': 0.1,
      },
    };

    final resp = await AiService.queryModel(apiKey, body);
    // Surface a human-readable cause instead of silently returning source text.
    if (resp.statusCode != 200) throw _translationError(resp.statusCode, resp.body);

    try {
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final model = decoded['modelVersion'] as String?;
      final candidates = decoded['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return (translations: sentences, model: model);
      final content = candidates.first['content'] as Map<String, dynamic>?;
      final parts = content?['parts'] as List?;
      if (parts == null || parts.isEmpty) return (translations: sentences, model: model);
      final text = (parts.first['text'] as String? ?? '').trim();
      final list = jsonDecode(text) as List;
      // Realign by the model's own "n" rather than by position. The old code
      // paired result[i] with sentence[i]; if the model dropped, merged, or
      // reordered even one item, every sentence after it got its neighbour's
      // translation cached against it ("still Greek, but wrong"). Slots the
      // model omits stay empty → returned as source → treated as a failure
      // (not cached) so they retry instead of poisoning the cache.
      final out = List<String>.filled(sentences.length, '');
      for (final item in list) {
        if (item is! Map) continue;
        final n = (item['n'] as num?)?.toInt();
        final t = item['t']?.toString().trim();
        if (n != null && t != null && t.isNotEmpty && n >= 1 && n <= sentences.length) {
          out[n - 1] = t;
        }
      }
      return (
        translations: [for (var i = 0; i < sentences.length; i++) out[i].isEmpty ? sentences[i] : out[i]],
        model: model,
      );
    } catch (_) {
      return (translations: sentences, model: null);
    }
  }
}
