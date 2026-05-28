import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Fetches and caches MP3 audio from the unofficial Google Translate audio
/// endpoint. Used for the target language (e.g. Greek), whose offline system
/// voice gives flat, statement-like intonation for questions — Google's audio
/// handles it properly. The endpoint is unofficial — it may rate-limit (429) or
/// change without notice — so callers should fall back to flutter_tts on failure.
///
/// This is a pure fetch/cache service; playback is done by the caller (via
/// just_audio). MP3s are cached persistently on disk (capped at
/// [_kMaxDiskEntries]) so they're only fetched once.
class GoogleTranslateTts {
  static const _kHost = 'translate.google.com';
  static const _kPath = '/translate_tts';
  static const _kMaxLen = 200; // endpoint truncates ~200 chars per request
  static const _kMaxDiskEntries = 10000;
  static const _kEvictionBatch = 200; // delete this many at a time when over cap
  static const _kCacheDirName = 'google_tts_cache';

  Future<Directory>? _diskDirInit;
  int? _diskCount;

  /// Returns true if [text] fits in a single endpoint request.
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

  Future<Uint8List> _downloadBytes(String text, String langCode) async {
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
    return resp.bodyBytes;
  }

  /// Ensures the MP3 for [text]/[langCode] exists on disk and returns its path.
  /// Downloads (and caches) if missing. Throws on network failure.
  Future<String> ensureFile(String text, String langCode) async {
    final diskFile = await _diskFileFor(text, langCode);
    if (await diskFile.exists()) {
      unawaited(_touch(diskFile));
      return diskFile.path;
    }
    final bytes = await _downloadBytes(text, langCode);
    await _evictIfFull();
    await diskFile.writeAsBytes(bytes, flush: true);
    _diskCount = (_diskCount ?? 0) + 1;
    return diskFile.path;
  }

  /// Bumps the file's mtime so disk eviction is LRU rather than FIFO.
  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // File may have been evicted between the read and the touch; ignore.
    }
  }

  /// Deletes every cached MP3 on disk. Used by the "Clear audio cache" button.
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
