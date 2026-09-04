import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/listen_story.dart';

/// Storage for Listen mode: its own subject selection, its generated story
/// bank, and the resume position.
///
/// Deliberately separate from [SentenceBankService]'s keys even though the
/// subject *list* is shared — Listen and Sentences are studied independently,
/// so selecting three subjects here must not disturb what Sentences is playing.
class ListenService {
  ListenService(this._prefs);

  final SharedPreferencesAsync _prefs;

  static const String _kSelectedSubjectsKey = 'listenSelectedSubjects';
  static String _storiesKey(String targetLang) => 'listenStories_$targetLang';
  static String _positionKey(String targetLang) => 'listenPosition_$targetLang';

  // ── Subject selection (independent of the Sentences tab) ──────────────────

  Future<void> saveSelectedSubjects(List<String> subjects) async {
    await _prefs.setString(_kSelectedSubjectsKey, jsonEncode(subjects));
  }

  /// The saved selection, or null if the user has never chosen one here.
  Future<List<String>?> loadSelectedSubjects() async {
    final raw = await _prefs.getString(_kSelectedSubjectsKey);
    if (raw == null) return null;
    try {
      return (jsonDecode(raw) as List).cast<String>();
    } catch (_) {
      return null;
    }
  }

  // ── Generated stories ─────────────────────────────────────────────────────
  //
  // Keyed by target language: the same subjects generate entirely different
  // texts for Greek and for German, and switching languages must not silently
  // replay the wrong bank.

  Future<List<ListenStory>> loadStories(String targetLang) async {
    final raw = await _prefs.getString(_storiesKey(targetLang));
    if (raw == null) return [];
    try {
      return [for (final e in jsonDecode(raw) as List) ListenStory.fromJson((e as Map).cast<String, dynamic>())];
    } catch (_) {
      return [];
    }
  }

  Future<void> saveStories(String targetLang, List<ListenStory> stories) async {
    await _prefs.setString(_storiesKey(targetLang), jsonEncode([for (final s in stories) s.toJson()]));
  }

  Future<void> clearStories(String targetLang) async {
    await _prefs.remove(_storiesKey(targetLang));
    await _prefs.remove(_positionKey(targetLang));
    await _prefs.remove(_reserveKey(targetLang));
  }

  // ── Reserve ───────────────────────────────────────────────────────────────
  //
  // Generated-but-not-yet-handed-out texts. One request that returns 24 costs
  // barely more than one returning 8 — the seed vocabulary that dominates the
  // prompt is sent once either way — so we over-fetch and hand out the user's
  // chosen batch size from here. Later top-ups are then instant and work with
  // no signal at all.
  //
  // Stored with the subject selection it was generated for: material written
  // against a different pool isn't valid for the current one, so a mismatch
  // discards it rather than quietly serving off-topic texts.

  static String _reserveKey(String targetLang) => 'listenReserve_$targetLang';

  Future<({String selectionSig, List<ListenStory> stories})> loadReserve(String targetLang) async {
    final raw = await _prefs.getString(_reserveKey(targetLang));
    if (raw == null) return (selectionSig: '', stories: <ListenStory>[]);
    try {
      final map = (jsonDecode(raw) as Map).cast<String, dynamic>();
      return (
        selectionSig: map['sig'] as String? ?? '',
        stories: [
          for (final e in (map['stories'] as List?) ?? const [])
            ListenStory.fromJson((e as Map).cast<String, dynamic>()),
        ],
      );
    } catch (_) {
      return (selectionSig: '', stories: <ListenStory>[]);
    }
  }

  Future<void> saveReserve(String targetLang, String selectionSig, List<ListenStory> stories) async {
    if (stories.isEmpty) {
      await _prefs.remove(_reserveKey(targetLang));
      return;
    }
    await _prefs.setString(
      _reserveKey(targetLang),
      jsonEncode({
        'sig': selectionSig,
        'stories': [for (final s in stories) s.toJson()],
      }),
    );
  }

  // ── Resume position ───────────────────────────────────────────────────────
  //
  // Stored as the story's text, not its index: regenerating the bank or
  // deselecting a subject renumbers everything.

  Future<void> savePosition(String targetLang, String storyKey) async {
    await _prefs.setString(_positionKey(targetLang), storyKey);
  }

  Future<String?> loadPosition(String targetLang) => _prefs.getString(_positionKey(targetLang));
}
