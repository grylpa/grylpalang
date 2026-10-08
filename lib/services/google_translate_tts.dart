import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'speech_text.dart';

/// The only speeds the endpoint actually has. It takes a `ttsspeed` float but
/// quantizes it into exactly three buckets — measured on one Greek sentence
/// whose normal rendering is 4.776s:
///
///   ttsspeed <= 0.15  -> 6.648s  (72% of normal pace)
///   ttsspeed 0.2-0.3  -> 5.760s  (83%)
///   ttsspeed >= 0.35  -> 4.776s  (100%, same as omitting it)
///
/// Nothing above normal exists, and the floor is 72% — so this cannot serve an
/// arbitrary percentage the way [TtsSynthService] can. Callers that need a
/// specific pace must synthesize on-device instead.
enum GoogleTtsSpeed {
  slow('0.1', 'slow'),
  // 0.25, not 0.2: the middle bucket is 0.20-0.30 inclusive, so 0.2 sits on its
  // lower boundary and any rounding change at the far end would drop it into
  // [slow]. Mid-bucket costs nothing — both return the same clip today.
  medium('0.25', 'med'),

  /// Normal pace. Sends no `ttsspeed` at all and takes the *unsuffixed* cache
  /// key, so every clip fetched before speeds existed is still a hit.
  fast('', '');

  const GoogleTtsSpeed(this.param, this.keySuffix);

  /// Value for the endpoint's `ttsspeed`; empty means omit the parameter.
  final String param;

  /// Appended to the cache key. Empty for [fast] — see the note above.
  final String keySuffix;
}

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

  // The key for [GoogleTtsSpeed.fast] is deliberately byte-identical to the
  // pre-speed one ('$langCode|$text'): the Sentence Bank has thousands of Greek
  // clips cached under it, and a reshaped key would silently re-download the lot.
  static String _hashKey(String text, String langCode, GoogleTtsSpeed speed) =>
      sha1.convert(utf8.encode('$langCode|$text${speed.keySuffix.isEmpty ? '' : '|${speed.keySuffix}'}')).toString();

  Future<Directory> _ensureDiskDir() {
    return _diskDirInit ??= () async {
      final base = await getApplicationSupportDirectory();
      final dir = Directory('${base.path}/$_kCacheDirName');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }();
  }

  Future<File> _diskFileFor(String text, String langCode, GoogleTtsSpeed speed) async {
    final dir = await _ensureDiskDir();
    return File('${dir.path}/${_hashKey(text, langCode, speed)}.mp3');
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

  // Backoff (ms) when the unofficial endpoint rate-limits a burst of requests
  // (HTTP 429) — e.g. fetching every clip the first time a subject is opened.
  static const _kRetryDelaysMs = [400, 900, 2000];

  Future<Uint8List> _downloadBytes(String text, String langCode, GoogleTtsSpeed speed) async {
    final uri = Uri.https(_kHost, _kPath, {
      'ie': 'UTF-8',
      'q': text,
      'tl': langCode,
      'client': 'tw-ob',
      // Omitted entirely at normal pace, so the request is unchanged from
      // before speeds existed.
      if (speed.param.isNotEmpty) 'ttsspeed': speed.param,
    });
    for (var attempt = 0; ; attempt++) {
      final resp = await http
          .get(
            uri,
            headers: {
              // The endpoint refuses requests without a browser-like UA.
              'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36',
              'Accept': '*/*',
              'Referer': 'https://translate.google.com/',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) return resp.bodyBytes;
      if (resp.statusCode == 429 && attempt < _kRetryDelaysMs.length) {
        await Future.delayed(Duration(milliseconds: _kRetryDelaysMs[attempt]));
        continue;
      }
      throw Exception('Google TTS HTTP ${resp.statusCode}');
    }
  }

  /// Returns the cached MP3 path for [text]/[langCode] if it's already on disk,
  /// else null. Never makes a network call — used by callers to know whether
  /// they'd be hitting the endpoint, without actually doing so.
  Future<String?> cachedFile(String text, String langCode, {GoogleTtsSpeed speed = GoogleTtsSpeed.fast}) async {
    final f = await _diskFileFor(speakable(text, langCode), langCode, speed);
    return await f.exists() ? f.path : null;
  }

  /// Ensures the MP3 for [text]/[langCode] exists on disk and returns its path.
  /// Downloads (and caches) if missing. Throws on network failure.
  Future<String> ensureFile(String text, String langCode, {GoogleTtsSpeed speed = GoogleTtsSpeed.fast}) async {
    // Keyed and fetched by what is spoken, so an abbreviation's dot never
    // reaches the endpoint as a full stop.
    final diskFile = await _diskFileFor(speakable(text, langCode), langCode, speed);
    if (await diskFile.exists()) {
      unawaited(_touch(diskFile));
      return diskFile.path;
    }
    final bytes = await _downloadBytes(speakable(text, langCode), langCode, speed);
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
