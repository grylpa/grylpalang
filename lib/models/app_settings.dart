import 'package:flutter/material.dart';

class AppSettings {
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
  String sentenceBankVoiceGender;   // 'male' | 'female'
  bool sentenceBankSpeakSource;     // in auto mode, speak the source sentence before the translation
  int? sentenceBankTtsRepeatCountOverride; // overrides tts_repeat_count from YAML (null = use YAML value)
  int? sentenceBankSourcePauseOverride; // overrides auto_source_pause from YAML (null = use YAML value)
  int? sentenceBankTtsRepeatDelayOverride; // overrides tts_repeat_delay from YAML (null = use YAML value)
  bool sentenceBankShuffle;             // randomize sentence order within subject

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
    required this.sentenceBankSpeakSource,
    this.sentenceBankTtsRepeatCountOverride,
    this.sentenceBankSourcePauseOverride,
    this.sentenceBankTtsRepeatDelayOverride,
    required this.sentenceBankShuffle,
  });

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
    bool? sentenceBankSpeakSource,
    Object? sentenceBankTtsRepeatCountOverride = _keep,
    Object? sentenceBankSourcePauseOverride = _keep,
    Object? sentenceBankTtsRepeatDelayOverride = _keep,
    bool? sentenceBankShuffle,
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
    'sentenceBankSpeakSource': sentenceBankSpeakSource,
    'sentenceBankTtsRepeatCountOverride': sentenceBankTtsRepeatCountOverride,
    'sentenceBankSourcePauseOverride': sentenceBankSourcePauseOverride,
    'sentenceBankTtsRepeatDelayOverride': sentenceBankTtsRepeatDelayOverride,
    'sentenceBankShuffle': sentenceBankShuffle,
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
      sentenceBankSpeakSource: json['sentenceBankSpeakSource'] as bool? ?? false,
      // Migration: if the new override key is absent, fall back to the
      // pre-override `sentenceBankTtsRepeatCount` value so the user's choice
      // is preserved across the upgrade.
      sentenceBankTtsRepeatCountOverride: json.containsKey('sentenceBankTtsRepeatCountOverride')
          ? json['sentenceBankTtsRepeatCountOverride'] as int?
          : json['sentenceBankTtsRepeatCount'] as int?,
      sentenceBankSourcePauseOverride: json['sentenceBankSourcePauseOverride'] as int?,
      sentenceBankTtsRepeatDelayOverride: json['sentenceBankTtsRepeatDelayOverride'] as int?,
      sentenceBankShuffle: json['sentenceBankShuffle'] as bool? ?? false,
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
      sentenceBankSpeakSource: false,
      sentenceBankShuffle: false,
    );
  }
}
