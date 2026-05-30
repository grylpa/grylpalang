import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_chapter.dart';
import '../models/book_entry.dart';

/// Downloads and caches EPUBs, extracts chapter text, and persists the user's
/// reading position per book. EPUB parsing is a minimal in-house regex+ZIP pass
/// (no `epubx` / `xml` deps), good enough for well-formed PG / SE files.
class BookLibraryService {
  static const String _kDir = 'book_epubs';
  static const String _kPositionsKey = 'bookPositions';

  final SharedPreferencesAsync _prefs;
  BookLibraryService(this._prefs);

  // ── EPUB file: ensure local copy ──────────────────────────────────────────

  /// Returns the local file path of the EPUB for [book], downloading it on the
  /// first call. Local imports (`file://…`) are returned as-is.
  Future<String> ensureEpubFile(BookEntry book) async {
    if (book.epubUrl.startsWith('file://')) {
      return book.epubUrl.substring('file://'.length);
    }
    if (book.epubUrl.isEmpty) {
      throw Exception('No EPUB download URL for this book.');
    }
    final dest = await _bookFile(book.id);
    if (await dest.exists()) return dest.path;
    final resp = await http.get(Uri.parse(book.epubUrl), headers: const {
      'User-Agent': 'Katalaveno/1.0 (Android; Flutter)',
    });
    if (resp.statusCode != 200) {
      throw Exception('EPUB download failed (HTTP ${resp.statusCode}).');
    }
    await dest.writeAsBytes(resp.bodyBytes, flush: true);
    return dest.path;
  }

  Future<File> _bookFile(String bookId) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_kDir');
    if (!await dir.exists()) await dir.create(recursive: true);
    final safe = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return File('${dir.path}/$safe.epub');
  }

  // ── Reading position ──────────────────────────────────────────────────────

  Future<int> loadChapterIndex(String bookId) async {
    final raw = await _prefs.getString(_kPositionsKey);
    if (raw == null) return 0;
    try {
      final map = jsonDecode(raw) as Map;
      final entry = map[bookId];
      if (entry is Map && entry['chapter'] is int) return entry['chapter'] as int;
    } catch (_) {}
    return 0;
  }

  Future<void> saveChapterIndex(String bookId, int chapterIndex) async {
    final map = await _loadPositionsMap();
    final entry = _entryFor(map, bookId);
    entry['chapter'] = chapterIndex;
    map[bookId] = entry;
    await _prefs.setString(_kPositionsKey, jsonEncode(map));
  }

  /// Audio playback position — saved chapter + chunk ordinal, so the user can
  /// pick up the auto-play exactly where they left off across app restarts.
  Future<({int chapter, int ordinal})?> loadAudioPosition(String bookId) async {
    final map = await _loadPositionsMap();
    final entry = map[bookId];
    if (entry is Map) {
      final audio = entry['audio'];
      if (audio is Map && audio['chapter'] is int && audio['ordinal'] is int) {
        return (chapter: audio['chapter'] as int, ordinal: audio['ordinal'] as int);
      }
    }
    return null;
  }

  Future<void> saveAudioPosition(String bookId, int chapterIndex, int ordinal) async {
    final map = await _loadPositionsMap();
    final entry = _entryFor(map, bookId);
    entry['audio'] = {'chapter': chapterIndex, 'ordinal': ordinal};
    map[bookId] = entry;
    await _prefs.setString(_kPositionsKey, jsonEncode(map));
  }

  Future<void> clearAudioPosition(String bookId) async {
    final map = await _loadPositionsMap();
    final entry = map[bookId];
    if (entry is Map) {
      entry.remove('audio');
      map[bookId] = entry;
      await _prefs.setString(_kPositionsKey, jsonEncode(map));
    }
  }

  Future<Map<String, dynamic>> _loadPositionsMap() async {
    final raw = await _prefs.getString(_kPositionsKey);
    if (raw == null) return <String, dynamic>{};
    try {
      return (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Map<String, dynamic> _entryFor(Map<String, dynamic> map, String bookId) {
    final e = map[bookId];
    return (e is Map) ? e.cast<String, dynamic>() : <String, dynamic>{};
  }

  // ── Text chunking (for audio mode) ────────────────────────────────────────

  /// Splits chapter [text] into chunks according to [unit] ('sentence' or
  /// 'paragraph'). Paragraph chunks use the blank-line boundaries the EPUB
  /// parser preserves; sentence chunks are a best-effort regex split. Empty
  /// chunks are dropped, and overly long fragments are kept whole (the TTS
  /// engine can read them — the user just won't get fine-grained pauses there).
  static List<String> chunkText(String text, String unit) {
    if (unit == 'paragraph') {
      return [
        for (final p in text.split(RegExp(r'\n\s*\n')))
          if (p.trim().isNotEmpty) p.trim(),
      ];
    }
    // 'sentence' (default): split on . / ! / ? / … followed by whitespace + an
    // upper-case letter or digit. Imperfect for abbreviations but readable.
    final out = <String>[];
    for (final p in text.split(RegExp(r'\n\s*\n'))) {
      final paragraph = p.trim();
      if (paragraph.isEmpty) continue;
      final pieces = paragraph
          .split(RegExp(r'(?<=[.!?…])\s+(?=[A-Z0-9"“‘])'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      out.addAll(pieces);
    }
    return out;
  }

  // ── EPUB parsing ──────────────────────────────────────────────────────────

  /// Reads the EPUB at [epubPath] and returns its chapters in reading order.
  Future<List<BookChapter>> loadChapters(String epubPath) async {
    final bytes = await File(epubPath).readAsBytes();
    return _parseChapters(bytes);
  }

  static List<BookChapter> _parseChapters(Uint8List bytes) {
    final zip = ZipDecoder().decodeBytes(bytes);

    final container = _readUtf8(zip, 'META-INF/container.xml');
    if (container == null) throw Exception('Not a valid EPUB (no container.xml).');
    final opfMatch = RegExp(r'full-path="([^"]+)"').firstMatch(container);
    if (opfMatch == null) throw Exception('Not a valid EPUB (no rootfile in container).');
    final opfPath = opfMatch.group(1)!;
    final opfXml = _readUtf8(zip, opfPath);
    if (opfXml == null) throw Exception('Not a valid EPUB (cannot read OPF).');

    final opfDir = opfPath.contains('/') ? opfPath.substring(0, opfPath.lastIndexOf('/') + 1) : '';

    // manifest: id -> href. The id and href attribute order varies between EPUB
    // toolchains, so we try both arrangements.
    final manifest = <String, String>{};
    final itemRe = RegExp(r'<item\b([^>]+)/?>', caseSensitive: false);
    final attrRe = RegExp(r'(\w[\w-]*)\s*=\s*"([^"]*)"');
    for (final m in itemRe.allMatches(opfXml)) {
      final attrs = <String, String>{};
      for (final a in attrRe.allMatches(m.group(1)!)) {
        attrs[a.group(1)!.toLowerCase()] = a.group(2)!;
      }
      final id = attrs['id'];
      final href = attrs['href'];
      if (id != null && href != null) manifest[id] = href;
    }

    // spine: list of idrefs in reading order.
    final spineIds = <String>[
      for (final m in RegExp(r'<itemref\b[^>]*\bidref="([^"]+)"', caseSensitive: false).allMatches(opfXml))
        m.group(1)!,
    ];

    final chapters = <BookChapter>[];
    for (var i = 0; i < spineIds.length; i++) {
      final id = spineIds[i];
      final hrefRaw = manifest[id];
      if (hrefRaw == null) continue;
      final href = Uri.decodeComponent(hrefRaw.split('#').first);
      final path = _resolveZipPath(opfDir, href);
      final xhtml = _readUtf8(zip, path);
      if (xhtml == null) continue;
      final text = _xhtmlToText(xhtml);
      if (text.trim().isEmpty) continue;
      final title = _chapterTitle(xhtml) ?? 'Chapter ${chapters.length + 1}';
      chapters.add(BookChapter(title: title, text: text));
    }
    return chapters;
  }

  static String _resolveZipPath(String opfDir, String href) {
    if (href.startsWith('/')) return href.substring(1);
    return '$opfDir$href';
  }

  static String? _chapterTitle(String xhtml) {
    for (final tag in const ['h1', 'h2', 'title']) {
      final m = RegExp('<$tag\\b[^>]*>(.*?)</$tag>', caseSensitive: false, dotAll: true)
          .firstMatch(xhtml);
      if (m != null) {
        final t = _stripTagsAndDecode(m.group(1)!);
        if (t.isNotEmpty) return t;
      }
    }
    return null;
  }

  static String _xhtmlToText(String xhtml) {
    final body = RegExp(r'<body\b[^>]*>(.*?)</body>', caseSensitive: false, dotAll: true)
            .firstMatch(xhtml)
            ?.group(1) ??
        xhtml;
    // Preserve paragraph boundaries before stripping tags.
    final withBreaks = body
        .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'</h[1-6]\s*>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</li\s*>', caseSensitive: false), '\n');
    return _stripTagsAndDecode(withBreaks);
  }

  // Strip tags, decode common HTML entities, collapse whitespace but preserve
  // paragraph breaks (double newlines).
  static String _stripTagsAndDecode(String s) {
    var t = s.replaceAll(RegExp(r'<[^>]+>'), '');
    t = t
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&mdash;', '—')
        .replaceAll('&ndash;', '–')
        .replaceAll('&hellip;', '…')
        .replaceAll('&lsquo;', '‘')
        .replaceAll('&rsquo;', '’')
        .replaceAll('&ldquo;', '“')
        .replaceAll('&rdquo;', '”');
    t = t.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      final code = int.tryParse(m.group(1)!);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    t = t.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
      final code = int.tryParse(m.group(1)!, radix: 16);
      return code == null ? m.group(0)! : String.fromCharCode(code);
    });
    return t
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r' *\n *'), '\n')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  static String? _readUtf8(Archive zip, String path) {
    for (final f in zip.files) {
      if (f.name == path) return utf8.decode(f.content, allowMalformed: true);
    }
    return null;
  }
}
