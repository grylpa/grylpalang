import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ai_engine.dart';
import '../models/app_tab.dart';
import '../services/ai_service.dart';
import '../services/app_update_service.dart';
import '../services/data_transfer_service.dart';
import '../state/app_state.dart';
import '../widgets.dart';
import 'policies_screen.dart';

/// Writes a backup and lets the user save it wherever they like.
///
/// `flutter_file_dialog` rather than `file_selector`, which the rest of the app
/// uses: file_selector implements `openFile` on Android but not
/// `getSaveLocation`, so it can open a file and not save one. This opens
/// Android's own ACTION_CREATE_DOCUMENT picker — a real folder-and-name dialog,
/// and the supported way to write outside the app sandbox.
Future<void> _exportData(BuildContext context) async {
  final ok = await showYesNoDialog(
    context,
    title: 'Export data?',
    message:
        'Saves your words, settings, sentence bank, Listen texts and progress '
        'to one file.\n\nThe file includes your Gemini API key, so keep it '
        'somewhere private.\n\nDownloaded books and cached audio are not '
        'included — they rebuild themselves.',
  );
  if (ok != true || !context.mounted) return;
  try {
    final info = await PackageInfo.fromPlatform();
    final file = await DataTransferService.writeBackup(appVersion: info.version);
    final saved = await FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        sourceFilePath: file.path,
        fileName: file.uri.pathSegments.last,
        mimeTypesFilter: const ['application/json'],
      ),
    );
    if (!context.mounted) return;
    // null means the user backed out of the picker, which needs no report.
    if (saved != null) lpSnack(context, 'Backup saved.', 3000);
  } catch (e) {
    if (context.mounted) lpSnack(context, 'Export failed: ${e.toString().split('\n').first.trim()}', 5000);
  }
}

/// Restores a backup over this install's data.
///
/// Deliberately a full replace and deliberately blunt about it: a merge between
/// two divergent installs would leave a state neither of them was ever in.
Future<void> _importData(BuildContext context) async {
  final ok = await showYesNoDialog(
    context,
    title: 'Import data?',
    message:
        'This REPLACES everything currently in this app — words, settings, API '
        'key, sentence bank, Listen texts and progress — with the contents of '
        'the file you pick.\n\nThere is no undo.',
  );
  if (ok != true || !context.mounted) return;

  // The same Android picker the export writes through, and deliberately
  // *unfiltered*: a .json saved to Downloads is reported by different providers
  // as application/json, text/plain or application/octet-stream, and a MIME
  // filter would grey out the very file the user just saved. The file's own
  // header is what validates it, in DataTransferService.restore.
  final picked = await FlutterFileDialog.pickFile(params: const OpenFileDialogParams(copyFileToCacheDir: true));
  if (picked == null || !context.mounted) return;

  try {
    final count = await DataTransferService.restore(File(picked));
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Data restored'),
        content: Text(
          '$count entries were restored.\n\nClose Katalaveno completely and '
          'open it again — the app is still showing what was loaded before the '
          'import.',
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
      ),
    );
  } catch (e) {
    if (context.mounted) lpSnack(context, 'Import failed: ${e.toString().split('\n').first.trim()}', 5000);
  }
}

/// Pings every model in the selected chain, one at a time, showing the list up
/// front with a spinner on whichever is being asked.
///
/// The probes are sequential and each one waits for a real answer, so the whole
/// run takes several seconds; a single spinner for all of it looks hung, and
/// says nothing about how far along it is.
Future<void> _testModels(BuildContext context, String apiKey) => showDialog<void>(
  context: context,
  builder: (ctx) => _ModelTestDialog(apiKey: apiKey),
);

class _ModelTestDialog extends StatefulWidget {
  const _ModelTestDialog({required this.apiKey});

  final String apiKey;

  @override
  State<_ModelTestDialog> createState() => _ModelTestDialogState();
}

class _ModelTestDialogState extends State<_ModelTestDialog> {
  final Map<String, ({int status, String detail})> _results = {};
  String? _running;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    for (final model in AiService.engine.models) {
      // Closing the dialog mid-run abandons the rest: the remaining probes are
      // only worth their seconds while someone is watching.
      if (!mounted) return;
      setState(() => _running = model);
      final r = await AiService.probeModel(widget.apiKey, model);
      if (!mounted) return;
      setState(() {
        _results[model] = r;
        _running = null;
      });
    }
  }

  static String _label(int status) => switch (status) {
    200 => 'OK',
    404 => 'not available to this key',
    429 => 'rate-limited / no quota',
    401 || 403 => 'key rejected',
    -1 => 'network error',
    _ when status >= 500 => 'server error',
    _ => 'failed',
  };

  Widget _row(BuildContext ctx, String model) {
    final done = _results[model];
    final scheme = Theme.of(ctx).colorScheme;
    final Widget leading = done != null
        ? Icon(
            done.status == 200 ? Icons.check_circle_outline : Icons.error_outline,
            size: 18,
            color: done.status == 200 ? scheme.primary : scheme.error,
          )
        : _running == model
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        // Not started: an outline, so the list reads as a queue rather than as
        // a set of failures.
        : Icon(Icons.circle_outlined, size: 18, color: scheme.outlineVariant);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(width: 18, child: Center(child: leading)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  done != null ? '$model — ${_label(done.status)}' : model,
                  style: done == null && _running != model ? TextStyle(color: scheme.onSurfaceVariant) : null,
                ),
              ),
            ],
          ),
          if (done != null && done.detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2),
              child: Text(done.detail, style: Theme.of(ctx).textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final models = AiService.engine.models;
    final finished = _results.length == models.length;
    return AlertDialog(
      title: const Text('Model test'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in models) _row(context, m),
            const SizedBox(height: 12),
            Text(
              'Requests walk this list top to bottom, using the first that answers. '
              'If none do, the app reports the last failure.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
      actions: [FilledButton(onPressed: () => Navigator.pop(context), child: Text(finished ? 'Close' : 'Stop'))],
    );
  }
}

/// Clock time for a failure line. Date omitted on purpose — the log is capped
/// at 60 entries and read minutes after the fact, so the time of day is the part
/// that helps.
String _hhmm(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// The per-model tally behind the "last answered by" line: how many answers
/// each model in the chain has actually given.
Future<void> _showModelUsage(BuildContext context) async {
  final entries = AiService.modelCalls.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final total = entries.fold<int>(0, (sum, e) => sum + e.value);
  final cleared = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Models used'),
      // Wider and taller than a stock dialog, and scrollable: a failure line
      // carries Google's own message, which is long, and there can be one per
      // model in the chain.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      content: SizedBox(
        width: double.maxFinite,
        height: MediaQuery.of(ctx).size.height * 0.6,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in entries)
                Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('${e.key} — ${e.value}')),
              if (AiService.failures.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('Failures (newest first)', style: Theme.of(ctx).textTheme.labelLarge),
                // Newest first: the reason you opened this is almost always
                // whatever just happened.
                for (final f in AiService.failures.reversed)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${_hhmm(f.at)}  ${f.model}',
                          style: Theme.of(ctx).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        // Selectable: these are the messages worth pasting into
                        // a search or a bug report.
                        SelectableText(f.detail, style: Theme.of(ctx).textTheme.bodySmall),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 12),
              Text(
                '$total successful ${total == 1 ? 'call' : 'calls'} in total. A model '
                'other than the first in the chain means the ones above it failed.',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset')),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
      ],
    ),
  );
  if (cleared == true) await AiService.clearUsage();
}

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
  final versionLine = pubspec.split('\n').firstWhere((l) => l.trimLeft().startsWith('version:'), orElse: () => '');
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
    children: [
      const SizedBox(height: 12),
      const Text(
        'A spaced-repetition vocabulary trainer that uses AI to generate '
        'example sentences and reinforces them through scheduled notifications '
        'and an interactive sentence bank.',
      ),
      const SizedBox(height: 12),
      const Text('Built with Flutter. AI by Google Gemini.'),
      const SizedBox(height: 12),
      InkWell(
        onTap: () => launchUrl(Uri.parse('https://grylpa.com'), mode: LaunchMode.externalApplication),
        child: Text(
          'grylpa.com',
          style: TextStyle(color: Theme.of(context).colorScheme.primary, decoration: TextDecoration.underline),
        ),
      ),
    ],
  );
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _knownCtrl;
  late TextEditingController _targetCtrl;
  late TextEditingController _apiKeyCtrl;

  bool _savingSettings = false;

  // Lets the startup "no API key" flow (AppState.aiEngineFocusToken) open the
  // AI-engine card and scroll it into view.
  final ScrollController _scrollCtrl = ScrollController();
  final ExpansibleController _aiExpansion = ExpansibleController();
  final GlobalKey _aiSectionKey = GlobalKey();
  int _seenAiFocusToken = 0;

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
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// Expands the AI-engine card and scrolls it into view. Called when
  /// [AppState.aiEngineFocusToken] changes (startup flow with no API key).
  void _focusAiEngine() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_aiExpansion.isExpanded) _aiExpansion.expand();
      final ctx = _aiSectionKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 350), alignment: 0.1);
      }
    });
  }

  Widget _section(String title, List<Widget> children, {Key? sectionKey, ExpansibleController? controller}) {
    return Card(
      key: sectionKey,
      margin: const EdgeInsets.only(bottom: 10),
      elevation: 0,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        controller: controller,
        title: Text(title, style: Theme.of(context).textTheme.titleMedium),
        shape: const Border(),
        collapsedShape: const Border(),
        maintainState: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
          ),
        ],
      ),
    );
  }

  /// Applies the two language fields together, since changing either one
  /// invalidates every generated sentence. Disabled until something actually
  /// differs from the saved settings, so an accidental tap can't kick off a
  /// reschedule for nothing.
  Widget _applyLanguagesButton(AppState state) {
    final s = state.settings;
    final known = _knownCtrl.text.trim();
    final target = _targetCtrl.text.trim();
    final changed = known.isNotEmpty && target.isNotEmpty && (known != s.knownLanguage || target != s.targetLanguage);

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: !changed || _savingSettings
            ? null
            : () async {
                setState(() => _savingSettings = true);
                try {
                  // updateSettings (not saveSettingsOnly): the notification
                  // schedule has to be rebuilt for the new languages.
                  await state.updateSettings(s.copyWith(knownLanguage: known, targetLanguage: target));
                } finally {
                  if (mounted) setState(() => _savingSettings = false);
                }
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Languages set: $known → $target')));
              },
        icon: const Icon(Icons.check),
        label: const Text('Apply languages'),
      ),
    );
  }

  /// One row of the Tabs card. Settings is shown but locked on — it holds
  /// these switches — and the last two visible tabs lock as well, so the bottom
  /// bar can never be left with nothing to switch between.
  Widget _tabSwitch(AppState state, AppTab tab) {
    final hidden = state.settings.hiddenTabIds;
    final visible = !hidden.contains(tab.id);
    final visibleCount = AppTab.visibleFrom(hidden).length;
    final locked = !tab.canHide || (visible && visibleCount <= 2);

    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      secondary: Icon(visible ? tab.activeIcon : tab.icon),
      title: Text(tab.label, style: Theme.of(context).textTheme.titleMedium),
      subtitle: tab.canHide ? null : Text('Always available', style: Theme.of(context).textTheme.bodySmall),
      value: visible,
      onChanged: locked ? null : (v) => _setTabVisible(state, tab, v),
    );
  }

  void _setTabVisible(AppState state, AppTab tab, bool visible) {
    final hidden = [...state.settings.hiddenTabIds];
    if (visible) {
      hidden.remove(tab.id);
    } else if (!hidden.contains(tab.id)) {
      hidden.add(tab.id);
    }
    // saveSettingsOnly, not updateSettings: the nav layout has nothing to do
    // with the notification schedule, so there's no reason to rebuild it.
    state.saveSettingsOnly(state.settings.copyWith(hiddenTabIds: hidden));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    final titleStyle = Theme.of(context).textTheme.titleMedium;

    // Startup "no API key" flow asked us to reveal the AI-engine card.
    if (state.aiEngineFocusToken != _seenAiFocusToken) {
      _seenAiFocusToken = state.aiEngineFocusToken;
      _focusAiEngine();
    }

    return SafeArea(
      child: SingleChildScrollView(
        controller: _scrollCtrl,
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

            // ── Tabs ────────────────────────────────────────────────────
            // Which bottom-nav destinations exist at all. Hiding one removes it
            // from the bar *and* from the swipe order, and disposes its screen.
            _section('Tabs', [
              Text(
                'Choose which tabs appear in the bottom bar. A hidden tab is also '
                'skipped when you swipe, and its screen stops running.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              for (final t in AppTab.values) _tabSwitch(state, t),
            ]),

            // ── AI Engine ───────────────────────────────────────────────
            _section(
              'AI engine',
              [
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
                // One key covers every model — it is scoped to the Google
                // project, not to a generation — so switching here needs no
                // other change.
                DropdownButtonFormField<String>(
                  initialValue: AiEngine.byId(s.aiEngineId).id,
                  decoration: const InputDecoration(labelText: 'Engine'),
                  items: [for (final e in AiEngine.values) DropdownMenuItem(value: e.id, child: Text(e.label))],
                  onChanged: (v) => state.saveSettingsOnly(s.copyWith(aiEngineId: v ?? AiEngine.gemini25.id)),
                ),
                const SizedBox(height: 6),
                Text(AiEngine.byId(s.aiEngineId).description, style: Theme.of(context).textTheme.bodySmall),
                // Which model actually answered last. One quiet line, because
                // the chain means the model that serves a request isn't always
                // the one asked first — and nothing else in the app would ever
                // tell you that you have been living on a fallback.
                const SizedBox(height: 10),
                // Set apart from the description above it: these are live
                // readings about this key, not more explanatory prose, and
                // styled the same they blurred into it.
                if (AiService.lastModel.isNotEmpty)
                  ActionChip(
                    avatar: Icon(Icons.check_circle_outline, size: 18, color: Theme.of(context).colorScheme.primary),
                    label: Text('Last answered by ${AiService.lastModel}'),
                    onPressed: () => _showModelUsage(context),
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  // The only way to find out whether this key can reach the
                  // models at all. A failing call can't tell you: by the time it
                  // reports, the chain has moved on and the message describes
                  // whichever model answered last.
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.network_check, size: 18),
                    label: const Text('Test models'),
                    onPressed: state.hasAiKey ? () => _testModels(context, s.aiApiKey) : null,
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
              ],
              sectionKey: _aiSectionKey,
              controller: _aiExpansion,
            ),

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

            // ── Backup ───────────────────────────────────────────────────
            _section('Backup', [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.upload_file_outlined),
                title: const Text('Export data'),
                subtitle: const Text('Words, settings, sentences, stories and progress to a file'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _exportData(context),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.download_outlined),
                title: const Text('Import data'),
                subtitle: const Text('Replace everything with a previously exported file'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _importData(context),
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
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PoliciesScreen())),
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
                title: const Text('Check for updates'),
                onTap: () => AppUpdateService.checkManually(context),
              ),
            ),

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
