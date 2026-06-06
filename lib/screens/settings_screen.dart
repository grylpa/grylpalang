import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/ai_service.dart';
import '../state/app_state.dart';
import '../widgets.dart';
import 'policies_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

Future<void> _showAbout(BuildContext context) async {
  final info = await PackageInfo.fromPlatform();
  // Android always reports some buildNumber (defaults to "1" when pubspec omits
  // `+N`), so we can't tell from PackageInfo alone whether the developer set a
  // build number. Bundle pubspec.yaml and look at the version line directly.
  final pubspec = await rootBundle.loadString('pubspec.yaml');
  final versionLine = pubspec
      .split('\n')
      .firstWhere((l) => l.trimLeft().startsWith('version:'), orElse: () => '');
  final hasExplicitBuild = versionLine.contains('+');
  if (!context.mounted) return;
  showAboutDialog(
    context: context,
    applicationName: 'Katalaveno',
    applicationVersion: hasExplicitBuild ? '${info.version} (build ${info.buildNumber})' : info.version,
    applicationIcon: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.asset('assets/icon.png', width: 48, height: 48),
    ),
    applicationLegalese: '© ${DateTime.now().year} Katalaveno',
    children: const [
      SizedBox(height: 12),
      Text(
        'A spaced-repetition vocabulary trainer that uses AI to generate '
        'example sentences and reinforces them through scheduled notifications '
        'and an interactive sentence bank.',
      ),
      SizedBox(height: 12),
      Text(
        'Built with Flutter. AI by Google Gemini.',
      ),
    ],
  );
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _knownCtrl;
  late TextEditingController _targetCtrl;
  late TextEditingController _intervalCtrl;
  String _intervalUnit = 'hours';

  late TextEditingController _numSentencesCtrl;
  late TextEditingController _connectorCtrl;
  late TextEditingController _apiKeyCtrl;
  late TextEditingController _sbUrlCtrl;

  bool _addingConnector = false;
  bool _savingSettings = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().settings;
    _knownCtrl = TextEditingController(text: s.knownLanguage);
    _targetCtrl = TextEditingController(text: s.targetLanguage);

    final d = s.interval;
    if (d.inHours >= 24) {
      _intervalUnit = 'days';
      _intervalCtrl = TextEditingController(text: d.inDays.toString());
    } else if (d.inMinutes >= 60) {
      _intervalUnit = 'hours';
      _intervalCtrl = TextEditingController(text: d.inHours.toString());
    } else {
      _intervalUnit = 'minutes';
      _intervalCtrl = TextEditingController(text: d.inMinutes.toString());
    }

    _numSentencesCtrl = TextEditingController(text: (s.simpleCount + s.conjugatedCount).toString());
    _connectorCtrl = TextEditingController();
    _apiKeyCtrl = TextEditingController(text: s.aiApiKey);
    _sbUrlCtrl = TextEditingController(text: s.sentenceBankUrl);
    _sbUrlCtrl.addListener(() { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _knownCtrl.dispose();
    _targetCtrl.dispose();
    _intervalCtrl.dispose();
    _numSentencesCtrl.dispose();
    _connectorCtrl.dispose();
    _apiKeyCtrl.dispose();
    _sbUrlCtrl.dispose();
    super.dispose();
  }

  Duration _intervalFromFields() {
    final n = int.tryParse(_intervalCtrl.text.trim());
    final v = (n == null || n <= 0) ? 1 : n;
    switch (_intervalUnit) {
      case 'minutes':
        return Duration(minutes: v);
      case 'days':
        return Duration(days: v);
      case 'hours':
      default:
        return Duration(hours: v);
    }
  }

  Widget _section(String title, List<Widget> children) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        shape: const Border(),
        collapsedShape: const Border(),
        maintainState: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    final titleStyle = Theme.of(context).textTheme.titleMedium;

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // ── Languages & Schedule ────────────────────────────────────
                  _section('Languages & Schedule', [
                    Row(
                      children: [
                        Expanded(
                          child: filledTF(
                            context,
                            controller: _knownCtrl,
                            labelText: 'Known language',
                            style: titleStyle,
                            suffixIcon: _savingSettings ? tinySpinner() : null,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: filledTF(
                            context,
                            controller: _targetCtrl,
                            labelText: 'Target language',
                            style: titleStyle,
                            suffixIcon: _savingSettings ? tinySpinner() : null,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text('Interval:', style: titleStyle),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 80,
                          child: TextField(
                            decoration: tfDecor(context),
                            controller: _intervalCtrl,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 20),
                        DropdownButton<String>(
                          focusColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          value: _intervalUnit,
                          onChanged: (val) {
                            if (val == null) return;
                            setState(() => _intervalUnit = val);
                          },
                          items: const [
                            DropdownMenuItem(value: 'minutes', child: Text('minutes')),
                            DropdownMenuItem(value: 'hours', child: Text('hours')),
                            DropdownMenuItem(value: 'days', child: Text('days')),
                          ],
                        ),
                      ],
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Translation in notifications', maxLines: 1),
                      value: s.showTranslation,
                      onChanged: (v) => state.updateSettings(s.copyWith(showTranslation: v)),
                    ),
                  ]),

                  // ── Notification style ──────────────────────────────────────
                  _section('Notification style', [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Read: See the target language', style: textStyle),
                      value: s.modeClean,
                      onChanged: (v) {
                        if (!v && !s.modeCloze && !s.modeReverse) {
                          lpSnack(context, 'At least one style must be enabled.', 3000);
                          return;
                        }
                        state.updateSettings(s.copyWith(modeClean: v));
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Complete: Guess the missing word', style: textStyle),
                      value: s.modeCloze,
                      onChanged: (v) {
                        if (!v && !s.modeClean && !s.modeReverse) {
                          lpSnack(context, 'At least one style must be enabled.', 3000);
                          return;
                        }
                        state.updateSettings(s.copyWith(modeCloze: v));
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Translate: See your known language', style: textStyle),
                      value: s.modeReverse,
                      onChanged: (v) {
                        if (!v && !s.modeClean && !s.modeCloze) {
                          lpSnack(context, 'At least one style must be enabled.', 3000);
                          return;
                        }
                        state.updateSettings(s.copyWith(modeReverse: v));
                      },
                    ),
                  ]),

                  // ── Vocabulary ──────────────────────────────────────────────
                  _section('Vocabulary', [
                    Row(
                      children: [
                        Expanded(child: Text('Sentences to create:', style: titleStyle)),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 80,
                          child: TextField(
                            decoration: tfDecor(context),
                            controller: _numSentencesCtrl,
                            keyboardType: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Preferred connector words', style: titleStyle),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      children: s.connectorWords
                          .map((w) => Chip(
                                label: Text(w),
                                onDeleted: () => context.read<AppState>().removeConnectorWord(w),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: filledTF(
                            context,
                            controller: _connectorCtrl,
                            suffixIcon: _addingConnector ? tinySpinner() : null,
                            style: Theme.of(context).textTheme.labelSmall,
                            hintText: 'Phonetic, comma/space separated',
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton.filled(
                          icon: const Icon(Icons.add),
                          onPressed: _addingConnector
                              ? null
                              : () async {
                                  final raw = _connectorCtrl.text.trim();
                                  if (raw.isEmpty) return;
                                  final appState = context.read<AppState>();
                                  final apiKey = appState.settings.aiApiKey.trim();
                                  if (apiKey.isEmpty) {
                                    lpSnack(context, 'Set your Gemini API key first in AI settings.', 4000);
                                    return;
                                  }
                                  FocusScope.of(context).unfocus();
                                  final parts = raw
                                      .split(RegExp(r'[, \t\n]+'))
                                      .map((w) => w.trim())
                                      .where((w) => w.isNotEmpty)
                                      .toList();
                                  if (parts.isEmpty) return;
                                  setState(() => _addingConnector = true);
                                  final added = <String, String>{};
                                  try {
                                    for (final p in parts) {
                                      final normalized = await AiService.normalizeWordToTargetScript(
                                        apiKey: apiKey,
                                        word: p,
                                        targetLanguage: appState.settings.targetLanguage,
                                      );
                                      await appState.addConnectorWord(normalized);
                                      added[p] = normalized;
                                    }
                                    _connectorCtrl.clear();
                                    if (context.mounted) {
                                      final msg = added.entries.map((e) => '${e.key} → ${e.value}').join(', ');
                                      lpSnack(context, msg, 4000);
                                    }
                                  } catch (e) {
                                    if (context.mounted) lpSnack(context, 'AI error (connector): $e', 8000);
                                  } finally {
                                    if (mounted) setState(() => _addingConnector = false);
                                  }
                                },
                        ),
                      ],
                    ),
                  ]),

                  // ── Appearance ──────────────────────────────────────────────
                  _section('Appearance', [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Dark mode', style: titleStyle),
                      value: s.useDarkMode,
                      onChanged: (v) => state.updateSettings(s.copyWith(useDarkMode: v)),
                    ),
                  ]),

                  // ── AI Engine ───────────────────────────────────────────────
                  _section('AI engine', [
                    Text(
                      'This app uses Google Gemini to generate example sentences. '
                      'You can get a free personal API key (no credit card needed).',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Get a free Gemini API key'),
                        onPressed: () => launchUrl(
                          Uri.parse('https://aistudio.google.com/apikey'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    filledTF(
                      context,
                      controller: _apiKeyCtrl,
                      labelText: 'Gemini API key',
                      obscureText: !state.showApiKey,
                      style: titleStyle,
                      onChanged: (value) => state.updateSettings(s.copyWith(aiApiKey: value.trim())),
                      suffixIcon: IconButton(
                        onPressed: () => setState(() => state.showApiKey = !state.showApiKey),
                        icon: Icon(state.showApiKey ? Icons.visibility : Icons.visibility_off),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        FilledButton(
                          onPressed: () async {
                            final ok = await AiService.testApiKey(_apiKeyCtrl.text.trim());
                            if (!context.mounted) return;
                            lpSnack(context, ok ? 'API key is valid.' : 'API key seems invalid or blocked.', 4000);
                          },
                          child: const Text('Test key'),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _apiKeyCtrl.text.trim().isEmpty
                                ? 'No key set.'
                                : 'Key is stored locally and used only for generating sentences and translations.',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ]),

                  // ── Sentence Bank ───────────────────────────────────────────
                  _section('Sentence Bank', [
                    Text(
                      'Optionally host your own sentence_bank.yaml online (GitHub Gist, '
                      'Dropbox public link, etc.) and paste the raw URL below. '
                      'Leave empty to use the built-in sentence bank.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    filledTF(
                      context,
                      controller: _sbUrlCtrl,
                      labelText: 'Sentence bank URL (optional)',
                      style: textStyle,
                      suffixIcon: _sbUrlCtrl.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              tooltip: 'Clear URL (use built-in bank)',
                              onPressed: () {
                                _sbUrlCtrl.clear();
                                final appState = context.read<AppState>();
                                appState.saveSettingsOnly(appState.settings.copyWith(sentenceBankUrl: ''));
                                appState.triggerSentenceBankReload();
                              },
                            )
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        OutlinedButton.icon(
                          icon: const Icon(Icons.refresh),
                          label: const Text('Reload sentence bank'),
                          onPressed: () {
                            state.saveSettingsOnly(s.copyWith(sentenceBankUrl: _sbUrlCtrl.text.trim()));
                            state.triggerSentenceBankReload();
                            lpSnack(context, 'Sentence bank reloading…', 3000);
                          },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.translate_outlined),
                          label: const Text('Clear translations'),
                          onPressed: () async {
                            await state.clearSentenceBankTranslationCache();
                            state.triggerSentenceBankReload();
                            if (context.mounted) lpSnack(context, 'Translation cache cleared — re-translating…', 3000);
                          },
                        ),
                        OutlinedButton.icon(
                          icon: const Icon(Icons.volume_off_outlined),
                          label: const Text('Clear audio cache'),
                          onPressed: () async {
                            await state.clearGoogleTtsAudioCache();
                            if (context.mounted) lpSnack(context, 'Audio cache cleared.', 3000);
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    // Text(
                    //   'Auto-mode timing (seconds before/after translation) is set in the sentence_bank.yaml file itself.',
                    //   style: Theme.of(context).textTheme.bodySmall,
                    // ),
                    const SizedBox(height: 12),
                    Builder(builder: (context) {
                      final yamlValue = context.select<AppState, int>((a) => a.sentenceBankYamlSourcePause);
                      final current = s.sentenceBankSourcePauseOverride ?? yamlValue;
                      return Row(
                        children: [
                          Expanded(child: Text('Pause after source', style: textStyle)),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: current <= 0
                                ? null
                                : () => state.saveSettingsOnly(
                                      s.copyWith(sentenceBankSourcePauseOverride: current - 1),
                                    ),
                          ),
                          SizedBox(
                            width: 32,
                            child: Text(
                              '${current}s',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: () => state.saveSettingsOnly(
                              s.copyWith(sentenceBankSourcePauseOverride: current + 1),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.restart_alt),
                            tooltip: 'Reset to YAML value ($yamlValue s)',
                            onPressed: current == yamlValue
                                ? null
                                : () => state.saveSettingsOnly(
                                      s.copyWith(sentenceBankSourcePauseOverride: null),
                                    ),
                          ),
                        ],
                      );
                    }),
                    // Text(
                    //   'Time between speaking the source sentence and showing the translation. Reset restores the YAML value.',
                    //   style: Theme.of(context).textTheme.bodySmall,
                    // ),
                    const SizedBox(height: 12),
                    Builder(builder: (context) {
                      final yamlValue = context.select<AppState, int>((a) => a.sentenceBankYamlTtsRepeatCount);
                      final current = s.sentenceBankTtsRepeatCountOverride ?? yamlValue;
                      return Row(
                        children: [
                          Expanded(child: Text('Repeat translation TTS', style: textStyle)),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: current <= 1
                                ? null
                                : () => state.saveSettingsOnly(
                                      s.copyWith(sentenceBankTtsRepeatCountOverride: current - 1),
                                    ),
                          ),
                          SizedBox(
                            width: 32,
                            child: Text(
                              '${current}×',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: current >= 10
                                ? null
                                : () => state.saveSettingsOnly(
                                      s.copyWith(sentenceBankTtsRepeatCountOverride: current + 1),
                                    ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.restart_alt),
                            tooltip: 'Reset to YAML value ($yamlValue×)',
                            onPressed: current == yamlValue
                                ? null
                                : () => state.saveSettingsOnly(
                                      s.copyWith(sentenceBankTtsRepeatCountOverride: null),
                                    ),
                          ),
                        ],
                      );
                    }),
                    const SizedBox(height: 12),
                    Builder(builder: (context) {
                      final yamlValue = context.select<AppState, int>((a) => a.sentenceBankYamlTtsRepeatDelay);
                      final current = s.sentenceBankTtsRepeatDelayOverride ?? yamlValue;
                      return Row(
                        children: [
                          Expanded(child: Text('Delay between repeats', style: textStyle)),
                          const SizedBox(width: 8),
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: current <= 0
                                ? null
                                : () => state.saveSettingsOnly(
                                      s.copyWith(sentenceBankTtsRepeatDelayOverride: current - 1),
                                    ),
                          ),
                          SizedBox(
                            width: 32,
                            child: Text(
                              '${current}s',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: () => state.saveSettingsOnly(
                              s.copyWith(sentenceBankTtsRepeatDelayOverride: current + 1),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.restart_alt),
                            tooltip: 'Reset to YAML value ($yamlValue s)',
                            onPressed: current == yamlValue
                                ? null
                                : () => state.saveSettingsOnly(
                                      s.copyWith(sentenceBankTtsRepeatDelayOverride: null),
                                    ),
                          ),
                        ],
                      );
                    }),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Speak source sentence in auto mode', style: textStyle),
                      value: s.sentenceBankSpeakSource,
                      onChanged: (v) => state.saveSettingsOnly(s.copyWith(sentenceBankSpeakSource: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Shuffle sentence order', style: textStyle),
                      value: s.sentenceBankShuffle,
                      onChanged: (v) => state.saveSettingsOnly(s.copyWith(sentenceBankShuffle: v)),
                    ),
                  ]),

                  // ── Books — Audio mode ──────────────────────────────────────
                  _section('Books — Audio mode', [
                    Text(
                      'Drives the auto-playback in the Books tab. Each chunk is read in '
                      'the book\'s language, paused, then read in your target language, '
                      'with both sides repeated.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Text('Chunk by', style: textStyle),
                        const SizedBox(width: 12),
                        DropdownButton<String>(
                          focusColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          dropdownColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                          value: s.booksChunkUnit,
                          items: const [
                            DropdownMenuItem(value: 'sentence', child: Text('Sentence')),
                            DropdownMenuItem(value: 'paragraph', child: Text('Paragraph')),
                          ],
                          onChanged: (v) {
                            if (v != null) state.saveSettingsOnly(s.copyWith(booksChunkUnit: v));
                          },
                        ),
                      ],
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Repeat each side: ${s.booksRepeatCount}×', style: textStyle),
                      subtitle: Slider(
                        value: s.booksRepeatCount.toDouble().clamp(1, 5),
                        min: 1, max: 5, divisions: 4,
                        label: '${s.booksRepeatCount}×',
                        onChanged: (v) =>
                            state.saveSettingsOnly(s.copyWith(booksRepeatCount: v.round())),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Pause between source and target: ${s.booksSourcePauseSec}s',
                          style: textStyle),
                      subtitle: Slider(
                        value: s.booksSourcePauseSec.toDouble().clamp(0, 10),
                        min: 0, max: 10, divisions: 10,
                        label: '${s.booksSourcePauseSec}s',
                        onChanged: (v) =>
                            state.saveSettingsOnly(s.copyWith(booksSourcePauseSec: v.round())),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Pause between chunks: ${s.booksBetweenChunksPauseSec}s',
                          style: textStyle),
                      subtitle: Slider(
                        value: s.booksBetweenChunksPauseSec.toDouble().clamp(0, 15),
                        min: 0, max: 15, divisions: 15,
                        label: '${s.booksBetweenChunksPauseSec}s',
                        onChanged: (v) => state
                            .saveSettingsOnly(s.copyWith(booksBetweenChunksPauseSec: v.round())),
                      ),
                    ),
                  ]),

                  // ── Maintenance ─────────────────────────────────────────────
                  _section('Maintenance', [
                    Text(
                      'Use these if you changed the sentence/cloze format and want to wipe old cached data on this device.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.delete_forever),
                            label: const Text('Delete all history'),
                            onPressed: () async {
                              final ok = await showYesNoDialog(
                                context,
                                title: 'Delete all history?',
                                message: 'This will delete the tapped-notification history on this device. Continue?',
                              );
                              if (ok != true) return;
                              await state.clearAllHistory();
                              if (!context.mounted) return;
                              lpSnack(context, 'History deleted.', 4000);
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.notifications_off),
                            label: const Text('Delete all pending sentences'),
                            onPressed: () async {
                              final ok = await showYesNoDialog(
                                context,
                                title: 'Delete all pending sentences?',
                                message:
                                    'This will cancel scheduled notifications and reset scheduling progress (start from the beginning again). Continue?',
                              );
                              if (ok != true) return;
                              await state.clearAllPendingSentencesAndRegenerate();
                              if (!context.mounted) return;
                              lpSnack(context, 'Pending sentences cleared and rescheduled.', 4000);
                            },
                          ),
                        ),
                      ],
                    ),
                  ]),

                  // ── Legal ────────────────────────────────────────────────────
                  _section('Legal', [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.description_outlined),
                      title: const Text('Policies'),
                      subtitle: const Text('Privacy Policy & Terms'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const PoliciesScreen()),
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.gavel_outlined),
                      title: const Text('Licenses'),
                      subtitle: const Text('Open-source licenses'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: 'Katalaveno',
                        applicationLegalese: '© ${DateTime.now().year}',
                      ),
                    ),
                  ]),

                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ListTile(
                      // leading: const Icon(Icons.info_outline),
                      title: const Text('About Katalaveno'),
                      // subtitle: const Text('Version and credits'),
                      onTap: () => _showAbout(context),
                    ),
                  ),

                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),

          // ── Save button (fixed at bottom) ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 1,
              ),
              icon: _savingSettings ? tinyCenteredSpinner(scale: 0.8) : const Icon(Icons.save),
              label: const Text('Save & reschedule'),
              onPressed: _savingSettings
                  ? null
                  : () async {
                      FocusScope.of(context).unfocus();
                      setState(() => _savingSettings = true);
                      try {
                        String newKnown = _knownCtrl.text.trim();
                        String newTarget = _targetCtrl.text.trim();
                        final langCache = Map<String, String>.from(s.languageNameCache);
                        final apiKey = _apiKeyCtrl.text.trim();
                        try {
                          if (newKnown.isNotEmpty) {
                            newKnown = await AiService.normalizeLanguageName(apiKey: apiKey, userInput: newKnown, cache: langCache);
                          }
                          if (newTarget.isNotEmpty) {
                            newTarget = await AiService.normalizeLanguageName(apiKey: apiKey, userInput: newTarget, cache: langCache);
                          }
                        } catch (_) {}
                        _knownCtrl.text = newKnown;
                        _targetCtrl.text = newTarget;
                        final total = max(3, int.tryParse(_numSentencesCtrl.text.trim()) ?? s.conjugatedCount + s.simpleCount);
                        final newSettings = s.copyWith(
                          knownLanguage: newKnown.isEmpty ? s.knownLanguage : newKnown,
                          targetLanguage: newTarget.isEmpty ? s.targetLanguage : newTarget,
                          interval: _intervalFromFields(),
                          simpleCount: 3,
                          conjugatedCount: total - 3,
                          aiApiKey: apiKey,
                          languageNameCache: langCache,
                          sentenceBankUrl: _sbUrlCtrl.text.trim(),
                        );
                        await state.updateSettings(newSettings);
                        if (context.mounted) lpSnack(context, 'Settings saved and notifications rescheduled', 4000);
                      } finally {
                        if (mounted) setState(() => _savingSettings = false);
                      }
                    },
            ),
          ),
        ],
      ),
    );
  }
}
