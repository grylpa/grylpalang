enum WordType { verb, noun, both, other }

extension WordTypeLabel on WordType {
  /// What the word list shows. `both` is the interesting one: a word the AI
  /// judged genuinely ambiguous in the known language (English "walk",
  /// "book"), whose sentences deliberately cover both senses rather than
  /// guessing at which one the user meant.
  String get label => switch (this) {
    WordType.verb => 'Verb',
    WordType.noun => 'Noun',
    WordType.both => 'Verb & noun',
    WordType.other => 'Other',
  };
}
