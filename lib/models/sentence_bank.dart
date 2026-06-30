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
          // Empty YAML entries parse to Dart null; `.toString()` on null would
          // surface the literal word "null" as a sentence. Filter null and
          // whitespace-only entries — but keep the kept value un-trimmed so
          // the translation cache key (`sourceLang|targetLang|sentence`) stays
          // byte-identical to entries cached before this filter existed.
          final sents = <String>[
            for (final e in (val['sentences'] as List? ?? const []))
              if (e != null && e.toString().trim().isNotEmpty) e.toString(),
          ];
          subjects[name] = LeafSubject(name: name, sentences: sents);
        }
      }
    }

    return SentenceBank(language: language, subjects: subjects, autoShowDelay: autoShowDelay, autoPostTtsDelay: autoPostTtsDelay, autoSourcePause: autoSourcePause, ttsRepeatDelay: ttsRepeatDelay, ttsRepeatCount: ttsRepeatCount);
  }
}

/// Parses the inline directives an author may put in a Sentence Bank *source*
/// sentence:
///   * a leading `N,` repeat directive — include this sentence N times in the
///     play order (emphasis). e.g. `3, I am tired`
///   * `( … )` hints — kept on screen but never spoken or translated.
///   * `a/b` options — alternatives; only the first side is spoken/translated,
///     while both stay visible on screen.
///
/// [display] is what the learner sees; [spoken] is what gets synthesized to
/// audio and sent to the translator. For a plain sentence (no directives) both
/// equal the original, so existing banks and their translation cache are
/// unaffected.
class SbSentence {
  static final RegExp _repeatRe = RegExp(r'^\s*(\d+)\s*,\s*');
  static final RegExp _hintRe = RegExp(r'\s*\([^()]*\)');
  static final RegExp _optionRe = RegExp(r'[^\s/]+(?:/[^\s/]+)+');
  static final RegExp _wsRe = RegExp(r'\s{2,}');

  /// How many times this sentence should appear in the play order (1–99).
  static int repeatCount(String raw) {
    final m = _repeatRe.firstMatch(raw);
    if (m == null) return 1;
    final n = int.tryParse(m.group(1)!) ?? 1;
    if (n < 1) return 1;
    return n > 99 ? 99 : n;
  }

  /// Text to show on screen: drops the `N,` directive but keeps hints and the
  /// option slashes so the learner sees them.
  static String display(String raw) => raw.replaceFirst(_repeatRe, '').replaceAll(_wsRe, ' ').trim();

  /// Text to speak / translate: drops the `N,` directive and `( … )` hints, and
  /// collapses each `a/b` option to its first alternative.
  static String spoken(String raw) {
    var s = raw.replaceFirst(_repeatRe, '');
    s = s.replaceAll(_hintRe, '');
    s = s.replaceAllMapped(_optionRe, (m) => m.group(0)!.split('/').first);
    return s.replaceAll(_wsRe, ' ').trim();
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
