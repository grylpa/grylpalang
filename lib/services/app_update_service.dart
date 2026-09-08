import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../widgets.dart';

/// Google Play in-app updates.
///
/// Play itself performs the update — we only ask whether one exists and hand
/// control over. Nothing here works in a build Play didn't install: a debug run
/// or a sideloaded APK fails with ERROR_API_NOT_AVAILABLE. That's why the
/// automatic check swallows every error silently — there is nothing the user
/// could act on and nothing worth interrupting them for — while the manual
/// check in Settings says what happened, since someone who pressed a button
/// deserves an answer.
class AppUpdateService {
  AppUpdateService._();

  /// The version the user has already said "Later" to. Never prompted again.
  static const String _kSkippedVersionKey = 'updateSkippedVersionCode';

  /// When we last put the prompt on screen, so a decline-by-back-button doesn't
  /// mean being asked again on the next launch.
  static const String _kLastPromptKey = 'updateLastPromptMs';

  static const Duration _minPromptInterval = Duration(hours: 24);

  /// Once per app run, whatever else happens.
  static bool _checkedThisRun = false;

  /// The startup check: silent unless there is genuinely something to install.
  static Future<void> maybePromptOnStartup(BuildContext context) async {
    if (_checkedThisRun) return;
    _checkedThisRun = true;

    final info = await _check();
    if (info == null || info.updateAvailability != UpdateAvailability.updateAvailable) return;

    final prefs = SharedPreferencesAsync();
    if (await prefs.getInt(_kSkippedVersionKey) == info.availableVersionCode) return;
    final last = await prefs.getInt(_kLastPromptKey) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - last < _minPromptInterval.inMilliseconds) return;

    if (!context.mounted) return;
    await _prompt(context, info);
  }

  /// The Settings entry. Always checks and always reports — including "you're
  /// up to date", which is the whole point of pressing it.
  static Future<void> checkManually(BuildContext context) async {
    final info = await _check();
    if (!context.mounted) return;
    if (info == null) {
      lpSnack(context, 'Could not reach Google Play. In-app updates need a build installed from the Play Store.', 5000);
      return;
    }
    if (info.updateAvailability != UpdateAvailability.updateAvailable) {
      lpSnack(context, "You're on the latest version.", 3000);
      return;
    }
    await _prompt(context, info);
  }

  static Future<AppUpdateInfo?> _check() async {
    if (!Platform.isAndroid) return null;
    try {
      return await InAppUpdate.checkForUpdate();
    } catch (_) {
      return null;
    }
  }

  static Future<void> _prompt(BuildContext context, AppUpdateInfo info) async {
    // Play can refuse both flows (e.g. a metered connection it won't download
    // over). Offering an Update button that can only fail is worse than saying
    // nothing on startup.
    if (!info.immediateUpdateAllowed && !info.flexibleUpdateAllowed) return;

    final stale = info.clientVersionStalenessDays ?? 0;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('A newer version of Katalaveno is on Google Play.'),
            if (stale > 0) ...[
              const SizedBox(height: 8),
              Text('Your version is $stale day${stale == 1 ? '' : 's'} old.', style: Theme.of(ctx).textTheme.bodySmall),
            ],
            const SizedBox(height: 12),
            Text(
              info.immediateUpdateAllowed
                  ? 'Google Play will install it and reopen the app.'
                  : 'It downloads in the background; you can keep using the app.',
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Update')),
        ],
      ),
    );

    final prefs = SharedPreferencesAsync();
    await prefs.setInt(_kLastPromptKey, DateTime.now().millisecondsSinceEpoch);
    if (go != true) {
      // Only an explicit "Later" retires this version — a back-button dismissal
      // leaves it to the 24h throttle, since it isn't really an answer.
      if (go == false && info.availableVersionCode != null) {
        await prefs.setInt(_kSkippedVersionKey, info.availableVersionCode!);
      }
      return;
    }
    if (!context.mounted) return;
    await _run(context, info);
  }

  static Future<void> _run(BuildContext context, AppUpdateInfo info) async {
    try {
      // Immediate whenever Play allows it: Play takes over the screen, installs
      // and relaunches, so there is no half-finished state left for us to
      // manage. Flexible is the fallback — it downloads in the background and
      // needs an explicit install step afterwards.
      if (info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
        return;
      }
      final result = await InAppUpdate.startFlexibleUpdate();
      // The future completes when the *download* finishes, which can be minutes
      // later — hence the mounted check before installing.
      if (result != AppUpdateResult.success) return;
      await InAppUpdate.completeFlexibleUpdate();
    } catch (_) {
      if (context.mounted) lpSnack(context, 'The update could not be started.', 4000);
    }
  }
}
