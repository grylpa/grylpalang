/// One generated listening text: a long sentence or micro-story in the target
/// language plus its known-language translation.
///
/// Generated once (AI) and persisted, so re-opening Listen mode replays the
/// same bank instead of spending API calls again.
class ListenStory {
  /// The bank subjects this text was generated from. A text is free to weave
  /// several of them together, which is the point of Listen mode — so this is a
  /// list, not a single owner, and it records the *pool* the story came out of
  /// rather than a claim about which topics it ended up using.
  final List<String> subjects;

  /// Target-language text (the thing being learned).
  final String l2;

  /// Known-language translation, played once as the "answer".
  final String l1;

  const ListenStory({required this.subjects, required this.l2, required this.l1});

  Map<String, dynamic> toJson() => {'subjects': subjects, 'l2': l2, 'l1': l1};

  static ListenStory fromJson(Map<String, dynamic> json) {
    // `subject` (singular) is the pre-mixed-generation shape, when every text
    // belonged to exactly one subject.
    final list = (json['subjects'] as List?)?.cast<String>();
    final legacy = json['subject'] as String?;
    return ListenStory(
      subjects: list ?? [if (legacy != null && legacy.isNotEmpty) legacy],
      l2: json['l2'] as String? ?? '',
      l1: json['l1'] as String? ?? '',
    );
  }

  /// Stable identity for resume — the text itself, since indices shift whenever
  /// the bank is regenerated or a subject is deselected.
  String get key => l2;
}
