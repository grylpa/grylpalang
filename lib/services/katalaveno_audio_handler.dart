import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart' as ja;

/// Single shared [AudioHandler] owned by the app. Replaces just_audio_background
/// so we can route system media controls (lockscreen, Bluetooth headphones,
/// Android Auto, etc.) to the app's app-level semantics — e.g. SkipToNext
/// advances to the next *chunk*, not the next clip.
///
/// Each tab/screen that uses audio (Sentence Bank, Books) calls [bind] when it
/// becomes the active session and [unbind] when it ends. Until something binds,
/// the handler falls back to passthrough behaviour on the underlying player.
class KatalavenoAudioHandler extends BaseAudioHandler with SeekHandler {
  /// The single AudioPlayer used by every controller in the app.
  final ja.AudioPlayer player = ja.AudioPlayer();

  // Stack of bindings. The top one wins; when it unbinds, the next-most-recent
  // one is restored. This lets e.g. the Sentence Bank tab keep a persistent
  // "tap-Play-to-start-auto" fallback registered while the Book Reader pushes
  // a transient session on top during playback.
  final List<_Binding> _stack = [];

  KatalavenoAudioHandler() {
    // Mirror the player's state into the audio_service playbackState so the
    // system media notification reflects what we're doing.
    player.playbackEventStream.listen(_emitPlaybackState);
    player.processingStateStream.listen((_) => _emitPlaybackState(player.playbackEvent));
  }

  /// Pushes a binding onto the stack. If [owner] already has one, it's
  /// replaced in place. The newest binding handles incoming media events.
  void bind({
    required Object owner,
    Future<void> Function()? onPlay,
    Future<void> Function()? onPause,
    Future<void> Function()? onStop,
    Future<void> Function()? onSkipNext,
    Future<void> Function()? onSkipPrev,
  }) {
    _stack.removeWhere((b) => identical(b.owner, owner));
    _stack.add(_Binding(
      owner: owner,
      onPlay: onPlay,
      onPause: onPause,
      onStop: onStop,
      onSkipNext: onSkipNext,
      onSkipPrev: onSkipPrev,
    ));
  }

  /// Removes [owner]'s binding from the stack. The previous one becomes active
  /// (or nothing if the stack is empty).
  void unbind(Object owner) {
    _stack.removeWhere((b) => identical(b.owner, owner));
  }

  _Binding? get _top => _stack.isEmpty ? null : _stack.last;

  // ── AudioHandler overrides — system → app ────────────────────────────────

  // When no session is bound, media events are no-ops (instead of falling
  // through to the bare player, which would restart a stale playlist with no
  // app state to back it up — see "bluetooth plays but UI doesn't change").

  @override
  Future<void> play() async {
    if (_top?.onPlay != null) await _top!.onPlay!();
  }

  @override
  Future<void> pause() async {
    if (_top?.onPause != null) await _top!.onPause!();
  }

  @override
  Future<void> stop() async {
    if (_top?.onStop != null) {
      await _top!.onStop!();
    } else {
      // Safety net for system-stop with nothing bound (e.g. headphones disconnected).
      await player.stop();
    }
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_top?.onSkipNext != null) await _top!.onSkipNext!();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_top?.onSkipPrev != null) await _top!.onSkipPrev!();
  }

  // ── Playback state mirroring ─────────────────────────────────────────────

  void _emitPlaybackState(ja.PlaybackEvent event) {
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.seek},
      processingState: _mapProcessingState(event.processingState),
      playing: player.playing,
      updatePosition: event.updatePosition,
      bufferedPosition: event.bufferedPosition,
      speed: player.speed,
      queueIndex: event.currentIndex,
    ));
  }

  AudioProcessingState _mapProcessingState(ja.ProcessingState s) {
    switch (s) {
      case ja.ProcessingState.idle:
        return AudioProcessingState.idle;
      case ja.ProcessingState.loading:
        return AudioProcessingState.loading;
      case ja.ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ja.ProcessingState.ready:
        return AudioProcessingState.ready;
      case ja.ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }
}

class _Binding {
  final Object owner;
  final Future<void> Function()? onPlay;
  final Future<void> Function()? onPause;
  final Future<void> Function()? onStop;
  final Future<void> Function()? onSkipNext;
  final Future<void> Function()? onSkipPrev;
  _Binding({
    required this.owner,
    this.onPlay,
    this.onPause,
    this.onStop,
    this.onSkipNext,
    this.onSkipPrev,
  });
}

/// Global handler — set once in [main] after [AudioService.init], then read
/// from anywhere that needs the shared player or wants to bind to media events.
late final KatalavenoAudioHandler katalavenoAudio;
