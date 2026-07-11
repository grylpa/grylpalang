import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_settings.dart';
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
  late TextEditingController _apiKeyCtrl;

  bool _savingSettings = false;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppState>().settings;
    _knownCtrl = TextEditingController(text: s.knownLanguage);
    _targetCtrl = TextEditingController(text: s.targetLanguage);
    _apiKeyCtrl = TextEditingController(text: s.aiApiKey);
  }

  @override
  void dispose() {
    _knownCtrl.dispose();
    _targetCtrl.dispose();
    _apiKeyCtrl.dispose();
    super.dispose();
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

  /// A `−  value  +` stepper row matching the Sentence Bank controls (instead of
  /// a slider). [suffix] is appended to the value (e.g. 's' or '×'). When
  /// [defaultValue] is given, a reset button restores it (disabled when already
  /// at the default), mirroring the Sentence Bank rows.
  Widget _stepperRow({
    required String label,
    required int value,
    required String suffix,
    required int min,
    int? max,
    int? defaultValue,
    required ValueChanged<int> onChanged,
  }) {
    final textStyle = Theme.of(context).textTheme.bodyMedium;
    return Row(
      children: [
        Expanded(child: Text(label, style: textStyle)),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.remove),
          onPressed: value <= min ? null : () => onChanged(value - 1),
        ),
        SizedBox(
          width: 36,
          child: Text(
            '$value$suffix',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: (max != null && value >= max) ? null : () => onChanged(value + 1),
        ),
        if (defaultValue != null)
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Reset to default ($defaultValue$suffix)',
            onPressed: value == defaultValue ? null : () => onChanged(defaultValue),
          ),
      ],
    );
  }

  /// Wraps a classic [DropdownButton] so it reads as a filled, borderless M3
  /// field (no underline), matching the app's text inputs.
  Widget _filledDropdown({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: DropdownButtonHideUnderline(child: child),
    );
  }

  /// Commits the known/target language fields (normalizing them via the AI) and
  /// reschedules. These are the only deferred fields left on the Settings screen;
  /// everything else moved to the Dashboard's ⋮ menu.
  Widget _applyLanguagesButton(AppState state) {
    final s = state.settings;
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          elevation: 1,
        ),
        icon: _savingSettings ? tinyCenteredSpinner(scale: 0.8) : const Icon(Icons.save),
        label: const Text('Save languages'),
        onPressed: _savingSettings
            ? null
            : () async {
                FocusScope.of(context).unfocus();
                setState(() => _savingSettings = true);
                try {
                  String newKnown = _knownCtrl.text.trim();
                  String newTarget = _targetCtrl.text.trim();
                  final langCache = Map<String, String>.from(s.languageNameCache);
                  // The API key field auto-saves on change; read the controller so a
                  // just-typed key is used for normalization.
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
                  final newSettings = s.copyWith(
                    knownLanguage: newKnown.isEmpty ? s.knownLanguage : newKnown,
                    targetLanguage: newTarget.isEmpty ? s.targetLanguage : newTarget,
                    languageNameCache: langCache,
                  );
                  await state.updateSettings(newSettings);
                  if (mounted) lpSnack(context, 'Languages saved', 4000);
                } finally {
                  if (mounted) setState(() => _savingSettings = false);
                }
              },
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
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

                  // ── Languages (global) ──────────────────────────────────────
                  // Interval, notification style, sentence count and connector
                  // words moved to the Dashboard's ⋮ menu (the screen they affect);
                  // only the known/target languages remain here as an app-wide
                  // setting.
                  _section('Languages', [
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
                    _applyLanguagesButton(state),
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
                        _filledDropdown(
                          child: DropdownButton<String>(
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
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _stepperRow(
                      label: 'Repeat each side',
                      value: s.booksRepeatCount,
                      suffix: '×',
                      min: 1,
                      max: 10,
                      defaultValue: AppSettings.kBooksRepeatCountDefault,
                      onChanged: (v) => state.saveSettingsOnly(s.copyWith(booksRepeatCount: v)),
                    ),
                    const SizedBox(height: 12),
                    _stepperRow(
                      label: 'Pause between source and target',
                      value: s.booksSourcePauseSec,
                      suffix: 's',
                      min: 0,
                      defaultValue: AppSettings.kBooksSourcePauseSecDefault,
                      onChanged: (v) => state.saveSettingsOnly(s.copyWith(booksSourcePauseSec: v)),
                    ),
                    const SizedBox(height: 12),
                    _stepperRow(
                      label: 'Delay between repeats',
                      value: s.booksRepeatDelaySec,
                      suffix: 's',
                      min: 0,
                      defaultValue: AppSettings.kBooksRepeatDelaySecDefault,
                      onChanged: (v) => state.saveSettingsOnly(s.copyWith(booksRepeatDelaySec: v)),
                    ),
                    const SizedBox(height: 12),
                    _stepperRow(
                      label: 'Pause between chunks',
                      value: s.booksBetweenChunksPauseSec,
                      suffix: 's',
                      min: 0,
                      defaultValue: AppSettings.kBooksBetweenChunksPauseSecDefault,
                      onChanged: (v) => state.saveSettingsOnly(s.copyWith(booksBetweenChunksPauseSec: v)),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Force short sentences', style: textStyle),
                      subtitle: Text('Split on commas/clauses so each chunk is as short as possible',
                          style: Theme.of(context).textTheme.bodySmall),
                      value: s.booksForceShortSentences,
                      onChanged: s.booksChunkUnit == 'sentence'
                          ? (v) => state.saveSettingsOnly(s.copyWith(booksForceShortSentences: v))
                          : null,
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
    );
  }
}
