import 'dart:convert';
// import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/word_sentence.dart';
import '../models/word_type.dart';
import '../widgets.dart';
import "../utils/http_date.dart";

class AiException implements Exception {
  final String message;
  AiException(this.message);

  @override
  String toString() => message;
}

class AiService {
  static const String _fallbackModelEndpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent';
  static const String _modelEndpoint = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent';

  // static Future<http.Response> queryModel(String apiKey, body) async {
  //   try {
  //     final uri = Uri.parse('$_modelEndpoint?key=$apiKey');
  //     final resp = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
  //     // final String respstr = 'status=${resp.statusCode}\nheaders=${resp.headers}\nbody=${resp.body}';
  //     if (resp.statusCode == 429) {
  //       // debugPrint("got resp $respstr");
  //       final uri = Uri.parse('$_fallbackModelEndpoint?key=$apiKey');
  //       final resp = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));
  //       return resp;
  //     }
  //     return resp;
  //   } catch (_) {
  //     http.Response resp = http.Response("exception", -1);
  //     return resp;
  //   }
  // }

  // A 429 whose RetryInfo asks us to wait longer than this is a daily-cap
  // exhaustion (per-minute windows recover in <60s). We don't block on those —
  // we return the 429 so the caller can surface "try again later".
  static const Duration _maxBackoff = Duration(seconds: 60);

  /// Parses `error.details[].retryDelay` (e.g. "27s") from a 429 body.
  static Duration? _retryDelayFrom(String body) {
    try {
      final details = (jsonDecode(body)['error']?['details'] as List?) ?? const [];
      for (final d in details) {
        if (d is Map && (d['@type']?.toString().contains('RetryInfo') ?? false)) {
          final m = RegExp(r'^(\d+(?:\.\d+)?)s$').firstMatch((d['retryDelay'] ?? '').toString().trim());
          if (m != null) return Duration(milliseconds: (double.parse(m.group(1)!) * 1000).round());
        }
      }
    } catch (_) {}
    return null;
  }

  /// True if a 429 body is a *daily* quota exhaustion (vs a per-minute window).
  /// Waiting it out is pointless, so callers should bail immediately.
  static bool isDailyQuota(String body) {
    try {
      final details = (jsonDecode(body)['error']?['details'] as List?) ?? const [];
      for (final d in details) {
        if (d is Map && (d['@type']?.toString().contains('QuotaFailure') ?? false)) {
          for (final v in (d['violations'] as List?) ?? const []) {
            final id = '${(v as Map)['quotaId'] ?? ''} ${v['quotaMetric'] ?? ''}'.toLowerCase();
            if (id.contains('perday') || id.contains('per_day') || id.contains('per day')) return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  static Future<http.Response> _post(String endpoint, String apiKey, body) =>
      http.post(Uri.parse('$endpoint?key=$apiKey'),
          headers: {'Content-Type': 'application/json'}, body: jsonEncode(body));

  static Future<http.Response> queryModel(String apiKey, body, {int maxRetries = 3}) async {
    try {
      var resp = await _post(_modelEndpoint, apiKey, body);
      if (resp.statusCode != 429) return resp;

      // Primary is rate-limited — try the lite model.
      var fb = await _post(_fallbackModelEndpoint, apiKey, body);
      if (fb.statusCode != 429) return fb;

      // Daily cap on both models: waiting won't help today — return now.
      if (isDailyQuota(fb.body) || isDailyQuota(resp.body)) return fb;

      // Per-minute window: honor RetryInfo with bounded backoff (recovers <60s).
      for (var attempt = 0; attempt < maxRetries; attempt++) {
        final delay = _retryDelayFrom(fb.body) ?? _retryDelayFrom(resp.body);
        if (delay == null || delay > _maxBackoff) return fb;
        await Future.delayed(delay + const Duration(milliseconds: 300));
        resp = await _post(_modelEndpoint, apiKey, body);
        if (resp.statusCode != 429) return resp;
        fb = await _post(_fallbackModelEndpoint, apiKey, body);
        if (fb.statusCode != 429) return fb;
      }
      return fb;
    } catch (e) {
      // Keep the real cause (SocketException, HandshakeException, etc.)
      throw AiException('Network/HTTP failure calling Gemini: $e');
    }
  }


  /// Evaluate a user's "prediction" answer using the AI model.
  ///
  /// The evaluator should be *meaning-aware* and forgiving about:
  /// - phonetic/transliteration input (e.g. Greeklish)
  /// - minor typos
  /// - missing tonos/diacritics
  /// - acceptable alternate word order
  ///
  /// Returns a JSON-like Map with these fields:
  /// - verdict: correct | mostly_correct | partially_correct | incorrect
  /// - score: 0..1
  /// - normalized_user_l2: a best-effort rewrite of the user's answer into the target script
  /// - feedback_short: 1-2 lines, friendly
  /// - feedback_detail: short actionable notes
  /// - target_word: assessment about the word-of-interest (can be empty)
  static Future<Map<String, dynamic>> evaluatePrediction({
    required String apiKey,
    required String knownLanguage,
    required String targetLanguage,
    required String promptL1,
    required String expectedL2,
    required String userAnswer,
    required String wordOfInterestL2,
    required String wordOfInterestL1,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('AI API key is empty (set it in Settings).');
    }

    final prompt = '''
You are a strict-but-kind language tutor and evaluator.

KNOWN LANGUAGE: $knownLanguage
TARGET LANGUAGE: $targetLanguage

TASK:
Given:
1) The prompt in the known language (what the learner saw)
2) The expected answer in the target language (canonical)
3) The learner's typed answer (may include Latin transliteration/phonetics, missing accents, small typos)
4) The "word of interest" (the word the sentence was generated from), in both languages

Decide how correct the learner's answer is.

IMPORTANT RULES:
- Be meaning-aware. If the learner wrote an equivalent sentence that conveys the same meaning, count it as correct.
- Be forgiving about word order if meaning is preserved.
- Be forgiving about missing tonos/diacritics.
- If the learner used Latin transliteration (Greeklish) or phonetics, treat it as an attempt to write the target language and map it mentally to the target script.
- If the learner mixed some known-language words, don't fail them automatically; judge whether they correctly produced the key target-language parts and meaning.
- Prefer encouragement. If it's correct, be HAPPY.

INPUT:
PROMPT: $promptL1
EXPECTED: $expectedL2
LEARNER_ANSWER: $userAnswer
WORD_OF_INTEREST_TARGET: $wordOfInterestL2
WORD_OF_INTEREST_KNOWN: $wordOfInterestL1

OUTPUT FORMAT (VERY IMPORTANT):
Return ONLY a JSON object and nothing else.
No markdown, no code fences, no explanations outside JSON.

The JSON must be:
{
  "verdict": "correct"|"mostly_correct"|"partially_correct"|"incorrect",
  "score": number,
  "normalized_user_l2": string,
  "feedback_short": string,
  "feedback_detail": string,
  "target_word": string
}

Guidance for score:
- correct: 0.92..1.0
- mostly_correct: 0.75..0.91
- partially_correct: 0.45..0.74
- incorrect: 0.0..0.44
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
          'type': 'object',
          'properties': {
            'verdict': {
              'type': 'string',
              'enum': ['correct', 'mostly_correct', 'partially_correct', 'incorrect'],
            },
            'score': {'type': 'number'},
            'normalized_user_l2': {'type': 'string'},
            'feedback_short': {'type': 'string'},
            'feedback_detail': {'type': 'string'},
            'target_word': {'type': 'string'},
          },
          'required': ['verdict', 'score', 'normalized_user_l2', 'feedback_short', 'feedback_detail', 'target_word'],
        },
        // Keep it cheap + deterministic.
        'temperature': 0.2,
      },
    };

    final resp = await queryModel(apiKey, body);
    if (resp.statusCode != 200) _throwAiError(resp, 'evaluatePrediction');

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('AI returned no candidates for evaluatePrediction');
    }

    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      throw Exception('AI returned empty content for evaluatePrediction');
    }

    final text = (parts.first['text'] as String? ?? '').trim();
    if (text.isEmpty) {
      throw Exception('AI returned empty text for evaluatePrediction');
    }

    final out = jsonDecode(text);
    if (out is! Map) throw Exception('AI returned non-object JSON for evaluatePrediction');
    return out.cast<String, dynamic>();
  }

  static ({String wordL2, String wordL1, List<WordSentence> sentences}) _parseWordAndSentencesJson(
      {required String jsonString, required String fallbackWord, required String fallbackKnownWord, required List<String> connectorWords}) {
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map) throw Exception('AI returned non-object JSON for combined word+sentences.');

    final wordL2 = ((decoded['word_l2'] as String?) ?? '').trim();
    final outWord = wordL2.isEmpty ? fallbackWord : wordL2;

    final wordL1 = ((decoded['word_l1'] as String?) ?? '').trim();
    final outKnownWord = wordL1.isEmpty ? fallbackKnownWord : wordL1;

    final raw = decoded['sentences'];
    if (raw is! List) throw Exception('AI combined response missing "sentences" array.');

    final result = <WordSentence>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final l2raw = (item['l2'] as String? ?? '').trim();
      final l2 = normalizeMarkersWithConnectorPolicy(l2raw, connectorWords);
      final l1 = (item['l1'] as String? ?? '').trim();
      if (l2.isEmpty && l1.isEmpty) continue;
      final l1conj = (item['l1conj'] as String? ?? outKnownWord).trim();
      result.add(WordSentence(l2: l2, l1: l1, word: outWord, translatedWord: l1conj));
    }

    return (wordL2: outWord, wordL1: outKnownWord, sentences: result);
  }
  /// Normalize a user-typed language name to a canonical English name
  /// (e.g. "ellinika", "Ελληνικά", "gr" -> "Greek").
  /// If anything goes wrong, just return the original input trimmed.
  static String _normKey(String s) {
    final lower = s.trim().toLowerCase();
    final cleaned = lower
        .replaceAll(RegExp(r"[_\-.,/\\()\[\]{}:;'|]+"),' ',)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned;
  }


  static String? _commonLanguageLookup(String input) {
    final k = _normKey(input);

    // Common aliases → canonical English name
    const map = <String, String>{
      // English
      'en': 'English',
      'eng': 'English',
      'english': 'English',

      // Greek
      'el': 'Greek',
      'ell': 'Greek',
      'gr': 'Greek',
      'greek': 'Greek',
      'modern greek': 'Greek',
      'ελληνικά': 'Greek',
      'ελληνικα': 'Greek',

      // Hebrew
      'he': 'Hebrew',
      'heb': 'Hebrew',
      'hebrew': 'Hebrew',
      'עברית': 'Hebrew',

      // German
      'de': 'German',
      'deu': 'German',
      'ger': 'German',
      'german': 'German',
      'deutsch': 'German',

      // French
      'fr': 'French',
      'fra': 'French',
      'french': 'French',
      'français': 'French',
      'francais': 'French',

      // Spanish
      'es': 'Spanish',
      'spa': 'Spanish',
      'spanish': 'Spanish',
      'español': 'Spanish',
      'espanol': 'Spanish',

      // Italian
      'it': 'Italian',
      'ita': 'Italian',
      'italian': 'Italian',
      'italiano': 'Italian',

      // Portuguese
      'pt': 'Portuguese',
      'por': 'Portuguese',
      'portuguese': 'Portuguese',
      'português': 'Portuguese',
      'portugues': 'Portuguese',

      // Russian
      'ru': 'Russian',
      'rus': 'Russian',
      'russian': 'Russian',
      'русский': 'Russian',

      // Turkish
      'tr': 'Turkish',
      'tur': 'Turkish',
      'turkish': 'Turkish',
      'türkçe': 'Turkish',
      'turkce': 'Turkish',

      // Arabic
      'ar': 'Arabic',
      'ara': 'Arabic',
      'arabic': 'Arabic',
      'العربية': 'Arabic',

      // Chinese
      'zh': 'Chinese',
      'chi': 'Chinese',
      'chinese': 'Chinese',
      '中文': 'Chinese',

      // Japanese
      'ja': 'Japanese',
      'jpn': 'Japanese',
      'japanese': 'Japanese',
      '日本語': 'Japanese',

      // Korean
      'ko': 'Korean',
      'kor': 'Korean',
      'korean': 'Korean',
      '한국어': 'Korean',
    };

    return map[k];
  }

  /// Normalize a user-typed language name to a canonical English name.
  ///
  /// Order:
  /// 1) common offline aliases
  /// 2) cached conversions (stored/loaded in settings)
  /// 3) Gemini (only if apiKey provided)
  ///
  /// If Gemini is used and succeeds, this updates [cache] (if provided).
  static Future<String> normalizeLanguageName({
    required String apiKey,
    required String userInput,
    Map<String, String>? cache,
  }) async {
    final input = userInput.trim();
    if (input.isEmpty) return input;

    // 1) Offline common lookup
    final common = _commonLanguageLookup(input);
    if (common != null) {
      cache?[_normKey(input)] = common;
      return common;
    }

    // 2) Cache lookup
    final key = _normKey(input);
    final cached = cache?[key];
    if (cached != null && cached.trim().isNotEmpty) {
      return cached.trim();
    }

    // 3) Gemini fallback (only if key exists)
    final keyTrimmed = apiKey.trim();
    if (keyTrimmed.isEmpty) return input;

    final prompt = '''
You normalize language names.

The user types something that *means* a language:
- It might be in English ("Greek", "english", "modern greek", "deutsch").
- It might be in the local language ("Ελληνικά", "Français", "עברית").
- It might be an abbreviation ("el", "en", "gr", "heb").
- It might contain minor typos ("greeek", "engish").

TASK:
1. Infer which language they mean.
2. Return ONLY a short English language name, like:
   - "Greek"
   - "English"
   - "German"
   - "Hebrew"
   - "Modern Greek"
3. If you really cannot tell, just return the original input unchanged.
4. No quotes, no extra words, no explanation.

USER INPUT: "$input"
''';

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
    };

    final resp = await queryModel(apiKey, body);
    if (resp.statusCode != 200) {
      return input; // fail soft
    }

    try {
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      final candidates = decoded['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) return input;
      final content = candidates.first['content'] as Map<String, dynamic>?;
      final parts = content?['parts'] as List?;
      if (parts == null || parts.isEmpty) return input;
      final text = (parts.first['text'] as String? ?? '').trim();
      if (text.isEmpty) return input;

      final normalized = text.split('\n').first.trim();
      if (normalized.isEmpty) return input;

      // Update cache
      cache?[key] = normalized;
      return normalized;
    } catch (_) {
      return input;
    }
  }


//   // Translate a single word from known language (L1) into target language (L2).
//   static Future<String> translateSingleWordToTarget({
//     required String apiKey,
//     required String input,
//     required String knownLanguage,
//     required String targetLanguage,
//   }) async {
//     if (apiKey.trim().isEmpty) {
//       throw Exception('AI API key is empty (set it in Settings).');
//     }
//
//     final prompt = '''
// You translate a *single word* into the TARGET LANGUAGE.
//
// KNOWN LANGUAGE (L1): $knownLanguage
// TARGET LANGUAGE (L2): $targetLanguage
//
// USER INPUT (L1): "$input"
//
// Rules:
// 1. Translate this into ONE common, natural word in $targetLanguage.
// 2. Use the correct native script of $targetLanguage (e.g. Greek letters for Greek).
// 3. If the input already looks like a correct $targetLanguage word, return it unchanged.
// 4. Return ONLY the final L2 word, no quotes, no explanation, no extra text.
// ''';
//
//     final body = {
//       'contents': [
//         {
//           'parts': [
//             {'text': prompt},
//           ],
//         },
//       ],
//     };
//
//     final resp = await queryModel(apiKey, body);
//
//     if (resp.statusCode != 200) {
//       // throw Exception('AI error ${resp.statusCode}: ${resp.body}');
//       _throwAiError(resp, 'translateSingleWordToTarget');
//     }
//
//     final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
//     final candidates = decoded['candidates'] as List?;
//     if (candidates == null || candidates.isEmpty) {
//       throw Exception('AI returned no candidates for translateSingleWordToTarget');
//     }
//
//     final content = candidates.first['content'] as Map<String, dynamic>?;
//     final parts = content?['parts'] as List?;
//     if (parts == null || parts.isEmpty) {
//       throw Exception('AI returned empty content for translateSingleWordToTarget');
//     }
//
//     final text = (parts.first['text'] as String? ?? '').trim();
//     if (text.isEmpty) {
//       throw Exception('AI returned empty text for translateSingleWordToTarget');
//     }
//
//     return text.split('\n').first.trim();
//   }

  /// Option A: one request that (a) produces/normalizes the final L2 word and (b) generates the sentences.
  /// This is used when adding a new word, to avoid doing two back-to-back Gemini calls.
  static Future<({String wordL2, String wordL1, List<WordSentence> sentences})> generateWordAndSentences({
    required String apiKey,
    String? wordL1,
    String? wordL2,
    required WordType type,
    required String knownLanguage,
    required String targetLanguage,
    required int simpleCount,
    required int conjugatedCount,
    required List<String> connectorWords,
  }) async {
    var sc = simpleCount;
    var cc = conjugatedCount;
    if (defaultTargetPlatform == TargetPlatform.linux) { sc = min(1, sc); cc = min(5, cc); }
    if (apiKey.trim().isEmpty) throw Exception('AI API key is empty (set it in Settings).');

    final l1 = (wordL1 ?? '').trim();
    final l2 = (wordL2 ?? '').trim();
    if (l1.isEmpty && l2.isEmpty) throw Exception('Enter a word in either known or target language.');
    if (l1.isNotEmpty && l2.isNotEmpty) throw Exception('Please fill only one of the two fields, not both.');

    final total = sc + cc;
    final typeText = switch (type) { WordType.verb => 'verb (action)', WordType.noun => 'noun (thing)', WordType.other => 'other word type', };
    final connectorsList = connectorWords.where((w) => w.trim().isNotEmpty).toList();
    final connectorsText = connectorsList.isEmpty ? '[]' : '[${connectorsList.map((w) => '"$w"').join(', ')}]';

    final inputSection = l2.isNotEmpty
        ? '''
USER INPUT WORD (might be phonetic LATIN or already correct L2): "$l2"

TASK A (normalize the word to L2):
1. If the word is phonetic Latin, convert it into the correct native $targetLanguage script.
2. If it is already in the correct script, keep it as-is.
3. Output the final normalized L2 word as: WORD_L2
4. Output the final normalized L1 word as: WORD_L1
'''
        : '''
USER INPUT WORD (L1): "$l1"

TASK A (translate to L2):
1. Translate this into ONE common, natural word in $targetLanguage.
2. Use the correct native script of $targetLanguage (e.g. Greek letters for Greek).
3. If the input already looks like a correct $targetLanguage word, return it unchanged.
4. Output the final L2 word as: WORD_L2
5. Output the final L1 word as: WORD_L1 in $knownLanguage
7. If the input L1 is not in $knownLanguage, translate it to $knownLanguage and output as WORD_L1
''';

    final prompt = '''
You are an expert language generator.

TARGET LANGUAGE (L2): $targetLanguage
KNOWN LANGUAGE (L1): $knownLanguage

WORD TYPE: $typeText

CONNECTOR WORDS (very important):
$connectorsText

$inputSection

TASK B (generate sentences using WORD_L2):

Rules:
1. Generate $total very short, simple sentences in L2 using WORD_L2.
2. First $sc sentences:
   - Use the simplest form of WORD_L2
     - verbs: 1st person present
     - nouns: base form (nominative singular)
3. Next $cc sentences:
   - Use other natural forms (different tenses/persons/cases/etc.).
4. CONNECTORS USAGE (IMPORTANT):
   - In AT LEAST 70% of the sentences, use ONE OR MORE of the connector words from: $connectorsText
   - Use them exactly as written (correct script), unless a very small change is required by grammar.
   - You can repeat the same connector across many sentences.
   - If there are no connector words (empty list), just ignore this rule.
5. Vocabulary:
   - Use only very common, easy words besides WORD_L2 and the connectors.
   - Sentences must be short and simple.
6. For WORD_L2 inside each L2 sentence:
   - Surround ONLY the main word form with [[double square brackets]].
   - There must be EXACTLY ONE [[...]] per sentence.
   - Do NOT put [[ ]] around connector words.
   - If the main word appears more than once, mark ONLY the FIRST occurrence.
   Example: Χθες [[πήγα]] στο σχολείο.
   BAD: [[και]] [[πήγα]] ...
   GOOD: και [[πήγα]] ...

For each sentence, return:
- "l2": sentence in target language (L2, correct script)
- "l1": sentence translated into known language (L1)

RETURN FORMAT (VERY IMPORTANT):
Return ONLY a JSON object and nothing else.
No explanations, no markdown, no comments.

The JSON object must be:
{
  "word_l2": "...",
  "word_l1": "...",
  "sentences": [
    {"l2": "...", "l1": "..."},
    ...
  ]
}
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
          'type': 'object',
          'properties': {
            'word_l2': {'type': 'string', 'description': 'Final L2 word in correct script.'},
            'word_l1': {'type': 'string', 'description': 'Final L1 word in correct script.'},
            'sentences': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'l2': {'type': 'string', 'description': 'L2 sentence. MUST contain exactly one [[...]] around the word form.'},
                  'l1': {'type': 'string', 'description': 'L1 translation.'},
                },
                'required': ['l2', 'l1'],
              },
            },
          },
          'required': ['word_l2', 'word_l1', 'sentences'],
        },
      },
    };

    final resp = await queryModel(apiKey, body);
    if (resp.statusCode != 200) _throwAiError(resp, 'generateWordAndSentences');

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) throw Exception('AI returned no candidates');

    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) throw Exception('AI returned no content parts');

    final text = (parts.first['text'] as String? ?? '').trim();
    if (text.isEmpty) throw Exception('AI returned empty text');

    final parsed = _parseWordAndSentencesJson(jsonString: text, fallbackWord: l2.isNotEmpty ? l2 : l1, fallbackKnownWord: l1, connectorWords: connectorWords);
    var sentences = parsed.sentences;
    if (sentences.length > total) sentences = sentences.take(total).toList();
    if (sentences.isEmpty) throw Exception('AI returned empty sentences list');

    return (wordL2: parsed.wordL2, wordL1: parsed.wordL1, sentences: sentences);
  }

  static Future<List<WordSentence>> generateSentences({
    required String apiKey,
    required String word,
    required String knownWord,
    required WordType type,
    required String knownLanguage,
    required String targetLanguage,
    required int simpleCount,
    required int conjugatedCount,
    required List<String> connectorWords,
  }) async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      simpleCount = min(1, simpleCount);
      conjugatedCount = min(5, conjugatedCount);
    }
    if (apiKey.trim().isEmpty) {
      throw Exception('AI API key is empty (set it in Settings).');
    }

    final total = simpleCount + conjugatedCount;
    final typeText = switch (type) {
      WordType.verb => 'verb (action)',
      WordType.noun => 'noun (thing)',
      WordType.other => 'other word type',
    };

    final connectorsList = connectorWords.where((w) => w.trim().isNotEmpty).toList();
    final connectorsText = connectorsList.isEmpty ? '[]' : '[${connectorsList.map((w) => '"$w"').join(', ')}]';

    final prompt = '''
You are an expert language generator.

TARGET LANGUAGE (L2): $targetLanguage
KNOWN LANGUAGE (L1): $knownLanguage

MAIN WORD IN L2 (already in correct script): "$word"
WORD TYPE: $typeText

CONNECTOR WORDS (very important):
$connectorsText

Rules:

1. Generate $total very short, simple sentences in L2 using the main word.
2. First $simpleCount sentences:
   - Use the simplest form of the main word
     - verbs: 1st person present
     - nouns: base form (nominative singular)
3. Next $conjugatedCount sentences:
   - Use other natural forms (different tenses/persons/cases/etc.).

4. CONNECTORS USAGE (IMPORTANT):
   - In AT LEAST 70% of the sentences, use ONE OR MORE of the connector words from:
     $connectorsText
   - Use them exactly as written (correct script), unless a very small change is required by grammar.
   - You can repeat the same connector across many sentences.
   - If there are no connector words (empty list), just ignore this rule.

5. Vocabulary:
   - Use only very common, easy words besides the main word and the connectors.
   - Sentences must be short and simple.
   
6. For the main word:
   - Surround ONLY the main word form with [[double square brackets]].
   - There must be EXACTLY ONE [[...]] per sentence.
   - Do NOT put [[ ]] around connector words.
   - Use the main word EXACTLY once per sentence, even if it's the first word.
Example: 
  Sentence: Χθες [[πήγα]] στο σχολείο.

For each sentence, return:
- "l2": sentence in target language (L2, correct script)
- "l1": sentence translated into known language (L1)
- "L1Conj": the correct conjugated form of the main word (for example: if L1 is english: she will go, i went) 

RETURN FORMAT (VERY IMPORTANT):
Return ONLY a JSON array and nothing else.
No explanations, no markdown, no comments.

Example of the format (structure only):

[
  {"l2": "sentence in L2", "l1": "sentence in L1", "L1Conj": "conjugated main word"},
  {"l2": "sentence in L2", "l1": "sentence in L1", "L1Conj": "conjugated main word"}
]
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
              'l2': {'type': 'string', 'description': 'L2 sentence. MUST contain exactly one [[...]] around the main word form.'},
              'l1': {'type': 'string', 'description': 'L1 translation.'},
              'l1conj':  {'type': 'string', 'description': 'conjugated main word in L1.'},
            },
            'required': ['l2', 'l1', 'l1conj'],
          },
        },
      },
    };

    final resp = await queryModel(apiKey, body);

    if (resp.statusCode != 200) {
      _throwAiError(resp, 'generateSentences');
      // throw Exception('AI error ${resp.statusCode}: ${resp.body}');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('AI returned no candidates');
    }

    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      throw Exception('AI returned no content parts');
    }

    final text = parts.first['text'] as String? ?? '';
    if (text.isEmpty) {
      throw Exception('AI returned empty text');
    }

    // final match = RegExp(r'\[[\s\S]*\]').firstMatch(text);
    // if (match == null) {
    //   throw Exception('AI response did not contain a valid JSON array:\n$text');
    // }
    // final jsonString = match.group(0)!;

    final jsonString = text.trim();
    late List<dynamic> list;
    try {
      list = jsonDecode(jsonString) as List<dynamic>;
    } catch (e) {
      throw Exception('JSON decode failed: $e\nExtracted JSON:\n$jsonString');
    }

    if (list.length > total) {
      list = list.take(total).toList();
    }

    final result = <WordSentence>[];
    for (final item in list) {
      final m = (item as Map).cast<String, dynamic>();
      final l2raw = (m['l2'] as String? ?? '').trim();
      final l2 = removeDuplicateMainWord(normalizeMarkersWithConnectorPolicy(l2raw, connectorWords));
      final l1 = (m['l1'] as String? ?? '').trim();
      final l1conj = (m['l1conj'] as String? ?? knownWord).trim();
      // debugPrint("got l1conj $l1conj");
      result.add(WordSentence(l2: l2, l1: l1, word: word, translatedWord: l1conj));
    }

    return result;
  }

  // Convert a single word from phonetic Latin to proper target-language script.
  static Future<String> normalizeWordToTargetScript({
    required String apiKey,
    required String word,
    required String targetLanguage,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('AI API key is empty (set it in Settings).');
    }

    final prompt = '''
You are a transliteration helper.

TARGET LANGUAGE: $targetLanguage
USER INPUT WORD: "$word"

The user might type the word in phonetic LATIN characters that approximate a $targetLanguage word.
Example for Greek:
- "thelo" -> "θέλω"
- "kalispera" -> "καλησπέρα"
- "gia" -> "για"
- "apo" -> "από"

TASK:
1. If the word is phonetic Latin, convert it into the correct native $targetLanguage script.
2. If it is already in the correct script, keep it as-is.
3. Return ONLY the corrected word, no quotes, no extra text, no explanation.
''';

    final body = {
      'contents': [
        {
          'parts': [
            {'text': prompt},
          ],
        },
      ],
    };

    final resp = await queryModel(apiKey, body);

    if (resp.statusCode != 200) {
      // throw Exception('AI error ${resp.statusCode}: ${resp.body}');
      _throwAiError(resp, 'normalizeWordToTargetScript');
    }

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List?;
    if (candidates == null || candidates.isEmpty) {
      throw Exception('AI returned no candidates for connector word');
    }

    final content = candidates.first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List?;
    if (parts == null || parts.isEmpty) {
      throw Exception('AI returned empty content for connector word');
    }

    final text = (parts.first['text'] as String? ?? '').trim();
    if (text.isEmpty) {
      throw Exception('AI returned empty text for connector word');
    }

    final firstLine = text.split('\n').first.trim();
    return firstLine;
  }

  /// Simple key test for SettingsScreen.
  /// Returns true if Gemini replies with 200 OK.
  static Future<bool> testApiKey(String apiKey) async {
    final key = apiKey.trim();
    if (key.isEmpty) return false;

    final body = {
      'contents': [
        {
          'parts': [
            {'text': 'Test.'},
          ],
        },
      ],
    };

    final resp = await queryModel(apiKey, body);
    return resp.statusCode == 200;
  }

  static Never _throwAiError(http.Response resp, String where) {
    // Fast path: handle common cases without assuming JSON.
    if (resp.statusCode == 429) {
      final d = _retryAfterDuration(resp);
      if (d != null && d > Duration.zero) throw AiException('Gemini API quota exceeded. ${_formatRetryAfterMessage(d)}');
      final d2 = _retryDelayFromGeminiBody(resp.body);
      if (d2 != null && d2 > Duration.zero) throw AiException('Gemini API quota exceeded. ${_formatRetryAfterMessage(d2)}');
      throw AiException('Gemini API quota exceeded. Please try again in a bit.');
    }
    if (resp.statusCode == 503 || resp.statusCode == 502) {
      final d = _retryAfterDuration(resp);
      if (d != null && d > Duration.zero) throw AiException('AI service is temporarily busy. ${_formatRetryAfterMessage(d)}');
      throw AiException('AI service is temporarily busy. Please try again in a bit.');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw AiException(
        'Gemini API key seems invalid or unauthorized. Check it in Settings.',
      );
    }

    // Now *optionally* parse JSON for nicer messages.
    try {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map && decoded['error'] is Map) {
        final err = decoded['error'] as Map;
        final status = (err['status'] as String?) ?? '';
        final msg = (err['message'] as String?) ?? '';

        // Some Gemini responses use RESOURCE_EXHAUSTED even if code != 429.
        if (status == 'RESOURCE_EXHAUSTED') {
          throw AiException(
            'Gemini API quota exceeded. Please wait a bit or reduce usage.',
          );
        }

        // Generic, but still short
        if (msg.isNotEmpty) {
          throw AiException('AI error ($status): $msg');
        }
      }
    } catch (_) {
      // fall through to generic error
    }

    // Fallback if we couldn’t parse nicely
    throw AiException('AI error ${resp.statusCode} in $where.');
  }

  static Duration? _retryAfterDuration(http.Response resp) {
    final v = resp.headers.entries.firstWhere((e) => e.key.toLowerCase() == 'retry-after', orElse: () => const MapEntry('', '')).value.trim();
    if (v.isEmpty) return null;

    final seconds = int.tryParse(v);
    if (seconds != null) return Duration(seconds: seconds < 0 ? 0 : seconds);

    final delay = parseDelay(v);
    return delay;
    // // HTTP-date format
    // try {
    //   DateTime whenUtc;
    //   if (kIsWeb) {
    //     whenUtc = DateTime.parse(v).toUtc();
    //   } else {
    //     whenUtc = HttpDate.parse(v);
    //   }
    //   final nowUtc = DateTime.now().toUtc();
    //   final d = whenUtc.difference(nowUtc);
    //   return d.isNegative ? Duration.zero : d;
    // } catch (_) {
    //   return null;
    // }
  }

  static String _formatRetryAfterMessage(Duration d) {
    final nowLocal = DateTime.now();
    final whenLocal = nowLocal.add(d);

    String rel;
    if (d.inSeconds < 60) { rel = '${d.inSeconds}s'; }
    else if (d.inMinutes < 60) { rel = '${d.inMinutes} min'; }
    else { rel = '${d.inHours} h'; }

    final hh = whenLocal.hour.toString().padLeft(2, '0');
    final mm = whenLocal.minute.toString().padLeft(2, '0');

    return 'Please try again after $rel (around $hh:$mm).';
  }

  static Duration? _retryDelayFromGeminiBody(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded['error'];
      if (error is! Map) return null;

      final details = error['details'];
      if (details is List) {
        for (final d in details) {
          if (d is Map && d['@type'] == 'type.googleapis.com/google.rpc.RetryInfo') {
            final v = d['retryDelay'];
            if (v is String && v.endsWith('s')) {
              final secs = double.tryParse(v.substring(0, v.length - 1));
              if (secs != null) return Duration(milliseconds: (secs * 1000).round());
            }
          }
        }
      }

      // Fallback: parse from message text
      final msg = error['message'];
      if (msg is String) {
        final m = RegExp(r'retry in ([0-9.]+)s', caseSensitive: false).firstMatch(msg);
        if (m != null) {
          final secs = double.tryParse(m.group(1)!);
          if (secs != null) return Duration(milliseconds: (secs * 1000).round());
        }
      }
    } catch (_) {
      // ignore
    }
    return null;
  }

}
