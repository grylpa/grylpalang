import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';

/// Drives Sentence Bank auto mode through a native media session (just_audio +
/// just_audio_background). The whole subject is pre-built into one playlist of
/// audio clips + silence gaps; ExoPlayer advances clip-to-clip natively, so
/// playback keeps going when the screen is locked (the main isolate is
/// suspended on lock, which is why the old Dart-timer loop stalled).
///
/// Milestone A: Greek translation clips only (cached Google-TTS MP3s) + silence
/// gaps + repeats. The gendered English source is added in a later step.
class AutoPlaylistController {
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

  /// Player state (used by the caller to detect manual single-clip completion).
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  /// Plays a single clip (manual speaker button). Reuses the one player so we
  /// never have two just_audio instances (just_audio_background supports one).
  /// This clears the loaded playlist, so the next auto-start rebuilds.
  Future<void> playSingle(String path) async {
    _clipToOrdinal = [];
    await _player.stop();
    await _player.setLoopMode(LoopMode.off);
    await _player.setAudioSources([_fileSource(path, 'single', 'Katalaveno')]);
    await _player.play();
  }

  int? get currentOrdinal {
    final i = _player.currentIndex;
    if (i == null || i < 0 || i >= _clipToOrdinal.length) return null;
    return _clipToOrdinal[i];
  }

  /// True once a playlist has been built. just_audio retains the audio source
  /// across stop(), so we can resume without rebuilding (see [resumeAt]).
  bool get isLoaded => _clipToOrdinal.isNotEmpty;

  /// Resumes the already-loaded playlist from [ordinal] without rebuilding —
  /// instant, no file work. Caller guarantees the playlist is still valid.
  Future<void> resumeAt(int ordinal) async {
    if (!isLoaded) return;
    await _seekToOrdinal(ordinal);
    unawaited(_player.play()); // see note in start(): play() completes only on stop
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
    int sourceRepeatCount = 1,
    required int sourcePauseSec,
    required int repeatDelaySec,
    required int postDelaySec,
    int startOrdinal = 0,
    bool autoPlay = true,
    // When true, each chunk plays as (source → sourcePause → target) repeated
    // `repeatCount` times, instead of (source × srcReps) then (target × reps).
    bool alternate = false,
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
      final path = translationPaths[ord];
      final reps = repeatCount < 1 ? 1 : repeatCount;

      if (alternate) {
        // (source → sourcePause → target) repeated `reps` times, then postDelay.
        for (var r = 0; r < reps; r++) {
          if (src != null) {
            sources.add(_fileSource(src, 'src-$ord-$r', text));
            clipToOrdinal.add(ord);
            await addSilence(sourcePauseSec, ord);
          }
          sources.add(_fileSource(path, 't-$ord-$r', text));
          clipToOrdinal.add(ord);
          if (r < reps - 1) await addSilence(repeatDelaySec, ord);
        }
      } else {
        if (src != null) {
          final srcReps = sourceRepeatCount < 1 ? 1 : sourceRepeatCount;
          for (var r = 0; r < srcReps; r++) {
            if (r > 0) await addSilence(repeatDelaySec, ord);
            sources.add(_fileSource(src, 'src-$ord-$r', text));
            clipToOrdinal.add(ord);
          }
          await addSilence(sourcePauseSec, ord);
        }
        for (var r = 0; r < reps; r++) {
          if (r > 0) await addSilence(repeatDelaySec, ord);
          sources.add(_fileSource(path, 't-$ord-$r', text));
          clipToOrdinal.add(ord);
        }
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
    // Don't await: with LoopMode.all, play()'s future only completes when
    // playback stops, which never happens for a looping playlist. Awaiting it
    // would hang start() and leave the caller's "Preparing…" indicator up.
    if (autoPlay) unawaited(_player.play());
  }

  // ── Dynamic mode ──────────────────────────────────────────────────────────
  //
  // Builds the playlist incrementally as chunks are prepared (used by Books'
  // audio mode so playback starts after one chunk and the rest stream in).
  // Backed by a [ConcatenatingAudioSource] which just_audio lets us mutate
  // while it's playing.

  // Tracks whether we've sent the first batch of sources to the player yet —
  // the first append uses setAudioSources, subsequent ones addAudioSources.
  bool _dynStarted = false;
  // Per-chunk playback parameters, captured by [beginDynamic] and reused for
  // every [appendChunk] call so callers don't have to repeat them.
  int _dynRepeatCount = 1;
  int _dynSourcePauseSec = 0;
  int _dynRepeatDelaySec = 0;
  int _dynPostDelaySec = 0;
  bool _dynAlternate = false;

  /// Prepares the player for dynamic-playlist mode. Call [appendChunk] as
  /// chunks become ready; the first call actually sends them to the player,
  /// subsequent calls extend the in-flight queue without disrupting playback.
  Future<void> beginDynamic({
    required int ordinalCount,
    required int repeatCount,
    required int sourcePauseSec,
    required int repeatDelaySec,
    required int postDelaySec,
    bool alternate = false,
    bool loop = false,
  }) async {
    _clipToOrdinal = [];
    _ordinalCount = ordinalCount;
    _dynStarted = false;
    _dynRepeatCount = repeatCount < 1 ? 1 : repeatCount;
    _dynSourcePauseSec = sourcePauseSec;
    _dynRepeatDelaySec = repeatDelaySec;
    _dynPostDelaySec = postDelaySec;
    _dynAlternate = alternate;

    await _player.stop();
    await _player.setLoopMode(loop ? LoopMode.all : LoopMode.off);
    _idxSub?.cancel();
    _idxSub = _player.currentIndexStream.listen((i) {
      if (i != null && i >= 0 && i < _clipToOrdinal.length) {
        _ordinalCtrl.add(_clipToOrdinal[i]);
      }
    });
  }

  /// Appends the clips for one chunk to the dynamic playlist. Safe to call
  /// while playback is in progress — the new sources extend the queue.
  Future<void> appendChunk({
    required int ord,
    required String text,
    required String? sourcePath,
    required String translationPath,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final newSources = <AudioSource>[];
    final newOrdinals = <int>[];

    Future<void> addSilence(int sec) async {
      if (sec <= 0) return;
      newSources.add(_fileSource(
          await _silenceFile(dir, sec), 'sil-$ord-${_clipToOrdinal.length + newSources.length}', 'gap'));
      newOrdinals.add(ord);
    }

    if (_dynAlternate) {
      for (var r = 0; r < _dynRepeatCount; r++) {
        if (sourcePath != null) {
          newSources.add(_fileSource(sourcePath, 'src-$ord-$r', text));
          newOrdinals.add(ord);
          await addSilence(_dynSourcePauseSec);
        }
        newSources.add(_fileSource(translationPath, 't-$ord-$r', text));
        newOrdinals.add(ord);
        if (r < _dynRepeatCount - 1) await addSilence(_dynRepeatDelaySec);
      }
    } else {
      if (sourcePath != null) {
        newSources.add(_fileSource(sourcePath, 'src-$ord', text));
        newOrdinals.add(ord);
        await addSilence(_dynSourcePauseSec);
      }
      for (var r = 0; r < _dynRepeatCount; r++) {
        if (r > 0) await addSilence(_dynRepeatDelaySec);
        newSources.add(_fileSource(translationPath, 't-$ord-$r', text));
        newOrdinals.add(ord);
      }
    }
    await addSilence(_dynPostDelaySec);

    if (!_dynStarted) {
      await _player.setAudioSources(newSources);
      _dynStarted = true;
    } else {
      await _player.addAudioSources(newSources);
    }
    _clipToOrdinal.addAll(newOrdinals);
  }

  /// Starts playback of the dynamic playlist. Must be called after at least
  /// one [appendChunk]. Playback begins at the first clip in the playlist.
  Future<void> playDynamic() async {
    if (_clipToOrdinal.isEmpty) return;
    unawaited(_player.play());
  }

  Future<void> next() async {
    final ord = currentOrdinal;
    if (ord != null && ord + 1 < _ordinalCount) await _seekToOrdinal(ord + 1);
  }

  Future<void> previous() async {
    final ord = currentOrdinal;
    if (ord != null && ord - 1 >= 0) await _seekToOrdinal(ord - 1);
  }

  /// Seeks the player to the first clip of [ord] (or no-ops if that ordinal
  /// has no clips in the current playlist — e.g. it hasn't been appended yet
  /// in dynamic mode).
  Future<void> seekToOrdinal(int ord) => _seekToOrdinal(ord);

  Future<void> _seekToOrdinal(int ord) async {
    final clip = _clipToOrdinal.indexOf(ord);
    if (clip >= 0) await _player.seek(Duration.zero, index: clip);
  }

  Future<void> stop() => _player.stop();
  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();
  bool get isPlaying => _player.playing;

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
