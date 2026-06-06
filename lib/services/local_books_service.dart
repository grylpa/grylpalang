import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/book_entry.dart';

/// Imports user-supplied EPUBs from device storage, copies them into the app's
/// document directory, extracts minimal metadata (title / author / language)
/// from the OPF, and tracks them as a separate list merged into the catalog.
class LocalBooksService {
  static const String _kKey = 'localBooks';
  static const String _kDir = 'local_books';

  // Local-book ids carry this prefix so the rest of the app can tell at a glance
  // (e.g. to skip the Era filter for them — we don't know their publication year).
  static const String kIdPrefix = 'local:';

  final SharedPreferencesAsync _prefs;
  LocalBooksService(this._prefs);

  /// Returns the list of previously-imported local books, in import order.
  Future<List<BookEntry>> list() async {
    final raw = await _prefs.getString(_kKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = (jsonDecode(raw) as List).cast<dynamic>();
      return [for (final e in list) BookEntry.fromJson((e as Map).cast<String, dynamic>())];
    } catch (_) {
      return const [];
    }
  }

  /// Opens the system file picker filtered to [format] (`'epub'` or `'txt'`),
  /// copies the chosen file into app storage, parses minimal metadata when
  /// possible, and appends it to the list. Returns the new entry, or `null` if
  /// the user cancelled.
  Future<BookEntry?> pickAndImport({String format = 'epub'}) async {
    final group = format == 'txt'
        ? const XTypeGroup(label: 'Text', extensions: ['txt'])
        : const XTypeGroup(label: 'EPUB', extensions: ['epub']);
    final picked = await openFile(acceptedTypeGroups: [group]);
    if (picked == null) return null;
    final src = File(picked.path);
    final bytes = await src.readAsBytes();

    final id = '$kIdPrefix${sha1.convert(bytes).toString().substring(0, 12)}';
    final dest = await _destFile(id, ext: format);
    await dest.writeAsBytes(bytes, flush: true);

    final fallbackTitle = _fileBaseName(picked.path);
    final meta = format == 'txt'
        ? (title: fallbackTitle, author: '', language: '')
        : _parseEpubMetadata(bytes, fallbackTitle: fallbackTitle);
    final entry = BookEntry(
      id: id,
      title: meta.title,
      authors: meta.author.isEmpty ? const [] : [meta.author],
      language: meta.language,
      summary: '',
      tags: const ['Local'],
      wordCount: 0,
      publicationYear: null,
      coverUrl: '',
      epubUrl: 'file://${dest.path}',
      difficulty: 'medium',
    );

    final current = await list();
    // Replace any existing entry with the same id (same file imported twice).
    final updated = [...current.where((b) => b.id != id), entry];
    await _save(updated);
    return entry;
  }

  /// Removes an imported book and its cached file (epub or txt).
  Future<void> remove(String id) async {
    final current = await list();
    final updated = current.where((b) => b.id != id).toList();
    await _save(updated);
    try {
      for (final ext in const ['epub', 'txt']) {
        final f = await _destFile(id, ext: ext);
        if (await f.exists()) await f.delete();
      }
    } catch (_) {}
  }

  Future<void> _save(List<BookEntry> books) async {
    await _prefs.setString(_kKey, jsonEncode([for (final b in books) b.toJson()]));
  }

  Future<File> _destFile(String id, {required String ext}) async {
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/$_kDir');
    if (!await dir.exists()) await dir.create(recursive: true);
    final safeName = id.replaceAll(':', '_');
    return File('${dir.path}/$safeName.$ext');
  }

  // ── EPUB metadata (minimal in-house parser) ───────────────────────────────

  static String _fileBaseName(String path) {
    final n = path.split(RegExp(r'[\\/]')).last;
    final lower = n.toLowerCase();
    for (final ext in const ['.epub', '.txt']) {
      if (lower.endsWith(ext)) return n.substring(0, n.length - ext.length);
    }
    return n;
  }

  /// Reads the EPUB's container.xml to find the OPF, then extracts the Dublin
  /// Core title / creator / language from the OPF using simple regex. Robust
  /// enough for well-formed EPUBs; falls back to [fallbackTitle] on failure.
  static ({String title, String author, String language}) _parseEpubMetadata(
    Uint8List bytes, {
    required String fallbackTitle,
  }) {
    String? opfXml;
    try {
      final zip = ZipDecoder().decodeBytes(bytes);
      final container = _readUtf8(zip, 'META-INF/container.xml');
      if (container != null) {
        final m = RegExp(r'full-path="([^"]+)"').firstMatch(container);
        if (m != null) opfXml = _readUtf8(zip, m.group(1)!);
      }
    } catch (_) {
      // Fall through to defaults below.
    }
    if (opfXml == null) {
      return (title: fallbackTitle, author: '', language: '');
    }
    String? tag(String name) {
      // Matches <dc:title>…</dc:title> or <title>…</title> across namespaces.
      final re = RegExp('<(?:[a-zA-Z0-9]+:)?$name\\b[^>]*>(.*?)</(?:[a-zA-Z0-9]+:)?$name>',
          dotAll: true, caseSensitive: false);
      final m = re.firstMatch(opfXml!);
      final inner = m?.group(1)?.trim();
      if (inner == null || inner.isEmpty) return null;
      // Strip any nested markup (rare but possible).
      return inner.replaceAll(RegExp(r'<[^>]+>'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    return (
      title: tag('title') ?? fallbackTitle,
      author: tag('creator') ?? '',
      language: tag('language') ?? '',
    );
  }

  static String? _readUtf8(Archive zip, String path) {
    for (final f in zip.files) {
      if (f.name == path) {
        return utf8.decode(f.content, allowMalformed: true);
      }
    }
    return null;
  }
}
