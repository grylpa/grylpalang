import 'dart:async';
import 'dart:convert';
// import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/word_sentence.dart';
import '../models/ai_engine.dart';
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
  /// The generation every request goes to. Set once from settings (see
  /// [AppState]) rather than threaded through each call: there is one engine per
  /// process, and passing it to forty call sites would only create forty chances
  /// to forget.
  static AiEngine engine = AiEngine.gemini25;

  static String _endpoint(String model) =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent';

  /// Which model actually answered, and how many answers each has given.
  ///
  /// The chain means the model that serves a request is not always the one that
  /// was asked first, and nothing in the response says which it was. Counting
  /// here is the only way to know whether you are really running on 3.8 or
  /// quietly living on the fallback — without putting a badge on every screen.
  static String lastModel = '';
  static Map<String, int> modelCalls = {};

  /// What the current request is doing right now: which model is being asked,
  /// or how long it is waiting out a rate limit. Empty when nothing is in
  /// flight.
  ///
  /// A notifier rather than a snackbar: a single call can try four models and
  /// sit through two backoffs, and four snackbars would cover the screen to say
  /// what one line beside the existing spinner says better. Screens that show a
  /// spinner for an AI call watch this and print it underneath.
  static final ValueNotifier<String> activity = ValueNotifier<String>('');

  /// Incremented when a *new model* is tried. The banner flashes on this, not on
  /// every text change, so the elapsed-time ticks below don't strobe.
  static final ValueNotifier<int> activityStep = ValueNotifier<int>(0);

  static const String _kUsageKey = 'aiModelUsage';

  /// Restores the tally at startup so it reads as history, not "since launch".
  static Future<void> loadUsage() async {
    try {
      final raw = await SharedPreferencesAsync().getString(_kUsageKey);
      if (raw == null) return;
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      lastModel = map['last'] as String? ?? '';
      modelCalls = ((map['calls'] as Map?) ?? {}).map((k, v) => MapEntry(k.toString(), (v as num).toInt()));
      failures = [
        for (final f in (map['failures'] as List?) ?? const [])
          if (f is Map)
            (
              at: DateTime.tryParse(f['at']?.toString() ?? '') ?? DateTime.now(),
              model: f['model']?.toString() ?? '?',
              detail: f['detail']?.toString() ?? '',
            ),
      ];
    } catch (_) {}
  }

  /// A rolling log of failed attempts, oldest first: every fallback the app has
  /// taken, with when and why.
  ///
  /// A list, not a per-model map — a map keeps only the newest failure for each
  /// model, so five entries is the most it could ever show and a repeated
  /// pattern (the same model refusing all afternoon) stayed invisible. Capped
  /// and persisted alongside the usage tally, so it survives a restart and is
  /// still there when you go looking after the fact.
  static List<({DateTime at, String model, String detail})> failures = [];

  static const int _kMaxFailures = 60;

  /// The newest failure per model, derived from [failures].
  static Map<String, String> get lastErrors {
    final out = <String, String>{};
    for (final f in failures) out[f.model] = f.detail;
    return out;
  }

  /// Why the previous model was abandoned, carried into the next model's
  /// message so the banner explains the move instead of just naming a new
  /// model. Null on a first attempt.
  static String? _lastReason;

  /// Model ids are long and all start the same way; the tail is the part that
  /// distinguishes them.
  static String _shortName(String model) => model.replaceFirst('gemini-', '');

  static String _shortReason(int status) => switch (status) {
    429 => 'rate-limited',
    404 => 'unavailable',
    401 || 403 => 'key rejected',
    _ when status >= 500 => 'server busy',
    _ => 'failed',
  };

  /// Posts to [model], reporting it through [activity].
  ///
  /// The delay before a first attempt announces itself is what keeps the banner
  /// off screen for ordinary fast calls while still explaining a slow one —
  /// which, from the outside, is indistinguishable from a hung spinner.
  static Future<http.Response> _postAnnounced(
    String model,
    String apiKey,
    dynamic body, {
    required bool immediate,
  }) async {
    final name = _shortName(model);
    final because = _lastReason == null ? '' : '$_lastReason — ';
    final started = DateTime.now();
    var base = '';
    Timer? announce;
    activityStep.value++;
    if (immediate) {
      base = '${because}trying $name…';
      activity.value = base;
    } else {
      announce = Timer(const Duration(milliseconds: 1500), () {
        base = 'Asking $name…';
        activity.value = base;
      });
    }
    // A generation can now run for a minute or more, and a message frozen for
    // that long reads as a hang. Ticking the elapsed time is the cheapest honest
    // way to show it is still going — and the wording changes once it is long
    // enough to be worth explaining.
    final tick = Timer.periodic(const Duration(seconds: 10), (_) {
      if (base.isEmpty) return;
      final secs = DateTime.now().difference(started).inSeconds;
      final note = secs >= 45 ? ' — long texts take a while' : '';
      activity.value = '$base  ${secs}s$note';
    });
    try {
      return await _post(_endpoint(model), apiKey, body).timeout(_requestTimeout);
    } finally {
      announce?.cancel();
      tick.cancel();
    }
  }

  /// Stands in for "nothing answered at all" — every model timed out, so there
  /// is no real response to report. Shaped like Gemini's own error body so the
  /// usual error path can read it.
  static http.Response _noAnswer() => http.Response(
    jsonEncode({
      'error': {'status': 'UNAVAILABLE', 'message': 'No model answered in time.'},
    }),
    503,
  );

  static void _recordError(String model, http.Response resp) {
    var detail = '';
    try {
      final err = jsonDecode(resp.body)['error'];
      if (err is Map) detail = (err['message'] as String? ?? '').split('\n').first.trim();
    } catch (_) {}
    if (detail.length > 200) detail = '${detail.substring(0, 197)}…';
    _recordFailure(model, detail.isEmpty ? '${resp.statusCode}' : '${resp.statusCode} — $detail');
  }

  static void _recordFailure(String model, String detail) {
    failures.add((at: DateTime.now(), model: model, detail: detail));
    if (failures.length > _kMaxFailures) failures.removeRange(0, failures.length - _kMaxFailures);
    _persistUsage();
  }

  static void _recordUse(String model) {
    lastModel = model;
    modelCalls[model] = (modelCalls[model] ?? 0) + 1;
    _persistUsage();
  }

  /// Fire and forget: a lost tally is not worth failing or delaying a request.
  static void _persistUsage() {
    unawaited(
      SharedPreferencesAsync().setString(
        _kUsageKey,
        jsonEncode({
          'last': lastModel,
          'calls': modelCalls,
          'failures': [
            for (final f in failures) {'at': f.at.toIso8601String(), 'model': f.model, 'detail': f.detail},
          ],
        }),
      ),
    );
  }

  /// Asks one model a trivial question and reports what it says.
  ///
  /// Per model rather than per chain so the caller can show progress: the probe
  /// is the one way to tell "this account cannot use 3.8 at all" (404, or a 429
  /// with a zero limit) from "3.8 was briefly overloaded" — a distinction the
  /// normal error path hides, because by then the chain has moved on and the
  /// message describes only whatever answered last.
  static Future<({int status, String detail})> probeModel(String apiKey, String model) async {
    try {
      final resp = await _post(
        _endpoint(model),
        apiKey,
        _adaptBody({
          'contents': [
            {
              'parts': [
                {'text': 'ping'},
              ],
            },
          ],
          'generationConfig': {'maxOutputTokens': 8},
        }),
      );
      var detail = '';
      if (resp.statusCode != 200) {
        try {
          final err = jsonDecode(resp.body)['error'];
          if (err is Map) detail = (err['message'] as String? ?? '').split('\n').first.trim();
        } catch (_) {}
        if (detail.length > 140) detail = '${detail.substring(0, 137)}…';
      }
      return (status: resp.statusCode, detail: detail);
    } catch (e) {
      return (status: -1, detail: e.toString().split('\n').first.trim());
    }
  }

  /// Forgets the tally (Settings → the model-usage dialog).
  static Future<void> clearUsage() async {
    lastModel = '';
    modelCalls = {};
    failures = [];
    try {
      await SharedPreferencesAsync().remove(_kUsageKey);
    } catch (_) {}
  }

  /// Rewrites a request body for the selected engine.
  ///
  /// Done centrally, at the one place every request passes through, so a call
  /// site can go on asking for the temperature it wants without knowing whether
  /// the current model accepts one. Gemini 3.x removed the sampling parameters
  /// and added a thinking level; sending a parameter a model doesn't take can
  /// fail the request outright, so they are stripped rather than left to luck.
  static Map<String, dynamic> _adaptBody(dynamic body) {
    if (body is! Map) return <String, dynamic>{};
    final out = Map<String, dynamic>.from(body);
    final cfg = out['generationConfig'];
    final g = cfg is Map ? Map<String, dynamic>.from(cfg) : <String, dynamic>{};
    if (!engine.acceptsSampling) {
      for (final k in const ['temperature', 'topP', 'top_p', 'topK', 'top_k', 'candidateCount', 'candidate_count']) {
        g.remove(k);
      }
    }
    final level = engine.thinkingLevel;
    if (level != null) g['thinkingConfig'] = {'thinkingLevel': level};
    if (g.isNotEmpty) out['generationConfig'] = g;
    return out;
  }

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

  // Everything a single call may spend, across every model and retry — request
  // time included, which is the part that actually runs away. Checked before
  // every request and every backoff, not only between passes.
  static const Duration _maxTotalWait = Duration(seconds: 150);

  // One HTTP request.
  //
  // Long on purpose. The first model in the chain is the one doing the actual
  // work — twenty-odd sentences with translations, with thinking on — and that
  // genuinely runs to a minute or more. A tighter cap made things *slower*, not
  // safer: it cut off a generation that was going to succeed, threw the work
  // away, and fell through to models that refuse instantly because the minute's
  // quota is already spent, before a later pass came back to the first model and
  // finally got the answer. This is here only to catch a request that has truly
  // stopped answering.
  static const Duration _requestTimeout = Duration(seconds: 120);

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

  static Future<http.Response> _post(String endpoint, String apiKey, body) => http.post(
    Uri.parse('$endpoint?key=$apiKey'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(body),
  );

  static Future<http.Response> queryModel(String apiKey, body, {int maxRetries = 3, bool allowFallback = true}) async {
    try {
      body = _adaptBody(body);
      // A caller may want the primary model only (e.g. manual re-translate,
      // which must not silently produce a weaker lite translation). It then gets
      // the failure back and can say "try again later" instead of caching worse
      // output.
      final chain = allowFallback ? engine.models : [engine.primaryModel];
      // A hard wall-clock stop. Without it a chain of five models, each with its
      // own RetryInfo backoff, can spin for minutes behind a spinner while the
      // user waits on what is meant to be an interactive action.
      final deadline = DateTime.now().add(_maxTotalWait);
      _lastReason = null;

      // Nullable: every model in the chain can time out without ever producing
      // a response to hold onto.
      http.Response? last;
      // One pass down the chain, then up to [maxRetries] more after a backoff.
      for (var attempt = 0; attempt <= maxRetries; attempt++) {
        var dailyCapped = false;
        for (final model in chain) {
          // Checked per model, not just per pass: without this the deadline only
          // ever cut a *backoff* short, and a chain of slow requests sailed past
          // it — which is exactly the "took forever" case.
          if (DateTime.now().isAfter(deadline) && attempt > 0) {
            activity.value = '';
            return last ?? _noAnswer();
          }
          final http.Response resp;
          try {
            resp = await _postAnnounced(
              model,
              apiKey,
              body,
              // A fallback is announced at once — something already went wrong.
              // The very first attempt only announces itself if it turns out to be
              // slow, so a normal quick call stays silent.
              immediate: !(model == chain.first && attempt == 0),
            );
          } on TimeoutException {
            // Treated exactly like a 5xx: this model isn't answering, the next
            // one might.
            _recordFailure(model, 'timed out after ${_requestTimeout.inSeconds}s');
            _lastReason = '${_shortName(model)} timed out';
            continue;
          }
          if (resp.statusCode == 200) {
            _recordUse(model);
            activity.value = '';
            return resp;
          }
          _recordError(model, resp);
          last = resp;
          // Worth asking the next model: it is rate-limited (429), overloaded or
          // erroring server-side (5xx), or simply not available to this key
          // (404 — which is exactly what a model the account can't use returns,
          // and aborting the whole chain on it would make one missing model look
          // like a total outage). Anything else — a bad key, a malformed
          // request — will fail identically everywhere, so report it now.
          final worthNext = resp.statusCode == 429 || resp.statusCode == 404 || resp.statusCode >= 500;
          if (!worthNext) {
            activity.value = '';
            return resp;
          }
          _lastReason = '${_shortName(model)} ${_shortReason(resp.statusCode)}';
          dailyCapped = dailyCapped || isDailyQuota(resp.body);
        }
        // Every model failed. A daily cap won't lift by waiting, and a caller
        // that opted out of fallbacks wants the failure now, not in a minute.
        if (dailyCapped || !allowFallback) {
          activity.value = '';
          return last ?? _noAnswer();
        }
        // Per-minute window: honor RetryInfo with bounded backoff (recovers <60s).
        final delay = last == null ? null : _retryDelayFrom(last.body);
        if (delay == null || delay > _maxBackoff || DateTime.now().add(delay).isAfter(deadline)) {
          activity.value = '';
          return last ?? _noAnswer();
        }
        activity.value = 'Every model busy — waiting ${delay.inSeconds}s…';
        _lastReason = null;
        await Future.delayed(delay + const Duration(milliseconds: 300));
      }
      activity.value = '';
      return last ?? _noAnswer();
    } catch (e) {
      activity.value = '';
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

    final prompt =
        '''
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
- If the learner used Latin transliteration or phonetics, treat it as an attempt to write the target language and map it mentally to the target script.
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

  /// Maps the model's `word_type` string onto the enum. Anything unrecognised
  /// becomes [WordType.other], which is also what an older cached response
  /// without the field yields.
  static WordType _wordTypeFrom(String? raw) {
    final v = (raw ?? '').trim().toLowerCase();
    if (v.contains('both')) return WordType.both;
    if (v.contains('verb')) return WordType.verb;
    if (v.contains('noun')) return WordType.noun;
    return WordType.other;
  }

  static ({String wordL2, String wordL1, WordType type, String typeLabel, List<WordSentence> sentences})
  _parseWordAndSentencesJson({
    required String jsonString,
    required String fallbackWord,
    required String fallbackKnownWord,
    required List<String> connectorWords,
  }) {
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
      // A sentence may carry its own base word: for an ambiguous entry the two
      // senses are usually different lexemes in L2 (English "walk" is
      // περπατάω but περπάτημα), and the cloze needs the one this sentence
      // actually uses.
      final own = (item['word'] as String? ?? '').trim();
      result.add(WordSentence(l2: l2, l1: l1, word: own.isEmpty ? outWord : own, translatedWord: l1conj));
    }

    final rawType = (decoded['word_type'] as String? ?? '').trim();
    return (
      wordL2: outWord,
      wordL1: outKnownWord,
      type: _wordTypeFrom(rawType),
      typeLabel: rawType.isEmpty ? WordType.other.label : rawType,
      sentences: result,
    );
  }

  /// Normalize a user-typed language name to a canonical English name
  /// (e.g. "ellinika", "Ελληνικά", "gr" -> "Greek").
  /// If anything goes wrong, just return the original input trimmed.
  static String _normKey(String s) {
    final lower = s.trim().toLowerCase();
    final cleaned = lower.replaceAll(RegExp(r"[_\-.,/\\()\[\]{}:;'|]+"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
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

    final prompt =
        '''
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
  // 2. Use the correct native script of $targetLanguage (e.g. Greek letters for Greek, Cyrillic for Russian).
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
  static Future<({String wordL2, String wordL1, WordType type, String typeLabel, List<WordSentence> sentences})>
  generateWordAndSentences({
    required String apiKey,
    String? wordL1,
    String? wordL2,
    required String knownLanguage,
    required String targetLanguage,
    required int simpleCount,
    required int conjugatedCount,
    required List<String> connectorWords,
  }) async {
    var sc = simpleCount;
    var cc = conjugatedCount;
    if (defaultTargetPlatform == TargetPlatform.linux) {
      sc = min(1, sc);
      cc = min(5, cc);
    }
    if (apiKey.trim().isEmpty) throw Exception('AI API key is empty (set it in Settings).');

    final l1 = (wordL1 ?? '').trim();
    final l2 = (wordL2 ?? '').trim();
    if (l1.isEmpty && l2.isEmpty) throw Exception('Enter a word in either known or target language.');
    if (l1.isNotEmpty && l2.isNotEmpty) throw Exception('Please fill only one of the two fields, not both.');

    final total = sc + cc;
    // The model decides the part of speech while it is already reading and
    // normalizing the word — strictly easier than what it is doing anyway, and
    // it cannot be overruled by a mis-tapped dropdown. Free text, not a fixed
    // set: parts of speech don't enumerate cleanly, and a word that is two of
    // them is exactly the case worth teaching both sides of.
    const typeText = '''DECIDE IT YOURSELF from the input word, and report it in "word_type".
- A short lower-case label: "verb", "noun", "adjective", "adverb",
  "preposition", "phrase"… whatever the word actually is.
- If it is commonly used as MORE THAN ONE part of speech, do NOT pick one.
  Give a combined label — "verb & noun", "noun & adjective" — and split TASK
  B's sentences between those senses, roughly evenly and interleaved rather
  than grouped, so the learner meets both as they go.
- Judge that ambiguity in the language the user typed the word in. Combine at
  most two senses: the two most common ones.
- When the senses are different words in the target language, WORD_L2 is the
  more common sense, and each sentence of another sense carries its own base
  form in that sentence's "word" field (still exactly one [[...]] per sentence,
  around whichever word that sentence is teaching).''';
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
2. Use the correct native script of $targetLanguage (e.g. Greek letters for Greek, Cyrillic for Russian).
3. If the input already looks like a correct $targetLanguage word, return it unchanged.
4. Output the final L2 word as: WORD_L2
5. Output the final L1 word as: WORD_L1 in $knownLanguage
7. If the input L1 is not in $knownLanguage, translate it to $knownLanguage and output as WORD_L1
''';

    final prompt =
        '''
You are an expert language generator.

TARGET LANGUAGE (L2): $targetLanguage
KNOWN LANGUAGE (L1): $knownLanguage

WORD TYPE:
$typeText

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
  "word_type": "verb" | "noun" | "adjective" | "noun & adjective" | ...,
  "sentences": [
    {"l2": "...", "l1": "...", "word": "base L2 word this sentence teaches"},
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
            'word_type': {
              'type': 'string',
              'description':
                  'Short lower-case part-of-speech label for the input word, e.g. "verb", "adjective". When '
                  'the word is commonly two parts of speech, a combined label such as "noun & adjective", '
                  'and the sentences must then cover both senses.',
            },
            'sentences': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'l2': {
                    'type': 'string',
                    'description': 'L2 sentence. MUST contain exactly one [[...]] around the word form.',
                  },
                  'l1': {'type': 'string', 'description': 'L1 translation.'},
                  'word': {
                    'type': 'string',
                    'description':
                        'Base L2 form this sentence teaches. Same as word_l2 except for the other sense of a '
                        '"both" word, where it is that sense\'s own word.',
                  },
                },
                'required': ['l2', 'l1'],
              },
            },
          },
          'required': ['word_l2', 'word_l1', 'word_type', 'sentences'],
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

    final parsed = _parseWordAndSentencesJson(
      jsonString: text,
      fallbackWord: l2.isNotEmpty ? l2 : l1,
      fallbackKnownWord: l1,
      connectorWords: connectorWords,
    );
    var sentences = parsed.sentences;
    if (sentences.length > total) sentences = sentences.take(total).toList();
    if (sentences.isEmpty) throw Exception('AI returned empty sentences list');

    return (
      wordL2: parsed.wordL2,
      wordL1: parsed.wordL1,
      type: parsed.type,
      typeLabel: parsed.typeLabel,
      sentences: sentences,
    );
  }

  static Future<List<WordSentence>> generateSentences({
    required String apiKey,
    required String word,
    required String knownWord,

    /// The label the AI gave this word when it was added, passed back verbatim
    /// so a later batch is shaped like the first instead of quietly narrowing
    /// a two-sense word to one.
    required String typeLabel,
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
    final label = typeLabel.trim().isEmpty ? 'unknown' : typeLabel.trim();
    // A combined label ("noun & adjective") must keep covering both senses here
    // too, or the second batch quietly narrows the word to one of them.
    final typeText = label.contains('&') ? '$label — split the sentences between those senses, interleaved' : label;

    final connectorsList = connectorWords.where((w) => w.trim().isNotEmpty).toList();
    final connectorsText = connectorsList.isEmpty ? '[]' : '[${connectorsList.map((w) => '"$w"').join(', ')}]';

    final prompt =
        '''
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
              'l2': {
                'type': 'string',
                'description': 'L2 sentence. MUST contain exactly one [[...]] around the main word form.',
              },
              'l1': {'type': 'string', 'description': 'L1 translation.'},
              'l1conj': {'type': 'string', 'description': 'conjugated main word in L1.'},
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

  /// Maximum seed phrases fed to the generator, and the character budget they
  /// share. The point is a broad picture of the learner's vocabulary, so more
  /// is better — but not so much that the reference buries the instructions.
  static const int _kMaxSeedPhrases = 400;
  static const int _kMaxSeedChars = 20000;

  /// Generates listening-comprehension texts: long sentences or micro-stories
  /// in L2, each with its L1 translation.
  ///
  /// [knownPhrases] is every sentence from the selected subjects, **flattened**
  /// — no subject grouping, deliberately. Grouped, narrow seed lists made the
  /// model build each story around two or three of them, which a learner who
  /// already knows those phrases can simply recognise rather than decode. As
  /// one large unlabelled pool the list stops steering the plot and does what
  /// it should: describe the vocabulary and level the learner can follow.
  static Future<List<({String l2, String l1})>> generateListeningTexts({
    required String apiKey,
    required List<String> knownPhrases,
    required String knownLanguage,
    required String targetLanguage,
    required int count,
    required int sentencesPerText,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('AI API key is empty (set it in Settings).');
    }
    if (knownPhrases.isEmpty) return const [];

    // Shuffled, so a bank too large for the budget still shows the model a
    // different cross-section on every run instead of always its first slice.
    final pool = [...knownPhrases]..shuffle();
    final seeds = <String>[];
    var chars = 0;
    for (final phrase in pool) {
      if (seeds.length >= _kMaxSeedPhrases || chars + phrase.length > _kMaxSeedChars) break;
      seeds.add(phrase);
      chars += phrase.length;
    }
    final vocabulary = seeds.map((x) => '  - $x').join('\n');

    // Variety across a batch normally comes from temperature — raised to 1.15
    // below, precisely so eight texts don't turn into eight versions of one
    // café scene. Gemini 3.x removes that control, so on those models the
    // spread has to be bought in the prompt instead: one concrete situation per
    // text, the same trick [generateStory] uses.
    // Shuffled once, then walked in order: re-shuffling per line would happily
    // hand the same situation to two texts, which is the exact failure this is
    // meant to prevent.
    final shuffledSeeds = _storySeeds.toList()..shuffle();
    final situations = AiService.engine.acceptsSampling
        ? ''
        : '''

ONE SITUATION PER TEXT (use them in order, one each — they are starting points,
not plots, and none of them appears in the vocabulary list):
${[for (var i = 0; i < count; i++) '  ${i + 1}. ${shuffledSeeds[i % shuffledSeeds.length]}'].join('\n')}
''';

    final prompt =
        '''
You are writing short listening-comprehension texts for a language learner.

TARGET LANGUAGE (L2): $targetLanguage
KNOWN LANGUAGE (L1): $knownLanguage

THE LEARNER'S ACTIVE VOCABULARY
Below is what this learner has studied, in one flat list with no topics or
grouping — deliberately, so nothing steers you toward a particular theme. Read
it as a picture of the words, structures, tenses and register they can follow.
$vocabulary

HOW TO USE THAT LIST — READ THIS TWICE
The learner knows every one of those phrases by heart. So:
* A text assembled from them, or recognisably built around two or three of
  them, is guessed rather than understood, and is worthless as practice.
* Never quote a phrase, never lightly reword one, never chain several together.
* Invent situations that do NOT appear anywhere in the list. Recombine the
  vocabulary into things the learner has never heard.
* You have real freedom here: any everyday scene is fair game, whether or not
  the list hints at it. Introducing a few new words the learner can infer from
  context is welcome — that is what listening practice is for.

YOUR TASK
Write $count different texts in $targetLanguage. Each one is a tiny, complete
story.

WHAT MAKES A TEXT ACCEPTABLE
1. ONE coherent scene. The same people, the same place, the same stretch of
   time from beginning to end. Something actually happens: a small setup, a
   development, and an outcome or a closing thought. A listener should be able
   to retell what happened.
2. Every sentence follows from the one before it. A set of true, unrelated
   statements that merely share a subject is a FAILURE, even when every
   sentence is perfectly correct on its own.
3. Length: about $sentencesPerText sentences, each roughly as long as the
   phrases in the list above. Aim for that overall size, not an exact count.
4. It stands alone. No title, no preamble, no naming of themes. Start straight
   into the scene.
5. Vary across the set: different people, places, moods, tenses and outcomes.
   No two texts should open the same way or retell the same situation.$situations
6. Write for the ear: natural connected speech, at an upper-beginner to
   intermediate level. No headings, bullet points, emoji, surrounding quotation
   marks, or parenthetical asides.
7. "l1" is a faithful, natural translation of the whole of "l2" — not a summary.

THE SHAPE TO AIM FOR (shown in English so you can see the structure — write
yours in $targetLanguage):
  GOOD: "I got to the bakery ten minutes before closing. There was only one
  loaf left, and the woman ahead of me was already reaching for it. She saw my
  face, laughed, and cut it in half for us both."
    → one scene, connected sentences, something happens, it resolves.
  BAD: "I like bread. The bakery near my house opens at seven. My sister is a
  doctor. Yesterday the weather was nice."
    → correct sentences with no scene and no connection. Never produce this.

RETURN FORMAT (VERY IMPORTANT):
Return ONLY a JSON array and nothing else. No explanations, no markdown.

[
  {"l2": "text in $targetLanguage", "l1": "translation in $knownLanguage"}
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
        // Storytelling, not extraction: a little extra spread keeps the set of
        // texts from collapsing into variations of one scene.
        'temperature': 1.15,
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'l2': {
                'type': 'string',
                'description':
                    'One self-contained micro-story in L2: a single connected scene with a beginning, '
                    'a development and an outcome. Never a list of unrelated sentences.',
              },
              'l1': {'type': 'string', 'description': 'Faithful full translation of l2 into L1.'},
            },
            'required': ['l2', 'l1'],
          },
        },
      },
    };

    final resp = await queryModel(apiKey, body);
    if (resp.statusCode != 200) _throwAiError(resp, 'generateListeningTexts');

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final parts =
        ((decoded['candidates'] as List?)?.firstOrNull?['content'] as Map<String, dynamic>?)?['parts'] as List?;
    final text = (parts?.firstOrNull?['text'] as String? ?? '').trim();
    if (text.isEmpty) throw Exception('AI returned no listening texts');

    late List<dynamic> list;
    try {
      list = jsonDecode(text) as List<dynamic>;
    } catch (e) {
      throw Exception('JSON decode failed: $e');
    }

    final out = <({String l2, String l1})>[];
    for (final item in list.take(count)) {
      final m = (item as Map).cast<String, dynamic>();
      final l2 = (m['l2'] as String? ?? '').trim();
      final l1 = (m['l1'] as String? ?? '').trim();
      if (l2.isEmpty) continue;
      out.add((l2: l2, l1: l1));
    }
    return out;
  }

  /// Generates ONE long story in L2, already split into consecutive parts.
  ///
  /// The counterpart of [generateListeningTexts]: same seed pool and the same
  /// "this is the level, not the plot" framing, but one continuous narrative
  /// instead of many unrelated scenes. Parts come back pre-split so Listen mode
  /// can play them exactly as it plays micro-stories — the model knows where its
  /// own sentence boundaries are, and asking it to segment is far safer than
  /// splitting L2 prose on punctuation afterwards (there would be no way to keep
  /// the translation aligned if we did).
  ///
  /// The outline is requested *first, in the same response*: committing to a
  /// plot before writing the prose is what stops a long text from wandering and
  /// then ending because it ran out of room. It is never shown to the user.
  static Future<({String titleL2, String titleL1, String outline, List<({String l2, String l1})> parts})>
  generateStory({
    required String apiKey,
    required List<String> knownPhrases,
    required String knownLanguage,
    required String targetLanguage,
    required int parts,
    required int sentencesPerPart,
    String theme = '',
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('AI API key is empty (set it in Settings).');
    }
    if (knownPhrases.isEmpty) {
      throw Exception('No sentences in the selected subjects.');
    }

    final pool = [...knownPhrases]..shuffle();
    final seeds = <String>[];
    var chars = 0;
    for (final phrase in pool) {
      if (seeds.length >= _kMaxSeedPhrases || chars + phrase.length > _kMaxSeedChars) break;
      seeds.add(phrase);
      chars += phrase.length;
    }
    final vocabulary = seeds.map((x) => '  - $x').join('\n');
    // Given per generation rather than left to the model: asked to "be creative"
    // it reliably returns the same handful of gentle scenes, so the variety has
    // to come from the instruction.
    final seedIdea = theme.trim().isNotEmpty ? theme.trim() : (_storySeeds.toList()..shuffle()).first;

    final prompt =
        '''
You are writing a short story for a language learner to listen to.

TARGET LANGUAGE (L2): $targetLanguage
KNOWN LANGUAGE (L1): $knownLanguage

THE LEARNER'S ACTIVE VOCABULARY
One flat list, no topics or grouping. Read it as a picture of the words,
structures, tenses and register they can follow.
$vocabulary

HOW TO USE THAT LIST — READ THIS TWICE
It tells you their LEVEL. It is NOT a plot outline, NOT sentences to reuse, and
NOT a list of topics to cover. They know every phrase on it by heart, so a story
recognisably assembled out of them is recognised rather than understood, and is
worthless as practice. Invent situations that appear nowhere in the list.
Introducing a few new words the listener can infer from context is welcome —
that is what listening practice is for.

YOUR TASK
Write ONE short story in $targetLanguage — a real short story, the kind that
would sit in a collection, not a language exercise.

Seed idea: $seedIdea

Answer in two stages, both inside the JSON:
1. "outline": 3-6 sentences in $knownLanguage. Who the people are, what the
   problem is, what complicates it, how it ends. Commit to this BEFORE writing
   any prose.
2. "parts": the story itself, already divided into exactly $parts consecutive
   parts of about $sentencesPerPart sentences each. Part 2 continues part 1.
   These are slices of ONE story, never separate vignettes, and the learner
   hears them in order.

WHAT MAKES THE STORY ACCEPTABLE
1. Two or three named characters. Use their names and keep them straight
   throughout.
2. Something is wrong by the end of part 1. Not "a lovely day at the market".
3. Concrete physical detail — what is in the room, what someone is holding, what
   the weather is doing. Dialogue is welcome.
4. An ending that resolves the situation. NO moral, NO "and so they learned", NO
   narrator stepping in to explain the point.
5. Sentences roughly as long as the phrases in the vocabulary list above.
   Written for the ear: natural connected speech, no headings, bullets, emoji or
   parenthetical asides.
6. Each part's "l1" is a faithful, natural translation of that part's "l2" — not
   a summary.
7. "title_l2" is the story's title in $targetLanguage, "title_l1" the same title
   in $knownLanguage. Short, and not a summary of the plot.

Return JSON only.
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
        // Lower than the micro-story batch: there, spread stops many texts
        // collapsing into one scene. Here there is only one text, and what
        // matters instead is that it holds together over its whole length.
        'temperature': 1.0,
        'responseMimeType': 'application/json',
        'responseSchema': {
          'type': 'object',
          'properties': {
            'outline': {
              'type': 'string',
              'description': 'The plot, in L1, decided before the prose is written. Never shown to the learner.',
            },
            'title_l2': {'type': 'string'},
            'title_l1': {'type': 'string'},
            'parts': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'l2': {
                    'type': 'string',
                    'description': 'One consecutive slice of the story in L2. Continues directly from the part before.',
                  },
                  'l1': {'type': 'string', 'description': 'Faithful full translation of l2 into L1.'},
                },
                'required': ['l2', 'l1'],
              },
            },
          },
          'required': ['outline', 'title_l2', 'title_l1', 'parts'],
        },
      },
    };

    final resp = await queryModel(apiKey, body);
    if (resp.statusCode != 200) _throwAiError(resp, 'generateStory');

    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    final respParts =
        ((decoded['candidates'] as List?)?.firstOrNull?['content'] as Map<String, dynamic>?)?['parts'] as List?;
    final text = (respParts?.firstOrNull?['text'] as String? ?? '').trim();
    if (text.isEmpty) throw Exception('AI returned no story');

    late Map<String, dynamic> map;
    try {
      map = (jsonDecode(text) as Map).cast<String, dynamic>();
    } catch (e) {
      throw Exception('JSON decode failed: $e');
    }

    final out = <({String l2, String l1})>[];
    for (final item in (map['parts'] as List?) ?? const []) {
      final m = (item as Map).cast<String, dynamic>();
      final l2 = (m['l2'] as String? ?? '').trim();
      final l1 = (m['l1'] as String? ?? '').trim();
      if (l2.isEmpty) continue;
      out.add((l2: l2, l1: l1));
    }
    if (out.isEmpty) throw Exception('AI returned a story with no parts');

    return (
      titleL2: (map['title_l2'] as String? ?? '').trim(),
      titleL1: (map['title_l1'] as String? ?? '').trim(),
      outline: (map['outline'] as String? ?? '').trim(),
      parts: out,
    );
  }

  /// Seed situations for [generateStory], one picked at random per run. Left to
  /// itself the model returns the same few mild scenes over and over; a concrete
  /// starting point is what produces the variety.
  static const List<String> _storySeeds = [
    'a misunderstanding between neighbours that gets out of hand',
    'a small theft that turns out not to be a theft',
    'a journey that goes wrong in an ordinary way',
    'someone waiting for a person who does not come',
    'a favour that costs far more than expected',
    'an object that keeps turning up where it should not be',
    'a secret kept for a good reason and found out anyway',
    'two people who need the same thing at the same time',
    'a letter or message that arrives much too late',
    'a promise made carelessly and taken seriously',
    'a stranger who knows more than they should',
    'a repair that makes the problem worse',
    'a celebration nobody is in the mood for',
    'an animal that decides the outcome of something',
    'a lie told to be kind, which then has to be maintained',
  ];

  /// The few-shot examples below are written in Greek script, so they only help
  /// when Greek is what's being learned — shown to a German learner they'd just
  /// be noise (or a nudge toward the wrong alphabet).
  static bool _isGreek(String language) => language.trim().toLowerCase().startsWith('greek');

  // Convert a single word from phonetic Latin to proper target-language script.
  static Future<String> normalizeWordToTargetScript({
    required String apiKey,
    required String word,
    required String targetLanguage,
  }) async {
    if (apiKey.trim().isEmpty) {
      throw Exception('AI API key is empty (set it in Settings).');
    }

    final prompt =
        '''
You are a transliteration helper.

TARGET LANGUAGE: $targetLanguage
USER INPUT WORD: "$word"

The user might type the word in phonetic LATIN characters that approximate a $targetLanguage word.
${_isGreek(targetLanguage) ? '''Examples:
- "thelo" -> "θέλω"
- "kalispera" -> "καλησπέρα"
- "gia" -> "για"
- "apo" -> "από"
''' : 'For example, a learner may spell out the sounds of the word using the Latin alphabet.'}

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
      if (d != null && d > Duration.zero)
        throw AiException('Gemini API quota exceeded. ${_formatRetryAfterMessage(d)}');
      final d2 = _retryDelayFromGeminiBody(resp.body);
      if (d2 != null && d2 > Duration.zero)
        throw AiException('Gemini API quota exceeded. ${_formatRetryAfterMessage(d2)}');
      throw AiException('Gemini API quota exceeded. Please try again in a bit.');
    }
    if (resp.statusCode == 503 || resp.statusCode == 502) {
      final d = _retryAfterDuration(resp);
      if (d != null && d > Duration.zero)
        throw AiException('AI service is temporarily busy. ${_formatRetryAfterMessage(d)}');
      throw AiException('AI service is temporarily busy. Please try again in a bit.');
    }
    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw AiException('Gemini API key seems invalid or unauthorized. Check it in Settings.');
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
          throw AiException('Gemini API quota exceeded. Please wait a bit or reduce usage.');
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
    final v = resp.headers.entries
        .firstWhere((e) => e.key.toLowerCase() == 'retry-after', orElse: () => const MapEntry('', ''))
        .value
        .trim();
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
    if (d.inSeconds < 60) {
      rel = '${d.inSeconds}s';
    } else if (d.inMinutes < 60) {
      rel = '${d.inMinutes} min';
    } else {
      rel = '${d.inHours} h';
    }

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
