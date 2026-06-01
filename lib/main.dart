import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest.dart' as tz;

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'screens/main_scaffold.dart';
import 'services/katalaveno_audio_handler.dart' as kah;
import 'services/sentence_bank_foreground_service.dart';
import 'state/app_state.dart';

final GlobalKey<NavigatorState> rootNavKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Background audio (native media session) — also routes system media-control
  // events (Bluetooth, lockscreen, Android Auto) into our app handler so e.g.
  // "next track" advances to the next chunk/sentence rather than the next clip.
  kah.katalavenoAudio = await AudioService.init(
    builder: () => kah.KatalavenoAudioHandler(),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.grylpa.katalaveno.audio',
      androidNotificationChannelName: 'Katalaveno audio',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );

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
