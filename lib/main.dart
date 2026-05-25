import 'package:flutter/material.dart';
// import 'package:katalaveno/services/notification_service.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest.dart' as tz;
// import 'package:timezone/timezone.dart' as tz;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'screens/main_scaffold.dart';
import 'services/sentence_bank_foreground_service.dart';
import 'state/app_state.dart';

final GlobalKey<NavigatorState> rootNavKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Foreground service for Sentence Bank auto mode (Android only, no-op elsewhere).
  FlutterForegroundTask.initCommunicationPort();
  SentenceBankForegroundService.init();

  // Timezone for scheduling
  tz.initializeTimeZones();
  // tz.setLocalLocation(tz.getLocation('Europe/Athens'));

  final state = AppState();

  runApp(ChangeNotifierProvider.value(value: state, child: const MyApp()));
  state.init();
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppState>().settings;

    WidgetsBinding.instance.addPostFrameCallback((_) { context.read<AppState>().attachNavigator(rootNavKey.currentState); });

    final lightTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.light),
      useMaterial3: true,
    );

    final darkTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
      useMaterial3: true,
    );

    return MaterialApp(
      navigatorKey: rootNavKey,
      title: 'Katalaveno',
      debugShowCheckedModeBanner: false,

      // Two themes:
      theme: lightTheme,
      darkTheme: darkTheme,

      // Which one to use:
      themeMode: settings.useDarkMode ? ThemeMode.dark : ThemeMode.light,

      // 👇 Built-in animation between themes
      themeAnimationDuration: const Duration(milliseconds: 700),
      themeAnimationCurve: Curves.easeInOutCubic,

      home: const MainScaffold(),
    );
  }
}
