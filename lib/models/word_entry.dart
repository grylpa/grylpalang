import 'word_sentence.dart';
import 'word_type.dart';

class WordEntry {
  final String id;
  final String wordL2;
  final String wordL1;
  final WordType type;
  final DateTime createdAt;
  final List<WordSentence> sentences;
  final int startStep; // global step at which this word starts appearing
  bool active;

  WordEntry({
    required this.id,
    required this.wordL2,
    required this.wordL1,
    required this.type,
    required this.createdAt,
    required this.active,
    required this.sentences,
    required this.startStep,
  });

  int get totalSteps => sentences.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'wordL2': wordL2,
    'wordL1': wordL1,
    'type': type.name,
    'createdAt': createdAt.toIso8601String(),
    'active': active,
    'sentences': sentences.map((s) => s.toJson()).toList(),
    'startStep': startStep,
  };

  factory WordEntry.fromJson(Map<String, dynamic> json) {
    final rawType = (json['type'] as String? ?? 'other').toLowerCase();
    WordType parseType() {
      if (rawType.contains('verb')) return WordType.verb;
      if (rawType.contains('noun')) return WordType.noun;
      return WordType.other;
    }

    return WordEntry(
      id: json['id'] as String,
      wordL2: json['wordL2'] as String,
      wordL1: json['wordL1'] as String,
      type: parseType(),
      createdAt: DateTime.parse(json['createdAt'] as String),
      active: json['active'] as bool? ?? true,
      sentences: ((json['sentences'] as List?) ?? [])
          .map((e) => WordSentence.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
      startStep: json['startStep'] as int? ?? 0,
    );
  }
}
