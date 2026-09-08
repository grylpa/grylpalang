/// One generated listening text: a micro-story, or one consecutive part of a
/// longer story, in the target language plus its known-language translation.
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

  /// Non-empty only for a part of a long story: the id shared by every part of
  /// that story. It is what keeps the parts together and in order when the bank
  /// is shuffled, and what makes one narrator read the whole story.
  final String storyId;

  /// 0-based position within the story, and how many parts it has. Both 0 for a
  /// standalone micro-story.
  final int part;
  final int partCount;

  /// The story's title in L2 / L1. Empty for a micro-story, which is
  /// deliberately untitled — naming a self-contained scene would give it away.
  final String titleL2;
  final String titleL1;

  const ListenStory({
    required this.subjects,
    required this.l2,
    required this.l1,
    this.storyId = '',
    this.part = 0,
    this.partCount = 0,
    this.titleL2 = '',
    this.titleL1 = '',
  });

  /// True when this is one part of a longer story rather than a standalone text.
  bool get isStoryPart => storyId.isNotEmpty;

  Map<String, dynamic> toJson() => {
    'subjects': subjects,
    'l2': l2,
    'l1': l1,
    // Omitted entirely for micro-stories, which are the common case — no reason
    // to grow every stored entry with five empty fields.
    if (storyId.isNotEmpty) ...{
      'storyId': storyId,
      'part': part,
      'partCount': partCount,
      'titleL2': titleL2,
      'titleL1': titleL1,
    },
  };

  static ListenStory fromJson(Map<String, dynamic> json) {
    // `subject` (singular) is the pre-mixed-generation shape, when every text
    // belonged to exactly one subject.
    final list = (json['subjects'] as List?)?.cast<String>();
    final legacy = json['subject'] as String?;
    return ListenStory(
      subjects: list ?? [if (legacy != null && legacy.isNotEmpty) legacy],
      l2: json['l2'] as String? ?? '',
      l1: json['l1'] as String? ?? '',
      storyId: json['storyId'] as String? ?? '',
      part: json['part'] as int? ?? 0,
      partCount: json['partCount'] as int? ?? 0,
      titleL2: json['titleL2'] as String? ?? '',
      titleL1: json['titleL1'] as String? ?? '',
    );
  }

  /// Stable identity for resume — the text itself, since indices shift whenever
  /// the bank is regenerated or a subject is deselected.
  String get key => l2;
}
