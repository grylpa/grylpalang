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

    ThemeData buildTheme(Brightness brightness) {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.blue, brightness: brightness);
      // The "interval unit" dropdown explicitly sets dropdownColor to
      // surfaceContainerHighest, which reads as a real popup surface on top of
      // the page. Mirror that here for every popup/dropdown surface in the app
      // so menus like the EPUB/TXT picker no longer collapse into a plain
      // black rectangle.
      return ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        popupMenuTheme: PopupMenuThemeData(
          color: scheme.surfaceContainerHighest,
          surfaceTintColor: scheme.surfaceContainerHighest,
        ),
        dropdownMenuTheme: DropdownMenuThemeData(
          menuStyle: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
            surfaceTintColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
          ),
        ),
        menuTheme: MenuThemeData(
          style: MenuStyle(
            backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
            surfaceTintColor: WidgetStatePropertyAll(scheme.surfaceContainerHighest),
          ),
        ),
      );
    }

    final lightTheme = buildTheme(Brightness.light);
    final darkTheme = buildTheme(Brightness.dark);

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
