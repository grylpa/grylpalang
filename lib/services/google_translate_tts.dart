import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Thin TTS using the unofficial Google Translate audio endpoint.
/// Returns MP3 bytes for short snippets and plays them via audioplayers.
///
/// Why we use it: Android's offline Greek voices give a flat, statement-like
/// intonation for question marks. Google Translate's audio handles it
/// properly. The endpoint is not officially supported — it may rate-limit
/// (HTTP 429) or change without notice — so callers should fall back to
/// flutter_tts on failure.
///
/// MP3s are cached persistently on disk (capped at [_kMaxDiskEntries]) so
/// they never need to be re-fetched. A small in-memory cache speeds up
/// immediate replay.
class GoogleTranslateTts {
  static const _kHost = 'translate.google.com';
  static const _kPath = '/translate_tts';
  static const _kMaxLen = 200; // endpoint truncates ~200 chars per request
  static const _kMaxMemoryEntries = 50;
  static const _kMaxDiskEntries = 10000;
  static const _kEvictionBatch = 200; // delete this many at a time when over cap
  static const _kCacheDirName = 'google_tts_cache';

  final _player = AudioPlayer();
  final _memCache = <String, Uint8List>{};

  Future<Directory>? _diskDirInit;
  int? _diskCount;

  void Function()? onComplete;

  GoogleTranslateTts() {
    _player.onPlayerComplete.listen((_) => onComplete?.call());
  }

  /// Returns true if the [text] fits in a single endpoint request.
  bool canSpeak(String text) => text.length <= _kMaxLen;

  static String _hashKey(String text, String langCode) =>
      sha1.convert(utf8.encode('$langCode|$text')).toString();

  Future<Directory> _ensureDiskDir() {
    return _diskDirInit ??= () async {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/$_kCacheDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }();
  }

  Future<File> _diskFileFor(String text, String langCode) async {
    final dir = await _ensureDiskDir();
    return File('${dir.path}/${_hashKey(text, langCode)}.mp3');
  }

  /// Lazily counts disk cache files so we only enumerate when needed.
  Future<int> _diskFileCount() async {
    if (_diskCount != null) return _diskCount!;
    final dir = await _ensureDiskDir();
    final files = await dir.list(followLinks: false).toList();
    _diskCount = files.length;
    return _diskCount!;
  }

  /// If we're over the cap, delete the oldest files by mtime in a batch so we
  /// amortize the directory listing cost across many writes.
  Future<void> _evictIfFull() async {
    final count = await _diskFileCount();
    if (count < _kMaxDiskEntries) return;
    final dir = await _ensureDiskDir();
    final entries = await dir.list(followLinks: false).toList();
    final files = entries.whereType<File>().toList()
      ..sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    var deleted = 0;
    for (final f in files) {
      if (deleted >= _kEvictionBatch) break;
      try {
        await f.delete();
        deleted++;
      } catch (_) {}
    }
    _diskCount = count - deleted;
  }

  void _rememberInMemory(String key, Uint8List bytes) {
    _memCache[key] = bytes;
    if (_memCache.length > _kMaxMemoryEntries) {
      _memCache.remove(_memCache.keys.first);
    }
  }

  /// Fetches MP3 bytes for [text] in [langCode] (e.g. `'el'`).
  /// Order: in-memory → disk → network. Throws on network failure.
  ///
  /// On every cache hit we bump the disk file's mtime so eviction is LRU
  /// (least-recently-used) rather than FIFO by creation date.
  Future<Uint8List> _fetch(String text, String langCode) async {
    final key = _hashKey(text, langCode);
    final diskFile = await _diskFileFor(text, langCode);

    final mem = _memCache[key];
    if (mem != null) {
      unawaited(_touch(diskFile));
      return mem;
    }

    if (await diskFile.exists()) {
      final bytes = await diskFile.readAsBytes();
      _rememberInMemory(key, bytes);
      unawaited(_touch(diskFile));
      return bytes;
    }

    final uri = Uri.https(_kHost, _kPath, {
      'ie': 'UTF-8',
      'q': text,
      'tl': langCode,
      'client': 'tw-ob',
    });
    final resp = await http.get(uri, headers: {
      // The endpoint refuses requests without a browser-like UA.
      'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
      'Accept': '*/*',
      'Referer': 'https://translate.google.com/',
    }).timeout(const Duration(seconds: 8));

    if (resp.statusCode != 200) {
      throw Exception('Google TTS HTTP ${resp.statusCode}');
    }

    final bytes = resp.bodyBytes;
    _rememberInMemory(key, bytes);

    // Persist to disk in the background — don't make playback wait on it.
    unawaited(_persistToDisk(diskFile, bytes));
    return bytes;
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // File may have been evicted between the read and the touch; ignore.
    }
  }

  Future<void> _persistToDisk(File file, Uint8List bytes) async {
    try {
      await _evictIfFull();
      await file.writeAsBytes(bytes, flush: false);
      _diskCount = (_diskCount ?? 0) + 1;
    } catch (_) {
      // Caching failures are non-fatal.
    }
  }

  /// Fetches and plays [text] in [langCode]. Throws on failure (caller can
  /// fall back to another TTS).
  Future<void> speak(String text, String langCode) async {
    final bytes = await _fetch(text, langCode);
    await _player.stop();
    await _player.play(BytesSource(bytes, mimeType: 'audio/mpeg'));
  }

  Future<void> stop() => _player.stop();

  Future<void> dispose() => _player.dispose();

  /// Deletes every cached MP3 on disk and clears the in-memory cache.
  /// Used by the "Clear audio cache" button in Settings.
  static Future<void> clearAllCachedAudio() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/$_kCacheDirName');
    if (!await dir.exists()) return;
    await for (final entry in dir.list(followLinks: false)) {
      try {
        await entry.delete();
      } catch (_) {}
    }
  }
}
