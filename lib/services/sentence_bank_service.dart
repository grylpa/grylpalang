import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yaml/yaml.dart';

import '../models/sentence_bank.dart';
import 'ai_service.dart';

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

    cache[key] = translation;
    await _saveCache(cache);
    return translation;
  }

  /// Translate a batch of sentences, returning cached ones immediately and
  /// fetching the rest from AI in a single request.
  Future<List<String>> translateBatch({
    required List<String> sentences,
    required String sourceLang,
    required String targetLang,
    required String apiKey,
  }) async {
    if (sourceLang.toLowerCase() == targetLang.toLowerCase()) return sentences;

    final cache = await _loadCache();
    final results = List<String?>.filled(sentences.length, null);
    final toFetch = <int>[];

    for (var i = 0; i < sentences.length; i++) {
      final key = _cacheKey(sourceLang, targetLang, sentences[i]);
      if (cache.containsKey(key)) {
        results[i] = cache[key];
      } else {
        toFetch.add(i);
      }
    }

    if (toFetch.isNotEmpty) {
      final fetched = await _translateBatchViaAi(
        sentences: [for (final i in toFetch) sentences[i]],
        sourceLang: sourceLang,
        targetLang: targetLang,
        apiKey: apiKey,
      );

      for (var fi = 0; fi < toFetch.length; fi++) {
        final origIdx = toFetch[fi];
        final translation = fi < fetched.length ? fetched[fi] : sentences[origIdx];
        results[origIdx] = translation;
        cache[_cacheKey(sourceLang, targetLang, sentences[origIdx])] = translation;
      }

      await _saveCache(cache);
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

    final cache = await _loadCache();

    // Collect only uncached sentences (preserving original index for writing back).
    final uncached = <({int idx, String sentence})>[];
    for (var i = 0; i < sentences.length; i++) {
      if (!cache.containsKey(_cacheKey(sourceLang, targetLang, sentences[i]))) {
        uncached.add((idx: i, sentence: sentences[i]));
      }
    }

    if (uncached.isEmpty) {
      onProgress?.call(0, 0);
      return 0;
    }

    final total = uncached.length;
    var done = 0;
    var failed = 0;

    for (var start = 0; start < uncached.length; start += chunkSize) {
      final chunk = uncached.sublist(start, (start + chunkSize).clamp(0, uncached.length));
      final chunkSentences = chunk.map((e) => e.sentence).toList();

      final translations = await _translateBatchViaAi(
        sentences: chunkSentences,
        sourceLang: sourceLang,
        targetLang: targetLang,
        apiKey: apiKey,
      );

      for (var ci = 0; ci < chunk.length; ci++) {
        final orig = chunk[ci].sentence;
        final translation = ci < translations.length ? translations[ci] : orig;
        // Only cache if we got an actual translation (not a fallback to source text).
        if (translation != orig) {
          cache[_cacheKey(sourceLang, targetLang, orig)] = translation;
        } else {
          failed++;
        }
      }

      await _saveCache(cache);
      done += chunk.length;
      onProgress?.call(done, total);
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
    if (resp.statusCode != 200) throw Exception('AI translation failed (${resp.statusCode}).');

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
    if (resp.statusCode != 200) {
      // Fall back to translating one by one.
      final result = <String>[];
      for (final s in sentences) {
        try {
          result.add(await _translateViaAi(sentence: s, sourceLang: sourceLang, targetLang: targetLang, apiKey: apiKey));
        } catch (_) {
          result.add(s);
        }
      }
      return result;
    }

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
