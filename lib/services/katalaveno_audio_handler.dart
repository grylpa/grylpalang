import 'dart:async';

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
    player.playingStream.listen((playing) => playing ? _idleTimer?.cancel() : _armIdleStop());
  }

  // ── Idle teardown ─────────────────────────────────────────────────────────
  //
  // A paused session must keep the service in the foreground: Android 12+ has no
  // exemption for a media button, so once foreground is dropped a headset Play
  // from the background cannot legally bring it back and playback would run
  // silently. The cost is a wakelock and a visible battery line for as long as
  // the app stays paused — which, since nothing ever stopped it, was forever.
  //
  // So: pause keeps everything, and after [idleStopAfter] of it the session ends
  // for real — the notification goes too, so coming back means the app. That is
  // a fair trade for an idle wakelock that otherwise lasted until the user
  // noticed it in the battery screen.
  //
  // This is a plain Timer, not an alarm: Doze may fire it late, which only means
  // the service lives a little longer than asked.
  Duration idleStopAfter = const Duration(minutes: 10);
  Timer? _idleTimer;

  void _armIdleStop() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (idleStopAfter <= Duration.zero) return;
    // Nothing loaded means nothing to tear down (this fires at launch too).
    if (player.audioSource == null) return;
    _idleTimer = Timer(idleStopAfter, () {
      if (player.playing) return;
      unawaited(_endIdleSession());
    });
  }

  /// Ends the session the way another screen claiming the player would, so the
  /// owning screen resets its own state through the callback it already has —
  /// position saved, in-flight render abandoned, flags cleared — while the
  /// player and the foreground service are torn down here.
  ///
  /// The callback runs *before* the player is stopped, the reverse of a
  /// hand-over: there is no incoming audio to protect here, and a screen saving
  /// its position should see a live player when it does.
  ///
  /// The binding then goes too. A screen that kept it would still answer
  /// `isActiveSession` and take its resume fast-path on the next Play — seeking
  /// into a queue that no longer exists, which plays silence. Every screen binds
  /// again when it plays, so nothing is lost; the per-tab starters, which is
  /// what a cold Play goes through, are registered separately and stay.
  Future<void> _endIdleSession() async {
    _idleTimer = null;
    final owner = _top;
    owner?.onSessionLost?.call();
    if (owner != null) unbind(owner.owner);
    await player.stop();
    await super.stop();
  }

  /// Pushes a binding onto the stack. If [owner] already has one, it's
  /// replaced in place. The newest binding handles incoming media events.
  ///
  /// Binding is also how a screen claims the shared player, so the owner it
  /// displaces is told via [_Binding.onSessionLost]. There is exactly one
  /// player: the incoming session is about to replace the queue, and without
  /// that signal the displaced screen keeps a live index subscription on it —
  /// mapping someone else's clip indices through its own map — and goes on
  /// showing itself as playing.
  void bind({
    required Object owner,
    Future<void> Function()? onPlay,
    bool Function()? hasSession,
    Future<void> Function()? onPause,
    Future<void> Function()? onStop,
    Future<void> Function()? onSkipNext,
    Future<void> Function()? onSkipPrev,
    void Function()? onSessionLost,
  }) {
    final displaced = _top;
    _stack.removeWhere((b) => identical(b.owner, owner));
    _stack.add(
      _Binding(
        owner: owner,
        onPlay: onPlay,
        hasSession: hasSession,
        onPause: onPause,
        onStop: onStop,
        onSkipNext: onSkipNext,
        onSkipPrev: onSkipPrev,
        onSessionLost: onSessionLost,
      ),
    );
    // Re-binding your own session (every play does) displaces nobody.
    if (displaced != null && !identical(displaced.owner, owner)) displaced.onSessionLost?.call();
  }

  /// Removes [owner]'s binding from the stack. The previous one becomes active
  /// (or nothing if the stack is empty).
  void unbind(Object owner) {
    _stack.removeWhere((b) => identical(b.owner, owner));
  }

  _Binding? get _top => _stack.isEmpty ? null : _stack.last;

  // ── Which tab the user is looking at ─────────────────────────────────────
  //
  // A system Play (headset button, lockscreen) with nothing playing means
  // "start the tab I am on" — not "start whatever bound last". The Sentence
  // Bank binds at launch so that it can answer a cold Play at all, which left
  // it answering *every* cold Play even while the user sat in Listen.
  //
  // Starters are registered per tab id at init and, unlike [bind], claim
  // nothing: a tab that has pre-built its playlist keeps its instant resume.
  String? _visibleTab;
  final Map<String, ({Object owner, Future<void> Function() onPlay})> _starters = {};

  void setVisibleTab(String tabId) => _visibleTab = tabId;

  void registerStarter(String tabId, Object owner, Future<void> Function() onPlay) =>
      _starters[tabId] = (owner: owner, onPlay: onPlay);

  /// Only drops the entry if it is still [owner]'s — a rebuilt screen may have
  /// registered over it already.
  void unregisterStarter(String tabId, Object owner) {
    if (identical(_starters[tabId]?.owner, owner)) _starters.remove(tabId);
  }

  /// True when [owner] holds the top binding — i.e. it is the session the
  /// shared player is currently serving. Since every screen re-binds when it
  /// starts playing, this is how a tab tells "the player is playing *my*
  /// playlist" from "another tab is using it".
  bool isActiveSession(Object owner) => identical(_top?.owner, owner);

  // ── AudioHandler overrides — system → app ────────────────────────────────

  // When no session is bound, media events are no-ops (instead of falling
  // through to the bare player, which would restart a stale playlist with no
  // app state to back it up — see "bluetooth plays but UI doesn't change").

  @override
  Future<void> play() async {
    // Nothing playing, and whoever holds the buttons has no paused session to
    // resume? Then this Play belongs to the tab on screen. A paused session
    // keeps the button — pressing play after pausing must resume, not switch.
    if (!player.playing && !(_top?.hasSession?.call() ?? false)) {
      final visible = _visibleTab;
      final starter = visible == null ? null : _starters[visible];
      if (starter != null && !identical(starter.owner, _top?.owner)) {
        // That screen's own bind() promotes it and notifies the owner it
        // displaces, so the queue hand-over stays on the one existing path.
        return starter.onPlay();
      }
    }
    if (_top?.onPlay != null) await _top!.onPlay!();
  }

  @override
  Future<void> pause() async {
    if (_top?.onPause != null) await _top!.onPause!();
  }

  @override
  Future<void> stop() async {
    _idleTimer?.cancel();
    _idleTimer = null;
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
    playbackState.add(
      playbackState.value.copyWith(
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
      ),
    );
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

  /// Whether this screen has a built playlist it could resume. Read on a system
  /// Play to tell "resume what was paused" from "start the tab on screen".
  final bool Function()? hasSession;
  final Future<void> Function()? onPause;
  final Future<void> Function()? onStop;
  final Future<void> Function()? onSkipNext;
  final Future<void> Function()? onSkipPrev;

  /// Called when another screen claims the shared player. Must reset local
  /// state only — never touch the player, which now belongs to someone else.
  final void Function()? onSessionLost;
  _Binding({
    required this.owner,
    this.onPlay,
    this.hasSession,
    this.onPause,
    this.onStop,
    this.onSkipNext,
    this.onSkipPrev,
    this.onSessionLost,
  });
}

/// Global handler — set once in [main] after [AudioService.init], then read
/// from anywhere that needs the shared player or wants to bind to media events.
late final KatalavenoAudioHandler katalavenoAudio;
