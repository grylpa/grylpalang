import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_tab.dart';
import '../widgets.dart';
import '../services/app_update_service.dart';
import '../state/app_state.dart';
import 'books_tab.dart';
import 'dashboard_screen.dart';
import 'listen_tab.dart';
import 'notification_history_tab.dart';
import 'sentence_bank_tab.dart';
import 'settings_screen.dart';
import 'prediction_tab.dart';

class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  // Default to Settings so a fresh install (no saved tab, no API key) shows it
  // behind the intro popup with no visible tab flip. A returning user's saved
  // tab is restored over this in initState.
  //
  // The *tab*, not its position, is the source of truth: the user can hide
  // destinations, so an index is only ever derived from `_tabs` at build time.
  AppTab _current = AppTab.settings;
  // The visible destinations, recomputed from settings on every build. Kept as
  // a field because the scroll callbacks (which run outside build) need to map
  // pixel offsets to tabs.
  List<AppTab> _tabs = AppTab.values;
  int _seenNotificationTapToken = 0;
  late final AppLifecycleListener _listener;

  // Tabs are hosted in a horizontal ListView (not a PageView) so we can force
  // every page to be built and kept alive from startup via a full cacheExtent.
  // That matters here: e.g. SentenceBankTab.initState registers the shared
  // audio media-control binding (Bluetooth/lockscreen) and kicks off its bank
  // load — both must happen at launch, not on first visit. PageScrollPhysics
  // gives PageView-style one-page snapping, and the swipe is scroll-physics
  // driven, so it animates regardless of the device's "remove animations"
  // setting (an AnimationController would be collapsed to instant by it).
  final ScrollController _hScroll = ScrollController();
  double _pageWidth = 0;
  // True once the current scroll was driven by a real user drag/fling. Only such
  // a settle should change the selected tab — a layout-induced offset correction
  // (e.g. a rotation changing the page width) must not, or it snaps to a
  // neighbor tab. Set from drag details on scroll start/update, cleared on end.
  bool _userDragged = false;

  // One widget instance per destination, built once. Hiding a tab drops it from
  // the pager (disposing that screen); showing it again re-creates it. Held in
  // a map rather than a list so the visible set can change without any index
  // arithmetic.
  static const Map<AppTab, Widget> _pages = {
    AppTab.dashboard: _KeepAlive(child: DashboardScreen()),
    AppTab.predict: _KeepAlive(child: PredictionTab()),
    AppTab.sentences: _KeepAlive(child: SentenceBankTab()),
    AppTab.books: _KeepAlive(child: BooksTab()),
    AppTab.listen: _KeepAlive(child: ListenTab()),
    AppTab.settings: _KeepAlive(child: SettingsScreen()),
  };

  // Current key holds an AppTab id; the legacy one held a raw index into the
  // pre-hideable-tabs order, and is read once to migrate it.
  static const _kTabIdKey = 'lastTabId';
  static const _kLegacyTabKey = 'lastTabIndex';

  // Once-per-process guard: the "AI is imperfect / set an API key" intro is
  // shown at most once each app run (only while no key is set — see
  // _maybeShowApiKeyIntro), never persisted.
  bool _apiKeyIntroHandled = false;

  // Same shape for the Play update check: at most one attempt per app run.
  bool _updateCheckStarted = false;

  void _persistTab(AppTab t) => SharedPreferencesAsync().setString(_kTabIdKey, t.id);

  /// Position of the selected tab among the *visible* ones. Never negative:
  /// build keeps `_current` inside `_tabs`.
  int get _index => _tabs.indexOf(_current).clamp(0, _tabs.length - 1);

  /// Pixel offset that puts page [i] at the left of the viewport, clamped.
  double _offsetFor(int i) =>
      (i * _pageWidth).clamp(0.0, _hScroll.hasClients ? _hScroll.position.maxScrollExtent : double.infinity);

  /// Nav-bar tap on the [i]th *visible* tab. Slides for an adjacent page
  /// (250ms); **jumps** for a non-adjacent one so the transition doesn't scroll
  /// through — and briefly flash — the tabs in between. Swipes are handled by
  /// the ListView itself.
  void _goToTab(int i) {
    if (i < 0 || i >= _tabs.length || i == _index) return;
    final adjacent = (i - _index).abs() == 1;
    final tab = _tabs[i];
    _persistTab(tab);
    setState(() => _current = tab);
    if (!_hScroll.hasClients || _pageWidth <= 0) return; // pin will place it on layout
    if (adjacent) {
      _hScroll.animateTo(_offsetFor(i), duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
    } else {
      _hScroll.jumpTo(_offsetFor(i));
    }
  }

  /// A swipe settled on the [i]th visible page. Update the nav-bar selection
  /// + remember it.
  void _onPageSettled(int i) {
    if (i < 0 || i >= _tabs.length || _tabs[i] == _current) return;
    final tab = _tabs[i];
    _persistTab(tab);
    setState(() => _current = tab);
  }

  /// Moves to [tab] without animating (restore last tab, a notification opening
  /// History). A hidden tab is ignored — the user switched it off, so nothing
  /// should drag them back to it. Safe before layout: sets the tab and the
  /// build-time "pin" places the ListView on it once laid out.
  void _jumpToTab(AppTab tab) {
    if (!_tabs.contains(tab)) return;
    _persistTab(tab);
    setState(() => _current = tab);
    if (_hScroll.hasClients && _pageWidth > 0) _hScroll.jumpTo(_offsetFor(_tabs.indexOf(tab)));
  }

  /// On the first launch where no Gemini API key is set: route the user to the
  /// Settings tab, open its "AI engine" card, and show a one-tap-to-dismiss
  /// intro explaining that translations are AI-generated (so may be wrong) and
  /// that a key must be pasted in Settings. Runs at most once per app run and
  /// only while the key is empty — deliberately not remembered across runs.
  Future<void> _maybeShowApiKeyIntro() async {
    if (_apiKeyIntroHandled || !mounted) return;
    final appState = context.read<AppState>();
    if (appState.settings.aiApiKey.trim().isNotEmpty) return;
    _apiKeyIntroHandled = true;

    // Land the user on Settings with the AI-engine card open behind the intro.
    _jumpToTab(AppTab.settings);
    appState.requestAiEngineFocus();

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        // Any tap anywhere — content or barrier — dismisses.
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.of(ctx).pop(),
          child: AlertDialog(
            title: const Text('Welcome to Katalaveno'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Text(
                  'Sentences and translations in this app are generated by AI '
                  '(Google Gemini). AI is powerful but not perfect — translations '
                  'can occasionally be wrong or awkward, so treat them as a helpful '
                  'guide rather than an authority.',
                ),
                SizedBox(height: 12),
                Text(
                  'To get started you need a free Gemini API key. Create one, then '
                  'paste it into the "AI engine" section of the Settings screen '
                  '(open below).',
                ),
                SizedBox(height: 16),
                Text('Tap anywhere to continue.', style: TextStyle(fontStyle: FontStyle.italic)),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Opens the notification history over the current tab.
  ///
  /// History is no longer a destination — it is a view of the Active-words
  /// data — so a notification tap pushes it rather than switching tabs, which
  /// also means Back returns the user exactly where they were.
  bool _historyOpen = false;

  Future<void> _openHistory() async {
    if (_historyOpen || !mounted) return;
    _historyOpen = true;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const NotificationHistoryScreen()));
    _historyOpen = false;
  }

  /// Asks Google Play whether a newer build is out, and offers to install it.
  ///
  /// Deliberately last and deliberately timid: it waits a few seconds so the
  /// app is usable first, and gives up entirely if any other dialog is on
  /// screen (the first-run intro, most likely). An update prompt is never
  /// urgent enough to stack on top of something else — the next launch will do.
  Future<void> _startupUpdateCheck() async {
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
    await AppUpdateService.maybePromptOnStartup(context);
  }

  /// Restores the tab the user was last on. Reads the id key first; falls back
  /// once to the legacy raw index, translated through the tab order as it was
  /// before tabs became hideable.
  Future<void> _restoreLastTab() async {
    final prefs = SharedPreferencesAsync();
    var tab = AppTab.byId(await prefs.getString(_kTabIdKey) ?? '');
    if (tab == null) {
      final legacy = await prefs.getInt(_kLegacyTabKey);
      if (legacy != null && legacy >= 0 && legacy < AppTab.legacyOrder.length) {
        tab = AppTab.legacyOrder[legacy];
      }
    }
    // The intro may have routed us to Settings while this was in flight; that
    // takes precedence.
    if (tab == null || _apiKeyIntroHandled || !mounted) return;
    _jumpToTab(tab);
  }

  @override
  void initState() {
    super.initState();
    // Restore last active tab — unless the no-API-key intro has already routed
    // us to Settings (in which case that takes precedence).
    _restoreLastTab();
    _listener = AppLifecycleListener(
      onStateChange: (AppLifecycleState state) {
        final s = context.read<AppState>();
        if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
          s.resetHistoryHighlight(silent: true);
          s.paused = true;
        }

        if (state == AppLifecycleState.resumed) {
          s.onAppResumed();
          s.handleLaunchPayloadIfAny();
        }
      },
    );
    // WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final appState = context.read<AppState>();
      final token = appState.notificationTapToken;
      if (token != _seenNotificationTapToken) {
        _seenNotificationTapToken = token;
        _openHistory();
      }
    });
  }

  @override
  void dispose() {
    _hScroll.dispose();
    _listener.dispose();
    // WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();
    // The hidden-tab set is joined into a string so the record stays cheaply
    // comparable — Selector rebuilds on `!=`, which a List would fail.
    return Selector<AppState, (int, bool, String)>(
      selector: (_, s) => (s.notificationTapToken, s.initialized, s.settings.hiddenTabIds.join(',')),
      builder: (context, data, child) {
        final (tapToken, isInitialized, hiddenSig) = data;
        _tabs = AppTab.visibleFrom(hiddenSig.isEmpty ? const [] : hiddenSig.split(','));
        // The selected tab was just switched off (it can only have been done
        // from Settings, which is where we land). Assigned straight rather than
        // via setState: we're already building with the new value, and the
        // post-frame pin will move the pager onto it.
        if (!_tabs.contains(_current)) _current = AppTab.settings;
        // if (!isInitialized) {
        //   return const InitializingOverlay(); // Show your loading screen
        // }
        // Once settings have loaded, show the AI-key intro if no key is set.
        if (isInitialized && !_apiKeyIntroHandled) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowApiKeyIntro());
        }
        if (isInitialized && !_updateCheckStarted) {
          _updateCheckStarted = true;
          WidgetsBinding.instance.addPostFrameCallback((_) => _startupUpdateCheck());
        }
        // New tap? Open the history screen over whatever tab is showing.
        if (tapToken != _seenNotificationTapToken) {
          _seenNotificationTapToken = tapToken;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _openHistory();
          });
        }

        // Horizontal swipes move one tab at a time and are non-cyclic (the list
        // can't scroll past the first/last page). depth == 0 targets the pager's
        // own horizontal scroll — not the in-page vertical lists — so a tab
        // swipe dismisses the keyboard, and a settle updates the selected tab.
        Widget body = NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.depth == 0) {
              if (n is ScrollStartNotification) {
                FocusManager.instance.primaryFocus?.unfocus();
                _userDragged = n.dragDetails != null;
              } else if (n is ScrollUpdateNotification) {
                if (n.dragDetails != null) _userDragged = true;
              } else if (n is ScrollEndNotification && _pageWidth > 0) {
                // Only a user-driven settle changes the tab; a rotation's layout
                // correction (no drag) must not, or it snaps to a neighbor.
                if (_userDragged) {
                  final page = (_hScroll.offset / _pageWidth).round().clamp(0, _tabs.length - 1);
                  _onPageSettled(page);
                }
                _userDragged = false;
              }
            }
            return false;
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              // A width change (rotation) makes the current pixel offset point at
              // the wrong page, so it must be re-pinned even if the position is
              // still settling from the resize — otherwise the view lands on a
              // neighbor tab while the nav bar still shows the right one.
              final widthChanged = _pageWidth != 0 && w != _pageWidth;
              _pageWidth = w;
              // Keep the list pinned to the selected page across first layout,
              // programmatic jumps, and width changes (rotation) — but for a plain
              // re-layout never while a drag/animation is in flight (that would
              // fight the user).
              if (w > 0) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_hScroll.hasClients) return;
                  if (!widthChanged && _hScroll.position.isScrollingNotifier.value) return;
                  final target = _offsetFor(_index);
                  if ((_hScroll.offset - target).abs() > 0.5) _hScroll.jumpTo(target);
                });
              }
              return ListView.builder(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                physics: const _SnapPageScrollPhysics(),
                // Full-width cache so every page is built at first layout and
                // never disposed (eager init + kept alive).
                scrollCacheExtent: ScrollCacheExtent.pixels(w * _tabs.length),
                itemCount: _tabs.length,
                // Hiding a tab shifts every page after it. The key identifies a
                // page by tab, and findChildIndexCallback tells the sliver where
                // that key moved to — without it the shifted pages would be torn
                // down and rebuilt from scratch, losing their state.
                findChildIndexCallback: (key) {
                  if (key is! ValueKey<AppTab>) return null;
                  final i = _tabs.indexOf(key.value);
                  return i < 0 ? null : i;
                },
                itemBuilder: (context, i) => SizedBox(key: ValueKey(_tabs[i]), width: w, child: _pages[_tabs[i]]),
              );
            },
          ),
        );

        return !appState.initialized
            ? Container(
                alignment: Alignment.center,
                color: Colors.black,
                width: double.infinity,
                height: double.infinity,
                child: Image.asset('assets/splash.png', width: 300, fit: BoxFit.contain),
              )
            : Scaffold(
                appBar: AppBar(title: const Text('Katalaveno'), centerTitle: true, titleSpacing: 8),
                // The AI-activity strip lives here, once, so every screen that
                // calls the AI reports its fallbacks and waits without having to
                // add anything of its own. Floating over the bottom of the
                // content, not in a Column: that is where the eye already is
                // (the add-word row, the Generate buttons), and overlaying keeps
                // a fixed-behavior SnackBar — laid out in that same strip — from
                // shunting the page up and down whenever a message appears.
                body: Stack(
                  children: [
                    Positioned.fill(child: body),
                    const Positioned(left: 0, right: 0, bottom: 0, child: AiActivityBanner()),
                  ],
                ),
                // A single visible destination needs no bar (and BottomNavigationBar
                // asserts on fewer than two items). Settings can't be hidden, so
                // there is always a way back to the tab switches.
                bottomNavigationBar: _tabs.length < 2
                    ? null
                    : BottomNavigationBar(
                        currentIndex: _index,
                        onTap: _goToTab,
                        type: BottomNavigationBarType.fixed,
                        selectedItemColor: Theme.of(context).colorScheme.primary,
                        unselectedItemColor: Theme.of(context).colorScheme.onSurfaceVariant,
                        // Same size selected or not, so the bar doesn't "jump".
                        selectedFontSize: 12,
                        unselectedFontSize: 12,
                        showUnselectedLabels: true,
                        items: [
                          for (final t in _tabs)
                            BottomNavigationBarItem(icon: Icon(t.icon), activeIcon: Icon(t.activeIcon), label: t.label),
                        ],
                      ),
              );
      },
    );
  }
}

/// Keeps its [child] alive inside the tab ListView so switching tabs never
/// rebuilds a screen (preserves its state, scroll position, and audio
/// subscriptions). Belt-and-suspenders with the full `scrollCacheExtent`, which
/// builds every page up front and keeps them from being disposed.
class _KeepAlive extends StatefulWidget {
  const _KeepAlive({required this.child});
  final Widget child;

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

/// `PageScrollPhysics` tuned to remove the swipe "bounce". The default page-snap
/// spring is only lightly damped, so a fast swipe overshoots the target page and
/// springs back. Capping the fling speed fed to the settle and using a more
/// heavily-damped spring makes a swipe land on the page with no overshoot — like
/// the nav-bar tap's `animateTo(easeOutCubic)`.
class _SnapPageScrollPhysics extends PageScrollPhysics {
  const _SnapPageScrollPhysics({super.parent});

  @override
  _SnapPageScrollPhysics applyTo(ScrollPhysics? ancestor) => _SnapPageScrollPhysics(parent: buildParent(ancestor));

  // Stiff + slightly overdamped: settles quickly (roughly matching the nav-bar
  // tap's 250ms animateTo) without the default spring's overshoot bounce.
  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(mass: 0.5, stiffness: 320, ratio: 1.2);

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    // Keep the flick direction (which picks the target page) but cap the speed
    // so the settle can't shoot past the page and bounce back.
    return super.createBallisticSimulation(position, velocity.clamp(-3500.0, 3500.0));
  }
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
