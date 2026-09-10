import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_settings.dart';
import '../models/listen_story.dart';
import '../models/sentence_bank.dart';
import '../services/ai_service.dart';
import '../services/auto_playlist_controller.dart';
import '../services/katalaveno_audio_handler.dart';
import '../services/listen_service.dart';
import '../services/sentence_bank_service.dart';
import '../services/tts_synth_service.dart';
import '../state/app_state.dart';
import '../widgets.dart';

/// Listen mode — listening comprehension rather than vocabulary.
///
/// Shares the Sentence Bank's *subjects* but nothing else: its own selection,
/// its own AI-generated material (long sentences / micro-stories instead of
/// drill sentences), and its own playback shape. Each text is played
/// slow → pause → faster → pause → translation → full speed → pause, so the
/// learner gets two chances to follow it before the answer and one more after.
///
/// Deliberately shows no text: reading along would defeat the point.
class ListenTab extends StatefulWidget {
  const ListenTab({super.key});

  @override
  State<ListenTab> createState() => _ListenTabState();
}

class _ListenTabState extends State<ListenTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  late final ListenService _service;
  late final SentenceBankService _bankService;
  final _playlist = AutoPlaylistController();
  StreamSubscription<int>? _ordinalSub;
  StreamSubscription<bool>? _playingSub;

  bool _initialized = false;
  bool _loading = true;
  String? _loadError;

  SentenceBank? _bank;
  final Set<String> _selectedSubjects = {};
  List<ListenStory> _stories = [];
  // Generated ahead and not yet handed out — see [_generate] — along with the
  // subject selection it was written for. Material generated against a
  // different pool isn't valid for the current one, so the reserve is only used
  // while the signatures match (and survives on disk if you switch back).
  List<ListenStory> _reserve = [];
  String _reserveSig = '';

  /// How many texts one API call asks for, regardless of how many the user
  /// takes per press. The seed vocabulary dominates the prompt and is sent once
  /// per request, so a request returning 24 costs little more than one
  /// returning 8 — while three requests of 8 pay for that vocabulary 3 times.
  static const int _kFetchBatch = 24;

  /// Position within [_playable]; the *text* is what gets persisted.
  int _index = 0;

  bool _generating = false;

  /// Which of the two make-material actions is running, so the spinner and the
  /// "…ing" label land on the button that was actually pressed. Both buttons are
  /// disabled while either runs, but only one should look busy.
  bool _generatingStory = false;

  // Bumped to abandon an in-flight streaming build; a build that finds the
  // token changed stops touching the playlist and the UI.
  int _buildToken = 0;
  bool _preparing = false;
  int _prepDone = 0;
  int _prepTotal = 0;

  // Whether the device can actually speak each language. Null until checked.
  // A missing *target* voice blocks playback outright — there is nothing to
  // salvage; a missing known-language voice only drops the translation clip.
  bool? _targetSpeechOk;
  bool _knownSpeechOk = true;
  String _speechCheckedFor = '';

  bool _playing = false;
  bool _sessionLoaded = false; // a playlist is built and can be resumed
  String? _preparedSig;
  String _lastCfgSig = '';

  @override
  void initState() {
    super.initState();
    // The player is shared with the other tabs, so "playing" only means *us*
    // while we hold the top media binding — otherwise the Sentences tab
    // starting would light up this tab's controls too.
    _playingSub = _playlist.playingStream.listen((p) {
      if (mounted) setState(() => _playing = p && katalavenoAudio.isActiveSession(this));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _init();
  }

  Future<void> _init() async {
    final prefs = SharedPreferencesAsync();
    _service = ListenService(prefs);
    _bankService = SentenceBankService(prefs);
    await _load();
  }

  @override
  void dispose() {
    katalavenoAudio.unbind(this);
    // The tab can be disposed mid-playback (hidden from Settings → Tabs), and
    // the player belongs to the shared handler — so it would otherwise keep
    // looping with nobody left to control it.
    if (_playing) _playlist.stop();
    _ordinalSub?.cancel();
    _playingSub?.cancel();
    _playlist.dispose();
    super.dispose();
  }

  // ── Loading ───────────────────────────────────────────────────────────────

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final state = context.read<AppState>();
      final bank = await _bankService.loadBank(url: state.settings.sentenceBankUrl);
      if (!mounted) return;

      final available = {
        for (final n in bank.subjectNames)
          if (bank.subjects[n] is! MetaSubject) n,
      };
      final saved = await _service.loadSelectedSubjects();
      final stories = await _service.loadStories(state.settings.targetLanguage);
      final reserve = await _service.loadReserve(state.settings.targetLanguage);
      final resume = await _service.loadPosition(state.settings.targetLanguage);
      if (!mounted) return;

      // No default selection: generating costs API calls, so the first visit
      // should wait for a deliberate choice rather than pick for you.
      final selection = {...?saved}.where(available.contains).toSet();

      unawaited(_checkSpeechAvailability(state.settings));
      setState(() {
        _bank = bank;
        _stories = stories;
        _reserve = reserve.stories;
        _reserveSig = reserve.selectionSig;
        _selectedSubjects
          ..clear()
          ..addAll(selection);
        _loading = false;
        _index = 0;
      });
      _seekToStory(resume);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  /// Order-independent signature of a subject selection, used to tell whether
  /// a stored reserve was generated for the subjects now in play.
  static String _sigFor(Iterable<String> subjects) => (subjects.toList()..sort()).join('§');

  /// Every selectable subject — meta subjects are pure groups in the bank, so
  /// they're excluded here exactly as in the Sentences tab.
  List<String> get _selectableSubjects => [
    for (final n in _bank?.subjectNames ?? const <String>[])
      if (_bank!.subjects[n] is! MetaSubject) n,
  ];

  /// The stories actually in play: generated material whose subject pool
  /// overlaps the current selection. Lets the user narrow down without
  /// regenerating — a text built from several topics still counts while any one
  /// of them is selected, since that's what it was written to practise.
  List<ListenStory> get _playable => [
    for (final s in _stories)
      if (s.subjects.any(_selectedSubjects.contains)) s,
  ];

  void _seekToStory(String? key) {
    if (key == null) return;
    final i = _playable.indexWhere((s) => s.key == key);
    if (i >= 0 && mounted) setState(() => _index = i);
  }

  String _selectionSummary() {
    if (_selectedSubjects.isEmpty) return 'none';
    if (_selectedSubjects.length >= _selectableSubjects.length) return 'All';
    if (_selectedSubjects.length == 1) return _selectedSubjects.first;
    return '${_selectedSubjects.length} selected';
  }

  // ── Subject selection ─────────────────────────────────────────────────────

  Future<void> _openSubjectPicker() async {
    final all = _selectableSubjects;
    final working = {..._selectedSubjects};
    // How much material each subject already has, so it's obvious what a new
    // generation run would actually add.
    final counts = <String, int>{};
    for (final s in _stories) {
      for (final name in s.subjects) counts[name] = (counts[name] ?? 0) + 1;
    }

    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Text('Select subjects', style: Theme.of(ctx).textTheme.titleMedium),
                    const Spacer(),
                    Text('${working.length}/${all.length}', style: Theme.of(ctx).textTheme.labelMedium),
                  ],
                ),
              ),
              CheckboxListTile(
                dense: true,
                title: const Text('All subjects'),
                value: working.length == all.length
                    ? true
                    : working.isEmpty
                    ? false
                    : null,
                tristate: true,
                onChanged: (_) => setSheet(() {
                  if (working.length == all.length) {
                    working.clear();
                  } else {
                    working
                      ..clear()
                      ..addAll(all);
                  }
                }),
              ),
              const Divider(height: 1),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: all.length,
                  itemBuilder: (_, i) {
                    final name = all[i];
                    final n = counts[name] ?? 0;
                    return CheckboxListTile(
                      dense: true,
                      title: Text(name, overflow: TextOverflow.ellipsis),
                      subtitle: Text(n == 0 ? 'No texts yet' : '$n text${n == 1 ? '' : 's'}'),
                      value: working.contains(name),
                      onChanged: (v) => setSheet(() {
                        if (v == true) {
                          working.add(name);
                        } else {
                          working.remove(name);
                        }
                      }),
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                    const Spacer(),
                    FilledButton(onPressed: () => Navigator.pop(ctx, working), child: const Text('Apply')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (result == null || !mounted) return;
    await _applySelection(result);
  }

  Future<void> _applySelection(Set<String> sel) async {
    _pause();
    setState(() {
      _selectedSubjects
        ..clear()
        ..addAll(sel);
      _index = 0;
      // The play order changed, so the built playlist no longer matches.
      _cancelBuild();
    });
    await _service.saveSelectedSubjects(sel.toList());
  }

  // ── Generation ────────────────────────────────────────────────────────────

  /// Hands the user their next batch of texts, fetching more only when the
  /// reserve can't cover it.
  ///
  /// One request that returns [_kFetchBatch] costs barely more than one
  /// returning eight — the learner's whole vocabulary dominates the prompt and
  /// is sent once per request either way, so three small requests pay for it
  /// three times. We therefore over-fetch and keep the surplus, which also
  /// makes later top-ups instant and usable with no signal.
  ///
  /// One call covers the whole selection rather than looping per subject: a
  /// text is allowed to weave several topics into one scene.
  Future<void> _generate() async {
    final state = context.read<AppState>();
    final s = state.settings;
    final subjects = _selectableSubjects.where(_selectedSubjects.contains).toList();
    if (subjects.isEmpty) {
      lpSnack(context, 'Select at least one subject first.', 3000);
      return;
    }
    final want = s.listenTextsPerRun;
    final sig = _sigFor(subjects);
    var reserve = sig == _reserveSig ? [..._reserve] : <ListenStory>[];

    _pause();
    setState(() => _generating = true);

    String? error;
    var fetched = 0;
    if (reserve.length < want) {
      if (s.aiApiKey.trim().isEmpty) {
        setState(() => _generating = false);
        lpSnack(context, 'Set a Gemini API key in Settings first.', 4000);
        return;
      }
      try {
        final texts = await AiService.generateListeningTexts(
          apiKey: s.aiApiKey,
          // One flat, de-duplicated pool across every selected subject. The
          // subject boundaries are dropped on purpose: grouped seeds made the
          // model build each story around a couple of phrases the learner
          // already knows by heart, which is recognisable rather than
          // comprehensible.
          knownPhrases: {
            for (final name in subjects)
              for (final raw in _bank?.sentencesFor(name) ?? const []) SbSentence.spoken(raw),
          }.toList(),
          knownLanguage: s.knownLanguage,
          targetLanguage: s.targetLanguage,
          count: want > _kFetchBatch ? want : _kFetchBatch,
          sentencesPerText: s.listenSentencesPerText,
        );
        final existing = {for (final st in _stories) st.l2, for (final st in reserve) st.l2};
        for (final text in texts) {
          // The model can repeat itself across runs; a duplicate would just be
          // the same audio twice in the loop.
          if (!existing.add(text.l2)) continue;
          // The whole selection is recorded as the pool this text came from —
          // we can't tell which topics it actually leaned on, and don't need to.
          reserve.add(ListenStory(subjects: subjects, l2: text.l2, l1: text.l1));
          fetched++;
        }
      } catch (e) {
        error = e.toString().split('\n').first.trim();
      }
    }

    final take = reserve.length < want ? reserve.length : want;
    final added = reserve.take(take).toList();
    reserve = reserve.skip(take).toList();

    if (!mounted) return;
    // Shuffled rather than appended: fresh texts should turn up early in the
    // rotation instead of only after the whole existing bank has played out.
    // The bank is a pool to listen through, not an ordered course, so there is
    // no order to preserve — and the play order restarts from the top.
    final all = added.isEmpty ? [..._stories] : _shuffledGroups([..._stories, ...added]);
    if (added.isNotEmpty || fetched > 0) {
      await _service.saveStories(s.targetLanguage, all);
      await _service.saveReserve(s.targetLanguage, sig, reserve);
    }
    if (!mounted) return;
    setState(() {
      _stories = all;
      _reserve = reserve;
      _reserveSig = sig;
      _generating = false;
      if (added.isNotEmpty) _index = 0;
      // New material means a new play order.
      _cancelBuild();
    });
    final playable = _playable;
    if (added.isNotEmpty && playable.isNotEmpty) {
      unawaited(_service.savePosition(s.targetLanguage, playable.first.key));
    }
    lpSnack(
      context,
      error != null && added.isEmpty
          ? 'Generation failed: $error'
          : added.isEmpty
          ? 'No new texts came back — try again for more.'
          : 'Added ${added.length} text${added.length == 1 ? '' : 's'}'
                '${reserve.isEmpty ? '' : ' — ${reserve.length} more ready offline'}.',
      4000,
    );
  }

  /// Shuffles the bank a *group* at a time: a micro-story is its own group and
  /// moves freely, while the parts of a long story stay together and in their
  /// written order. They are one continuous narrative — shuffling them would be
  /// shuffling the pages of a book.
  static List<ListenStory> _shuffledGroups(List<ListenStory> all) {
    final groups = <List<ListenStory>>[];
    final byStory = <String, List<ListenStory>>{};
    for (final story in all) {
      if (!story.isStoryPart) {
        groups.add([story]);
        continue;
      }
      byStory
          .putIfAbsent(story.storyId, () {
            final fresh = <ListenStory>[];
            groups.add(fresh);
            return fresh;
          })
          .add(story);
    }
    for (final g in groups) {
      if (g.length > 1) g.sort((a, b) => a.part.compareTo(b.part));
    }
    groups.shuffle();
    return [for (final g in groups) ...g];
  }

  /// The offered story lengths, in sentences before the part size divides them.
  /// A short story, not a novel — long enough to have a plot, short enough to
  /// finish on one walk.
  static const List<(String, int)> _kStoryLengths = [('Short', 24), ('Med', 48), ('Long', 80)];

  /// Creates one long story and adds its parts to the bank, in order.
  ///
  /// Unlike [_generate] there is no reserve: a story is one bespoke request, and
  /// banking spare stories would mean paying for material the learner may never
  /// reach.
  Future<void> _createStory() async {
    final state = context.read<AppState>();
    final s = state.settings;
    final subjects = _selectableSubjects.where(_selectedSubjects.contains).toList();
    if (subjects.isEmpty) {
      lpSnack(context, 'Select at least one subject first.', 3000);
      return;
    }
    if (s.aiApiKey.trim().isEmpty) {
      lpSnack(context, 'Set a Gemini API key in Settings first.', 4000);
      return;
    }
    final ask = await _askStoryOptions(s);
    if (ask == null || !mounted) return;
    // Remembered, so the next story defaults to what worked last time.
    if (ask.sentences != s.listenStorySentences || ask.perPart != s.listenStoryPartSentences) {
      await state.saveSettingsOnly(
        s.copyWith(listenStorySentences: ask.sentences, listenStoryPartSentences: ask.perPart),
      );
      if (!mounted) return;
    }

    _pause();
    setState(() {
      _generating = true;
      _generatingStory = true;
    });
    try {
      // Both come from the dialog: only the number of parts moves, so the story
      // comes out the length they asked for however finely they sliced it.
      final perPart = ask.perPart;
      final partCount = (ask.sentences / perPart).round().clamp(3, 40);
      final story = await AiService.generateStory(
        apiKey: s.aiApiKey,
        knownPhrases: {
          for (final name in subjects)
            for (final raw in _bank?.sentencesFor(name) ?? const []) SbSentence.spoken(raw),
        }.toList(),
        knownLanguage: s.knownLanguage,
        targetLanguage: s.targetLanguage,
        parts: partCount,
        sentencesPerPart: perPart,
        theme: ask.idea,
      );
      final id = 'st${DateTime.now().millisecondsSinceEpoch}';
      final added = [
        for (var i = 0; i < story.parts.length; i++)
          ListenStory(
            subjects: subjects,
            l2: story.parts[i].l2,
            l1: story.parts[i].l1,
            storyId: id,
            part: i,
            partCount: story.parts.length,
            titleL2: story.titleL2,
            titleL1: story.titleL1,
          ),
      ];
      if (!mounted) return;
      final all = _shuffledGroups([..._stories, ...added]);
      await _service.saveStories(s.targetLanguage, all);
      if (!mounted) return;
      setState(() {
        _stories = all;
        _generating = false;
        _generatingStory = false;
        _cancelBuild();
      });
      // Land on the new story's first part: it was just asked for, so that is
      // what the next Play should start with.
      final at = _playable.indexWhere((x) => x.key == added.first.key);
      if (at >= 0) {
        setState(() => _index = at);
        unawaited(_service.savePosition(s.targetLanguage, added.first.key));
      }
      if (!mounted) return;
      lpSnack(context, 'Added "${story.titleL1}" in ${added.length} parts.', 4000);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _generatingStory = false;
      });
      lpSnack(context, 'Could not write the story: ${e.toString().split('\n').first.trim()}', 5000);
    }
  }

  /// Length and an optional steer for the story. Left blank, the idea field
  /// lets [AiService.generateStory] pick one of its own seed situations — which
  /// is the normal case, and why it is a hint rather than a required field.
  ///
  /// The length is shown in sentences *and* in the parts it works out to, since
  /// the part size is the learner's own setting and is what they will actually
  /// hear.
  Future<({String idea, int sentences, int perPart})?> _askStoryOptions(AppSettings s) async {
    final ctl = TextEditingController();
    var sentences = s.listenStorySentences;
    var perPart = s.listenStoryPartSentences;
    final result = await showDialog<({String idea, int sentences, int perPart})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => AlertDialog(
          title: const Text('Create a story'),
          // Wider than a default dialog, with tighter padding inside it: the
          // three length segments have to fit on one row without eliding their
          // labels, which the stock content box can't manage.
          insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          contentPadding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'One long story at your level, split into parts and played in '
                'order. Takes a moment to generate.',
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.maxFinite,
                child: SegmentedButton<int>(
                  segments: [for (final (label, n) in _kStoryLengths) ButtonSegment<int>(value: n, label: Text(label))],
                  selected: {sentences},
                  showSelectedIcon: false,
                  onSelectionChanged: (v) => setSheet(() => sentences = v.first),
                ),
              ),
              // A story's own part size, separate from the micro-texts' — the
              // two are read differently: a self-contained text is drilled,
              // while a story part is a beat in a narrative and wants more room.
              _stepper(
                ctx,
                label: 'Part size',
                suffix: ' sent.',
                value: perPart,
                min: 1,
                max: 10,
                valueWidth: 80,
                onSet: (v) => setSheet(() => perPart = v),
              ),
              const SizedBox(height: 4),
              Text(
                '$sentences sentences — about ${(sentences / perPart).round().clamp(3, 40)} parts of $perPart',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctl,
                autofocus: false,
                decoration: const InputDecoration(labelText: 'Idea (optional)', hintText: 'e.g. a lost dog'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, (idea: ctl.text.trim(), sentences: sentences, perPart: perPart)),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    return result;
  }

  Future<void> _clearTexts() async {
    final state = context.read<AppState>();
    final ok = await showYesNoDialog(
      context,
      title: 'Delete generated texts?',
      message:
          'Removes every Listen text for ${state.settings.targetLanguage}. '
          'Generating them again uses the AI service.',
    );
    if (ok != true || !mounted) return;
    _pause();
    await _service.clearStories(state.settings.targetLanguage);
    if (!mounted) return;
    setState(() {
      _stories = [];
      _reserve = [];
      _reserveSig = '';
      _index = 0;
      _cancelBuild();
    });
  }

  // ── Playback ──────────────────────────────────────────────────────────────

  /// Asks the engine whether it can speak each language, so a missing language
  /// pack is reported up front instead of surfacing as "could not prepare
  /// audio" after a long synthesis run.
  Future<void> _checkSpeechAvailability(AppSettings s) async {
    final sig = '${s.targetLanguage}¦${s.knownLanguage}';
    if (sig == _speechCheckedFor) return;
    _speechCheckedFor = sig;
    final target = await TtsSynthService.instance.isLanguageAvailable(localeForLanguage(s.targetLanguage));
    final known = await TtsSynthService.instance.isLanguageAvailable(localeForLanguage(s.knownLanguage));
    if (!mounted) return;
    setState(() {
      _targetSpeechOk = target;
      _knownSpeechOk = known;
    });
  }

  double _rate(int pct) => (kSourceSpeechRate * pct / 100).clamp(0.05, 2.0);

  /// Everything that changes what the playlist sounds like. Matching it means
  /// we can resume the loaded playlist instantly instead of re-synthesizing.
  String _playlistSig(AppSettings s) => [
    for (final st in _playable) st.l2,
    s.targetLanguage,
    s.knownLanguage,
    s.listenSlowRatePct,
    s.listenMediumRatePct,
    s.listenFullRatePct,
    s.listenPauseAfterSlowSec,
    s.listenPauseAfterMediumSec,
    s.listenPauseBeforeNextSec,
    s.listenVoiceIds.join('+'),
    s.listenKnownVoice,
    s.sentenceBankVoiceGender,
  ].join('¦');

  /// Voices to rotate through for the target language: the user's picks, or
  /// every installed voice when they haven't chosen any. One voice per story
  /// (not per playback pass) — the three speeds are the *same* utterance, and
  /// changing speaker mid-story would obscure that.
  Future<List<String>> _targetVoices(String targetLang) async {
    final chosen = context.read<AppState>().settings.listenVoiceIds;
    if (chosen.isNotEmpty) return chosen;
    final byLocale = await TtsSynthService.instance.voicesByLocale(langCodeForLanguage(targetLang));
    return [
      for (final entry in byLocale.entries)
        for (final v in entry.value) '${v['name']}__SEP__${entry.key}',
    ];
  }

  /// Builds the clips for one story, or null if it can't be voiced.
  Future<List<ClipSpec>?> _clipsFor(ListenStory story, String voice, AppSettings s) async {
    final tgtCode = langCodeForLanguage(s.targetLanguage);
    final tgtLocale = localeForLanguage(s.targetLanguage);
    try {
      Future<String> target(int pct) => TtsSynthService.instance.synthToFile(
        story.l2,
        langCode: tgtCode,
        locale: tgtLocale,
        voiceId: voice,
        gender: s.sentenceBankVoiceGender,
        rate: _rate(pct),
      );
      final slow = await target(s.listenSlowRatePct);
      final medium = await target(s.listenMediumRatePct);
      final full = await target(s.listenFullRatePct);
      // The translation is the only optional clip: without a known-language
      // voice the exercise still works (three target passes), so a failure here
      // drops one clip rather than the whole text.
      String? known;
      try {
        known = await TtsSynthService.instance.synthToFile(
          story.l1,
          langCode: langCodeForLanguage(s.knownLanguage),
          locale: localeForLanguage(s.knownLanguage),
          voiceId: s.listenKnownVoice,
          gender: s.sentenceBankVoiceGender,
        );
      } catch (_) {
        known = null;
      }
      return [
        ClipSpec.file(slow),
        ClipSpec.silence(s.listenPauseAfterSlowSec),
        ClipSpec.file(medium),
        ClipSpec.silence(s.listenPauseAfterMediumSec),
        if (known != null) ClipSpec.file(known),
        ClipSpec.file(full),
        ClipSpec.silence(s.listenPauseBeforeNextSec),
      ];
    } catch (_) {
      return null;
    }
  }

  /// Abandons an in-flight streaming build (selection changed, new material,
  /// different voices) so it can't keep appending stale clips to the queue.
  void _cancelBuild() {
    _buildToken++;
    _preparing = false;
    _preparedSig = null;
    _sessionLoaded = false;
  }

  /// Starts playback, streaming the playlist in as clips are rendered.
  ///
  /// This is what makes Listen usable with the phone in a pocket. Synthesizing
  /// the whole bank first meant minutes of silence before anything played — and
  /// during that silence nothing is playing, so there is no media foreground
  /// service and no wakelock, and Android suspends the isolate the moment the
  /// screen locks: the build stalls and the session never starts. Playing the
  /// first text as soon as it's ready starts the foreground service, which keeps
  /// the isolate alive to render the rest.
  Future<void> _play() async {
    final stories = _playable;
    if (stories.isEmpty || !ttsSupported() || _targetSpeechOk == false) return;
    final s = context.read<AppState>().settings;
    final sig = _playlistSig(s);

    // Checked *before* re-binding, which would make it trivially true: did we
    // still own the shared player, or did another tab load its own playlist
    // over ours?
    final stillOurs = katalavenoAudio.isActiveSession(this);
    // Re-push our media binding so the lockscreen / Bluetooth buttons drive
    // this session rather than whichever tab played last.
    _bindMediaControls();

    if (sig == _preparedSig && _sessionLoaded && stillOurs) {
      // Plain resume, not a seek: this is what makes the pause button a true
      // pause — playback continues mid-word, not from the top of the text.
      await _playlist.resume();
      return;
    }

    _buildToken++;
    final token = _buildToken;
    setState(() {
      _preparing = true;
      _prepDone = 0;
      _prepTotal = stories.length;
      _sessionLoaded = false;
      _preparedSig = null;
    });

    try {
      final voices = await _targetVoices(s.targetLanguage);
      await _playlist.beginDynamicClips(ordinalCount: stories.length, loop: true);
      _ordinalSub?.cancel();
      _ordinalSub = _playlist.currentOrdinalStream.listen(_onOrdinal);

      var started = false;
      var failed = 0;
      final from = _index.clamp(0, stories.length - 1);
      for (var n = 0; n < stories.length; n++) {
        if (!mounted || token != _buildToken) return;
        // Built from the resume position and wrapping around, so playback can
        // start on the text the user left off at rather than at the top.
        final i = (from + n) % stories.length;
        // The voice follows the story's own index, so it doesn't change
        // depending on where the build happened to start. Every part of a long
        // story shares one voice instead — a narrator that changed mid-chapter
        // would sound like the recording had been spliced.
        final story = stories[i];
        final vi = story.isStoryPart ? story.storyId.hashCode.abs() : i;
        final clips = await _clipsFor(story, voices.isEmpty ? '' : voices[vi % voices.length], s);
        if (!mounted || token != _buildToken) return;

        if (clips == null) {
          failed++;
        } else {
          // Positional title only — the media notification and lockscreen would
          // otherwise show the text itself, which is the one thing this mode is
          // built not to reveal.
          await _playlist.appendClipGroup(ord: i, title: 'Text ${i + 1} of ${stories.length}', clips: clips);
          if (!started) {
            // Synthesizing drives the TTS engine, which holds Android audio
            // focus. If it isn't released first the playlist starts silently —
            // the exact failure that looks like "it doesn't work in my pocket".
            await TtsSynthService.instance.stop();
            await _playlist.playDynamic();
            started = true;
            if (!mounted || token != _buildToken) return;
            // Marked playable as soon as audio is running, so pause/resume work
            // while the rest of the queue is still being rendered.
            setState(() {
              _sessionLoaded = true;
              _preparedSig = sig;
            });
          }
        }
        if (!mounted || token != _buildToken) return;
        setState(() => _prepDone = n + 1);
      }

      if (!started) throw Exception('No audio could be produced');
      if (!mounted || token != _buildToken) return;
      setState(() => _preparing = false);
      if (failed > 0) lpSnack(context, '$failed text(s) could not be voiced — skipped.', 4000);
    } catch (e) {
      if (!mounted || token != _buildToken) return;
      setState(() => _preparing = false);
      lpSnack(context, 'Could not prepare audio.', 4000);
    }
  }

  void _onOrdinal(int ord) {
    if (!mounted || ord == _index) return;
    setState(() => _index = ord);
    final stories = _playable;
    if (ord >= 0 && ord < stories.length) {
      _service.savePosition(context.read<AppState>().settings.targetLanguage, stories[ord].key);
    }
  }

  /// The "stop" button. Genuinely a pause: the built playlist and the exact
  /// position within the current clip are kept, so Play continues from the same
  /// word rather than restarting the story.
  void _pause() => _playlist.pause();

  Future<void> _next() async {
    if (_sessionLoaded) return _playlist.next();
    if (_index + 1 < _playable.length) setState(() => _index++);
  }

  Future<void> _previous() async {
    if (_sessionLoaded) return _playlist.previous();
    if (_index > 0) setState(() => _index--);
  }

  /// Makes the text at [i] the current one.
  ///
  /// If our playlist is live and that text has already been rendered into the
  /// queue we seek straight to it. If it hasn't (the streaming build hasn't
  /// reached it yet) seeking would silently no-op and leave the player where it
  /// was, so the build is restarted from here instead — it always begins at
  /// [_index] and wraps.
  Future<void> _jumpTo(int i) async {
    final stories = _playable;
    if (i < 0 || i >= stories.length) return;
    setState(() => _index = i);
    unawaited(_service.savePosition(context.read<AppState>().settings.targetLanguage, stories[i].key));
    if (!_sessionLoaded || !katalavenoAudio.isActiveSession(this)) return;
    if (await _playlist.seekToOrdinal(i)) return;
    if (!mounted) return;
    setState(_cancelBuild);
    await _play();
  }

  void _bindMediaControls() {
    katalavenoAudio.bind(
      owner: this,
      onPlay: _play,
      onPause: () async => _pause(),
      onStop: () async => _pause(),
      onSkipNext: _next,
      onSkipPrev: _previous,
      onSessionLost: _onSessionLost,
    );
  }

  /// Another screen claimed the shared player. Reset local state only — the
  /// queue is theirs now, so pausing or stopping here would cut off the audio
  /// they just started.
  void _onSessionLost() {
    _ordinalSub?.cancel();
    _ordinalSub = null;
    _playlist.detach();
    if (!mounted) return;
    setState(() {
      _cancelBuild();
      _playing = false;
    });
  }

  // ── UI ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    super.build(context);

    // Re-prepare when a playback-shaping setting changes mid-session, so a rate
    // or pause tweak is heard on the next Play instead of silently ignored.
    final s = context.select<AppState, AppSettings>((st) => st.settings);
    // Changing either language in Settings can change what the engine can
    // speak, so the availability check follows it.
    if ('${s.targetLanguage}¦${s.knownLanguage}' != _speechCheckedFor) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _checkSpeechAvailability(s);
      });
    }
    final cfg = _playlistSig(s);
    if (cfg != _lastCfgSig) {
      _lastCfgSig = cfg;
      if (_preparedSig != null && cfg != _preparedSig) _cancelBuild();
    }

    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text('Could not load subjects:\n$_loadError', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: _subjectPicker()),
              const SizedBox(width: 12),
              _overflowMenu(),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(child: _statusCard(s)),
          const SizedBox(height: 10),
          // Side by side, and wrapping rather than truncating: at half a phone
          // width neither label fits on one line, and "Generate 8 more te…"
          // hides exactly the part that says what the press will cost.
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: _generateButton(s)),
                const SizedBox(width: 8),
                Expanded(child: _storyButton()),
              ],
            ),
          ),
          const SizedBox(height: 16),
          _controls(),
        ],
      ),
    );
  }

  Widget _subjectPicker() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Subjects',
        border: OutlineInputBorder(),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      ),
      child: InkWell(
        onTap: _generating ? null : _openSubjectPicker,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Expanded(child: Text(_selectionSummary(), overflow: TextOverflow.ellipsis)),
              const Icon(Icons.arrow_drop_down),
            ],
          ),
        ),
      ),
    );
  }

  /// The ⋮ menu. Only what Listen actually has: voices, its playback settings,
  /// and clearing the generated bank. The Sentence Bank's URL / file loading /
  /// format items have no meaning here — the material is generated, not authored.
  Widget _overflowMenu() {
    PopupMenuItem<String> item(String v, IconData icon, String label, {bool enabled = true}) => PopupMenuItem<String>(
      value: v,
      enabled: enabled,
      child: Row(children: [Icon(icon), const SizedBox(width: 12), Text(label)]),
    );
    return PopupMenuButton<String>(
      enabled: !_generating,
      tooltip: 'Listen options',
      position: PopupMenuPosition.under,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
        child: Icon(Icons.more_vert, color: _generating ? Theme.of(context).disabledColor : null),
      ),
      onSelected: (v) {
        switch (v) {
          case 'texts':
            _showTextPicker();
          case 'voices':
            _showVoicePicker();
          case 'settings':
            _showSettingsSheet();
          case 'clear':
            _clearTexts();
        }
      },
      itemBuilder: (_) => [
        if (ttsSupported()) item('voices', Icons.record_voice_over_outlined, 'Voices'),
        item('settings', Icons.tune, 'Settings'),
        item('clear', Icons.delete_outline, 'Delete generated texts', enabled: _stories.isNotEmpty),
        item('texts', Icons.list_alt_outlined, 'All texts', enabled: _playable.isNotEmpty),
      ],
    );
  }

  /// The whole bank as a list, target language only, tap to jump.
  ///
  /// Deliberately one-sided: the translation is what you check yourself
  /// against, so showing it here would turn picking a text into reading the
  /// answer first.
  Future<void> _showTextPicker() async {
    final stories = _playable;
    if (stories.isEmpty) return;
    final current = _index.clamp(0, stories.length - 1);
    final picked = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Text('All texts', style: Theme.of(ctx).textTheme.titleMedium),
                    const Spacer(),
                    Text('${stories.length}', style: Theme.of(ctx).textTheme.labelMedium),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                // Positioned list, not a plain ListView: it opens scrolled to
                // the text you're on, which a ListView can't do when the tiles
                // have no fixed height (there is no offset to compute, and
                // ensureVisible can't reach a tile the builder hasn't built).
                // Same widget the History tab uses for the same reason.
                child: ScrollablePositionedList.separated(
                  padding: EdgeInsets.zero,
                  itemCount: stories.length,
                  initialScrollIndex: current,
                  // A third of the way down rather than glued to the top, so
                  // the texts either side of it are visible for context.
                  initialAlignment: current == 0 ? 0 : 0.3,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final sel = i == current;
                    final theme = Theme.of(ctx);
                    final story = stories[i];
                    final tile = ListTile(
                      selected: sel,
                      leading: Text('${i + 1}', style: theme.textTheme.labelMedium),
                      title: Text(story.l2, maxLines: 3, overflow: TextOverflow.ellipsis),
                      // The title is named once, on the story's first part —
                      // the stripe already says which rows below it belong to
                      // the same story, so repeating the name on each is noise.
                      // Muted, never primary: primary is what marks the row you
                      // are on.
                      subtitle: !story.isStoryPart
                          ? null
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (story.part == 0 && story.titleL2.isNotEmpty)
                                  Text(
                                    story.titleL2,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                Text(
                                  'part ${story.part + 1} of ${story.partCount}',
                                  style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                                ),
                              ],
                            ),
                      trailing: sel ? Icon(_playing ? Icons.graphic_eq : Icons.play_arrow, size: 20) : null,
                      onTap: () => Navigator.pop(ctx, i),
                    );
                    // A story's parts are a run of consecutive rows, so a
                    // continuous stripe down their left edge shows at a glance
                    // where it starts and ends — which the per-row label alone
                    // doesn't.
                    if (!story.isStoryPart) return tile;
                    return DecoratedBox(
                      decoration: BoxDecoration(
                        // Secondary, not primary: primary is the "you are here"
                        // colour, and a stripe in it would read as selection.
                        border: Border(left: BorderSide(width: 3, color: theme.colorScheme.secondary)),
                      ),
                      child: tile,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && mounted) await _jumpTo(picked);
  }

  /// The reading pane: a compact header line, then the current text and its
  /// translation, scrollable in whatever height is left.
  ///
  /// The text is shown rather than hidden — you're meant to be able to stop
  /// mid-walk, glance down and check yourself. It just isn't the *point* of the
  /// screen, so it sits below the position line rather than dominating it.
  Widget _statusCard(AppSettings s) {
    // Nothing else on this screen matters if the phone can't speak the language.
    if (_targetSpeechOk == false) return _scrollable(_noSpeechNotice(s.targetLanguage));

    final stories = _playable;
    if (_selectedSubjects.isEmpty) {
      return _scrollable(_placeholder(Icons.hearing_outlined, 'Pick one or more subjects to listen to.'));
    }
    if (stories.isEmpty) {
      return _scrollable(
        _placeholder(
          Icons.auto_awesome_outlined,
          'No texts for these subjects yet.\nTap "Generate texts" to create some.',
        ),
      );
    }

    final theme = Theme.of(context);
    final story = stories[_index.clamp(0, stories.length - 1)];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header: position on the left, the playing indicator on the right —
        // side by side rather than stacked, which buys the text its height.
        Row(
          children: [
            Expanded(child: Text('Text ${_index + 1} of ${stories.length}', style: theme.textTheme.bodySmall)),
            Icon(
              _playing ? Icons.graphic_eq : Icons.hearing_outlined,
              color: _playing ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
        // Long stories say where you are inside them; a micro-story is
        // self-contained and gets no title, which would only give it away.
        if (story.isStoryPart)
          Text(
            '${story.titleL2} — part ${story.part + 1} of ${story.partCount}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
          ),
        if (!_knownSpeechOk)
          // Not a blocking notice like the target language — the exercise still
          // works without the translation — but it gets the same instructions,
          // one tap away, so it's fixable rather than merely reported.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
              onPressed: () => _showMissingVoiceDialog(s.knownLanguage),
              icon: Icon(Icons.info_outline, size: 18, color: theme.colorScheme.error),
              label: Text(
                'No ${s.knownLanguage} voice — translation skipped',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
          ),
        const Divider(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(story.l2, style: theme.textTheme.titleMedium?.copyWith(height: 1.4)),
                const SizedBox(height: 16),
                SelectableText(
                  story.l1,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.4, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Wraps a fixed placeholder so it still behaves inside the Expanded slot the
  /// reading pane normally fills.
  Widget _scrollable(Widget child) => SingleChildScrollView(child: child);

  /// Where to install a missing voice. One string for both languages — the
  /// steps are identical, only the severity differs, so they must not drift
  /// into two slightly different sets of instructions.
  static String _installVoiceHint(String language) =>
      'Android: Settings → System → Languages & input → Text-to-speech output '
      '→ the gear beside your engine → Install voice data, then pick $language.';

  void _recheckSpeech() {
    // Cheap enough to redo, and the user has usually just come back from
    // installing a voice.
    _speechCheckedFor = '';
    _checkSpeechAvailability(context.read<AppState>().settings);
  }

  /// Shown when the device has no speech for the target language. Listen is
  /// entirely audio, so there is no reduced mode to fall back to — the honest
  /// thing is to say what's missing and where to add it, rather than let a long
  /// synthesis run end in "could not prepare audio".
  Widget _noSpeechNotice(String language) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
      child: Column(
        children: [
          Icon(Icons.voice_over_off_outlined, size: 56, color: theme.colorScheme.error),
          const SizedBox(height: 16),
          Text('No $language speech on this phone', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(
            'Listen mode reads every text aloud, so it needs a $language '
            'text-to-speech voice installed on the device.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Text(
            _installVoiceHint(language),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: _recheckSpeech,
            icon: const Icon(Icons.refresh),
            label: const Text('Check again'),
          ),
        ],
      ),
    );
  }

  /// The non-blocking counterpart of [_noSpeechNotice]: same explanation and
  /// same install steps, in a dialog, for a language whose absence only costs
  /// one clip.
  Future<void> _showMissingVoiceDialog(String language) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('No $language voice'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This phone has no $language text-to-speech voice, so the '
              'translation pass is left out. The ${context.read<AppState>().settings.targetLanguage} '
              'passes still play normally.',
            ),
            const SizedBox(height: 12),
            Text(_installVoiceHint(language), style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _recheckSpeech();
            },
            child: const Text('Check again'),
          ),
        ],
      ),
    );
  }

  Widget _placeholder(IconData icon, String message) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(icon, size: 56, color: scheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Whether the AI can be called at all. Both make-material buttons are dead
  /// without a key — the reserve is the one exception, but it can only ever be
  /// filled by a call that needed one.
  bool get _aiReady => context.read<AppState>().hasAiKey;

  /// Shared shape for the two make-material buttons: a tight icon+label pair
  /// whose label is allowed to wrap onto a second line, since they sit half a
  /// screen wide.
  Widget _makeButton({required Widget icon, required String label, required VoidCallback? onPressed}) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          icon,
          const SizedBox(width: 8),
          Flexible(child: Text(label, textAlign: TextAlign.center)),
        ],
      ),
    );
  }

  Widget _generateButton(AppSettings s) {
    final busy = _generating && !_generatingStory;
    return _makeButton(
      onPressed: _generating || _selectedSubjects.isEmpty || !_aiReady ? null : _generate,
      icon: busy
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.auto_awesome),
      label: busy
          ? 'Generating…'
          : _stories.isEmpty
          ? 'Generate texts'
          // Says "Add" rather than "Generate" when it costs no API call, so
          // it's clear which presses are free and which reach the network.
          : _reserveSig == _sigFor(_selectedSubjects) && _reserve.length >= s.listenTextsPerRun
          ? 'Add ${s.listenTextsPerRun} more (${_reserve.length} ready)'
          : 'Generate ${s.listenTextsPerRun} more texts',
    );
  }

  /// The story generator, at the same level as [_generateButton] rather than
  /// buried in the ⋮ menu: it is one of the two ways to make material, not a
  /// setting.
  Widget _storyButton() {
    return _makeButton(
      onPressed: _generating || _selectedSubjects.isEmpty || !_aiReady ? null : _createStory,
      icon: _generatingStory
          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.auto_stories_outlined),
      label: _generatingStory ? 'Creating…' : 'Create a story',
    );
  }

  /// Identical shape to the Sentence Bank's control bar: three equal-width
  /// 56px filled buttons with 36px icons, ordered **prev, next, play** (play on
  /// the right, not the middle) and turning error-red while running. Kept
  /// deliberately in lockstep — muscle memory should carry between the audio
  /// tabs.
  Widget _navBtn({
    required IconData icon,
    required VoidCallback? onPressed,
    Color? backgroundColor,
    Color? foregroundColor,
  }) {
    return Expanded(
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: backgroundColor,
          foregroundColor: foregroundColor,
          // 1.5x the old 56. The extra height is taken out of the bottom
          // padding below, so the buttons grow downwards and nothing above
          // them shifts.
          minimumSize: const Size(0, 84),
          padding: EdgeInsets.zero,
        ),
        child: Icon(icon, size: 36),
      ),
    );
  }

  Widget _controls() {
    final ready = _playable.isNotEmpty && ttsSupported() && _targetSpeechOk != false;
    final scheme = Theme.of(context).colorScheme;

    final navRow = Row(
      children: [
        _navBtn(icon: Icons.skip_previous, onPressed: ready ? _previous : null),
        const SizedBox(width: 8),
        _navBtn(icon: Icons.skip_next, onPressed: ready ? _next : null),
        const SizedBox(width: 8),
        _navBtn(
          // Pause rather than stop, but the same outlined-circle weight as the
          // Sentences button it sits opposite.
          icon: _playing ? Icons.pause_circle_outline : Icons.play_circle_outline,
          // Only blocked while waiting for the *first* clip; once playback has
          // started, pause/resume work during the background render.
          onPressed: !ready || (_preparing && !_sessionLoaded) ? null : (_playing ? _pause : _play),
          backgroundColor: _playing ? scheme.error : null,
          foregroundColor: _playing ? scheme.onError : null,
        ),
      ],
    );

    if (!_preparing) return navRow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Once audio is running the rest is rendered ahead of the playhead, so
        // calling that "preparing" would suggest you're still waiting on it.
        Text(
          _sessionLoaded ? 'Rendering ahead… $_prepDone/$_prepTotal' : 'Preparing audio… $_prepDone/$_prepTotal',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        navRow,
      ],
    );
  }

  // ── Voices ────────────────────────────────────────────────────────────────

  Future<void> _preview(String locale, String voiceName, double rate) async {
    // The shared player holds audio focus; a live utterance over it is
    // inaudible on some devices, so the playlist yields first.
    await _playlist.pause();
    await TtsSynthService.instance.speak(kVoiceSample, locale: locale, voiceName: voiceName, rate: rate);
  }

  /// Voice picker for both languages at once.
  ///
  /// Target language is multi-select — Listen rotates one voice per text, so
  /// picking several is the normal case. The known language is single-select
  /// (it only ever speaks the translation), matching the Sentences tab's picker.
  Future<void> _showVoicePicker() async {
    final state = context.read<AppState>();
    final s = state.settings;
    final targetByLocale = await TtsSynthService.instance.voicesByLocale(langCodeForLanguage(s.targetLanguage));
    final knownByLocale = await TtsSynthService.instance.voicesByLocale(langCodeForLanguage(s.knownLanguage));
    if (!mounted) return;

    final result = await showModalBottomSheet<({List<String> target, String known})>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _VoicePickerSheet(
        targetLang: s.targetLanguage,
        knownLang: s.knownLanguage,
        targetByLocale: targetByLocale,
        knownByLocale: knownByLocale,
        initialTarget: s.listenVoiceIds,
        initialKnown: s.listenKnownVoice,
        targetRate: _rate(s.listenMediumRatePct),
        onPreview: _preview,
      ),
    );

    await TtsSynthService.instance.stop();
    if (result == null || !mounted) return;
    _pause();
    await state.saveSettingsOnly(
      state.settings.copyWith(listenVoiceIds: result.target, listenKnownVoice: result.known),
    );
    if (!mounted) return;
    setState(() => _cancelBuild()); // different voices → different clips
  }

  // ── Settings ──────────────────────────────────────────────────────────────

  Future<void> _showSettingsSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Consumer<AppState>(
          builder: (ctx, state, _) {
            final s = state.settings;
            void set(AppSettings updated) => state.saveSettingsOnly(updated);
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Listen settings', style: Theme.of(ctx).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Text('Speed', style: Theme.of(ctx).textTheme.titleSmall),
                  Text(
                    'Percentage of normal speaking pace, for each of the three '
                    '${s.targetLanguage} passes.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  _stepper(
                    ctx,
                    label: '1st pass (slow)',
                    suffix: '%',
                    value: s.listenSlowRatePct,
                    min: 30,
                    max: 150,
                    step: 5,
                    onSet: (v) => set(s.copyWith(listenSlowRatePct: v)),
                  ),
                  _stepper(
                    ctx,
                    label: '2nd pass',
                    suffix: '%',
                    value: s.listenMediumRatePct,
                    min: 30,
                    max: 150,
                    step: 5,
                    onSet: (v) => set(s.copyWith(listenMediumRatePct: v)),
                  ),
                  _stepper(
                    ctx,
                    label: 'Final pass (full)',
                    suffix: '%',
                    value: s.listenFullRatePct,
                    min: 30,
                    max: 150,
                    step: 5,
                    onSet: (v) => set(s.copyWith(listenFullRatePct: v)),
                  ),
                  const Divider(height: 24),
                  Text('Pauses', style: Theme.of(ctx).textTheme.titleSmall),
                  _stepper(
                    ctx,
                    label: 'After 1st pass',
                    suffix: 's',
                    value: s.listenPauseAfterSlowSec,
                    min: 0,
                    max: 30,
                    onSet: (v) => set(s.copyWith(listenPauseAfterSlowSec: v)),
                  ),
                  _stepper(
                    ctx,
                    label: 'After 2nd pass',
                    suffix: 's',
                    value: s.listenPauseAfterMediumSec,
                    min: 0,
                    max: 30,
                    onSet: (v) => set(s.copyWith(listenPauseAfterMediumSec: v)),
                  ),
                  _stepper(
                    ctx,
                    label: 'Before next text',
                    suffix: 's',
                    value: s.listenPauseBeforeNextSec,
                    min: 0,
                    max: 30,
                    onSet: (v) => set(s.copyWith(listenPauseBeforeNextSec: v)),
                  ),
                  const Divider(height: 24),
                  Text('Generation', style: Theme.of(ctx).textTheme.titleSmall),
                  Text(
                    'One run makes this many texts in total, drawing on every '
                    'selected subject — a text may combine several.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  _stepper(
                    ctx,
                    label: 'Texts per run',
                    suffix: '',
                    value: s.listenTextsPerRun,
                    min: 1,
                    max: 30,
                    onSet: (v) => set(s.copyWith(listenTextsPerRun: v)),
                  ),
                  _stepper(
                    ctx,
                    label: 'Length of each text',
                    suffix: ' sent.',
                    value: s.listenSentencesPerText,
                    min: 1,
                    max: 10,
                    onSet: (v) => set(s.copyWith(listenSentencesPerText: v)),
                  ),
                  Text(
                    'Roughly how many sentences long each story runs, at about the '
                    'length of your bank sentences — so 3 is about three of them. '
                    'Bank sentences are only seeds for vocabulary and level; the '
                    'stories are written fresh, never assembled from them.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _stepper(
    BuildContext ctx, {
    required String label,
    required String suffix,
    required int value,
    required int min,
    required int max,
    int step = 1,
    // The value box. Sized for the settings sheet's long labels; a shorter
    // label leaves room to widen it so the suffix stops wrapping.
    double valueWidth = 52,
    required void Function(int) onSet,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: Theme.of(ctx).textTheme.bodyMedium)),
          IconButton(icon: const Icon(Icons.remove), onPressed: value - step < min ? null : () => onSet(value - step)),
          SizedBox(
            width: valueWidth,
            child: Text('$value$suffix', textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.titleMedium),
          ),
          IconButton(icon: const Icon(Icons.add), onPressed: value + step > max ? null : () => onSet(value + step)),
        ],
      ),
    );
  }
}

/// What every voice preview says. Deliberately short and fixed — a generated
/// text runs for many seconds, which is far too long to audition a voice, let
/// alone to compare two. Digits are read in the voice's own language, so this
/// sounds like the right language without shipping sample text per language.
const String kVoiceSample = '1, 2, 3, 4, 5.';

/// The Listen voices sheet.
///
/// A real [StatefulWidget] rather than a `StatefulBuilder` over captured locals:
/// the selection is genuinely this sheet's state, and owning it here is what
/// guarantees a tap repaints every row that depends on it (the check moving off
/// "Automatic" being the visible one).
class _VoicePickerSheet extends StatefulWidget {
  const _VoicePickerSheet({
    required this.targetLang,
    required this.knownLang,
    required this.targetByLocale,
    required this.knownByLocale,
    required this.initialTarget,
    required this.initialKnown,
    required this.targetRate,
    required this.onPreview,
  });

  final String targetLang;
  final String knownLang;
  final Map<String, List<Map>> targetByLocale;
  final Map<String, List<Map>> knownByLocale;
  final List<String> initialTarget;
  final String initialKnown;
  final double targetRate;
  final Future<void> Function(String locale, String voiceName, double rate) onPreview;

  @override
  State<_VoicePickerSheet> createState() => _VoicePickerSheetState();
}

class _VoicePickerSheetState extends State<_VoicePickerSheet> {
  late final List<String> _allTargetIds;
  late Set<String> _target;
  late String _known;

  static String _id(String name, String locale) => '${name}__SEP__$locale';

  @override
  void initState() {
    super.initState();
    _allTargetIds = [
      for (final e in widget.targetByLocale.entries)
        for (final v in e.value) _id('${v['name']}', e.key),
    ];
    // An empty stored list *means* "all", so open with them all ticked rather
    // than all blank — an all-unchecked list that still plays every voice is
    // exactly the confusing state this avoids.
    _target = {...widget.initialTarget.where(_allTargetIds.contains)};
    if (_target.isEmpty) _target = {..._allTargetIds};
    _known = widget.initialKnown;
  }

  Widget _sectionTitle(String title, String blurb, {Widget? trailing}) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              Text(blurb, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );

  Widget _previewBtn(String locale, String name, double rate) => IconButton(
    icon: const Icon(Icons.play_arrow_outlined),
    tooltip: 'Hear this voice',
    onPressed: () => widget.onPreview(locale, name, rate),
  );

  static const _empty = Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      'No voices installed for this language. Add one in Android Settings → '
      'System → Languages & input → Text-to-speech output.',
    ),
  );

  /// One locale group. Matches the Sentences picker: an expander per locale,
  /// rows labelled `Voice n` over the engine's own name — the only thing that
  /// tells two otherwise identical rows apart.
  Widget _localeGroup(String locale, List<Map> voices, bool expanded, Widget Function(int, String) row) =>
      ExpansionTile(
        title: Text('$locale  (${voices.length})'),
        initiallyExpanded: expanded,
        children: [for (var i = 0; i < voices.length; i++) row(i, '${voices[i]['name']}')],
      );

  @override
  Widget build(BuildContext context) {
    final allOn = _target.length == _allTargetIds.length;
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
                Text(
                  '${_target.length}/${_allTargetIds.length} ${widget.targetLang}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
          const Divider(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                _sectionTitle(
                  widget.targetLang,
                  'Each text is spoken by the next voice in this list. '
                  'These are the voices installed on this phone.',
                  trailing: TextButton(
                    onPressed: () => setState(() => _target = allOn ? {} : {..._allTargetIds}),
                    child: Text(allOn ? 'None' : 'All'),
                  ),
                ),
                if (widget.targetByLocale.isEmpty) _empty,
                for (final entry in widget.targetByLocale.entries)
                  _localeGroup(entry.key, entry.value, widget.targetByLocale.length == 1, (i, name) {
                    final id = _id(name, entry.key);
                    return CheckboxListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 24, right: 8),
                      title: Text('Voice ${i + 1}'),
                      subtitle: Text(name, overflow: TextOverflow.ellipsis),
                      value: _target.contains(id),
                      secondary: _previewBtn(entry.key, name, widget.targetRate),
                      onChanged: (on) => setState(() => on == true ? _target.add(id) : _target.remove(id)),
                    );
                  }),
                const Divider(height: 16),
                _sectionTitle(widget.knownLang, 'Speaks the translation. One voice only.'),
                ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.only(left: 16, right: 8),
                  title: const Text('Automatic'),
                  subtitle: const Text('Let the engine choose'),
                  trailing: _known.isEmpty ? const Icon(Icons.check) : null,
                  onTap: () => setState(() => _known = ''),
                ),
                if (widget.knownByLocale.isEmpty) _empty,
                for (final entry in widget.knownByLocale.entries)
                  _localeGroup(entry.key, entry.value, widget.knownByLocale.length == 1, (i, name) {
                    final id = _id(name, entry.key);
                    return ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 24, right: 8),
                      leading: _previewBtn(entry.key, name, kSourceSpeechRate),
                      title: Text('Voice ${i + 1}'),
                      subtitle: Text(name, overflow: TextOverflow.ellipsis),
                      trailing: _known == id ? const Icon(Icons.check) : null,
                      onTap: () => setState(() => _known = id),
                    );
                  }),
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
                  onPressed: () => Navigator.pop(context, (target: _target.toList(), known: _known)),
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
