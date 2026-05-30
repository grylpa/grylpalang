/// One book in the catalog, as fetched from a free-book OPDS source (currently
/// Standard Ebooks). Holds only the subset of metadata needed for browse +
/// filter; chapter text and the EPUB itself are loaded on demand in a later phase.
class BookEntry {
  final String id;                  // OPDS entry id (usually a URL)
  final String title;
  final List<String> authors;
  final String language;            // BCP-47 (e.g. 'en' / 'en-US')
  final String summary;             // plain text
  final List<String> tags;          // free-form subject labels (used as genres)
  final int wordCount;              // 0 if unknown
  final int? publicationYear;       // null if unknown
  final String coverUrl;            // '' if missing
  final String epubUrl;             // '' if missing
  final String difficulty;          // 'easy' | 'medium' | 'hard' (heuristic)

  const BookEntry({
    required this.id,
    required this.title,
    required this.authors,
    required this.language,
    required this.summary,
    required this.tags,
    required this.wordCount,
    required this.publicationYear,
    required this.coverUrl,
    required this.epubUrl,
    required this.difficulty,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'authors': authors,
        'language': language,
        'summary': summary,
        'tags': tags,
        'wordCount': wordCount,
        'publicationYear': publicationYear,
        'coverUrl': coverUrl,
        'epubUrl': epubUrl,
        'difficulty': difficulty,
      };

  factory BookEntry.fromJson(Map<String, dynamic> j) => BookEntry(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        authors: (j['authors'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        language: j['language'] as String? ?? '',
        summary: j['summary'] as String? ?? '',
        tags: (j['tags'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        wordCount: (j['wordCount'] as int?) ?? 0,
        publicationYear: j['publicationYear'] as int?,
        coverUrl: j['coverUrl'] as String? ?? '',
        epubUrl: j['epubUrl'] as String? ?? '',
        difficulty: j['difficulty'] as String? ?? 'medium',
      );
}
