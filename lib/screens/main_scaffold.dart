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
  int _index = 0;
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

  late final List<Widget> _pages = const [
    _KeepAlive(child: DashboardScreen()),
    _KeepAlive(child: NotificationHistoryTab()),
    _KeepAlive(child: PredictionTab()),
    _KeepAlive(child: SentenceBankTab()),
    _KeepAlive(child: BooksTab()),
    _KeepAlive(child: SettingsScreen()),
  ];

  static const _kTabKey = 'lastTabIndex';

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

  @override
  void initState() {
    super.initState();
    // Restore last active tab.
    SharedPreferencesAsync().getInt(_kTabKey).then((saved) {
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
              } else if (n is ScrollEndNotification && _pageWidth > 0) {
                final page = (_hScroll.offset / _pageWidth).round().clamp(0, _pages.length - 1);
                _onPageSettled(page);
              }
            }
            return false;
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              _pageWidth = w;
              // Keep the list pinned to the selected page across first layout,
              // programmatic jumps, and width changes (rotation) — but never
              // while a drag/animation is in flight (that would fight the user).
              if (w > 0) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted || !_hScroll.hasClients) return;
                  if (_hScroll.position.isScrollingNotifier.value) return;
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
                icon: Icon(Icons.dashboard_outlined),
                activeIcon: Icon(Icons.dashboard), // filled when active
                label: 'Words',
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

  @override
  SpringDescription get spring => SpringDescription.withDampingRatio(mass: 0.5, stiffness: 100, ratio: 1.3);

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    // Keep the flick direction (which picks the target page) but cap the speed
    // so the settle spring can't shoot past the page and bounce back.
    return super.createBallisticSimulation(position, velocity.clamp(-1600.0, 1600.0));
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
