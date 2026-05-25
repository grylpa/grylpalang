import 'dart:async';

import 'package:flutter/material.dart';
import 'package:katalaveno/widgets.dart';
import 'package:provider/provider.dart';

import '../models/word_entry.dart';
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
            Center(child: Text('${s.knownLanguage} ⮕ ${s.targetLanguage}')),
            // const SizedBox(height: 16),
            Center(child: Text('Active words (${active.length})', style: Theme.of(context).textTheme.titleMedium)),
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
