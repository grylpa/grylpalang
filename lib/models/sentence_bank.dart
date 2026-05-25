// Models for the Sentence Bank feature.
//
// The YAML file has the structure:
//
//   language: English
//   subjects:
//     Greetings:
//       sentences:
//         - Hello!
//     Beginner Mix:
//       includes:
//         - Greetings
//         - Travel

class SentenceBank {
  /// Source language of all sentences in this bank (e.g. "English").
  final String language;

  /// All named subjects (leaf + meta).
  final Map<String, BankSubject> subjects;

  /// Seconds to show the source sentence before revealing the translation in auto mode.
  final int autoShowDelay;

  /// Seconds to wait after TTS finishes before advancing to the next sentence in auto mode.
  final int autoPostTtsDelay;

  /// Seconds to pause after speaking the source sentence before revealing the translation.
  final int autoSourcePause;

  /// Pitch multiplier for the "lower" voice when no gendered TTS voice is found.
  final double ttsPitchLow;

  /// Pitch multiplier for the "higher" voice when no gendered TTS voice is found.
  final double ttsPitchHigh;

  /// Seconds to wait between TTS repetitions of the translation.
  final int ttsRepeatDelay;

  /// How many times to play the translation TTS (1 = once, 2 = play twice, etc.).
  final int ttsRepeatCount;

  const SentenceBank({
    required this.language,
    required this.subjects,
    required this.autoShowDelay,
    required this.autoPostTtsDelay,
    required this.autoSourcePause,
    required this.ttsPitchLow,
    required this.ttsPitchHigh,
    required this.ttsRepeatDelay,
    required this.ttsRepeatCount,
  });

  /// Ordered list of subject names for display.
  List<String> get subjectNames => subjects.keys.toList();

  /// Resolve a subject name to its flat list of sentences, handling meta subjects.
  List<String> sentencesFor(String subjectName) {
    final subject = subjects[subjectName];
    if (subject == null) return [];
    if (subject is LeafSubject) return List.unmodifiable(subject.sentences);
    if (subject is MetaSubject) {
      final result = <String>[];
      for (final ref in subject.subjectRefs) {
        final leaf = subjects[ref];
        if (leaf is LeafSubject) result.addAll(leaf.sentences);
        // Nested meta subjects are not supported — flatten one level only.
      }
      return result;
    }
    return [];
  }

  factory SentenceBank.fromYaml(Map<dynamic, dynamic> yaml) {
    final language = (yaml['language'] as String?) ?? 'English';
    final autoShowDelay = (yaml['auto_show_delay'] as int?) ?? 3;
    final autoPostTtsDelay = (yaml['auto_post_tts_delay'] as int?) ?? 2;
    final autoSourcePause = (yaml['auto_source_pause'] as int?) ?? 1;
    final ttsPitchLow = (yaml['tts_pitch_low'] as num?)?.toDouble() ?? 0.85;
    final ttsPitchHigh = (yaml['tts_pitch_high'] as num?)?.toDouble() ?? 1.1;
    final ttsRepeatDelay = (yaml['tts_repeat_delay'] as int?) ?? 1;
    final ttsRepeatCount = (yaml['tts_repeat_count'] as int?) ?? 2;
    final rawSubjects = yaml['subjects'];
    final subjects = <String, BankSubject>{};

    if (rawSubjects is Map) {
      for (final entry in rawSubjects.entries) {
        final name = entry.key.toString();
        final val = entry.value;
        if (val is! Map) continue;

        if (val.containsKey('includes')) {
          final refs = (val['includes'] as List?)?.map((e) => e.toString()).toList() ?? [];
          subjects[name] = MetaSubject(name: name, subjectRefs: refs);
        } else if (val.containsKey('sentences')) {
          final sents = (val['sentences'] as List?)?.map((e) => e.toString()).toList() ?? [];
          subjects[name] = LeafSubject(name: name, sentences: sents);
        }
      }
    }

    return SentenceBank(language: language, subjects: subjects, autoShowDelay: autoShowDelay, autoPostTtsDelay: autoPostTtsDelay, autoSourcePause: autoSourcePause, ttsPitchLow: ttsPitchLow, ttsPitchHigh: ttsPitchHigh, ttsRepeatDelay: ttsRepeatDelay, ttsRepeatCount: ttsRepeatCount);
  }
}

abstract class BankSubject {
  String get name;
}

class LeafSubject extends BankSubject {
  @override
  final String name;
  final List<String> sentences;

  LeafSubject({required this.name, required this.sentences});
}

class MetaSubject extends BankSubject {
  @override
  final String name;

  /// Names of the leaf subjects included in this meta subject.
  final List<String> subjectRefs;

  MetaSubject({required this.name, required this.subjectRefs});
}
