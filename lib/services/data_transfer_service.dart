import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Exports and restores everything the app has stored.
///
/// Everything durable in Katalaveno lives in one `SharedPreferencesAsync`
/// store — settings and API key, words, notification snapshots and history, the
/// sentence-bank translation cache and positions, Listen's stories and reserve,
/// book positions — so one dump of that store is a complete backup. Files the
/// app has *downloaded* (Gutenberg EPUBs, synthesized TTS clips, Google
/// Translate audio) are deliberately left out: they are caches that rebuild
/// themselves, and they dwarf the data that can't be recreated.
///
/// The reason this exists: a different `applicationId` — the `dev` flavor — is a
/// different Android sandbox, so there is no way for one build to read another's
/// data. Exporting and importing is the only unrooted path between them.
class DataTransferService {
  DataTransferService._();

  /// Bumped only if the on-disk shape changes incompatibly.
  static const int formatVersion = 1;
  static const String _magic = 'katalaveno-backup';

  /// Writes a backup into the temp directory and returns it, ready to be handed
  /// to the share sheet. Temp is right: the file only has to survive long enough
  /// for the user to save it somewhere real.
  static Future<File> writeBackup({String appVersion = ''}) async {
    final all = await SharedPreferencesAsync().getAll();
    final entries = <String, dynamic>{};
    for (final e in all.entries) {
      final v = e.value;
      // Typed on the way out, because JSON can't tell an int from a double and
      // SharedPreferences setters are type-specific: a double written back as
      // an int would throw on the next read.
      if (v is String) {
        entries[e.key] = {'t': 's', 'v': v};
      } else if (v is int) {
        entries[e.key] = {'t': 'i', 'v': v};
      } else if (v is double) {
        entries[e.key] = {'t': 'd', 'v': v};
      } else if (v is bool) {
        entries[e.key] = {'t': 'b', 'v': v};
      } else if (v is List<String>) {
        entries[e.key] = {'t': 'l', 'v': v};
      }
    }

    final stamp = DateTime.now().toIso8601String().substring(0, 16).replaceAll(RegExp('[:T]'), '-');
    final file = File('${(await getTemporaryDirectory()).path}/katalaveno-backup-$stamp.json');
    await file.writeAsString(
      jsonEncode({
        'app': _magic,
        'format': formatVersion,
        'created': DateTime.now().toIso8601String(),
        'appVersion': appVersion,
        'entries': entries,
      }),
    );
    return file;
  }

  /// Replaces every stored value with the backup's contents.
  ///
  /// A restore, not a merge: the store is cleared first, so what comes back is
  /// exactly the state the backup was taken in rather than a blend of two
  /// installs. Returns how many keys were written.
  static Future<int> restore(File file) async {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map || decoded['app'] != _magic) {
      throw Exception('Not a Katalaveno backup file.');
    }
    final format = decoded['format'] as int? ?? 0;
    if (format > formatVersion) {
      throw Exception('This backup was made by a newer version of the app.');
    }
    final entries = decoded['entries'];
    if (entries is! Map || entries.isEmpty) throw Exception('The backup is empty.');

    final prefs = SharedPreferencesAsync();
    await prefs.clear();
    var written = 0;
    for (final e in entries.entries) {
      final key = e.key.toString();
      final rec = e.value;
      if (rec is! Map) continue;
      final value = rec['v'];
      switch (rec['t']) {
        case 's' when value is String:
          await prefs.setString(key, value);
        case 'i' when value is num:
          await prefs.setInt(key, value.toInt());
        case 'd' when value is num:
          await prefs.setDouble(key, value.toDouble());
        case 'b' when value is bool:
          await prefs.setBool(key, value);
        case 'l' when value is List:
          await prefs.setStringList(key, [for (final x in value) x.toString()]);
        default:
          continue;
      }
      written++;
    }
    return written;
  }
}
