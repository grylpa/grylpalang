import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:katalaveno/widgets.dart';
import 'package:provider/provider.dart';

import '../models/word_entry.dart';
import '../services/ai_service.dart';
import '../state/app_state.dart';
import 'add_word_panel.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Timer? _timer;

  // Track which words are currently talking to the AI.
  final Set<String> _wordsLoading = {};

  @override
  void initState() {
    super.initState();

    // After the first frame, catch up currentStep based on any notifications
    // that should already have fired according to their scheduled time.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().refreshFromTime();
    });

    // While this tab is visible, periodically refresh from time so the
    // "Remaining" counters keep up with fired notifications.
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      context.read<AppState>().refreshFromTime();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _onAddSentencesForWord(BuildContext context, WordEntry w) async {
    // If already loading for this word, ignore extra taps.
    if (_wordsLoading.contains(w.id)) return;

    setState(() {
      _wordsLoading.add(w.id);
    });

    final state = context.read<AppState>();

    try {
      await state.addMoreForWord(w);
      if (!context.mounted) return;
      lpSnack(context, 'More sentences added via AI.', 4000);
    } catch (e) {
      if (!mounted) return;
      lpSnack(context, '$e', 8000);
    } finally {
      if (mounted) {
        setState(() {
          _wordsLoading.remove(w.id);
        });
      }
    }
  }

  Future<void> _onAskToDeleteWord(BuildContext context, WordEntry w) async {
    final state = context.read<AppState>();
    final result = await showYesNoDialog(context, title: 'Delete ${w.wordL2}', message: 'Are you sure ?');
    if (result == true) {
      await state.deleteWord(w);
    }
  }

  // ── ⋮ options menu ─────────────────────────────────────────────────────────
  // The word-generation and notification controls live here (on the screen they
  // affect) rather than on the global Settings screen — only the known/target
  // languages stayed there as an app-wide setting.
  Widget _buildMenuButton() {
    PopupMenuItem<String> item(String value, IconData icon, String label) => PopupMenuItem<String>(
          value: value,
          child: Row(children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)]),
        );
    return PopupMenuButton<String>(
      tooltip: 'Options',
      position: PopupMenuPosition.under,
      icon: const Icon(Icons.more_vert),
      onSelected: (v) {
        switch (v) {
          case 'active':
            _openActiveWordsSettings();
          case 'notif':
            _openNotificationSettings();
        }
      },
      itemBuilder: (ctx) => [
        item('active', Icons.tune, 'Active words settings'),
        item('notif', Icons.notifications_outlined, 'Notification settings'),
      ],
    );
  }

  /// Filled, borderless wrapper for a classic [DropdownButton] (matches the
  /// app's text inputs), same look as the Settings screen dropdowns.
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

  /// Interval + sentence-count + connector words. Text fields are deferred and
  /// committed together by the in-sheet "Save & reschedule" button; switches and
  /// connector chips save immediately.
  Future<void> _openActiveWordsSettings() async {
    final state = context.read<AppState>();
    final s0 = state.settings;

    final d = s0.interval;
    String intervalUnit;
    String intervalText;
    if (d.inHours >= 24) {
      intervalUnit = 'days';
      intervalText = d.inDays.toString();
    } else if (d.inMinutes >= 60) {
      intervalUnit = 'hours';
      intervalText = d.inHours.toString();
    } else {
      intervalUnit = 'minutes';
      intervalText = d.inMinutes.toString();
    }
    final intervalCtrl = TextEditingController(text: intervalText);
    final numCtrl = TextEditingController(text: (s0.simpleCount + s0.conjugatedCount).toString());
    final connectorCtrl = TextEditingController();
    bool adding = false;
    bool saving = false;

    Duration intervalFromFields() {
      final n = int.tryParse(intervalCtrl.text.trim());
      final v = (n == null || n <= 0) ? 1 : n;
      switch (intervalUnit) {
        case 'minutes':
          return Duration(minutes: v);
        case 'days':
          return Duration(days: v);
        default:
          return Duration(hours: v);
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(
          builder: (ctx, setSheet) => Consumer<AppState>(
            builder: (ctx, state, _) {
              final s = state.settings;
              final titleStyle = Theme.of(ctx).textTheme.titleMedium;
              return SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Active words settings', style: Theme.of(ctx).textTheme.titleLarge),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Text('Interval:', style: titleStyle),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 80,
                            child: TextField(
                              decoration: tfDecor(ctx),
                              controller: intervalCtrl,
                              keyboardType: TextInputType.number,
                            ),
                          ),
                          const SizedBox(width: 20),
                          _filledDropdown(
                            child: DropdownButton<String>(
                              focusColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                              dropdownColor: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                              value: intervalUnit,
                              onChanged: (val) {
                                if (val == null) return;
                                setSheet(() => intervalUnit = val);
                              },
                              items: const [
                                DropdownMenuItem(value: 'minutes', child: Text('minutes')),
                                DropdownMenuItem(value: 'hours', child: Text('hours')),
                                DropdownMenuItem(value: 'days', child: Text('days')),
                              ],
                            ),
                          ),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Translation in notifications', maxLines: 1),
                        value: s.showTranslation,
                        onChanged: (v) => state.updateSettings(s.copyWith(showTranslation: v)),
                      ),
                      const Divider(height: 24),
                      Row(
                        children: [
                          Expanded(child: Text('Sentences to create:', style: titleStyle)),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 80,
                            child: TextField(
                              decoration: tfDecor(ctx),
                              controller: numCtrl,
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
                            .map((w) => Chip(label: Text(w), onDeleted: () => state.removeConnectorWord(w)))
                            .toList(),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: filledTF(
                              ctx,
                              controller: connectorCtrl,
                              suffixIcon: adding ? tinySpinner() : null,
                              style: Theme.of(ctx).textTheme.labelSmall,
                              hintText: 'Phonetic, comma/space separated',
                            ),
                          ),
                          const SizedBox(width: 4),
                          IconButton.filled(
                            style: blueIconButtonStyle(ctx),
                            icon: const Icon(Icons.add),
                            onPressed: adding
                                ? null
                                : () async {
                                    final raw = connectorCtrl.text.trim();
                                    if (raw.isEmpty) return;
                                    final apiKey = state.settings.aiApiKey.trim();
                                    if (apiKey.isEmpty) {
                                      lpSnack(ctx, 'Set your Gemini API key first in AI settings.', 4000);
                                      return;
                                    }
                                    FocusScope.of(ctx).unfocus();
                                    final parts = raw
                                        .split(RegExp(r'[, \t\n]+'))
                                        .map((w) => w.trim())
                                        .where((w) => w.isNotEmpty)
                                        .toList();
                                    if (parts.isEmpty) return;
                                    setSheet(() => adding = true);
                                    final added = <String, String>{};
                                    try {
                                      for (final p in parts) {
                                        final normalized = await AiService.normalizeWordToTargetScript(
                                          apiKey: apiKey,
                                          word: p,
                                          targetLanguage: state.settings.targetLanguage,
                                        );
                                        await state.addConnectorWord(normalized);
                                        added[p] = normalized;
                                      }
                                      connectorCtrl.clear();
                                      if (ctx.mounted) {
                                        final msg = added.entries.map((e) => '${e.key} → ${e.value}').join(', ');
                                        lpSnack(ctx, msg, 4000);
                                      }
                                    } catch (e) {
                                      if (ctx.mounted) lpSnack(ctx, 'AI error (connector): $e', 8000);
                                    } finally {
                                      if (ctx.mounted) setSheet(() => adding = false);
                                    }
                                  },
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: saving ? tinyCenteredSpinner(scale: 0.8) : const Icon(Icons.save),
                          label: const Text('Save & reschedule'),
                          onPressed: saving
                              ? null
                              : () async {
                                  FocusScope.of(ctx).unfocus();
                                  setSheet(() => saving = true);
                                  try {
                                    final cur = state.settings;
                                    final total = max(
                                        3, int.tryParse(numCtrl.text.trim()) ?? cur.conjugatedCount + cur.simpleCount);
                                    await state.updateSettings(cur.copyWith(
                                      interval: intervalFromFields(),
                                      simpleCount: 3,
                                      conjugatedCount: total - 3,
                                    ));
                                    if (ctx.mounted) Navigator.pop(ctx);
                                    if (mounted) lpSnack(context, 'Saved and notifications rescheduled', 4000);
                                  } catch (e) {
                                    if (ctx.mounted) {
                                      setSheet(() => saving = false);
                                      lpSnack(ctx, '$e', 6000);
                                    }
                                  }
                                },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );

    intervalCtrl.dispose();
    numCtrl.dispose();
    connectorCtrl.dispose();
  }

  /// The notification-style switches (at least one must stay enabled).
  Future<void> _openNotificationSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Consumer<AppState>(
        builder: (ctx, state, _) {
          final s = state.settings;
          final textStyle = Theme.of(ctx).textTheme.bodyMedium;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Notification settings', style: Theme.of(ctx).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Read: See the target language', style: textStyle),
                    value: s.modeClean,
                    onChanged: (v) {
                      if (!v && !s.modeCloze && !s.modeReverse) {
                        lpSnack(ctx, 'At least one style must be enabled.', 3000);
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
                        lpSnack(ctx, 'At least one style must be enabled.', 3000);
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
                        lpSnack(ctx, 'At least one style must be enabled.', 3000);
                        return;
                      }
                      state.updateSettings(s.copyWith(modeReverse: v));
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;
    final active = state.words.where((w) => w.active).toList();
    final words = [...state.words]..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    int maxWords = 4;
    bool canAddMoreWords = words.length < maxWords;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Column(
                  children: [
                    const SizedBox(height: 4),
                    Center(child: Text('${s.knownLanguage} ⮕ ${s.targetLanguage}')),
                    Center(
                        child: Text('Active words (${active.length})',
                            style: Theme.of(context).textTheme.titleMedium)),
                  ],
                ),
                Positioned(top: 0, right: 0, child: _buildMenuButton()),
              ],
            ),
            // const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: words.length,
                itemBuilder: (context, index) {
                  final WordEntry w = words[index];
                  final isLoading = _wordsLoading.contains(w.id);
                  final remaining = state.remainingSentencesFor(w);
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 0, vertical: 4),
                    child: ListTile(
                      contentPadding: EdgeInsets.fromLTRB(8, 0, 0, 4),
                      title: Text(
                        w.wordL2,
                        // style: TextStyle(fontWeight: FontWeight.w900,)
                        style: DefaultTextStyle.of(context).style.apply(fontSizeDelta: 8.0, fontWeightDelta: 2),
                      ),
                      subtitle: Text('${w.type.name.capitalize()}, Remaining: $remaining'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton.filledTonal(
                            style: IconButton.styleFrom(
                              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                              foregroundColor: Theme.of(context).colorScheme.onPrimaryContainer,
                            ),
                            onPressed: isLoading ? null : () => _onAddSentencesForWord(context, w),
                            icon: isLoading ? const SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ) : const Icon(Icons.add),
                          ),
                          // SizedBox(width: 4,),
                          IconButton(
                            // style: IconButton.styleFrom(
                            //   backgroundColor: Theme.of(context).colorScheme.primary,
                            //   foregroundColor: Theme.of(context).colorScheme.onPrimary,
                            // ),
                            onPressed: () => _onAskToDeleteWord(context, w),
                            icon: Icon(Icons.delete),
                          ), //, size: 60)),
                          // Switch(
                          //   value: w.active,
                          //   onChanged: (_) => state.toggleWordActive(w),
                          // ),
                        ],
                      ),
                      // onLongPress: () => _showWordActions(context, w),
                    ),
                  );
                },
              ),
            ),
            // const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
              child: Stack(
                alignment: AlignmentDirectional.center,
                children: [
                  Opacity(
                    opacity: canAddMoreWords ? 1 : 0.2,
                    // child: AbsorbPointer(absorbing: false, child: const AddWordPanel()),
                    child: AbsorbPointer(absorbing: !canAddMoreWords, child: AddWordPanel(canAddMoreWords:canAddMoreWords)),
                  ),
                  if (!canAddMoreWords)
                    Positioned.fill(
                      child: GestureDetector(
                        onTap: () => lpSnack(context, "Cannot add more\nthan $maxWords words", 2000),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
