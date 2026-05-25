class WordSentence {
  final String l2; // target language sentence
  final String l1; // known language sentence
  final String word; // original word in target language
  final String translatedWord;

  WordSentence({required this.l2, required this.l1, required this.word, required this.translatedWord});

  Map<String, dynamic> toJson() => {'l2': l2, 'l1': l1, 'word':word, 'translatedWord': translatedWord};

  factory WordSentence.fromJson(Map<String, dynamic> json) {
    return WordSentence(l2: json['l2'] as String? ?? '', l1: json['l1'] as String? ?? '',
        word: json['word'] as String? ?? '', translatedWord: json['translatedWord'] as String? ?? '');
  }
}
