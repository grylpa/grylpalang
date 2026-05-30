import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_entry.dart';

/// Snapshot of the catalog state for one author-year cutoff: the books fetched
/// so far, plus the URL of the next page (null if we've reached the end).
class CatalogState {
  final List<BookEntry> books;
  final String? nextUrl;
  const CatalogState({required this.books, required this.nextUrl});
  bool get hasMore => nextUrl != null;
}

/// Fetches the Project Gutenberg catalog from Gutendex (https://gutendex.com),
/// one page (~32 books) at a time. The cached snapshot holds the books we've
/// already pulled and the next-page URL, so reopening the tab or pressing
/// "Load more" continues where you left off — no need to pre-fetch hundreds of
/// books on first open.
class GutenbergService {
  static const String _kBase = 'https://gutendex.com/books/';

  // Per-cutoff cache (V6 = books + next-URL snapshot shape).
  static String _stateKey(int year) => 'gutenbergCatalogV6_$year';
  static String _fetchedAtKey(int year) => 'gutenbergCatalogV6_${year}_at';
  static const Duration _staleAfter = Duration(days: 7);

  final SharedPreferencesAsync _prefs;
  GutenbergService(this._prefs);

  // Default cap on how many pages we'll fetch in one call. ~32 books per page,
  // so 10 pages ≈ 320 books — enough variety for the in-app sort/filter to be
  // meaningful, without taking forever.
  static const int _kMaxPagesDefault = 10;

  /// Loads the catalog for [authorYearStart], streaming pages incrementally via
  /// [onPage] so the UI can grow the visible list as each page arrives instead
  /// of waiting for the whole batch. Resumes from cache (continues fetching
  /// from the saved next-URL if last time was incomplete) unless [forceRefresh].
  Future<CatalogState> loadCatalog({
    required int authorYearStart,
    bool forceRefresh = false,
    int maxPages = _kMaxPagesDefault,
    void Function(CatalogState state, int pagesDone, int pagesPlanned)? onPage,
  }) async {
    CatalogState state;
    var pagesDone = 0;
    if (forceRefresh) {
      state = CatalogState(books: const [], nextUrl: _firstPageUrl(authorYearStart));
    } else {
      final cached = await _readCached(authorYearStart);
      if (cached == null) {
        state = CatalogState(books: const [], nextUrl: _firstPageUrl(authorYearStart));
      } else {
        state = cached;
        // Approximate pages already fetched, so the progress callback sees a
        // sensible "page N of M" if we're resuming a partial download.
        pagesDone = (cached.books.length / 32).ceil();
        // Emit the cached state first so the UI shows what we already have.
        onPage?.call(state, pagesDone, maxPages);
      }
    }

    while (pagesDone < maxPages && state.nextUrl != null) {
      state = await _fetchAndAppend(authorYearStart, existing: state.books, url: state.nextUrl!);
      pagesDone += 1;
      onPage?.call(state, pagesDone, maxPages);
    }
    return state;
  }

  String _firstPageUrl(int authorYearStart) =>
      '$_kBase?languages=en&sort=popular&author_year_start=$authorYearStart';

  /// Read-only cache access — never touches the network. Returns null if no
  /// catalog has ever been fetched for [authorYearStart].
  Future<CatalogState?> loadCached(int authorYearStart) => _readCached(authorYearStart);

  Future<DateTime?> lastFetchedAt(int authorYearStart) async {
    final at = await _prefs.getInt(_fetchedAtKey(authorYearStart));
    return at == null ? null : DateTime.fromMillisecondsSinceEpoch(at);
  }

  Future<bool> isStale(int authorYearStart) async {
    final at = await _prefs.getInt(_fetchedAtKey(authorYearStart));
    if (at == null) return true;
    return DateTime.now().millisecondsSinceEpoch - at > _staleAfter.inMilliseconds;
  }

  // ── Internals ─────────────────────────────────────────────────────────────

  Future<CatalogState> _fetchAndAppend(
    int authorYearStart, {
    required List<BookEntry> existing,
    required String url,
  }) async {
    final resp = await http.get(Uri.parse(url), headers: const {
      'Accept': 'application/json',
      'User-Agent': 'Katalaveno/1.0 (Android; Flutter)',
    });
    if (resp.statusCode != 200) {
      throw Exception('Gutendex HTTP ${resp.statusCode}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final newBooks = <BookEntry>[...existing];
    for (final r in ((body['results'] as List?) ?? const [])) {
      newBooks.add(_jsonToBook((r as Map).cast<String, dynamic>()));
    }
    final next = body['next'];
    final nextUrl = (next is String && next.isNotEmpty) ? next : null;
    final newState = CatalogState(books: newBooks, nextUrl: nextUrl);
    await _writeCache(authorYearStart, newState);
    return newState;
  }

  Future<CatalogState?> _readCached(int authorYearStart) async {
    final raw = await _prefs.getString(_stateKey(authorYearStart));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final books = (decoded['books'] as List?) ?? const [];
      return CatalogState(
        books: [
          for (final e in books) BookEntry.fromJson((e as Map).cast<String, dynamic>())
        ],
        nextUrl: decoded['next'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(int authorYearStart, CatalogState state) async {
    await _prefs.setString(
      _stateKey(authorYearStart),
      jsonEncode({
        'books': [for (final b in state.books) b.toJson()],
        'next': state.nextUrl,
      }),
    );
    await _prefs.setInt(_fetchedAtKey(authorYearStart), DateTime.now().millisecondsSinceEpoch);
  }

  BookEntry _jsonToBook(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString();
    final title = (j['title'] ?? '').toString().trim();

    final authors = <String>[];
    int? deathYear;
    int? birthYear;
    for (final a in ((j['authors'] as List?) ?? const [])) {
      final m = (a as Map).cast<String, dynamic>();
      final name = (m['name'] ?? '').toString().trim();
      if (name.isNotEmpty) authors.add(name);
      final dy = m['death_year'];
      if (deathYear == null && dy is num) deathYear = dy.toInt();
      final by = m['birth_year'];
      if (birthYear == null && by is num) birthYear = by.toInt();
    }

    final langs = ((j['languages'] as List?) ?? const []).map((e) => e.toString()).toList();
    final language = langs.isNotEmpty ? langs.first : '';

    // Bookshelves are the curated PG categories ("Adventure", "Romance", ...) —
    // cleaner than the raw Library-of-Congress subjects. Strip the "Browsing:"
    // and any leading "Category…" wrapper PG sometimes adds.
    final tags = <String>[];
    for (final s in ((j['bookshelves'] as List?) ?? const [])) {
      final t = _cleanTag(s.toString());
      if (t.isNotEmpty) tags.add(t);
    }

    var coverUrl = '';
    var epubUrl = '';
    final formats = ((j['formats'] as Map?) ?? const {}).cast<String, dynamic>();
    for (final e in formats.entries) {
      final mime = e.key.toLowerCase();
      final url = e.value.toString();
      if (coverUrl.isEmpty && (mime.startsWith('image/jpeg') || mime.startsWith('image/png'))) {
        coverUrl = url;
      }
      if (epubUrl.isEmpty && mime.startsWith('application/epub+zip')) {
        epubUrl = url;
      }
    }

    // Gutendex doesn't expose original publication year, so we use the first
    // author's death year as a proxy (or birth + 40 as a fallback).
    final pubYearProxy = deathYear ?? (birthYear != null ? birthYear + 40 : null);

    return BookEntry(
      id: id,
      title: title,
      authors: authors,
      language: language,
      summary: '',
      tags: tags,
      wordCount: 0, // estimated post-EPUB later.
      publicationYear: pubYearProxy,
      coverUrl: coverUrl,
      epubUrl: epubUrl,
      difficulty: _computeDifficulty(pubYearProxy),
    );
  }

  // Strip PG's noisy bookshelf wrappers — leading "Browsing:" or "Category…"
  static final RegExp _wrapperPrefix =
      RegExp(r'^(browsing|category)\b[:\s]*', caseSensitive: false);
  static String _cleanTag(String raw) =>
      raw.trim().replaceFirst(_wrapperPrefix, '').trim();

  static String _computeDifficulty(int? pubYear) {
    if (pubYear == null) return 'medium';
    if (pubYear < 1800) return 'hard';
    if (pubYear < 1900) return 'medium';
    return 'easy';
  }
}
