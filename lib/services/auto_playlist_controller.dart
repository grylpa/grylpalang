import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';

import 'google_translate_tts.dart';

/// Drives Sentence Bank auto mode through a native media session (just_audio +
/// just_audio_background). The whole subject is pre-built into one playlist of
/// audio clips + silence gaps; ExoPlayer advances clip-to-clip natively, so
/// playback keeps going when the screen is locked (the main isolate is
/// suspended on lock, which is why the old Dart-timer loop stalled).
///
/// Milestone A: Greek translation clips only (cached Google-TTS MP3s) + silence
/// gaps + repeats. The gendered English source is added in a later step.
class AutoPlaylistController {
  AutoPlaylistController(this._greekTts);

  final GoogleTranslateTts _greekTts;
  final AudioPlayer _player = AudioPlayer();

  // Playlist clip index → ordinal (position of the sentence in the play order
  // the caller supplied). Lets the UI highlight the right sentence and lets us
  // persist the resume position.
  List<int> _clipToOrdinal = [];
  int _ordinalCount = 0;

  final _ordinalCtrl = StreamController<int>.broadcast();
  StreamSubscription<int?>? _idxSub;

  /// Emits the ordinal of the sentence currently playing.
  Stream<int> get currentOrdinalStream => _ordinalCtrl.stream;

  /// Emits true/false as playback starts/pauses.
  Stream<bool> get playingStream => _player.playingStream;

  int? get currentOrdinal {
    final i = _player.currentIndex;
    if (i == null || i < 0 || i >= _clipToOrdinal.length) return null;
    return _clipToOrdinal[i];
  }

  /// Pre-builds the playlist and starts playing from [startOrdinal].
  ///
  /// Each ordinal contributes: optional source clip + source-pause, then the
  /// translation clip (repeated [repeatCount] times with [repeatDelaySec] gaps),
  /// then [postDelaySec]. [sourcePaths] (aligned with [translations]) holds the
  /// pre-rendered source-clip file for each item, or null to skip the source.
  Future<void> start({
    required List<String> translations,
    List<String?>? sourcePaths,
    required List<String> translationPaths,
    required int repeatCount,
    required int sourcePauseSec,
    required int repeatDelaySec,
    required int postDelaySec,
    int startOrdinal = 0,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final sources = <AudioSource>[];
    final clipToOrdinal = <int>[];

    Future<void> addSilence(int sec, int ord) async {
      if (sec <= 0) return;
      sources.add(_fileSource(await _silenceFile(dir, sec), 'sil-$ord-${sources.length}', 'gap'));
      clipToOrdinal.add(ord);
    }

    for (var ord = 0; ord < translations.length; ord++) {
      final text = translations[ord];
      final src = (sourcePaths != null && ord < sourcePaths.length) ? sourcePaths[ord] : null;
      if (src != null) {
        sources.add(_fileSource(src, 'src-$ord', text));
        clipToOrdinal.add(ord);
        await addSilence(sourcePauseSec, ord);
      }
      final path = translationPaths[ord];
      final reps = repeatCount < 1 ? 1 : repeatCount;
      for (var r = 0; r < reps; r++) {
        if (r > 0) await addSilence(repeatDelaySec, ord);
        sources.add(_fileSource(path, 't-$ord-$r', text));
        clipToOrdinal.add(ord);
      }
      await addSilence(postDelaySec, ord);
    }

    if (sources.isEmpty) return;

    _clipToOrdinal = clipToOrdinal;
    _ordinalCount = translations.length;
    final startClip = clipToOrdinal.indexOf(startOrdinal.clamp(0, _ordinalCount - 1));

    await _player.setAudioSources(
      sources,
      initialIndex: startClip < 0 ? 0 : startClip,
      initialPosition: Duration.zero,
    );
    await _player.setLoopMode(LoopMode.all); // keep looping the subject when locked
    _idxSub?.cancel();
    _idxSub = _player.currentIndexStream.listen((i) {
      if (i != null && i >= 0 && i < _clipToOrdinal.length) {
        _ordinalCtrl.add(_clipToOrdinal[i]);
      }
    });
    await _player.play();
  }

  Future<void> next() async {
    final ord = currentOrdinal;
    if (ord != null && ord + 1 < _ordinalCount) await _seekToOrdinal(ord + 1);
  }

  Future<void> previous() async {
    final ord = currentOrdinal;
    if (ord != null && ord - 1 >= 0) await _seekToOrdinal(ord - 1);
  }

  Future<void> _seekToOrdinal(int ord) async {
    final clip = _clipToOrdinal.indexOf(ord);
    if (clip >= 0) await _player.seek(Duration.zero, index: clip);
  }

  Future<void> stop() => _player.stop();

  Future<void> dispose() async {
    await _idxSub?.cancel();
    await _ordinalCtrl.close();
    await _player.dispose();
  }

  AudioSource _fileSource(String path, String id, String title) => AudioSource.file(
        path,
        tag: MediaItem(id: id, title: title, album: 'Katalaveno'),
      );

  // Silent WAV of [sec] seconds, cached by duration.
  Future<String> _silenceFile(Directory dir, int sec) async {
    final f = File('${dir.path}/silence_${sec}s.wav');
    if (!await f.exists()) await f.writeAsBytes(_silenceWav(sec), flush: true);
    return f.path;
  }

  static Uint8List _silenceWav(int sec, {int rate = 8000}) {
    final samples = rate * sec;
    final dataLen = samples * 2;
    final b = BytesBuilder();
    void str(String s) => b.add(s.codeUnits);
    void u32(int v) => b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
    void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
    str('RIFF'); u32(36 + dataLen); str('WAVE');
    str('fmt '); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16);
    str('data'); u32(dataLen);
    b.add(Uint8List(dataLen)); // zeros = silence
    return b.toBytes();
  }
}
