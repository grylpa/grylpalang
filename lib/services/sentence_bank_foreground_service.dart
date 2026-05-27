import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

// Top-level entry point required by flutter_foreground_task — runs in a
// separate isolate just to keep the Android foreground service alive.
// All real auto-mode logic stays in the main isolate.
@pragma('vm:entry-point')
void foregroundTaskEntryPoint() {
  FlutterForegroundTask.setTaskHandler(_IdleTaskHandler());
}

class _IdleTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

/// Thin wrapper around [FlutterForegroundTask] — Android-only.
/// On every other platform every call is a silent no-op.
class SentenceBankForegroundService {
  static bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Call once at app startup (before [runApp]).
  static void init() {
    if (!_isAndroid) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'katalaveno_sentence_bank',
        channelName: 'Sentence Bank',
        channelDescription: 'Keeps auto mode running when the screen is off',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        playSound: false,
        enableVibration: false,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true, // keeps CPU alive with screen off
        allowWifiLock: false,
        allowAutoRestart: false,
        stopWithTask: true,
      ),
    );
  }

  /// Requests the OS to exempt this app from battery optimization.
  /// Returns null on success, or an error string on failure.
  static Future<String?> requestBatteryExemption() async {
    if (!_isAndroid) return null;
    if (await FlutterForegroundTask.isIgnoringBatteryOptimizations) return null;
    try {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      return null;
    } catch (e) {
      return e.toString();
    }
  }

  static const _notificationIcon = NotificationIcon(
    metaDataName: 'katalaveno.foreground_service.notification_icon',
  );

  /// Start the foreground service. Returns null on success, error string on failure.
  static Future<String?> start({required String subject}) async {
    if (!_isAndroid) return null;
    if (await FlutterForegroundTask.isRunningService) {
      final r = await FlutterForegroundTask.updateService(
        notificationTitle: 'Katalaveno — Auto Mode',
        notificationText: subject,
        notificationIcon: _notificationIcon,
      );
      return r is ServiceRequestFailure ? r.error.toString() : null;
    }
    final result = await FlutterForegroundTask.startService(
      serviceId: 1042,
      serviceTypes: [ForegroundServiceTypes.mediaPlayback],
      notificationTitle: 'Katalaveno — Auto Mode',
      notificationText: subject,
      notificationIcon: _notificationIcon,
      callback: foregroundTaskEntryPoint,
    );
    return result is ServiceRequestFailure ? result.error.toString() : null;
  }

  /// Whether the foreground service is currently running. Used for diagnostics.
  static Future<bool> isRunning() async {
    if (!_isAndroid) return false;
    return FlutterForegroundTask.isRunningService;
  }

  /// Stop the foreground service and dismiss the notification.
  static Future<void> stop() async {
    if (!_isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}
