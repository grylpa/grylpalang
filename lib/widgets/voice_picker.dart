import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../models/app_settings.dart';
import '../services/google_translate_tts.dart';
import '../services/tts_synth_service.dart';

/// What every preview says. Digits, because each engine reads them in its own
/// language — and short, because a preview is auditioned, not listened to.
const String kVoiceSample = '1, 2, 3, 4, 5.';

/// Plays voice previews for a picker, one at a time.
///
/// Every preview — installed voice or natural — is a *file* played through one
/// reusable player, rather than the installed ones going through live
/// `TtsSynthService.speak`. Two reasons, both of which were bugs:
///
///  * One player means a second tap replaces the first. A fresh player per tap
///    played them on top of each other, and a live utterance over an MP3 did
///    the same across the two paths.
///  * A file tells us when it ended. `speak` leaves `awaitSpeakCompletion`
///    off (turning it on can hang on some engines), so it returns before a word
///    is spoken and could never drive a button back to ▶.
///
/// Samples are cached by voice and rate like any other clip, so only the first
/// tap on a given row costs a synthesis.
class VoicePreview {
  VoicePreview({required this.yieldAudio});

  /// Pauses whatever owns the shared player, so the preview can be heard.
  final Future<void> Function() yieldAudio;

  final _google = GoogleTranslateTts();
  ja.AudioPlayer? _player;
  String? _key;

  ja.AudioPlayer get _p => _player ??= ja.AudioPlayer();

  void dispose() => _player?.dispose();

  Future<void> stop() async {
    _key = null;
    try {
      await _player?.stop();
    } catch (_) {}
  }

  /// Stops whatever is previewing, then plays [clip] and returns when it ends.
  ///
  /// Asking for the row that is already playing just stops it, which is what
  /// makes a ■ a working stop button rather than a restart.
  Future<void> play(String key, Future<String> Function() clip, {void Function(Object error)? onError}) async {
    if (_key == key) return stop();
    await stop();
    // The shared playlist holds audio focus, and the synth engine holds it even
    // when idle; neither yields it on its own.
    await yieldAudio();
    await TtsSynthService.instance.stop();
    _key = key;
    try {
      final path = await clip();
      // A later tap won while this clip was being produced — that one owns the
      // player now, so this one must not start over the top of it.
      if (_key != key) return;
      await _p.setFilePath(path);
      await _p.play(); // completes when the clip ends
    } catch (e) {
      onError?.call(e);
    } finally {
      if (_key == key) _key = null;
    }
  }

  /// One installed voice, or — with an empty [voiceName] — whatever "Automatic"
  /// resolves to: rendered with no voice set, exactly as playback does, so what
  /// you hear is the choice the engine will actually make.
  ///
  /// Always at [kSourceSpeechRate]: a preview is for judging the voice, and
  /// comparing two of them is only fair at one pace.
  Future<void> voice(
    String key,
    String languageName, {
    String locale = '',
    String voiceName = '',
    String gender = 'female',
    void Function(Object error)? onError,
  }) {
    // An installed row knows its own locale, which is not always the one the
    // language maps to (a Cypriot Greek voice is el-CY, not el-GR).
    final loc = locale.isNotEmpty ? locale : localeForLanguage(languageName);
    return play(
      key,
      () => TtsSynthService.instance.synthToFile(
        kVoiceSample,
        langCode: langCodeForLanguage(languageName),
        locale: loc,
        voiceId: voiceName.isEmpty ? '' : '${voiceName}__SEP__${loc ?? ''}',
        gender: gender,
        rate: kSourceSpeechRate,
      ),
      onError: onError,
    );
  }

  /// The natural voice at normal pace, like every other row.
  /// [GoogleTtsSpeed.fast] also takes the unsuffixed cache key, so this sample
  /// is shared with the one playback already fetched rather than fetched again.
  Future<void> natural(String key, String languageName, {void Function(Object error)? onError}) => play(
    key,
    () => _google.ensureFile(kVoiceSample, langCodeForLanguage(languageName), speed: GoogleTtsSpeed.fast),
    onError: onError,
  );
}

/// The result of a [VoicePickerSheet]: the two voice ids it was editing.
typedef VoiceChoice = ({String target, String other});

/// Picks one voice for each of two languages.
///
/// Both sections are single-select and identically shaped: a tap sets the voice
/// and a trailing check marks it. The target list leads with the natural voice,
/// then a divider and the installed ones under their own heading — so choosing
/// the natural voice and choosing an installed one are the same gesture against
/// the same group, and cannot both be set. The [otherLang] section is installed
/// voices only; the natural voice is deliberately offered for the language being
/// *learned* and not for the one already known, where an installed voice is
/// good enough and a network round trip buys nothing.
///
/// Shared by Listen (text / translation) and Sentences (translation / source),
/// whose two sections have the same shape under different names.
class VoicePickerSheet extends StatefulWidget {
  const VoicePickerSheet({
    super.key,
    required this.targetLang,
    required this.targetBlurb,
    required this.otherLang,
    required this.otherBlurb,
    required this.targetByLocale,
    required this.otherByLocale,
    required this.initialTarget,
    required this.initialOther,
    required this.onPreviewVoice,
    required this.onPreviewNatural,
    required this.onStopPreview,
  });

  /// The language that may use the natural voice.
  final String targetLang;
  final String targetBlurb;
  final String otherLang;
  final String otherBlurb;
  final Map<String, List<Map>> targetByLocale;
  final Map<String, List<Map>> otherByLocale;
  final String initialTarget;
  final String initialOther;
  // The first two return when the clip ends, which is what lets a row show ■
  // for exactly as long as it is sounding.
  final Future<void> Function(String key, String languageName, {String locale, String voiceName}) onPreviewVoice;
  final Future<void> Function(String key) onPreviewNatural;
  final Future<void> Function() onStopPreview;

  @override
  State<VoicePickerSheet> createState() => _VoicePickerSheetState();
}

class _VoicePickerSheetState extends State<VoicePickerSheet> {
  late String _target;
  late String _other;

  static String _id(String name, String locale) => '${name}__SEP__$locale';

  /// Whether this locale group contains [selected].
  static bool _holds(MapEntry<String, List<Map>> entry, String selected) =>
      selected.isNotEmpty && entry.value.any((v) => _id('${v['name']}', entry.key) == selected);

  /// Every selectable voice row uses this, Automatic and the natural voice
  /// included, so the ▶ column and the voice names each line up down the whole
  /// sheet. The locale expanders are the only thing left flush with the section
  /// titles, which is what makes them read as headings rather than as choices.
  static const EdgeInsets _kRowPad = EdgeInsets.only(left: 16, right: 8);

  @override
  void initState() {
    super.initState();
    _target = _resolve(widget.initialTarget, widget.targetByLocale, allowNatural: true);
    _other = _resolve(widget.initialOther, widget.otherByLocale, allowNatural: false);
  }

  /// A voice that is no longer installed shows as Automatic rather than as a
  /// ticked row that does not exist.
  static String _resolve(String stored, Map<String, List<Map>> byLocale, {required bool allowNatural}) {
    if (allowNatural && stored == AppSettings.kVoiceGoogle) return stored;
    final installed = {
      for (final e in byLocale.entries)
        for (final v in e.value) _id('${v['name']}', e.key),
    };
    return installed.contains(stored) ? stored : '';
  }

  /// The row that is sounding, so exactly one shows ■ at a time.
  String? _playing;

  /// Runs one preview and keeps [_playing] in step with it.
  ///
  /// [run] stops any other preview itself, so a tap while another row is
  /// sounding replaces it. That older call then returns and finds [_playing]
  /// already moved on, which is why it must not clear it.
  Future<void> _tapPreview(String key, Future<void> Function() run) async {
    if (_playing == key) {
      await widget.onStopPreview();
      if (mounted) setState(() => _playing = null);
      return;
    }
    setState(() => _playing = key);
    await run();
    if (mounted && _playing == key) setState(() => _playing = null);
  }

  /// ▶ normally, ■ while this row is sounding — tapping it then stops it.
  Widget _previewToggle(String key, Future<void> Function() run) => IconButton(
    icon: Icon(_playing == key ? Icons.stop_outlined : Icons.play_arrow_outlined),
    tooltip: _playing == key ? 'Stop' : 'Hear this voice',
    onPressed: () => _tapPreview(key, run),
  );

  Widget _sectionTitle(String title, String blurb) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        Text(blurb, style: Theme.of(context).textTheme.bodySmall),
      ],
    ),
  );

  /// A caption over a run of rows, aligned with the section title rather than
  /// with the rows, so it reads as a heading for them.
  Widget _groupLabel(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  static const _empty = Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      'No voices installed for this language. Add one in Android Settings → '
      'System → Languages & input → Text-to-speech output.',
    ),
  );

  /// One locale group: an expander per locale, rows labelled `Voice n` over the
  /// engine's own name — the only thing that tells two identical rows apart.
  ///
  /// [expanded] opens it on the first build only — `ExpansionTile` reads
  /// `initiallyExpanded` in its own initState — which is exactly the wanted
  /// scope: the sheet opens showing the current selection, and picking a voice
  /// elsewhere afterwards never makes folders open or shut under the finger.
  Widget _localeGroup(String locale, List<Map> voices, bool expanded, Widget Function(int, String) row) =>
      ExpansionTile(
        title: Text('$locale  (${voices.length})'),
        initiallyExpanded: expanded,
        children: [for (var i = 0; i < voices.length; i++) row(i, '${voices[i]['name']}')],
      );

  /// The Automatic row plus every installed voice, for one language.
  List<Widget> _installedRows({
    required String prefix,
    required String lang,
    required Map<String, List<Map>> byLocale,
    required String selected,
    required ValueChanged<String> onPick,
  }) => [
    ListTile(
      dense: true,
      contentPadding: _kRowPad,
      leading: _previewToggle('$prefix:auto', () => widget.onPreviewVoice('$prefix:auto', lang)),
      title: const Text('Automatic'),
      subtitle: const Text('Chosen by the engine'),
      trailing: selected.isEmpty ? const Icon(Icons.check) : null,
      onTap: () => onPick(''),
    ),
    if (byLocale.isEmpty) _empty,
    for (final entry in byLocale.entries)
      // Open when it holds the current selection, so the sheet never opens
      // with the chosen voice hidden inside a collapsed folder — and still
      // open when it is the only folder there is.
      _localeGroup(entry.key, entry.value, byLocale.length == 1 || _holds(entry, selected), (i, name) {
        final id = _id(name, entry.key);
        return ListTile(
          dense: true,
          contentPadding: _kRowPad,
          leading: _previewToggle(
            '$prefix:$id',
            () => widget.onPreviewVoice('$prefix:$id', lang, locale: entry.key, voiceName: name),
          ),
          title: Text('Voice ${i + 1}'),
          subtitle: Text(name, overflow: TextOverflow.ellipsis),
          trailing: selected == id ? const Icon(Icons.check) : null,
          onTap: () => onPick(id),
        );
      }),
  ];

  /// What the header says the target is set to. Names the selection rather than
  /// counting it — with one voice a count would always read "1/n".
  String get _targetLabel => switch (_target) {
    '' => 'automatic',
    AppSettings.kVoiceGoogle => 'natural',
    _ => 'installed voice',
  };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Row(
              children: [
                Text('Voices', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text('${widget.targetLang} · $_targetLabel', style: Theme.of(context).textTheme.labelMedium),
              ],
            ),
          ),
          const Divider(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                _sectionTitle(widget.targetLang, widget.targetBlurb),
                // The natural voice leads, and the rest of the section sits
                // under its own heading below the divider. Automatic used to
                // come first, directly above it, which read as "pick the best
                // of everything" when it only ever picks from the installed
                // voices — the grouping is what says so.
                ListTile(
                  dense: true,
                  contentPadding: _kRowPad,
                  // Says the same sample as every other row, so the comparison
                  // is fair rather than flattering.
                  leading: _previewToggle('natural', () => widget.onPreviewNatural('natural')),
                  title: const Text('Natural voice'),
                  // Deliberately as short as its neighbours' subtitles: the
                  // paces are spelled out in the settings sheet, and a block of
                  // text here made this the one row of a different height.
                  subtitle: const Text('Google’s own — clearer, but needs a connection'),
                  trailing: _target == AppSettings.kVoiceGoogle ? const Icon(Icons.check) : null,
                  onTap: () => setState(() => _target = AppSettings.kVoiceGoogle),
                ),
                const Divider(height: 8, indent: 16, endIndent: 16),
                _groupLabel('Installed on this phone'),
                ..._installedRows(
                  prefix: 'tgt',
                  lang: widget.targetLang,
                  byLocale: widget.targetByLocale,
                  selected: _target,
                  onPick: (v) => setState(() => _target = v),
                ),
                const Divider(height: 16),
                _sectionTitle(widget.otherLang, widget.otherBlurb),
                ..._installedRows(
                  prefix: 'oth',
                  lang: widget.otherLang,
                  byLocale: widget.otherByLocale,
                  selected: _other,
                  onPick: (v) => setState(() => _other = v),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Spacer(),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context, (target: _target, other: _other)),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
