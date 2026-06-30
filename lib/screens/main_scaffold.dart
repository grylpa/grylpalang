import 'package:flutter/material.dart';
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

class _MainScaffoldState extends State<MainScaffold> {//with WidgetsBindingObserver {
  int _index = 0;
  int _seenNotificationTapToken = 0;
  late final AppLifecycleListener _listener;

  late final List<Widget> _pages = const [
    DashboardScreen(),
    NotificationHistoryTab(),
    PredictionTab(),
    SentenceBankTab(),
    BooksTab(),
    SettingsScreen(),
  ];

  static const _kTabKey = 'lastTabIndex';

  /// Switches to [idx], persisting it as the last active tab. No-op if [idx] is
  /// out of range or already current (keeps swipes non-cyclic — swiping past the
  /// first/last tab does nothing).
  void _changeTab(int idx) {
    if (idx < 0 || idx >= _pages.length || idx == _index) return;
    setState(() => _index = idx);
    SharedPreferencesAsync().setInt(_kTabKey, idx);
  }

  @override
  void initState() {
    super.initState();
    // Restore last active tab.
    SharedPreferencesAsync().getInt(_kTabKey).then((saved) {
      if (saved != null && saved >= 0 && saved < _pages.length && mounted) {
        setState(() => _index = saved);
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
        setState(() => _index = 1); // <-- your History tab index
      }
    });
  }

  @override
  void dispose() {
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
              setState(() => _index = 1);
            });
          }
        }

        // Horizontal swipes step one tab at a time (non-cyclic). The IndexedStack
        // is kept so every tab stays alive (audio tabs, keep-alive state); the
        // gesture detector just moves the index. Inner horizontal scrollables win
        // the gesture arena, so swiping on them scrolls instead of changing tabs.
        Widget body = GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragEnd: (details) {
            final v = details.primaryVelocity ?? 0;
            if (v <= -250) {
              _changeTab(_index + 1); // swipe left → next tab
            } else if (v >= 250) {
              _changeTab(_index - 1); // swipe right → previous tab
            }
          },
          child: IndexedStack(
            index: _index,
            children: _pages,
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
            currentIndex: _index,
            onTap: _changeTab,
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
                label: 'Dashboard',
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
