// lib/services/app_storage.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/app_settings.dart';
import '../models/history_entry.dart';
import '../models/notification_snapshot.dart';
import '../models/word_entry.dart';

class AppStorage {
  static const _keySettings = 'settings';
  static const _keyWords = 'words';
  static const _keySnapshots = 'notificationSnapshots';
  static const _keyHistory = 'notificationHistory';

  final SharedPreferencesAsync prefs;

  AppStorage(this.prefs);

  // -------------- Settings --------------

  Future<void> clearSharedPrefs() async {
    await prefs.clear();
  }

  Future<AppSettings> loadSettings() async {
    final s = await prefs.getString(_keySettings);
    if (s == null) return AppSettings.defaults();
    try {
      final jsonStr = jsonDecode(s) as Map<String, dynamic>;
      return AppSettings.fromJson(jsonStr);
    } catch (_) {
      return AppSettings.defaults();
    }
  }

  Future<void> saveSettings(AppSettings settings) async {
    await prefs.setString(_keySettings, jsonEncode(settings.toJson()));
  }

  // -------------- Words --------------

  Future<List<WordEntry>> loadWords() async {
    final s = await prefs.getString(_keyWords);
    if (s == null) return [];
    try {
      final list = (jsonDecode(s) as List).cast<Map<String, dynamic>>();
      return list.map(WordEntry.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveWords(List<WordEntry> words) async {
    await prefs.setString(_keyWords, jsonEncode(words.map((e) => e.toJson()).toList()));
  }

  // -------------- Notification snapshots --------------

  Future<List<NotificationSnapshot>> loadSnapshots() async {
    final s = await prefs.getString(_keySnapshots);
    if (s == null) return [];
    try {
      final list = (jsonDecode(s) as List).cast<Map<String, dynamic>>();
      return list.map(NotificationSnapshot.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSnapshots(List<NotificationSnapshot> snaps) async {
    await prefs.setString(_keySnapshots, jsonEncode(snaps.map((e) => e.toJson()).toList()));
  }

  Future<List<HistoryEntry>> loadHistory() async {
    final s = await prefs.getString(_keyHistory);
    if (s == null || s.isEmpty) return [];
    try {
      final list = (jsonDecode(s) as List).cast<Map<String, dynamic>>();
      return list.map(HistoryEntry.fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveHistory(List<HistoryEntry> history) async {
    await prefs.setString(_keyHistory, jsonEncode(history.map((e) => e.toJson()).toList()));
  }
}
