import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/app_state.dart';
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
    SettingsScreen(),
  ];

  static const _kTabKey = 'lastTabIndex';

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

        Widget body = IndexedStack(
          index: _index,
          children: _pages,
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
            onTap: (idx) {
              setState(() => _index = idx);
              SharedPreferencesAsync().setInt(_kTabKey, idx);
            },
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
