import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_entry.dart';
import '../services/book_library_service.dart';
import '../services/gutenberg_service.dart';
import '../services/local_books_service.dart';
import 'book_reader.dart';

/// Phase 1: browse a popular slice of the Project Gutenberg catalog (via the
/// free Gutendex JSON API) with genre / length / era / difficulty filters and
/// several sort modes. Tapping a book opens a details sheet only — download,
/// reader, and audio mode arrive in later phases.
class BooksTab extends StatefulWidget {
  const BooksTab({super.key});

  @override
  State<BooksTab> createState() => _BooksTabState();
}

class _BooksTabState extends State<BooksTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late GutenbergService _service;
  late LocalBooksService _localBooks;
  late BookLibraryService _bookLibrary;
  // Per-book audio resume position — drives the resume icon on cards and the
  // recently-played sort that pins played books to the top.
  Map<String, ({int chapter, int ordinal, int at})> _audioPositions = {};
  List<BookEntry> _remoteBooks = [];
  // Progress of the current Gutendex fetch (visible while > 0 and not done).
  int _pagesDone = 0;
  int _pagesPlanned = 0;
  // Seconds since the current fetch started — shown in the initial loading
  // screen so a slow connection is visibly slow instead of just spinning.
  Timer? _loadTicker;
  int _loadElapsedSec = 0;
  List<BookEntry> _localBooksList = [];
  List<BookEntry> get _books => [..._localBooksList, ..._remoteBooks];
  String? _error;
  bool _loading = true;
  bool _initialized = false;
  DateTime? _fetchedAt;

  // Filters / sort.
  String _query = '';
  String? _genre;                // null = any
  String _length = 'any';        // 'any' | 'short' | 'medium' | 'long'
  String _difficulty = 'any';    // 'any' | 'easy' | 'medium' | 'hard'
  // Earliest author year — drives both the Gutendex query (server-side cutoff)
  // and the post-fetch display filter, so they can never disagree. Persisted in
  // SharedPreferences under [_kEarliestYearKey].
  int _earliestYear = 1900;
  String _sort = 'newest';       // 'newest' | 'oldest' | 'title' | 'author' | 'shortest' | 'longest'

  static const String _kEarliestYearKey = 'booksEarliestAuthorYear';
  static const int _kMinAllowedYear = 1500;
  final TextEditingController _yearController = TextEditingController();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final prefs = SharedPreferencesAsync();
      _service = GutenbergService(prefs);
      _localBooks = LocalBooksService(prefs);
      _bookLibrary = BookLibraryService(prefs);
      _bootstrap(prefs);
    }
  }

  Future<void> _bootstrap(SharedPreferencesAsync prefs) async {
    final saved = await prefs.getInt(_kEarliestYearKey);
    final nowYear = DateTime.now().year;
    if (saved != null && saved >= _kMinAllowedYear && saved <= nowYear && mounted) {
      setState(() => _earliestYear = saved);
    }
    _yearController.text = _earliestYear.toString();
    await _reloadLocal();
    await _reloadAudioPositions();
    // Load whatever's already cached for this year — never auto-fetches. The
    // user triggers a fetch via the "Load from Project Gutenberg" button.
    await _loadFromCache();
  }

  Future<void> _reloadAudioPositions() async {
    final positions = await _bookLibrary.loadAllAudioPositions();
    if (!mounted) return;
    setState(() => _audioPositions = positions);
  }

  Future<void> _setEarliestYear(int year) async {
    final clamped = year.clamp(_kMinAllowedYear, DateTime.now().year);
    if (clamped == _earliestYear) return;
    setState(() => _earliestYear = clamped);
    _yearController.text = clamped.toString();
    await SharedPreferencesAsync().setInt(_kEarliestYearKey, clamped);
    // Per-year cache: show what we have for this year if anything; otherwise the
    // list goes to just-local + Load button until the user taps it.
    await _loadFromCache();
  }

  /// Reads cached books for the current year (no network). Sets _remoteBooks
  /// to that cache, or empty if there's nothing yet.
  Future<void> _loadFromCache() async {
    setState(() {
      _loading = true;
      _error = null;
      // Clear any leftover fetch-progress flags so the button doesn't look
      // like it's still mid-fetch after a year change / cache-only reload.
      _pagesDone = 0;
      _pagesPlanned = 0;
    });
    final cached = await _service.loadCached(_earliestYear);
    final at = await _service.lastFetchedAt(_earliestYear);
    if (!mounted) return;
    setState(() {
      _remoteBooks = cached?.books ?? const [];
      _fetchedAt = at;
      _loading = false;
      if (_genre != null && !_books.any((b) => b.tags.contains(_genre))) _genre = null;
    });
  }

  /// User-initiated fetch from Gutendex for the current year. Streams pages
  /// incrementally as before.
  Future<void> _fetchRemote({bool force = false}) async {
    _startLoadTicker();
    setState(() {
      _error = null;
      _pagesDone = 0;
      _pagesPlanned = 0;
    });
    try {
      await _service.loadCatalog(
        authorYearStart: _earliestYear,
        forceRefresh: force,
        onPage: (state, done, planned) {
          if (!mounted) return;
          setState(() {
            _remoteBooks = state.books;
            _pagesDone = done;
            _pagesPlanned = planned;
            if (_genre != null && !_books.any((b) => b.tags.contains(_genre))) _genre = null;
          });
          _stopLoadTicker();
        },
      );
      final at = await _service.lastFetchedAt(_earliestYear);
      if (!mounted) return;
      setState(() => _fetchedAt = at);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        // Clear so the Load button comes back instead of a sticky spinner.
        _pagesPlanned = 0;
        _pagesDone = 0;
      });
    } finally {
      _stopLoadTicker();
    }
  }

  @override
  void dispose() {
    _loadTicker?.cancel();
    _yearController.dispose();
    super.dispose();
  }

  void _startLoadTicker() {
    _loadTicker?.cancel();
    _loadElapsedSec = 0;
    _loadTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _loadElapsedSec++);
    });
  }

  void _stopLoadTicker() {
    _loadTicker?.cancel();
    _loadTicker = null;
  }

  Future<void> _reloadLocal() async {
    final local = await _localBooks.list();
    if (!mounted) return;
    setState(() => _localBooksList = local);
  }

  Future<void> _importLocal(String format) async {
    try {
      final entry = await _localBooks.pickAndImport(format: format);
      if (entry == null) return; // user cancelled
      await _reloadLocal();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported "${entry.title}"'), duration: const Duration(seconds: 3)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Import failed: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    }
  }

  /// Opens the book directly into audio playback at the saved chapter/ordinal.
  /// Refreshes the resume map after the reader is popped so the card's icon
  /// reflects any progress made in that session.
  Future<void> _resumeBook(BookEntry b) async {
    final pos = _audioPositions[b.id];
    if (pos == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BookReader(
          book: b,
          initialChapterIndex: pos.chapter,
          autoStartAudio: true,
        ),
      ),
    );
    if (mounted) await _reloadAudioPositions();
  }

  Future<void> _removeLocal(BookEntry b) async {
    await _localBooks.remove(b.id);
    await _reloadLocal();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed "${b.title}"'), duration: const Duration(seconds: 2)),
    );
  }

  bool get _isFetchingMore => _pagesPlanned > 0 && _pagesDone < _pagesPlanned;

  // ── Filtering / sorting ───────────────────────────────────────────────────

  List<BookEntry> _visibleBooks() {
    final q = _query.toLowerCase();
    bool matchesQuery(BookEntry b) =>
        q.isEmpty ||
        b.title.toLowerCase().contains(q) ||
        b.authors.any((a) => a.toLowerCase().contains(q));

    // Local imports bypass genre / length / difficulty / year filters — they're
    // explicitly yours, the user expects them to always be findable. Search is
    // still honoured so typing in the search box can hide them.
    final localList = _localBooksList.where(matchesQuery).toList();

    Iterable<BookEntry> it = _remoteBooks.where(matchesQuery);
    if (_genre != null) it = it.where((b) => b.tags.contains(_genre));
    if (_length != 'any') it = it.where((b) => _lengthBucket(b.wordCount) == _length);
    if (_difficulty != 'any') it = it.where((b) => b.difficulty == _difficulty);
    // Year cutoff mirrors the server-side cutoff (Gutendex doesn't always honour
    // it perfectly for unknown-death-year authors).
    it = it.where((b) => b.publicationYear != null && b.publicationYear! >= _earliestYear);

    final list = it.toList();
    switch (_sort) {
      case 'newest':
        list.sort((a, b) => (b.publicationYear ?? -1).compareTo(a.publicationYear ?? -1));
        break;
      case 'oldest':
        list.sort((a, b) => (a.publicationYear ?? 1 << 30).compareTo(b.publicationYear ?? 1 << 30));
        break;
      case 'title':
        list.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case 'author':
        list.sort((a, b) => (a.authors.isEmpty ? '' : a.authors.first.toLowerCase())
            .compareTo(b.authors.isEmpty ? '' : b.authors.first.toLowerCase()));
        break;
      case 'shortest':
        list.sort((a, b) => a.wordCount.compareTo(b.wordCount));
        break;
      case 'longest':
        list.sort((a, b) => b.wordCount.compareTo(a.wordCount));
        break;
    }
    // Order: recently-played books (newest first) → local imports → other
    // remote books in the user's sort. A recently-played local book still goes
    // to the very top, ahead of un-played locals.
    final combined = [...localList, ...list];
    final recent = <BookEntry>[];
    final rest = <BookEntry>[];
    for (final b in combined) {
      if (_audioPositions.containsKey(b.id)) {
        recent.add(b);
      } else {
        rest.add(b);
      }
    }
    recent.sort((a, b) =>
        (_audioPositions[b.id]!.at).compareTo(_audioPositions[a.id]!.at));
    return [...recent, ...rest];
  }

  String _lengthBucket(int wc) {
    if (wc <= 0) return 'unknown';
    if (wc < 30000) return 'short';
    if (wc < 100000) return 'medium';
    return 'long';
  }

  /// Genres for the dropdown: only those that appear in at least one book
  /// passing the current year / Length / Difficulty filters (genre itself is
  /// excluded from the predicate so picking one doesn't hide all alternatives).
  List<String> _allGenres() {
    bool yearOk(BookEntry b) =>
        b.id.startsWith(LocalBooksService.kIdPrefix) ||
        (b.publicationYear != null && b.publicationYear! >= _earliestYear);
    bool lenOk(BookEntry b) => _length == 'any' || _lengthBucket(b.wordCount) == _length;
    bool diffOk(BookEntry b) => _difficulty == 'any' || b.difficulty == _difficulty;

    final set = <String>{};
    for (final b in _books) {
      if (!yearOk(b) || !lenOk(b) || !diffOk(b)) continue;
      for (final t in b.tags) set.add(t);
    }
    final list = set.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (_loading && _books.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text(
              'Loading from Gutendex… ${_loadElapsedSec}s',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_loadElapsedSec >= 10)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Taking longer than usual — slow network or Gutendex busy.',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
          ],
        ),
      );
    }

    if (_error != null && _books.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.cloud_off, size: 48),
            const SizedBox(height: 12),
            Text('Could not load catalog:\n$_error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _fetchRemote(force: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ]),
        ),
      );
    }

    final visible = _visibleBooks();

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 60),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: _searchField()),
              const SizedBox(width: 8),
              _yearField(),
              const SizedBox(width: 8),
              PopupMenuButton<String>(
                tooltip: 'Import book from phone',
                onSelected: _importLocal,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'epub', child: Text('Import EPUB')),
                  PopupMenuItem(value: 'txt', child: Text('Import TXT')),
                ],
                icon: const Icon(Icons.file_upload_outlined),
              ),
            ],
          ),
          _filterRows(),
          _gutenbergButton(),
          const SizedBox(height: 8),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(8),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Gutenberg fetch failed: $_error',
                        style: Theme.of(context).textTheme.labelSmall),
                  ),
                  TextButton(
                    onPressed: () => _fetchRemote(force: true),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  '${visible.length} shown • ${_localBooksList.length} local · ${_remoteBooks.length} from Gutenberg'
                  '${_isFetchingMore ? "  •  fetching more books…" : ""}',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
              if (_fetchedAt != null && !_isFetchingMore)
                Text('Updated ${_relativeTime(_fetchedAt!)}',
                    style: Theme.of(context).textTheme.labelSmall),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            // No RefreshIndicator on purpose — only the Load/Reload button
            // triggers a Gutenberg fetch, never a swipe-down gesture.
            child: visible.isEmpty
                ? const Center(child: Text('No books match these filters.'))
                : ListView.builder(
                    // +1 slot at the bottom for the in-flight progress footer.
                    itemCount: visible.length + 1,
                    itemBuilder: (_, i) {
                      if (i < visible.length) return _buildCard(visible[i]);
                      return _buildListFooter();
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _searchField() {
    return TextField(
      decoration: const InputDecoration(
        prefixIcon: Icon(Icons.search),
        hintText: 'Search title or author',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onChanged: (v) => setState(() => _query = v),
    );
  }

  /// Two compact rows of dropdowns: [Genre, Length] then [Difficulty, Sort].
  /// Each dropdown is `Expanded` so they share the row evenly.
  Widget _filterRows() {
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: _genreDropdown()),
            const SizedBox(width: 12),
            Expanded(
              child: _enumDropdown('Length', _length, const ['any', 'short', 'medium', 'long'],
                  (v) => setState(() => _length = v)),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: _enumDropdown('Difficulty', _difficulty, const ['any', 'easy', 'medium', 'hard'],
                  (v) => setState(() => _difficulty = v)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _enumDropdown('Sort', _sort,
                  const ['newest', 'oldest', 'title', 'author', 'shortest', 'longest'],
                  (v) => setState(() => _sort = v)),
            ),
          ],
        ),
      ],
    );
  }

  Widget _genreDropdown() {
    final genres = _allGenres();
    // Stale selection (e.g. genre dropped out after a filter change) is included
    // as a "(no match)" item so the widget doesn't assert.
    final stale = _genre != null && !genres.contains(_genre);
    return DropdownButton<String?>(
      value: _genre,
      isExpanded: true,
      hint: const Text('Genre: any'),
      onChanged: (v) => setState(() => _genre = v),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('Genre: any')),
        if (stale) DropdownMenuItem<String?>(value: _genre, child: Text('${_genre!} (no match)')),
        for (final g in genres) DropdownMenuItem<String?>(value: g, child: Text(g)),
      ],
    );
  }

  Widget _enumDropdown(String label, String value, List<String> options, ValueChanged<String> onPick) {
    return DropdownButton<String>(
      value: value,
      isExpanded: true,
      onChanged: (v) {
        if (v != null) onPick(v);
      },
      items: [for (final o in options) DropdownMenuItem(value: o, child: Text('$label: $o'))],
    );
  }

  /// Earliest-author-year text field. Compact, matches the search field's
  /// height (no floating label — hint only — so they align cleanly).
  Widget _yearField() {
    return SizedBox(
      width: 96,
      child: TextField(
        controller: _yearController,
        decoration: const InputDecoration(
          hintText: 'From year',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12),
          border: OutlineInputBorder(),
        ),
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        textAlign: TextAlign.center,
        onSubmitted: (v) {
          final n = int.tryParse(v.trim());
          if (n != null) _setEarliestYear(n);
        },
      ),
    );
  }

  Widget _buildCard(BookEntry b) {
    final hasResume = _audioPositions.containsKey(b.id);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _showBookSheet(b),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 64,
                height: 96,
                child: b.coverUrl.isEmpty
                    ? const Center(child: Icon(Icons.menu_book, size: 32))
                    : Image.network(
                        b.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
                      ),
              ),
              if (hasResume)
                IconButton(
                  tooltip: 'Resume audio from chunk ${_audioPositions[b.id]!.ordinal + 1}',
                  icon: const Icon(Icons.play_circle, size: 28),
                  onPressed: () => _resumeBook(b),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (b.id.startsWith(LocalBooksService.kIdPrefix))
                          Padding(
                            padding: const EdgeInsets.only(right: 6, top: 2),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text('LOCAL',
                                  style: Theme.of(context).textTheme.labelSmall),
                            ),
                          ),
                        Expanded(
                          child: Text(b.title, style: Theme.of(context).textTheme.titleMedium),
                        ),
                      ],
                    ),
                    if (b.authors.isNotEmpty)
                      Text(b.authors.join(', '), style: Theme.of(context).textTheme.bodyMedium),
                    const SizedBox(height: 6),
                    Text(_metaLine(b), style: Theme.of(context).textTheme.labelSmall),
                    if (b.tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          _genresLine(b.tags),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _metaLine(BookEntry b) {
    final parts = <String>[];
    if (b.publicationYear != null) parts.add('${b.publicationYear}');
    parts.add(b.difficulty);
    // Length bucket — shown even when 'unknown' so it's visible we don't have
    // word counts yet (filled in by Phase 2 post-EPUB stats).
    parts.add(_lengthBucket(b.wordCount));
    if (b.wordCount > 0) parts.add(_humanWords(b.wordCount));
    return parts.join(' • ');
  }

  String _genresLine(List<String> tags) =>
      '${tags.length == 1 ? "Genre" : "Genres"}: ${tags.join(", ")}';

  /// Load / Reload Project Gutenberg button. Label adapts to current state:
  /// no cached remote → "Load…"; cached → "Reload…"; in-flight → spinner.
  Widget _gutenbergButton() {
    if (_isFetchingMore) {
      return Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              'Loading from Gutenberg… (${_remoteBooks.length} of ~${_pagesPlanned * 32})',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      );
    }
    final hasBooks = _remoteBooks.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: () => _fetchRemote(force: hasBooks),
          icon: Icon(hasBooks ? Icons.refresh : Icons.cloud_download_outlined),
          label: Text(hasBooks ? 'Reload from Gutenberg' : 'Load from Project Gutenberg'),
        ),
      ),
    );
  }

  /// Footer at the bottom of the book list — shows a spinner with progress
  /// while pages are still being fetched, nothing once done.
  Widget _buildListFooter() {
    if (!_isFetchingMore) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(
              // Concrete book counts make this self-explanatory — no "page" jargon.
              'Fetching more books… (${_remoteBooks.length} of ~${_pagesPlanned * 32} loaded)',
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }

  String _humanWords(int wc) {
    if (wc >= 1000) return '${(wc / 1000).round()}k words';
    return '$wc words';
  }

  String _relativeTime(DateTime t) {
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  void _showBookSheet(BookEntry b) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, ctrl) => SingleChildScrollView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (b.coverUrl.isNotEmpty)
                Center(
                  child: SizedBox(
                    height: 200,
                    child: Image.network(
                      b.coverUrl,
                      errorBuilder: (_, _, _) => const Icon(Icons.broken_image, size: 48),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Text(b.title, style: Theme.of(context).textTheme.headlineSmall),
              if (b.authors.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(b.authors.join(', '), style: Theme.of(context).textTheme.titleMedium),
                ),
              const SizedBox(height: 8),
              Text(_metaLine(b), style: Theme.of(context).textTheme.labelMedium),
              if (b.tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _genresLine(b.tags),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              const SizedBox(height: 12),
              if (b.summary.isNotEmpty)
                Text(b.summary, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: b.epubUrl.isEmpty
                          ? null
                          : () async {
                              Navigator.of(context).pop();
                              await Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => BookReader(book: b)),
                              );
                              if (mounted) await _reloadAudioPositions();
                            },
                      icon: const Icon(Icons.menu_book_outlined),
                      label: const Text('Open'),
                    ),
                  ),
                  if (b.id.startsWith(LocalBooksService.kIdPrefix)) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        _removeLocal(b);
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Remove'),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
