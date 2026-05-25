import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class BlobStore {
  static Directory? _dir;

  static Future<Directory> _getDir() async {
    return _dir ??= await getApplicationDocumentsDirectory();
  }

  static Future<File> _file(String name) async {
    final dir = await _getDir();
    return File('${dir.path}/$name.json');
  }

  static Future<Map<String, dynamic>?> readJsonMap(String name) async {
    final f = await _file(name);
    if (!await f.exists()) return null;
    final s = await f.readAsString();
    return jsonDecode(s) as Map<String, dynamic>;
  }

  static Future<List<dynamic>?> readJsonList(String name) async {
    final f = await _file(name);
    if (!await f.exists()) return null;
    final s = await f.readAsString();
    return jsonDecode(s) as List<dynamic>;
  }

  static Future<String?> readJsonString(String name) async {
    final f = await _file(name);
    if (!await f.exists()) return null;
    final s = await f.readAsString();
    return s;
  }

  static Future<void> writeJson(String name, Object value) async {
    final f = await _file(name);
    await f.writeAsString(jsonEncode(value), flush: true);
  }
}
