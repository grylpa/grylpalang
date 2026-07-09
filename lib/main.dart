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
      // Blue seed shared with the sibling app so the palette matches. All
      // primary action buttons use the tonal pair primaryContainer (fill) /
      // onPrimaryContainer (text+icon) — "light blue on dark blue" in dark mode,
      // adapting in light mode.
      final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF4F9CF9), brightness: brightness);
      const radius = 12.0;

      // Filled, borderless text fields / dropdowns (Material 3). Applied app-wide
      // so every input shares one calm look; focus shows a subtle primary ring.
      final inputTheme = InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radius),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      );

      // The single button look every action button inherits: solid tonal-blue
      // fill, no border. styleFrom keeps the correct dimmed disabled state.
      final buttonShape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
      final filledStyle = FilledButton.styleFrom(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        shape: buttonShape,
      );
      final outlinedAsFilled = OutlinedButton.styleFrom(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        side: BorderSide.none,
        shape: buttonShape,
      );
      final elevatedStyle = ElevatedButton.styleFrom(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        elevation: 0,
        shape: buttonShape,
      );

      // Popups (dropdown menus, popup menus) sit on a slightly lighter surface
      // with a gentle outline + shadow so they read as floating above the page.
      final menuSurface = WidgetStatePropertyAll(scheme.surfaceContainerHighest);
      final menuBorder = WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: scheme.outline)),
      );

      return ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        inputDecorationTheme: inputTheme,
        filledButtonTheme: FilledButtonThemeData(style: filledStyle),
        outlinedButtonTheme: OutlinedButtonThemeData(style: outlinedAsFilled),
        elevatedButtonTheme: ElevatedButtonThemeData(style: elevatedStyle),
        popupMenuTheme: PopupMenuThemeData(
          color: scheme.surfaceContainerHighest,
          surfaceTintColor: scheme.surfaceContainerHighest,
          elevation: 12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radius),
            side: BorderSide(color: scheme.outline),
          ),
        ),
        dropdownMenuTheme: DropdownMenuThemeData(
          inputDecorationTheme: inputTheme,
          menuStyle: MenuStyle(
            backgroundColor: menuSurface,
            surfaceTintColor: menuSurface,
            elevation: const WidgetStatePropertyAll(12),
            shape: menuBorder,
          ),
        ),
        menuTheme: MenuThemeData(
          style: MenuStyle(
            backgroundColor: menuSurface,
            surfaceTintColor: menuSurface,
            elevation: const WidgetStatePropertyAll(12),
            shape: menuBorder,
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
