import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/word_type.dart';
import '../state/app_state.dart';
import '../widgets.dart';

class AddWordPanel extends StatefulWidget {
  final bool canAddMoreWords;
  const AddWordPanel({super.key, required this.canAddMoreWords});

  @override
  State<AddWordPanel> createState() => _AddWordPanelState();
}

class _AddWordPanelState extends State<AddWordPanel> {
  final _formKey = GlobalKey<FormState>();
  final _knownCtrl = TextEditingController(); // L1
  final _targetCtrl = TextEditingController(); // L2 (Greek/phonetic)
  WordType _type = WordType.verb;
  bool _loading = false;

  @override
  void dispose() {
    _knownCtrl.dispose();
    _targetCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit(AppState state) async {
    final known = _knownCtrl.text.trim();
    final target = _targetCtrl.text.trim();

    if (known.isEmpty && target.isEmpty) {
      lpSnack(context, 'Enter a word either in the known language or the target language.', 4000);
      return;
    }
    if (known.isNotEmpty && target.isNotEmpty) {
      lpSnack(context, 'Please fill only one of the two fields, not both.', 4000);
      return;
    }

    FocusScope.of(context).unfocus();

    setState(() => _loading = true);
    try {
      await state.addWordWithAi(
        wordL1: known.isNotEmpty ? known : null,
        wordL2: target.isNotEmpty ? target : null,
        type: _type,
      );
      _knownCtrl.clear();
      _targetCtrl.clear();
      if (mounted) {
        lpSnack(context, 'Word added with AI sentences.', 4000);
      }
    } catch (e) {
      if (mounted) {
        lpSnack(context, '$e', 8000);
        // lpSnack(context, 'AI error: $e', 8000);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final s = state.settings;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text('Add new', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(width: 16),
                    DropdownButton<WordType>(
                      value: _type,
                      onChanged: (val) => setState(() => _type = val ?? WordType.verb),
                      items: const [
                        DropdownMenuItem(value: WordType.verb, child: Text('Verb')),
                        DropdownMenuItem(value: WordType.noun, child: Text('Noun')),
                        DropdownMenuItem(value: WordType.other, child: Text('Other')),
                      ],
                    ),
                  ],
                ),
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          filledTF(context, controller: _knownCtrl, hintText: 'Word in ${s.knownLanguage}'),
                          const SizedBox(height: 8),
                          filledTF(
                            context,
                            controller: _targetCtrl,
                            hintText: 'Word in ${s.targetLanguage} (real or phonetic)',
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 10),
                    Opacity(
                      opacity: widget.canAddMoreWords ? 1 : 0.3,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 0, 0, 0),
                        child: IconButton.filled(
                          icon: _loading
                              ? SizedBox(width: 60, height: 60, child: tinyCenteredSpinner(scale: 0.8))
                              : const Icon(Icons.add, size: 60),
                          onPressed: _loading
                              ? null
                              : () {
                                  final appState = context.read<AppState>();
                                  _submit(appState);
                                },
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
