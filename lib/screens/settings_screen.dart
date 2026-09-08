import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_tab.dart';
import '../services/ai_service.dart';
import '../services/app_update_service.dart';
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
