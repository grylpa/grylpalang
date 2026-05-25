import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../models/word_sentence.dart';
import '../state/app_state.dart';
import '../widgets.dart';

class PredictionTab extends StatefulWidget {
  const PredictionTab({super.key});

  @override
  State<PredictionTab> createState() => _PredictionTabState();
}

class _PredictionTabState extends State<PredictionTab> {
  final _answerCtl = TextEditingController();
  final _tts = FlutterTts();

  WordSentence? _current;
  String _feedback = '';
  bool _submitted = false;
  bool _loading = false;

  @override
  void dispose() {
    _answerCtl.dispose();
    super.dispose();
  }

  Future<void> _newSentence() async {
    setState(() {
      _loading = true;
      _feedback = '';
      _submitted = false;
    });

    final s = context.read<AppState>();
    final next = s.pickPredictionSentenceNonRepeating();

    setState(() {
      _current = next;
      _answerCtl.text = '';
      _loading = false;
    });
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final sent = _current;
    if (sent == null) return;

    final userText = _answerCtl.text.trim();
    final s = context.read<AppState>();
    setState(() {
      _loading = true;
      _feedback = '';
    });

    final result = await s.evaluatePrediction(sentence: sent, userAnswer: userText);

    if (!mounted) return;
    setState(() {
      _feedback = result;
      _submitted = true;
      _loading = false;
    });
  }

  Future<void> _speakAnswer() async {
    if (!_ttsSupported()) {
      if (!mounted) return;
        lpSnack(context, 'Text-to-speech is not available on this platform.', 4000);
      return;
    }

    try {
      final sent = _current;
      if (sent == null) return;

      // Pick a language: if your target is Greek, this is fine.
      // If you support multiple targets, you can map based on settings.targetLanguage.
      await _tts.setLanguage('el-GR');
      await _tts.setSpeechRate(0.45);

      // Speak the clean target-language sentence (strip [[...]] markers)
      final clean = (sentenceCleanup(sent.l2)['clean'] ?? sent.l2).trim();
      await _tts.stop();
      await _tts.speak(clean);
    } catch (e) {
      if (!mounted) return;
      lpSnack(context, 'TTS failed: $e', 8000);
    }
  }

  bool _ttsSupported() {
    if (kIsWeb) return false;
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => true,
      TargetPlatform.iOS => true,
      TargetPlatform.macOS => true, // keep only if it works for you
      TargetPlatform.windows => true, // keep only if it works for you
      _ => false, // linux, fuchsia
    };
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final knownLang = state.settings.knownLanguage;
    final targetLang = state.settings.targetLanguage;
    final noTranslation = noTranslationTextFor(state.settings.knownLanguage);

    final sent = _current;
    final ttsOk = _ttsSupported();
    final hintText = 'Type this in $targetLang. You can mix phonetic or $knownLang for words you don’t know.';

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _loading ? null : _newSentence,
                  icon: const Icon(Icons.casino),
                  label: const Text('Give me a new sentence'),
                ),
              ),
              if (ttsOk) ...[
                const SizedBox(width: 10),
                IconButton(
                  tooltip: 'Hear the answer in $targetLang',
                  onPressed: (sent == null || !ttsOk) ? null : _speakAnswer,
                  icon: const Icon(Icons.volume_up),
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          if (sent == null)
            Expanded(
              child: Center(
                child: Text(
                  '',
                  // 'Tap “Give me a new sentence”.',
                  style: Theme.of(context).textTheme.bodyLarge,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      elevation: 0,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Text(
                            //   'Prompt in $knownLang',
                            //   style: Theme.of(context).textTheme.labelLarge,
                            // ),
                            // const SizedBox(height: 8),
                            Text(
                              (sent.l1.isEmpty ? noTranslation : sent.l1),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              hintText,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    TextField(
                      controller: _answerCtl,
                      minLines: 2,
                      maxLines: 6,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: 'Your answer',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          tooltip: 'Clear',
                          onPressed: () => _answerCtl.clear(),
                          icon: const Icon(Icons.clear),
                        ),
                      ),
                    ),

                    const SizedBox(height: 10),

                    Row(
                      children: [
                        Expanded(
                          child: FilledButton(
                            onPressed: (_submitted || _loading) ? null : _submit,
                            child: _loading
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Text('Check'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton(
                            onPressed: () {
                              // Reveal solution (but still keep your “prediction-first” feel)
                              setState(() {
                                final clean = (sentenceCleanup(sent.l2)['clean'] ?? sent.l2).trim();
                                _feedback = '✅ Answer in $targetLang:\n$clean';
                                _submitted = true;
                              });
                            },
                            child: const Text('Reveal'),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    if (_feedback.isNotEmpty)
                      Card(
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            _feedback,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
