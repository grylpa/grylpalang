import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:just_audio/just_audio.dart';
import 'package:audio_service/audio_service.dart';

import 'katalaveno_audio_handler.dart';
import 'package:path_provider/path_provider.dart';

/// One element of a hand-built playlist: either an audio file or a gap.
///
/// Lets a caller with its own per-item structure (Listen mode's
/// slow → pause → faster → pause → translation → full → pause cycle) describe
/// the clip order directly, instead of bending it into the source/target shape
/// [AutoPlaylistController.start] builds.
class ClipSpec {
  const ClipSpec.file(this.path) : seconds = 0;
  const ClipSpec.silence(this.seconds) : path = '';

  final String path;
  final int seconds;

  bool get isSilence => path.isEmpty;
}

/// Drives auto-play mode (Sentence Bank or Books) through the shared
/// [KatalavenoAudioHandler]'s [AudioPlayer]. The handler also routes system
/// media-control events (Bluetooth headphones, lockscreen, Android Auto) to
/// the active session's app-level handlers, so SkipToNext advances by chunk
/// rather than by clip.
class AutoPlaylistController {
  AudioPlayer get _player => katalavenoAudio.player;

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
    // Pause after the 2nd+ source clip in [alternate] mode. Null = same as
    // [sourcePauseSec]; ignored entirely when not alternating, since there is
    // only ever one source clip per sentence then.
    int? nextSourcePauseSec,
    required int repeatDelaySec,
    required int postDelaySec,
    int startOrdinal = 0,
    bool autoPlay = true,
    // When true, each chunk plays as (source → sourcePause → target) repeated
    // `repeatCount` times, instead of (source × srcReps) then (target × reps).
    bool alternate = false,
    // Per-ordinal flag: play the target-language block *before* the source one,
    // so the learner hears the sentence they're learning first and the known
    // language confirms it. Absent/short list = normal (source-first) order.
    List<bool>? targetFirst,
  }) async {
    final ordinals = <List<ClipSpec>>[];
    for (var ord = 0; ord < translations.length; ord++) {
      final path = translationPaths[ord];
      // An empty translation path means the caller couldn't produce audio for
      // this ordinal — emit no clips so the playlist jumps to the next sentence.
      if (path.isEmpty) {
        ordinals.add(const []);
        continue;
      }
      ordinals.add(
        _sentenceClips(
          sourcePath: (sourcePaths != null && ord < sourcePaths.length) ? sourcePaths[ord] : null,
          translationPath: path,
          repeatCount: repeatCount,
          sourceRepeatCount: sourceRepeatCount,
          sourcePauseSec: sourcePauseSec,
          nextSourcePauseSec: nextSourcePauseSec,
          repeatDelaySec: repeatDelaySec,
          postDelaySec: postDelaySec,
          alternate: alternate,
          flip: targetFirst != null && ord < targetFirst.length && targetFirst[ord],
        ),
      );
    }
    await startClips(ordinals: ordinals, titles: translations, startOrdinal: startOrdinal, autoPlay: autoPlay);
  }

  /// The clip pattern for one sentence. The single definition of Sentence
  /// Bank / Books playback shape — [start] and [appendChunk] both go through
  /// it, so the up-front and streaming paths can't drift apart.
  List<ClipSpec> _sentenceClips({
    required String? sourcePath,
    required String translationPath,
    required int repeatCount,
    required int sourceRepeatCount,
    required int sourcePauseSec,
    int? nextSourcePauseSec,
    required int repeatDelaySec,
    required int postDelaySec,
    required bool alternate,
    required bool flip,
  }) {
    final clips = <ClipSpec>[];
    final reps = repeatCount < 1 ? 1 : repeatCount;
    final src = sourcePath;

    void addSource() => clips.add(ClipSpec.file(src!));
    void addTarget() => clips.add(ClipSpec.file(translationPath));

    if (alternate) {
      // (source → sourcePause → target) repeated `reps` times, then postDelay.
      // Flipped, the pair becomes (target → sourcePause → source).
      for (var r = 0; r < reps; r++) {
        // The first pair keeps the "pause after source" the user set; the
        // repeats get their own (usually shorter) gap, since by then they've
        // already heard the sentence and need less thinking time.
        final gap = r == 0 ? sourcePauseSec : (nextSourcePauseSec ?? sourcePauseSec);
        if (src != null && !flip) {
          addSource();
          clips.add(ClipSpec.silence(gap));
        }
        addTarget();
        if (src != null && flip) {
          clips.add(ClipSpec.silence(gap));
          addSource();
        }
        if (r < reps - 1) clips.add(ClipSpec.silence(repeatDelaySec));
      }
    } else {
      void sourceBlock() {
        if (src == null) return;
        final srcReps = sourceRepeatCount < 1 ? 1 : sourceRepeatCount;
        for (var r = 0; r < srcReps; r++) {
          if (r > 0) clips.add(ClipSpec.silence(repeatDelaySec));
          addSource();
        }
      }

      void targetBlock() {
        for (var r = 0; r < reps; r++) {
          if (r > 0) clips.add(ClipSpec.silence(repeatDelaySec));
          addTarget();
        }
      }

      if (flip) {
        // Target first: hear the language being learned, then the known one.
        targetBlock();
        if (src != null) clips.add(ClipSpec.silence(sourcePauseSec));
        sourceBlock();
      } else {
        sourceBlock();
        if (src != null) clips.add(ClipSpec.silence(sourcePauseSec));
        targetBlock();
      }
    }
    clips.add(ClipSpec.silence(postDelaySec));
    return clips;
  }

  /// Plays a playlist the caller assembled itself: [ordinals] holds one clip
  /// list per item, in play order. Silence specs are rendered to cached WAVs
  /// here, so the caller never deals with gap files.
  ///
  /// Same guarantees as [start] — a single native playlist on the shared
  /// player, so it keeps advancing with the screen locked — but with no opinion
  /// about what the clips *are*.
  Future<void> startClips({
    required List<List<ClipSpec>> ordinals,
    required List<String> titles,
    int startOrdinal = 0,
    bool autoPlay = true,
    bool loop = true,
  }) async {
    final dir = await getApplicationSupportDirectory();
    final sources = <AudioSource>[];
    final clipToOrdinal = <int>[];

    for (var ord = 0; ord < ordinals.length; ord++) {
      final title = ord < titles.length ? titles[ord] : 'Katalaveno';
      for (final spec in ordinals[ord]) {
        if (spec.isSilence) {
          if (spec.seconds <= 0) continue;
          sources.add(_fileSource(await _silenceFile(dir, spec.seconds), 'sil-$ord-${sources.length}', 'gap'));
        } else {
          sources.add(_fileSource(spec.path, 'c-$ord-${sources.length}', title));
        }
        clipToOrdinal.add(ord);
      }
    }
    if (sources.isEmpty) return;

    _clipToOrdinal = clipToOrdinal;
    _ordinalCount = ordinals.length;
    final startClip = clipToOrdinal.indexOf(startOrdinal.clamp(0, _ordinalCount - 1));

    // See start(): an explicit stop first makes the first play() reliably
    // produce sound after a single-clip playback or a background prep.
    await _player.stop();
    await _player.setAudioSources(sources, initialIndex: startClip < 0 ? 0 : startClip, initialPosition: Duration.zero);
    await _player.setLoopMode(loop ? LoopMode.all : LoopMode.off);
    _idxSub?.cancel();
    _idxSub = _player.currentIndexStream.listen((i) {
      if (i != null && i >= 0 && i < _clipToOrdinal.length) {
        _ordinalCtrl.add(_clipToOrdinal[i]);
      }
    });
    // Don't await — with LoopMode.all, play()'s future never completes.
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
  int? _dynNextSourcePauseSec;
  int _dynSourceRepeatCount = 1;
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
    int? nextSourcePauseSec,
    int sourceRepeatCount = 1,
    required int repeatDelaySec,
    required int postDelaySec,
    bool alternate = false,
    bool loop = false,
  }) async {
    _dynRepeatCount = repeatCount < 1 ? 1 : repeatCount;
    _dynSourcePauseSec = sourcePauseSec;
    _dynNextSourcePauseSec = nextSourcePauseSec;
    _dynSourceRepeatCount = sourceRepeatCount;
    _dynRepeatDelaySec = repeatDelaySec;
    _dynPostDelaySec = postDelaySec;
    _dynAlternate = alternate;
    await _resetForDynamic(ordinalCount, loop);
  }

  /// [beginDynamic] for callers that assemble their own clip lists (Listen
  /// mode) and append them with [appendClipGroup].
  Future<void> beginDynamicClips({required int ordinalCount, bool loop = true}) => _resetForDynamic(ordinalCount, loop);

  Future<void> _resetForDynamic(int ordinalCount, bool loop) async {
    _clipToOrdinal = [];
    _ordinalCount = ordinalCount;
    _dynStarted = false;

    await _player.stop();
    await _player.setLoopMode(loop ? LoopMode.all : LoopMode.off);
    _idxSub?.cancel();
    _idxSub = _player.currentIndexStream.listen((i) {
      if (i != null && i >= 0 && i < _clipToOrdinal.length) {
        _ordinalCtrl.add(_clipToOrdinal[i]);
      }
    });
  }

  /// Appends one caller-assembled group of clips for ordinal [ord]. Safe while
  /// playback is running, and safe to call in any ordinal order — [ord] is
  /// recorded per clip, so next/previous keep working even when the queue was
  /// built starting from the middle (Listen streams from its resume position).
  Future<void> appendClipGroup({required int ord, required String title, required List<ClipSpec> clips}) async {
    final dir = await getApplicationSupportDirectory();
    final newSources = <AudioSource>[];
    final newOrdinals = <int>[];
    for (final spec in clips) {
      final seq = _clipToOrdinal.length + newSources.length;
      if (spec.isSilence) {
        if (spec.seconds <= 0) continue;
        newSources.add(_fileSource(await _silenceFile(dir, spec.seconds), 'sil-$ord-$seq', 'gap'));
      } else {
        newSources.add(_fileSource(spec.path, 'c-$ord-$seq', title));
      }
      newOrdinals.add(ord);
    }
    if (newSources.isEmpty) return;

    if (!_dynStarted) {
      await _player.setAudioSources(newSources);
      _dynStarted = true;
    } else {
      await _player.addAudioSources(newSources);
    }
    _clipToOrdinal.addAll(newOrdinals);
  }

  /// Appends the clips for one chunk to the dynamic playlist. Safe to call
  /// while playback is in progress — the new sources extend the queue.
  ///
  /// An empty [translationPath] means the caller couldn't produce audio for
  /// this ordinal; nothing is appended, so playback skips straight past it.
  Future<void> appendChunk({
    required int ord,
    required String text,
    required String? sourcePath,
    required String translationPath,
    bool flip = false,
  }) async {
    if (translationPath.isEmpty) return;
    await appendClipGroup(
      ord: ord,
      title: text,
      clips: _sentenceClips(
        sourcePath: sourcePath,
        translationPath: translationPath,
        repeatCount: _dynRepeatCount,
        sourceRepeatCount: _dynSourceRepeatCount,
        sourcePauseSec: _dynSourcePauseSec,
        nextSourcePauseSec: _dynNextSourcePauseSec,
        repeatDelaySec: _dynRepeatDelaySec,
        postDelaySec: _dynPostDelaySec,
        alternate: _dynAlternate,
        flip: flip,
      ),
    );
  }

  /// Starts playback of the dynamic playlist. Must be called after at least
  /// one [appendChunk]. Playback begins at the first clip in the playlist.
  Future<void> playDynamic() async {
    if (_clipToOrdinal.isEmpty) return;
    unawaited(_player.play());
  }

  Future<void> next() async {
    final ord = currentOrdinal;
    if (ord == null) return;
    // Skip ordinals dropped from the playlist (empty translation path), so
    // pressing next from sentence 4 lands on sentence 6 if 5 had no audio.
    for (var n = ord + 1; n < _ordinalCount; n++) {
      final clip = _clipToOrdinal.indexOf(n);
      if (clip >= 0) {
        await _player.seek(Duration.zero, index: clip);
        return;
      }
    }
  }

  Future<void> previous() async {
    final ord = currentOrdinal;
    if (ord == null) return;
    for (var p = ord - 1; p >= 0; p--) {
      final clip = _clipToOrdinal.indexOf(p);
      if (clip >= 0) {
        await _player.seek(Duration.zero, index: clip);
        return;
      }
    }
  }

  /// Seeks the player to the first clip of [ord].
  ///
  /// Returns false — leaving the player exactly where it was — if that ordinal
  /// has no clips in the current playlist, e.g. it hasn't been appended yet in
  /// dynamic mode. Callers that must land on it can rebuild from there instead.
  Future<bool> seekToOrdinal(int ord) => _seekToOrdinal(ord);

  Future<bool> _seekToOrdinal(int ord) async {
    final clip = _clipToOrdinal.indexOf(ord);
    if (clip < 0) return false;
    await _player.seek(Duration.zero, index: clip);
    return true;
  }

  /// Gives up this controller's view of the shared player, without touching
  /// the player itself — used when another screen has claimed it. Drops the
  /// index subscription and the clip map so this controller can't emit ordinals
  /// for a queue that is no longer its own.
  Future<void> detach() async {
    await _idxSub?.cancel();
    _idxSub = null;
    _clipToOrdinal = [];
    _ordinalCount = 0;
    _dynStarted = false;
  }

  Future<void> stop() => _player.stop();
  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();
  bool get isPlaying => _player.playing;

  Future<void> dispose() async {
    await _idxSub?.cancel();
    await _ordinalCtrl.close();
    // Don't dispose `_player` — it's the shared handler's player and other
    // controllers (e.g. the other tab) may still need it.
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
    str('RIFF');
    u32(36 + dataLen);
    str('WAVE');
    str('fmt ');
    u32(16);
    u16(1);
    u16(1);
    u32(rate);
    u32(rate * 2);
    u16(2);
    u16(16);
    str('data');
    u32(dataLen);
    b.add(Uint8List(dataLen)); // zeros = silence
    return b.toBytes();
  }
}
