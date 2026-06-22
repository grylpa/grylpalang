import 'package:flutter/material.dart';

class AppSettings {
  // Books — Audio mode defaults (single source of truth; used by the
  // constructor, JSON fallback, and the Settings reset buttons).
  static const int kBooksRepeatCountDefault = 3;
  static const int kBooksSourcePauseSecDefault = 2;
  static const int kBooksRepeatDelaySecDefault = 3;
  static const int kBooksBetweenChunksPauseSecDefault = 3;

  String knownLanguage;
  String targetLanguage;
  Duration interval;
  bool showTranslation;
  bool useDarkMode;
  int simpleCount;
  int conjugatedCount;
  List<String> connectorWords;
  String aiApiKey; // Gemini key
  TimeOfDay dndStartTime;
  TimeOfDay dndEndTime;
  bool useDnd;
  Map<String, String> languageNameCache;
  bool modeClean;    // show full L2 sentence
  bool modeCloze;    // show L2 with target word blanked
  bool modeReverse;  // show L1 sentence as title

  // Sentence Bank settings
  String sentenceBankUrl;           // URL to fetch sentence_bank.yaml (empty = use bundled asset)
  String sentenceBankVoiceGender;   // 'male' | 'female' (fallback when no explicit source voice)
  String sentenceBankSourceVoice;   // chosen source-language TTS voice "namelocale" ('' = auto)
  bool sentenceBankSpeakSource;     // in auto mode, speak the source sentence before the translation
  int? sentenceBankTtsRepeatCountOverride; // overrides tts_repeat_count from YAML (null = use YAML value)
  int? sentenceBankSourcePauseOverride; // overrides auto_source_pause from YAML (null = use YAML value)
  int? sentenceBankTtsRepeatDelayOverride; // overrides tts_repeat_delay from YAML (null = use YAML value)
  bool sentenceBankShuffle;             // randomize sentence order within subject
  bool sentenceBankRepeatSourceBetween; // also replay the source before every target repeat (off by default)

  // Books mode (Phase 3 audio playback). All times in seconds.
  String booksChunkUnit;                // 'sentence' | 'paragraph'
  int booksRepeatCount;                 // times each side (source + target) is repeated
  int booksSourcePauseSec;              // pause between source and target TTS
  int booksRepeatDelaySec;              // pause between repeats of the same side
  int booksBetweenChunksPauseSec;       // pause after target before the next chunk
  bool booksForceShortSentences;        // split sentence chunks further on inner punctuation (off by default)
  // Selected TTS voice keyed by BCP-47 locale (e.g. 'en-US', 'el-GR'). The
  // voice value is the flutter_tts voice name as returned by getVoices().
  Map<String, String> booksVoiceByLocale;

  AppSettings({
    required this.knownLanguage,
    required this.targetLanguage,
    required this.interval,
    required this.showTranslation,
    required this.useDarkMode,
    required this.simpleCount,
    required this.conjugatedCount,
    required this.connectorWords,
    required this.aiApiKey,
    required this.dndStartTime,
    required this.dndEndTime,
    required this.useDnd,
    required this.languageNameCache,
    required this.modeClean,
    required this.modeCloze,
    required this.modeReverse,
    required this.sentenceBankUrl,
    required this.sentenceBankVoiceGender,
    this.sentenceBankSourceVoice = '',
    required this.sentenceBankSpeakSource,
    this.sentenceBankTtsRepeatCountOverride,
    this.sentenceBankSourcePauseOverride,
    this.sentenceBankTtsRepeatDelayOverride,
    required this.sentenceBankShuffle,
    this.sentenceBankRepeatSourceBetween = false,
    this.booksChunkUnit = 'sentence',
    this.booksRepeatCount = kBooksRepeatCountDefault,
    this.booksSourcePauseSec = kBooksSourcePauseSecDefault,
    this.booksRepeatDelaySec = kBooksRepeatDelaySecDefault,
    this.booksBetweenChunksPauseSec = kBooksBetweenChunksPauseSecDefault,
    this.booksForceShortSentences = false,
    Map<String, String>? booksVoiceByLocale,
  }) : booksVoiceByLocale = booksVoiceByLocale ?? <String, String>{};

  AppSettings copyWith({
    String? knownLanguage,
    String? targetLanguage,
    Duration? interval,
    bool? showTranslation,
    bool? useDarkMode,
    int? simpleCount,
    int? conjugatedCount,
    List<String>? connectorWords,
    String? aiApiKey,
    TimeOfDay? dndStartTime,
    TimeOfDay? dndEndTime,
    bool? useDnd,
    Map<String, String>? languageNameCache,
    bool? modeClean,
    bool? modeCloze,
    bool? modeReverse,
    String? sentenceBankUrl,
    String? sentenceBankVoiceGender,
    String? sentenceBankSourceVoice,
    bool? sentenceBankSpeakSource,
    Object? sentenceBankTtsRepeatCountOverride = _keep,
    Object? sentenceBankSourcePauseOverride = _keep,
    Object? sentenceBankTtsRepeatDelayOverride = _keep,
    bool? sentenceBankShuffle,
    bool? sentenceBankRepeatSourceBetween,
    String? booksChunkUnit,
    int? booksRepeatCount,
    int? booksSourcePauseSec,
    int? booksRepeatDelaySec,
    int? booksBetweenChunksPauseSec,
    bool? booksForceShortSentences,
    Map<String, String>? booksVoiceByLocale,
  }) {
    return AppSettings(
      knownLanguage: knownLanguage ?? this.knownLanguage,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      interval: interval ?? this.interval,
      showTranslation: showTranslation ?? this.showTranslation,
      useDarkMode: useDarkMode ?? this.useDarkMode,
      simpleCount: simpleCount ?? this.simpleCount,
      conjugatedCount: conjugatedCount ?? this.conjugatedCount,
      connectorWords: connectorWords ?? this.connectorWords,
      aiApiKey: aiApiKey ?? this.aiApiKey,
      dndStartTime: dndStartTime ?? this.dndStartTime,
      dndEndTime: dndEndTime ?? this.dndEndTime,
      useDnd: useDnd ?? this.useDnd,
      languageNameCache: languageNameCache ?? this.languageNameCache,
      modeClean: modeClean ?? this.modeClean,
      modeCloze: modeCloze ?? this.modeCloze,
      modeReverse: modeReverse ?? this.modeReverse,
      sentenceBankUrl: sentenceBankUrl ?? this.sentenceBankUrl,
      sentenceBankVoiceGender: sentenceBankVoiceGender ?? this.sentenceBankVoiceGender,
      sentenceBankSourceVoice: sentenceBankSourceVoice ?? this.sentenceBankSourceVoice,
      sentenceBankSpeakSource: sentenceBankSpeakSource ?? this.sentenceBankSpeakSource,
      sentenceBankTtsRepeatCountOverride: identical(sentenceBankTtsRepeatCountOverride, _keep)
          ? this.sentenceBankTtsRepeatCountOverride
          : sentenceBankTtsRepeatCountOverride as int?,
      sentenceBankSourcePauseOverride: identical(sentenceBankSourcePauseOverride, _keep)
          ? this.sentenceBankSourcePauseOverride
          : sentenceBankSourcePauseOverride as int?,
      sentenceBankTtsRepeatDelayOverride: identical(sentenceBankTtsRepeatDelayOverride, _keep)
          ? this.sentenceBankTtsRepeatDelayOverride
          : sentenceBankTtsRepeatDelayOverride as int?,
      sentenceBankShuffle: sentenceBankShuffle ?? this.sentenceBankShuffle,
      sentenceBankRepeatSourceBetween: sentenceBankRepeatSourceBetween ?? this.sentenceBankRepeatSourceBetween,
      booksChunkUnit: booksChunkUnit ?? this.booksChunkUnit,
      booksRepeatCount: booksRepeatCount ?? this.booksRepeatCount,
      booksSourcePauseSec: booksSourcePauseSec ?? this.booksSourcePauseSec,
      booksRepeatDelaySec: booksRepeatDelaySec ?? this.booksRepeatDelaySec,
      booksBetweenChunksPauseSec: booksBetweenChunksPauseSec ?? this.booksBetweenChunksPauseSec,
      booksForceShortSentences: booksForceShortSentences ?? this.booksForceShortSentences,
      booksVoiceByLocale: booksVoiceByLocale ?? Map.of(this.booksVoiceByLocale),
    );
  }

  static const Object _keep = Object();

  Map<String, dynamic> toJson() => {
    'knownLanguage': knownLanguage,
    'targetLanguage': targetLanguage,
    'intervalSeconds': interval.inSeconds,
    'showTranslation': showTranslation,
    'useDarkMode': useDarkMode,
    'simpleCount': simpleCount,
    'conjugatedCount': conjugatedCount,
    'connectorWords': connectorWords,
    'aiApiKey': aiApiKey,
    'dndStartMinutes': dndStartTime.hour * 60 + dndStartTime.minute,
    'dndEndMinutes': dndEndTime.hour * 60 + dndEndTime.minute,
    'useDnd': useDnd,
    'languageNameCache': languageNameCache,
    'modeClean': modeClean,
    'modeCloze': modeCloze,
    'modeReverse': modeReverse,
    'sentenceBankUrl': sentenceBankUrl,
    'sentenceBankVoiceGender': sentenceBankVoiceGender,
    'sentenceBankSourceVoice': sentenceBankSourceVoice,
    'sentenceBankSpeakSource': sentenceBankSpeakSource,
    'sentenceBankTtsRepeatCountOverride': sentenceBankTtsRepeatCountOverride,
    'sentenceBankSourcePauseOverride': sentenceBankSourcePauseOverride,
    'sentenceBankTtsRepeatDelayOverride': sentenceBankTtsRepeatDelayOverride,
    'sentenceBankShuffle': sentenceBankShuffle,
    'sentenceBankRepeatSourceBetween': sentenceBankRepeatSourceBetween,
    'booksChunkUnit': booksChunkUnit,
    'booksRepeatCount': booksRepeatCount,
    'booksSourcePauseSec': booksSourcePauseSec,
    'booksRepeatDelaySec': booksRepeatDelaySec,
    'booksBetweenChunksPauseSec': booksBetweenChunksPauseSec,
    'booksForceShortSentences': booksForceShortSentences,
    'booksVoiceByLocale': booksVoiceByLocale,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final startM = (json['dndStartMinutes'] as int?) ?? (22 * 60);
    final endM = (json['dndEndMinutes'] as int?) ?? (6 * 60);
    final rawCache = json['languageNameCache'];
    final cache = (rawCache is Map)
        ? rawCache.map((k, v) => MapEntry(k.toString(), v.toString()))
        : <String, String>{};
    final appSettings = AppSettings(
      knownLanguage: json['knownLanguage'] as String? ?? 'English',
      targetLanguage: json['targetLanguage'] as String? ?? 'Greek',
      interval: Duration(seconds: (json['intervalSeconds'] as int?) ?? 3600),
      showTranslation: json['showTranslation'] as bool? ?? false,
      useDarkMode: json['useDarkMode'] as bool? ?? true,
      simpleCount: json['simpleCount'] as int? ?? 3,
      conjugatedCount: json['conjugatedCount'] as int? ?? 20,
      connectorWords: (json['connectorWords'] as List?)?.cast<String>() ?? <String>[],
      aiApiKey: json['aiApiKey'] as String? ?? '',
      dndStartTime: TimeOfDay(hour: startM ~/ 60, minute: startM % 60),
      dndEndTime: TimeOfDay(hour: endM ~/ 60, minute: endM % 60),
      useDnd: json['useDnd'] as bool? ?? true,
      languageNameCache: cache,
      modeClean: json['modeClean'] as bool? ?? true,
      modeCloze: json['modeCloze'] as bool? ?? true,
      modeReverse: json['modeReverse'] as bool? ?? true,
      sentenceBankUrl: json['sentenceBankUrl'] as String? ?? '',
      sentenceBankVoiceGender: json['sentenceBankVoiceGender'] as String? ?? 'female',
      sentenceBankSourceVoice: json['sentenceBankSourceVoice'] as String? ?? '',
      sentenceBankSpeakSource: json['sentenceBankSpeakSource'] as bool? ?? true,
      // Migration: if the new override key is absent, fall back to the
      // pre-override `sentenceBankTtsRepeatCount` value so the user's choice
      // is preserved across the upgrade.
      sentenceBankTtsRepeatCountOverride: json.containsKey('sentenceBankTtsRepeatCountOverride')
          ? json['sentenceBankTtsRepeatCountOverride'] as int?
          : json['sentenceBankTtsRepeatCount'] as int?,
      sentenceBankSourcePauseOverride: json['sentenceBankSourcePauseOverride'] as int?,
      sentenceBankTtsRepeatDelayOverride: json['sentenceBankTtsRepeatDelayOverride'] as int?,
      sentenceBankShuffle: json['sentenceBankShuffle'] as bool? ?? true,
      sentenceBankRepeatSourceBetween: json['sentenceBankRepeatSourceBetween'] as bool? ?? false,
      booksChunkUnit: json['booksChunkUnit'] as String? ?? 'sentence',
      booksRepeatCount: (json['booksRepeatCount'] as int?) ?? kBooksRepeatCountDefault,
      booksSourcePauseSec: (json['booksSourcePauseSec'] as int?) ?? kBooksSourcePauseSecDefault,
      booksRepeatDelaySec: (json['booksRepeatDelaySec'] as int?) ?? kBooksRepeatDelaySecDefault,
      booksBetweenChunksPauseSec: (json['booksBetweenChunksPauseSec'] as int?) ?? kBooksBetweenChunksPauseSecDefault,
      booksForceShortSentences: json['booksForceShortSentences'] as bool? ?? false,
      booksVoiceByLocale: (json['booksVoiceByLocale'] as Map?)
              ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
          <String, String>{},
    );
    return appSettings;
  }

  static AppSettings defaults() {
    return AppSettings(
      knownLanguage: 'English',
      targetLanguage: 'Greek',
      interval: const Duration(hours: 3),
      showTranslation: false,
      useDarkMode: true,
      simpleCount: 3,
      conjugatedCount: 20,
      connectorWords: [],
      aiApiKey: '',
      dndStartTime: TimeOfDay(hour: 22, minute: 0),
      dndEndTime: TimeOfDay(hour: 6, minute: 0),
      useDnd: true,
      languageNameCache: <String, String>{},
      modeClean: true,
      modeCloze: true,
      modeReverse: true,
      sentenceBankUrl: '',
      sentenceBankVoiceGender: 'female',
      sentenceBankSpeakSource: true,
      sentenceBankShuffle: true,
    );
  }
}
