// lib/models/history_entry.dart
import 'word_sentence.dart';
import '../widgets.dart';

class HistoryEntry {
  final DateTime tappedAt;
  final List<WordSentence> sentences;

  String get fingerprint => fingerprintSentences(sentences);

  HistoryEntry({required this.tappedAt, required this.sentences});

  Map<String, dynamic> toJson() => {
    'tappedAt': tappedAt.toIso8601String(),
    'sentences': sentences.map((s) => s.toJson()).toList(),
  };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      tappedAt: DateTime.parse(json['tappedAt'] as String),
      sentences: ((json['sentences'] as List?) ?? [])
          .map((e) => WordSentence.fromJson((e as Map).cast<String, dynamic>()))
          .toList(),
    );
  }

  bool isValid() {
    for (WordSentence s in sentences) {
      if (s.l1.trim().isEmpty || s.l2.trim().isEmpty) return false;
    }
    return true;
  }

  void removeDuplicateMainWords() {
    for (int iws = 0 ; iws < sentences.length ; iws++) {
      WordSentence ws = sentences[iws];
      String cleaned = removeDuplicateMainWord(ws.l2);
      if (cleaned != ws.l2) {
        //debugPrint("changed ${ws.l2} to $cleaned");
        sentences[iws] = WordSentence(l2: cleaned, l1: ws.l1, word: ws.word, translatedWord: ws.translatedWord);
      }
    }
  }
}
