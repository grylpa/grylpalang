import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:timezone/data/latest.dart' as tz;

import 'screens/main_scaffold.dart';
import 'services/katalaveno_audio_handler.dart' as kah;
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
      // Must be a white/alpha silhouette — audio_service defaults to
      // 'mipmap/ic_launcher', whose full-colour bitmap the status bar cannot
      // render (it shows as a blank square). Reuses the notification icon
      // flutter_local_notifications already uses; kept from resource shrinking
      // by res/raw/keep.xml, since this is resolved by name at runtime.
      androidNotificationIcon: 'mipmap/notif_launcher',
      // Ongoing must be false whenever androidStopForegroundOnPause is false —
      // audio_service asserts the pair, since "ongoing" only means anything for
      // a service that leaves the foreground when paused.
      androidNotificationOngoing: false,
      // True, and it has to be true. This is the *only* path that releases
      // audio_service's PARTIAL_WAKE_LOCK while the app is running: the lock is
      // taken in enterPlayingState and released in exitPlayingState (gated on
      // this flag) or in onDestroy — and onDestroy never runs, because the
      // plugin keeps a MediaBrowserService binding open for the app's lifetime
      // and a bound service survives its own stopSelf(). `dumpsys activity
      // services` shows exactly that: startRequested=false (stopSelf did run)
      // next to a live binding, isForeground=true and the lock still held. With
      // this false, every pause leaked a held wakelock until Android killed the
      // app — measured at 4h17m with no audio at all, which is what the phone's
      // battery warning was reporting.
      //
      // The earlier fear was that a pause with the screen locked could never
      // re-enter the foreground, since Android 12+ blocks a background FGS
      // start. It doesn't apply here: the platform grants a temporary allowlist
      // precisely for this case — `dumpsys media_session` lists
      // media_button_receiver_fgs_allowlist_duration_ms and
      // media_session_calback_fgs_allowlist_duration_ms (10s each), and
      // batterystats shows it being granted by name on a headset press
      // (+tmpwhitelist=…KEYCODE_MEDIA_PREVIOUS). Pausing drops foreground with
      // STOP_FOREGROUND_DETACH, so the notification stays on screen and the
      // media session stays active; the Play that comes back through either of
      // them carries that allowlist. (The "code:DENIED" cited before was
      // mAllowWiu_byBindings, one per-reason field, not the verdict.)
      androidStopForegroundOnPause: true,
    ),
  );

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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().attachNavigator(rootNavKey.currentState);
    });

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
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
        // No focus ring — fields stay flat filled with no border in any state
        // (a focus outline read as an unwanted "border").
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide.none),
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
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
          side: BorderSide(color: scheme.outline),
        ),
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
