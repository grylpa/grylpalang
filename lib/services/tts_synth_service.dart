import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';

import 'audio_utils.dart';

/// The app's "normal" speech rate. flutter_tts on Android treats 0.5 as the
/// engine's natural pace (1.0 is roughly double speed), so this — not 1.0 — is
/// what 100% means everywhere in the app.
const double kSourceSpeechRate = 0.5;

/// BCP-47 locale for a language *name* as the app stores it ("Greek" → el-GR).
/// Null for a language we have no mapping for — callers then let the engine
/// pick, rather than guessing a wrong locale.
String? localeForLanguage(String languageName) {
  const map = <String, String>{
    'English': 'en-US',
    'Greek': 'el-GR',
    'Hebrew': 'he-IL',
    'German': 'de-DE',
    'French': 'fr-FR',
    'Spanish': 'es-ES',
    'Italian': 'it-IT',
    'Portuguese': 'pt-PT',
    'Russian': 'ru-RU',
    'Turkish': 'tr-TR',
    'Arabic': 'ar-SA',
    'Chinese': 'zh-CN',
    'Japanese': 'ja-JP',
    'Korean': 'ko-KR',
  };
  return map[languageName];
}

/// Two-letter code for a language name ("Greek" → "el"), defaulting to English.
String langCodeForLanguage(String languageName) =>
    (localeForLanguage(languageName) ?? 'en').toLowerCase().split(RegExp('[-_]')).first;

/// True where flutter_tts can actually synthesize.
bool ttsSupported() {
  if (kIsWeb) return false;
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => true,
    TargetPlatform.iOS => true,
    TargetPlatform.macOS => true,
    TargetPlatform.windows => true,
    _ => false,
  };
}

/// Renders text to cached WAV files with the on-device TTS engine.
///
/// A process-wide singleton on purpose: every `FlutterTts()` in the Dart isolate
/// talks to the *same* native engine, so two screens synthesizing at once would
/// interleave `setVoice`/`setSpeechRate`/`synthesizeToFile` calls and produce
/// clips in the wrong voice. [_locked] serializes every render.
class TtsSynthService {
  TtsSynthService._();
  static final TtsSynthService instance = TtsSynthService._();

  final FlutterTts _tts = FlutterTts();
  Directory? _dir;

  /// Serializes engine access — see the class doc.
  static Future<void> _mutex = Future<void>.value();
  static Future<T> _locked<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _mutex = _mutex.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<Directory> _ensureDir() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/tts_synth_cache');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dir = dir;
    return dir;
  }

  /// Cache key for a clip. Version token `p7`; bump to force re-synthesis
  /// (p1 = leading silence, p2 = region-first Automatic voice, p3 = 500ms lead,
  /// p5 = 24kHz cap, p6 = native rate/no downsampling, p7 = no pitch-shift
  /// fallback). The rate is folded in so clips synthesized at different speeds
  /// never collide — and so a clip made at the default rate keeps the key it
  /// had before rates were configurable.
  String _key(String langCode, String voiceKey, double rate, String text) =>
      sha1.convert(utf8.encode('$langCode|$voiceKey|p7|r$rate|$text')).toString();

  /// The cached clip path for these parameters if it's already on disk; null
  /// otherwise. Never synthesizes — used to pre-count real work for a progress
  /// bar instead of marching through cache hits.
  Future<String?> cachedPath(
    String text, {
    required String langCode,
    String voiceId = '',
    String gender = '',
    double rate = kSourceSpeechRate,
  }) async {
    try {
      final dir = await _ensureDir();
      final file = File('${dir.path}/${_key(langCode, voiceId.isNotEmpty ? voiceId : gender, rate, text)}.wav');
      return await file.exists() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  /// Renders [text] to a WAV, cached on disk so it's only synthesized once per
  /// (voice/gender, rate, text). When [voiceId] is a chosen voice
  /// ("name__SEP__locale") that exact voice is used; otherwise a voice is picked
  /// by [gender] within [locale].
  Future<String> synthToFile(
    String text, {
    required String langCode,
    String? locale,
    String voiceId = '',
    String gender = '',
    double rate = kSourceSpeechRate,
  }) async {
    final dir = await _ensureDir();
    final file = File('${dir.path}/${_key(langCode, voiceId.isNotEmpty ? voiceId : gender, rate, text)}.wav');
    // Reuse a cached clip only if it's a plausibly-real WAV. A previously
    // failed/timed-out synthesis can leave a 0-byte or header-only file; a valid
    // clip is always >20 KB (the 500ms silence pad alone is that big). Serving
    // the tiny one would replay as permanent silence, so delete + re-synth.
    if (await file.exists()) {
      if (await isUsableClip(file)) return file.path;
      try {
        await file.delete();
      } catch (_) {}
    }
    await _evictIfFull(dir);

    return _locked(() async {
      // Another queued render may have produced it while we waited our turn.
      if (await file.exists() && await isUsableClip(file)) return file.path;

      await _tts.stop();
      final parts = voiceId.split('__SEP__');
      if (voiceId.isNotEmpty && parts.length == 2) {
        if (parts[1].isNotEmpty) await _tts.setLanguage(parts[1]);
        await _tts.setVoice({'name': parts[0], 'locale': parts[1]});
      } else {
        if (locale != null) await _tts.setLanguage(locale);
        // Pick a gendered voice if one exists, but never pitch-shift to fake
        // one: the engine's pitch-shift adds grainy artefacts to every clip.
        await applyGenderedVoice(locale, gender);
      }
      await _tts.setSpeechRate(rate);
      await _tts.setPitch(1.0);
      await _tts.awaitSynthCompletion(true);
      // flutter_tts.synthesizeToFile occasionally hangs on Android (the engine's
      // completion callback never fires), which would leave the whole prep stuck
      // with no way for the per-item catch to kick in. Wrap it in a hard timeout
      // so a hung synthesis becomes a normal per-item failure that gets skipped.
      try {
        await _tts.synthesizeToFile(text, file.path, true).timeout(const Duration(seconds: 30));
      } on TimeoutException {
        // Best-effort: cancel any in-flight engine work so the next call starts
        // clean, and delete any partial file so it isn't cached as a silent clip.
        try {
          await _tts.stop();
        } catch (_) {}
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        throw Exception('TTS synthesis timed out');
      }
      if (!await file.exists()) throw Exception('TTS synthesis produced no file');
      // Prepend 500ms silence — the audio path drops the first frames at a clip
      // boundary / cold start. Keeps the engine's native rate (mono).
      await _normalizeWav(file);
      // Guard against a "successful" synth that produced an empty/broken clip:
      // don't cache silence — delete it so it retries next time.
      if (!await isUsableClip(file)) {
        try {
          await file.delete();
        } catch (_) {}
        throw Exception('TTS synthesis produced an empty clip');
      }
      return file.path;
    });
  }

  /// Speaks [text] live (voice preview). Serialized against synthesis so it
  /// can't reconfigure the engine mid-render.
  Future<void> speak(String text, {String? locale, String voiceName = '', double rate = kSourceSpeechRate}) =>
      _locked(() async {
        await _tts.stop();
        // synthToFile leaves the engine in await-completion mode; speak() would
        // then block this lock until the utterance ends (and on some engines
        // never return), so it's explicitly turned off for live playback.
        await _tts.awaitSpeakCompletion(false);
        if (locale != null && locale.isNotEmpty) await _tts.setLanguage(locale);
        if (voiceName.isNotEmpty) await _tts.setVoice({'name': voiceName, 'locale': locale ?? ''});
        await _tts.setSpeechRate(rate);
        await _tts.setPitch(1.0);
        await _tts.setVolume(1.0);
        await _tts.speak(text);
      });

  /// Whether the engine can actually speak [locale]. False means the language
  /// pack isn't installed — synthesis would either fail or quietly render the
  /// text in some other language, so callers should say so rather than let it
  /// happen.
  Future<bool> isLanguageAvailable(String? locale) async {
    if (locale == null || locale.isEmpty || !ttsSupported()) return false;
    try {
      final direct = await _tts.isLanguageAvailable(locale);
      if (direct == true) return true;
      // Some engines only report the bare language, or only a different region
      // of it (el-CY for el-GR). Any voice in the same language will do.
      final code = locale.toLowerCase().split(RegExp('[-_]')).first;
      final byLocale = await voicesByLocale(code);
      return byLocale.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  /// Every installed voice whose locale starts with [langCode], grouped by
  /// locale and ordered device-region first, then US → GB → AU, then the rest.
  Future<Map<String, List<Map>>> voicesByLocale(String langCode) async {
    List<dynamic> raw;
    try {
      raw = (await _tts.getVoices) as List? ?? const [];
    } catch (_) {
      raw = const [];
    }
    final matches = <Map>[
      for (final v in raw)
        if (v is Map && (v['locale'] as String? ?? '').toLowerCase().startsWith(langCode)) v,
    ]..sort((a, b) => '${a['locale']}'.compareTo('${b['locale']}'));

    final byLocale = <String, List<Map>>{};
    for (final v in matches) {
      byLocale.putIfAbsent((v['locale'] as String? ?? '').toString(), () => []).add(v);
    }

    final ordered = byLocale.keys.toList()
      ..sort((a, b) {
        final r = _regionRank(a, langCode).compareTo(_regionRank(b, langCode));
        return r != 0 ? r : a.compareTo(b);
      });
    return {for (final loc in ordered) loc: byLocale[loc]!};
  }

  static List<String> _regionPrefs(String langCode) {
    final prefs = <String>[];
    final dev = WidgetsBinding.instance.platformDispatcher.locale;
    if (dev.languageCode.toLowerCase() == langCode && (dev.countryCode ?? '').isNotEmpty) {
      prefs.add(dev.countryCode!.toLowerCase());
    }
    for (final r in const ['us', 'gb', 'au']) {
      if (!prefs.contains(r)) prefs.add(r);
    }
    return prefs;
  }

  static int _regionRank(String locale, String langCode) {
    final prefs = _regionPrefs(langCode);
    final rp = locale.toLowerCase().split(RegExp('[-_]'));
    final i = prefs.indexOf(rp.length > 1 ? rp[1] : '');
    return i >= 0 ? i : prefs.length;
  }

  /// Tries to select a voice matching [gender] for [locale].
  /// Returns true if a matching voice was found and set, false otherwise.
  Future<bool> applyGenderedVoice(String? locale, String gender) async {
    try {
      final raw = await _tts.getVoices;
      if (raw is! List || raw.isEmpty) return false;

      final langPrefix = locale?.substring(0, 2).toLowerCase();

      // Region preference: the device's own region first (if it speaks the
      // source language — e.g. an en-GB phone), otherwise US → UK(GB) → AU.
      final regionPrefs = <String>[];
      final dev = WidgetsBinding.instance.platformDispatcher.locale;
      if (langPrefix != null && dev.languageCode.toLowerCase() == langPrefix) {
        final c = (dev.countryCode ?? '').toLowerCase();
        if (c.isNotEmpty) regionPrefs.add(c);
      }
      for (final r in const ['us', 'gb', 'au']) {
        if (!regionPrefs.contains(r)) regionPrefs.add(r);
      }

      // Score each voice: higher = better match.
      Map? best;
      int bestScore = -1;

      for (final v in raw) {
        final m = v as Map;
        final vLocale = (m['locale'] as String? ?? '').toLowerCase();
        final vGender = (m['gender'] as String? ?? '').toLowerCase();
        final vName = (m['name'] as String? ?? '').toLowerCase();

        // Must match the target language.
        if (langPrefix != null && !vLocale.startsWith(langPrefix)) continue;

        int score = 1; // any matching-language voice is a valid candidate

        // Region preference dominates (×100) so accent wins over the gender
        // heuristic, which only breaks ties within the same region.
        final rp = vLocale.split(RegExp('[-_]'));
        final vRegion = rp.length > 1 ? rp[1] : '';
        final ri = regionPrefs.indexOf(vRegion);
        if (ri >= 0) score += (regionPrefs.length - ri) * 100;

        // Explicit gender field (most reliable).
        if (vGender == gender) score += 10;

        // Android Google TTS: names like "el-gr-x-elm-local" (m=male, a=female)
        // or "en-us-x-sfg#male_1-local" / "#female".
        if (gender == 'male') {
          if (vName.contains('#male') || vName.contains('male_')) score += 8;
          if (RegExp(r'-x-\w*m\w*-').hasMatch(vName)) score += 5;
          if (vName.contains('male')) score += 4;
          // iOS: known male voice names (heuristic — male voices are usually men's names).
          if (vName.contains('nikos') ||
              vName.contains('jorge') ||
              vName.contains('thomas') ||
              vName.contains('daniel') ||
              vName.contains('alex') ||
              vName.contains('fred'))
            score += 6;
          // Penalise obvious female names.
          if (vName.contains('female') ||
              vName.contains('#f') ||
              vName.contains('melina') ||
              vName.contains('anna') ||
              vName.contains('samantha') ||
              vName.contains('victoria'))
            score -= 20;
        } else {
          if (vName.contains('#female') || vName.contains('female_')) score += 8;
          if (RegExp(r'-x-\w*a\w*-').hasMatch(vName)) score += 5;
          if (vName.contains('female')) score += 4;
          // iOS known female voice names.
          if (vName.contains('melina') ||
              vName.contains('anna') ||
              vName.contains('samantha') ||
              vName.contains('victoria') ||
              vName.contains('karen') ||
              vName.contains('moira'))
            score += 6;
          // Penalise obvious male names.
          if (vName.contains('#male') ||
              vName.contains('male_') ||
              vName.contains('nikos') ||
              vName.contains('daniel') ||
              vName.contains('thomas'))
            score -= 20;
        }

        if (score > bestScore) {
          bestScore = score;
          best = m;
        }
      }

      // Only apply if we found something with a positive gender-match score.
      if (best != null && bestScore > 0) {
        await _tts.setVoice({'name': best['name'] as String, 'locale': (best['locale'] as String?) ?? ''});
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// A synthesized clip is only usable if it holds real audio. Failed/timed-out
  /// synthesis leaves a 0-byte or header-only (~44-byte) WAV; a genuine clip is
  /// always far larger (the 500ms silence pad alone is >20 KB), so a small file
  /// is treated as a failure to be retried rather than replayed as silence.
  static const int kMinUsableClipBytes = 1024;

  Future<bool> isUsableClip(File file) async {
    try {
      return await file.length() >= kMinUsableClipBytes;
    } catch (_) {
      return false;
    }
  }

  /// Prepends [padMs] of silence to a synthesized WAV (the audio path drops the
  /// first frames at a clip boundary / cold start). Keeps the engine's native
  /// sample rate — `parseWavPcm16` already collapses to one (mono) channel, and
  /// downsampling here used naive decimation (no anti-alias filter), which made
  /// the voice sound coarse. Best-effort: untouched if unparseable.
  Future<void> _normalizeWav(File f, {int padMs = 500}) async {
    try {
      final parsed = parseWavPcm16(await f.readAsBytes());
      if (parsed == null) return;
      final sil = silencePcm16(parsed.rate, padMs);
      final combined = Int16List(sil.length + parsed.samples.length)
        ..setAll(0, sil)
        ..setAll(sil.length, parsed.samples);
      await f.writeAsBytes(pcm16MonoToWav(combined, parsed.rate), flush: true);
    } catch (_) {}
  }

  /// Same 10k cap + LRU eviction the Google/Gemini caches use.
  Future<void> _evictIfFull(Directory dir, {int cap = 10000, int batch = 200}) async {
    try {
      final files = (await dir.list(followLinks: false).toList()).whereType<File>().toList();
      if (files.length < cap) return;
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      var deleted = 0;
      for (final fi in files) {
        if (deleted >= batch) break;
        try {
          await fi.delete();
          deleted++;
        } catch (_) {}
      }
    } catch (_) {}
  }
}
