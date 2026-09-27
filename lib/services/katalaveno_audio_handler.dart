import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
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
    player.processingStateStream.listen((_) {
      _emitPlaybackState(player.playbackEvent);
      _reviewSession();
    });
    player.playingStream.listen((_) => _reviewSession());
  }

  // ── Keeping the service honest ─────────────────────────────────
  //
  // audio_service holds a PARTIAL_WAKE_LOCK for as long as the session is in the
  // foreground, and with `androidStopForegroundOnPause: false` — which we need,
  // since Android 12+ would not let a background headset Play put the service
  // back in the foreground — it releases that lock in exactly one place: when
  // the playbackState goes **idle**. Nothing in the app used to take it there. A
  // pause kept it. A queue that ran out kept it. Even the notification's Stop
  // kept it, wherever the owning screen's `onStop` merely paused (Listen's does,
  // by design — "pause is the stop"). The phone's own battery warning was
  // reporting the result: a wakelock held for hours with nothing coming out of
  // the speaker.
  //
  // Two guards now watch for that, and both end in [_endSession], which drives
  // the state to idle and so releases the lock and stops the service:
  //
  //  * **Paused, ended or stopped** for [idleStopAfter] → stop for real. Coming
  //    back then means the app rather than the headset, which is the trade a ten
  //    minute idle earns.
  //  * **Nominally playing but not advancing** for [_kStallSamples] samples →
  //    the same. A session that renders nothing is a wakelock and nothing else,
  //    and `playing` staying true is why the first guard alone missed it.
  //
  // Exactly one guard is armed at a time, and the stall watch only ticks while
  // the player claims to be playing — when the CPU is already awake for audio.
  Duration idleStopAfter = const Duration(minutes: 10);
  Timer? _idleTimer;

  static const Duration _kStallSample = Duration(minutes: 1);
  static const int _kStallSamples = 3;
  Timer? _stallTimer;
  int _stallTicks = 0;
  (int?, int)? _lastProgress;

  /// True once the plugin has put the service in the foreground and taken the
  /// wakelock, which it does the moment we report `playing` — whatever the
  /// processing state. This is the "is there anything to tear down" test: before
  /// the first play, and after a teardown, there is not.
  bool _serviceLive = false;

  /// Re-arms the right guard. Called on every play/pause *and* processing-state
  /// change: a queue that simply ended leaves `playing` true and emits no pause,
  /// so watching one stream alone would miss it.
  ///
  /// The split is on `playing` alone, not on a set of "healthy" processing
  /// states, because a `play()` on a queue that never got prepared reports
  /// playing with the state still `idle` — enough for the plugin to go
  /// foreground and take the lock, and the worst case to leave uncovered.
  void _reviewSession() {
    if (player.playing) {
      _idleTimer?.cancel();
      _idleTimer = null;
      _startStallWatch();
    } else {
      _stopStallWatch();
      _armIdleStop();
    }
  }

  void _armIdleStop() {
    if (_idleTimer?.isActive ?? false) return; // already counting down
    if (idleStopAfter <= Duration.zero) return;
    if (!_serviceLive) return; // nothing playing has ever claimed the service
    _idleTimer = Timer(idleStopAfter, () {
      _idleTimer = null;
      if (player.playing) return;
      unawaited(_endSession('idle for ${idleStopAfter.inMinutes}m'));
    });
  }

  void _startStallWatch() {
    if (_stallTimer != null) return;
    _lastProgress = null;
    _stallTicks = 0;
    _stallTimer = Timer.periodic(_kStallSample, (_) => _checkProgress());
  }

  void _stopStallWatch() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _lastProgress = null;
    _stallTicks = 0;
  }

  /// Progress is the (clip, second) pair: either changing means audio is moving,
  /// and a clip boundary resets the position, so both have to be sampled. A
  /// player that reports playing while stuck at 0:00 — an unprepared queue —
  /// reads as no progress, which is exactly right.
  void _checkProgress() {
    if (!player.playing) return; // the idle guard owns every other state
    final now = (player.currentIndex, player.position.inSeconds);
    if (_lastProgress != null && now == _lastProgress) {
      if (++_stallTicks >= _kStallSamples) {
        _stopStallWatch();
        unawaited(_endSession('playing but stalled for ${_kStallSamples * _kStallSample.inMinutes}m'));
      }
      return;
    }
    _stallTicks = 0;
    _lastProgress = now;
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
  /// `isActiveSession` and take its resume fast-path on the next Play — calling
  /// `play()` on a player whose decoders were released, which plays nothing.
  /// Every screen binds again when it plays, so nothing is lost; the per-tab
  /// starters, which is what a cold Play goes through, are registered separately
  /// and stay.
  Future<void> _endSession(String reason) async {
    _idleTimer?.cancel();
    _idleTimer = null;
    _stopStallWatch();
    debugPrint('katalaveno: ending audio session — $reason');
    final owner = _top;
    owner?.onSessionLost?.call();
    if (owner != null) unbind(owner.owner);
    await player.stop();
    // The plugin stops the service (and releases the lock) on a **transition**
    // into idle — `oldProcessingState != idle && processingState == idle` in its
    // setState. A session that never got past idle in the first place would
    // never make that transition, so state it explicitly rather than trusting
    // the player's own stream to produce it.
    playbackState.add(playbackState.value.copyWith(playing: false, processingState: AudioProcessingState.ready));
    playbackState.add(playbackState.value.copyWith(playing: false, processingState: AudioProcessingState.idle));
    _serviceLive = false;
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
    // The screen's own semantics first — Listen's Stop is a pause, since its
    // playlist is worth keeping — and then the session really ends. A Stop that
    // left the player merely paused left the wakelock held, which is the whole
    // reason the guards above exist.
    if (_top?.onStop != null) await _top!.onStop!();
    await _endSession('stop requested');
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
    // Reporting `playing` is what makes the plugin go foreground and take the
    // wakelock, so it is also what makes a teardown something we owe.
    if (player.playing) _serviceLive = true;
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
