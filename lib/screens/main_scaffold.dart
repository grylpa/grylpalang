import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
import 'books_tab.dart';
import 'dashboard_screen.dart';
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
  int _index = _kSettingsTab;
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

  late final List<Widget> _pages = const [
    _KeepAlive(child: DashboardScreen()),
    _KeepAlive(child: NotificationHistoryTab()),
    _KeepAlive(child: PredictionTab()),
    _KeepAlive(child: SentenceBankTab()),
    _KeepAlive(child: BooksTab()),
    _KeepAlive(child: SettingsScreen()),
  ];

  static const _kTabKey = 'lastTabIndex';
  static const _kSettingsTab = 5; // Settings is the last bottom-nav tab.

  // Once-per-process guard: the "AI is imperfect / set an API key" intro is
  // shown at most once each app run (only while no key is set — see
  // _maybeShowApiKeyIntro), never persisted.
  bool _apiKeyIntroHandled = false;

  void _persistTab(int i) => SharedPreferencesAsync().setInt(_kTabKey, i);

  /// Pixel offset that puts page [i] at the top of the viewport, clamped.
  double _offsetFor(int i) =>
      (i * _pageWidth).clamp(0.0, _hScroll.hasClients ? _hScroll.position.maxScrollExtent : double.infinity);

  /// Nav-bar tap. Slides for an *adjacent* page (250ms); **jumps** for a
  /// non-adjacent one so the transition doesn't scroll through — and briefly
  /// flash — the tabs in between. Swipes are handled by the ListView itself.
  void _goToTab(int i) {
    if (i < 0 || i >= _pages.length || i == _index) return;
    final adjacent = (i - _index).abs() == 1;
    _persistTab(i);
    setState(() => _index = i);
    if (!_hScroll.hasClients || _pageWidth <= 0) return; // pin will place it on layout
    if (adjacent) {
      _hScroll.animateTo(_offsetFor(i), duration: const Duration(milliseconds: 250), curve: Curves.easeOutCubic);
    } else {
      _hScroll.jumpTo(_offsetFor(i));
    }
  }

  /// A swipe settled on page [i]. Update the nav-bar selection + remember it.
  void _onPageSettled(int i) {
    if (i == _index) return;
    _persistTab(i);
    setState(() => _index = i);
  }

  /// Moves to [i] without animating (restore last tab, a notification opening
  /// History). Safe before layout: sets the index and the build-time "pin"
  /// places the ListView on that page once it's laid out.
  void _jumpToTab(int i) {
    if (i < 0 || i >= _pages.length) return;
    _persistTab(i);
    setState(() => _index = i);
    if (_hScroll.hasClients && _pageWidth > 0) _hScroll.jumpTo(_offsetFor(i));
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
    _jumpToTab(_kSettingsTab);
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
                Text(
                  'Tap anywhere to continue.',
                  style: TextStyle(fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void initState() {
    super.initState();
    // Restore last active tab — unless the no-API-key intro has already routed
    // us to Settings (in which case that takes precedence).
    SharedPreferencesAsync().getInt(_kTabKey).then((saved) {
      if (_apiKeyIntroHandled) return;
      if (saved != null && saved >= 0 && saved < _pages.length && mounted) {
        _jumpToTab(saved);
      }
    });
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
        _jumpToTab(1); // <-- your History tab index
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
    return Selector<AppState, (int, bool)>(
      selector: (_, s) => (s.notificationTapToken, s.initialized),
      builder: (context, data, child) {
        final (tapToken, isInitialized) = data;
        // if (!isInitialized) {
        //   return const InitializingOverlay(); // Show your loading screen
        // }
        // Once settings have loaded, show the AI-key intro if no key is set.
        if (isInitialized && !_apiKeyIntroHandled) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowApiKeyIntro());
        }
        // New tap? Jump to history tab.
        if (tapToken != _seenNotificationTapToken) {
          debugPrint("hack got new tap token");
          _seenNotificationTapToken = tapToken;
          if (_index != 1) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!mounted) return;
              _jumpToTab(1);
            });
          }
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
                  final page = (_hScroll.offset / _pageWidth).round().clamp(0, _pages.length - 1);
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
                scrollCacheExtent: ScrollCacheExtent.pixels(w * _pages.length),
                itemCount: _pages.length,
                itemBuilder: (context, i) => SizedBox(width: w, child: _pages[i]),
              );
            },
          ),
        );

        return !appState.initialized ?
          Container(
            alignment: Alignment.center,
            color: Colors.black,
            width: double.infinity,
            height: double.infinity,
            child: Image.asset(
              'assets/splash.png',
              width: 300,
              fit: BoxFit.contain,
            ),
          ) : Scaffold(
          appBar: AppBar(title: const Text('Katalaveno'), centerTitle: true, titleSpacing: 8),
          body: body,
          bottomNavigationBar: BottomNavigationBar(
            currentIndex: _index.clamp(0, _pages.length - 1),
            onTap: _goToTab,
            type: BottomNavigationBarType.fixed,
            selectedItemColor: Theme.of(context).colorScheme.primary,
            unselectedItemColor: Theme.of(context).colorScheme.onSurfaceVariant,
            selectedFontSize: 12,
            unselectedFontSize: 12,
            // <- same size, no “jump”
            showUnselectedLabels: true,
            // or false if you prefer
            items: const [
              BottomNavigationBarItem(
                icon: Icon(Icons.spellcheck_outlined),
                activeIcon: Icon(Icons.spellcheck),
                label: 'Active',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.history_outlined),
                activeIcon: Icon(Icons.history),
                label: 'History',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.psychology_outlined),
                activeIcon: Icon(Icons.psychology),
                label: 'Predict',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.menu_book_outlined),
                activeIcon: Icon(Icons.menu_book),
                label: 'Sentences',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.auto_stories_outlined),
                activeIcon: Icon(Icons.auto_stories),
                label: 'Books',
              ),
              BottomNavigationBarItem(
                icon: Icon(Icons.settings_outlined),
                activeIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
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
