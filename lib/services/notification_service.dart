// import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint, defaultTargetPlatform;  //kDebugMode
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

bool get _supportsNotifications => !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.linux);

class NotificationService {
  NotificationService._();

  static final instance = NotificationService._();
  static final _groupKey = "KatalavenoNotifGroup";

  // Track which ids we've already shown on Linux in this app run.
  static final _linuxShownIds = <int>[];

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init({required void Function(String payload) onTap}) async {
    if (!_supportsNotifications) return;
    const androidInit = AndroidInitializationSettings('@mipmap/notif_launcher');
    const darwinInit = DarwinInitializationSettings();
    const linuxInit = LinuxInitializationSettings(defaultActionName: 'Open notification');

    const initSettings = InitializationSettings(android: androidInit, iOS: darwinInit, linux: linuxInit);

    try {
      await _plugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          debugPrint('🔔 notif tap id=${response.id} payloadLen=${response.payload?.length}');
          onTap(response.payload ?? "");
        },
      );
    } on UnimplementedError {
      return;
    } on MissingPluginException {
      return;
    }

    // Android 13+ runtime permission
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
  }

  Future<String?> getLaunchPayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details == null) return null;
      debugPrint("details.didNotificationLaunchApp: ${details.didNotificationLaunchApp}");
      if (details.didNotificationLaunchApp) {
        return details.notificationResponse?.payload ?? "";
      }
    } on UnimplementedError {
      // Some platforms (e.g. Linux) don't implement this API.
      // Treat it as "app was not launched from a notification".
      return null;
    } on MissingPluginException {
      return null;
    }
    return null;
  }

  Future<void> cancelAll() async {
    if (!_supportsNotifications) return;
    try {
      await _plugin.cancelAll();
    } on UnimplementedError {
      return;
    } on MissingPluginException {
      return;
    }
  }

  Future<void> scheduleNotification({
    required int id,
    required DateTime fireTime,
    required String? title,
    required String? body,
    required String? payload,
  }) async {
    if (!_supportsNotifications) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        'katalaveno_channel',
        'Katalaveno Notifications',
        channelDescription: 'Notifications for Katalaveno',
        importance: Importance.max,
        priority: Priority.high,
        autoCancel: false,
        // subText: 'Tap to see translations in app',
        styleInformation: BigTextStyleInformation(
          "${body ?? ""}\n\nTap for translation in app",
          contentTitle: title,
          // summaryText: "tap to see translations in app",
        ),
        // enableVibration: false,
        // color: Color.fromARGB(255,255,239,156),
      ),
      iOS: const DarwinNotificationDetails(),
    );

    final tzTime = tz.TZDateTime.from(fireTime, tz.local);

    // Linux: no real scheduler; show immediately but:
    // - max 2 notifications per app run
    // - never show the same id twice
    if (defaultTargetPlatform == TargetPlatform.linux) {
      if (_linuxShownIds.length >= 10) {
        _linuxShownIds.removeRange(0, _linuxShownIds.length - 10);
      }
      if (_linuxShownIds.contains(id)) {
        // return;
      }
      _linuxShownIds.add(id);

      try {
        await showNow(id: id, title: title, body: body, payload: payload);
        // await _plugin.show(
        //   id,
        //   title,
        //   body,
        //   details,
        //   payload: payload,
        // );
      } on UnimplementedError {
        // Some Linux builds may still not support notifications; just ignore.
        return;
      } on MissingPluginException {
        return;
      }
      return;
    }

    try {
      // Normal path (Android/iOS)
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tzTime,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: payload,
        matchDateTimeComponents: null,
      );

      // await _plugin.show(
      //   0,
      //   'Katalaveno Updates',
      //   'You have multiple notifications',
      //   NotificationDetails(
      //     android: AndroidNotificationDetails(
      //       'katalaveno_channel',
      //       'Katalaveno Notifications',
      //       groupKey: _groupKey,
      //       importance: Importance.max,
      //       priority: Priority.high,
      //       autoCancel: true,
      //       setAsGroupSummary: true,
      //     ),
      //   ),
      //   payload: '{"type":"summary"}', // This will now trigger your debugPrint
      // );
    } on UnimplementedError {
      // Linux or unsupported platform: just skip scheduling
      // History still works because AppState builds snapshots itself.
      return;
    } on MissingPluginException {
      return;
    }
  }

  Future<void> showNow({
    required int id,
    required String? title,
    required String? body,
    required String? payload,
  }) async {
    if (!_supportsNotifications) return;
    final androidDetails = AndroidNotificationDetails(
      'katalaveno_channel',
      'Katalaveno Notifications',
      channelDescription: 'Notifications for Katalaveno',
      importance: Importance.max,
      priority: Priority.high,
      groupKey: _groupKey,
      setAsGroupSummary: false,
      styleInformation: BigTextStyleInformation(body ?? '', contentTitle: title),
    );

    final linuxDetails = LinuxNotificationDetails(
      // optional: set urgency/category if you want
    );

    final details = NotificationDetails(android: androidDetails, linux: linuxDetails);

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: details,
      payload: payload,
    );
  }
}
