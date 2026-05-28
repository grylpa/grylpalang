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
  static const String _kCachedYamlKey = 'sentenceBankCachedYaml';

  final SharedPreferencesAsync _prefs;

  SentenceBankService(this._prefs);

  // ── Loading ──────────────────────────────────────────────────────────────

  /// Load the sentence bank. If [url] is non-empty, tries to fetch from that
  /// URL and caches the result locally. Falls back to the bundled asset.
  Future<SentenceBank> loadBank({String url = ''}) async {
    String yaml;

    if (url.trim().isNotEmpty) {
      yaml = await _fetchFromUrl(url.trim());
    } else {
      yaml = await rootBundle.loadString(_kAssetPath);
    }

    final parsed = loadYaml(yaml);
    if (parsed is! Map) throw Exception('Invalid sentence bank format.');
    return SentenceBank.fromYaml(parsed);
  }

  /// Non-null if the last [_fetchFromUrl] call fell back to cache or asset.
  String? lastFetchWarning;

  /// Strips the commit hash from GitHub Gist raw URLs so we always fetch the latest revision.
  /// e.g. `.../raw/abc123.../file.yaml` → `.../raw/file.yaml`
  static String _normalizeUrl(String url) => url.replaceFirstMapped(
        RegExp(r'(gist\.githubusercontent\.com/.+/raw/)[0-9a-f]{40}/'),
        (m) => m.group(1)!,
      );

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
      final resp = await http.get(Uri.parse(bustUrl)).timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final body = resp.body;
        await _prefs.setString(_kCachedYamlKey, body);
        return body;
      }
      lastFetchWarning = 'HTTP ${resp.statusCode} — showing cached version.';
    } catch (e) {
      lastFetchWarning = 'Fetch failed ($e) — showing cached version.';
    }

    // Fall back to cached YAML or bundled asset.
    final cached = await _prefs.getString(_kCachedYamlKey);
    if (cached != null && cached.isNotEmpty) return cached;
    lastFetchWarning = '${lastFetchWarning ?? 'Fetch failed'} No cache — using built-in bank.';
    return await rootBundle.loadString(_kAssetPath);
  }

  // ── Translation cache ─────────────────────────────────────────────────────

  Future<Map<String, String>> _loadCache() async {
    final raw = await _prefs.getString(_kTranslationCacheKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      return (jsonDecode(raw) as Map).cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveCache(Map<String, String> cache) async {
    await _prefs.setString(_kTranslationCacheKey, jsonEncode(cache));
  }

  Future<void> clearTranslationCache() async {
    await _prefs.remove(_kTranslationCacheKey);
  }

  static String _cacheKey(String sourceLang, String targetLang, String sentence) =>
      '$sourceLang|$targetLang|$sentence';

  // ── Subject history ───────────────────────────────────────────────────────

  static const String _kSubjectHistoryKey = 'sentenceBankSubjectHistory';
  static const String _kLastSubjectKey = 'sentenceBankLastSubject';

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

  static const String _kPositionsKey = 'sentenceBankPositions';

  Future<int> loadPosition(String subject) async {
    final raw = await _prefs.getString(_kPositionsKey);
    if (raw == null) return 0;
    try {
      final map = jsonDecode(raw) as Map;
      return (map[subject] as int?) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> savePosition(String subject, int index) async {
    final raw = await _prefs.getString(_kPositionsKey);
    final map = <String, int>{};
    if (raw != null) {
      try {
        map.addAll((jsonDecode(raw) as Map).cast<String, int>());
      } catch (_) {}
    }
    map[subject] = index;
    await _prefs.setString(_kPositionsKey, jsonEncode(map));
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
  /// caches the result.
  Future<String> translate({
    required String sentence,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
  }) async {
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return sentence;

    final cache = await _loadCache();
    final key = _cacheKey(sourceLang, targetLang, sentence);
    if (cache.containsKey(key)) return cache[key]!;

    final translation = await _translateViaAi(
      sentence: sentence,
      sourceLang: sourceLang,
      targetLang: targetLang,
      apiKey: apiKey,
    );

    // Only cache a real translation — a result equal to the source means the AI
    // failed/echoed; caching it would poison the cache (and get spoken by the
    // target-language TTS). Leave it uncached so it retries next time.
    if (translation.trim() != sentence.trim()) {
      cache[key] = translation;
      await _saveCache(cache);
    }
    return translation;
  }

  /// Fetches AI translations for [unique] sentences (already de-duplicated and
  /// known to be uncached), in chunks, writing each success into [cache] and
  /// persisting after every chunk. Returns a parallel list of results (the
  /// source text where a translation failed). When [graceful] is false a chunk
  /// error propagates to the caller (so the manual button can report it);
  /// otherwise the chunk falls back to source so auto mode keeps playing.
  Future<List<String>> _fetchUnique({
    required List<String> unique,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
    required Map<String, String> cache,
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
      try {
        fetched = await _translateBatchViaAi(
          sentences: chunk,
          sourceLang: sourceLang,
          targetLang: targetLang,
          apiKey: apiKey,
        );
      } catch (e) {
        // A daily-quota failure means every remaining chunk will fail too, so
        // the manual run stops and reports it. Any other error (transient 5xx,
        // a bad chunk) only fails this chunk — skip it and keep going so the
        // rest of a large run still completes. Auto mode ([graceful]) never
        // throws: it falls back to source so playback continues.
        if (!graceful && e is TranslationException && e.daily) rethrow;
        fetched = [...chunk];
      }
      for (var c = 0; c < chunk.length; c++) {
        final tr = c < fetched.length ? fetched[c] : chunk[c];
        out[start + c] = tr;
        // Don't cache failures (translation == source); leave them to retry.
        if (tr.trim() != chunk[c].trim()) {
          cache[_cacheKey(sourceLang, targetLang, chunk[c])] = tr;
        }
      }
      await _saveCache(cache);
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
        cache: cache,
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
    void Function(int done, int total)? onProgress,
  }) async {
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return 0;

    // Try the whole set, then automatically retry whatever is still missing a
    // couple more times before asking the user to tap again — transient 5xx /
    // "busy" errors usually clear. Successes are cached, so each pass only
    // targets the leftovers. A daily-quota failure throws straight out (no point
    // retrying today).
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
        onProgress?.call(0, 0);
        return 0;
      }

      // Report the total up front so the UI shows "0/N" during the first chunk
      // instead of nothing until the first chunk finishes.
      onProgress?.call(0, unique.length);

      final fetched = await _fetchUnique(
        unique: unique,
        sourceLang: sourceLang,
        targetLang: targetLang,
        apiKey: apiKey,
        cache: cache,
        graceful: false,
        chunkSize: chunkSize,
        onProgress: onProgress,
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

  Future<String> _translateViaAi({
    required String sentence,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
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

    final resp = await AiService.queryModel(apiKey, body);
    if (resp.statusCode != 200) throw _translationError(resp.statusCode, resp.body);

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) throw Exception('AI returned no candidates.');
    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) throw Exception('AI returned no content.');
    return (parts.first['text'] as String? ?? sentence).trim();
  }

  Future<List<String>> _translateBatchViaAi({
    required List<String> sentences,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
  }) async {
    if (apiKey.trim().isEmpty) throw Exception('AI API key is empty (set it in Settings).');

    final numberedList = sentences.asMap().entries.map((e) => '${e.key + 1}. ${e.value}').join('\n');

    final prompt = '''
Translate the following numbered sentences from $sourceLang to $targetLang.
Return ONLY a JSON array of translated strings in the same order.
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
          'items': {'type': 'string'},
        },
        'temperature': 0.1,
      },
    };

    final resp = await AiService.queryModel(apiKey, body);
    // Surface a human-readable cause instead of silently returning source text.
    if (resp.statusCode != 200) throw _translationError(resp.statusCode, resp.body);

    try {
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final candidates = decoded['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return sentences;
      final content = candidates.first['content'] as Map<String, dynamic>?;
      final parts = content?['parts'] as List?;
      if (parts == null || parts.isEmpty) return sentences;
      final text = (parts.first['text'] as String? ?? '').trim();
      final list = jsonDecode(text) as List;
      return list.map((e) => e.toString().trim()).toList();
    } catch (_) {
      return sentences;
    }
  }
}
