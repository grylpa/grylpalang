import 'dart:async';

import 'package:flutter/material.dart';
import 'models/word_sentence.dart';
import 'services/ai_service.dart';

/// Shared "tonal blue" style for *filled* icon-buttons (audio controls, add
/// buttons) so they match the app's FilledButtons: primaryContainer fill,
/// onPrimaryContainer icon. Plain icon-buttons (e.g. delete) intentionally keep
/// their transparent default and don't use this.
ButtonStyle blueIconButtonStyle(BuildContext context) {
  final s = Theme.of(context).colorScheme;
  return IconButton.styleFrom(backgroundColor: s.primaryContainer, foregroundColor: s.onPrimaryContainer);
}

Widget tinySpinner({double scale = 0.4}) {
  return SizedBox(
    width: 16,
    height: 16,
    child: Transform.translate(
      // positive Y = move *down* visually
      offset: const Offset(0, 8),
      child: Transform.scale(scale: scale, child: const CircularProgressIndicator(strokeWidth: 4)),
    ),
  );
}

Widget tinyCenteredSpinner({double scale = 0.4}) {
  return SizedBox(
    width: 16,
    height: 16,
    child: Transform.scale(scale: scale, child: const CircularProgressIndicator(strokeWidth: 4)),
  );
}

extension StringExtension on String {
  String capitalize() {
    return "${this[0].toUpperCase()}${substring(1).toLowerCase()}";
  }
}

InputDecoration tfDecor(BuildContext context) => InputDecoration(
  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
  filled: true,
  fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
  // hintText: 'Enter something...',
);

Widget filledTF(
  BuildContext context, {
  TextEditingController? controller,
  String? labelText,
  Widget? suffixIcon,
  bool obscureText = false,
  double leftPadding = 0,
  TextStyle? style,
  String? hintText,
  void Function(String)? onChanged,
}) {
  // TextStyle? textStyle = smallText ? Theme.of(context).textTheme.labelSmall :
  //   Theme.of(context).textTheme.labelMedium;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (labelText != null)
        Padding(
          padding: EdgeInsets.fromLTRB(leftPadding, 0, 0, 0),
          child: Text(labelText, style: style),
        ),
      // SizedBox(height: 4,),
      TextField(
        controller: controller,
        decoration: InputDecoration(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
          suffixIcon: suffixIcon,
          hint: hintText != null ? Text(hintText, style: Theme.of(context).textTheme.labelSmall) : null,
        ),
        onChanged: onChanged,
        obscureText: obscureText,
      ),
    ],
  );
}

Future<bool?> showYesNoDialog(BuildContext context, {required String title, required String message}) {
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('No')),
        TextButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Yes')),
      ],
    ),
  );
}

String noTranslationTextFor(String targetLangCodeOrName) {
  final k = targetLangCodeOrName.trim().toLowerCase();

  if (k.startsWith('el') || k.contains('greek') || k.contains('ελλην')) {
    return 'Δεν υπάρχει διαθέσιμη μετάφραση';
  }
  if (k.startsWith('he') || k.contains('hebrew') || k.contains('עבר')) {
    return 'אין תרגום זמין';
  }
  if (k.startsWith('es') || k.contains('spanish') || k.contains('españ')) {
    return 'No hay traducción disponible';
  }
  if (k.startsWith('fr') || k.contains('french') || k.contains('franç')) {
    return 'Aucune traduction disponible';
  }
  if (k.startsWith('de') || k.contains('german') || k.contains('deutsch')) {
    return 'Keine Übersetzung verfügbar';
  }
  // Fallback to English
  return 'No translation available';
}

bool isTODBetween(TimeOfDay tod, TimeOfDay start, TimeOfDay end) {
  if (start == end) return false;
  if (start.isBefore(end)) {
    return (tod.compareTo(start) >= 0 && tod.isBefore(end));
  } else {
    return (tod.compareTo(start) >= 0 || tod.isBefore(end));
  }
}

String baselineLine(int length) => List.filled(length, ' \u0332').join();

Map<String, String> sentenceCleanup(String sentence) {
  Map<String, String> ret = {"cloze": sentence, "clean": sentence};
  final int start = sentence.indexOf("[[");
  final int end = sentence.indexOf("]]");
  if (start >= 0 && end > start) {
    String cloze = sentence.replaceRange(start, end + 2, " ${baselineLine(6)}");
    String clean = sentence.replaceRange(end, end + 2, "").replaceRange(start, start + 2, "");
    ret["cloze"] = cloze;
    ret["clean"] = clean;
  }
  return ret;
}

String removeDuplicateMainWord(String sentence) {
  String ret = sentence;
  int start = sentence.indexOf("[[");
  int end = sentence.indexOf("]]");
  if (start >= 0 && end > start) {
    String lcsentence = sentence.toLowerCase();
    String mainw = lcsentence.substring(start + 2, end);
    int i = lcsentence.indexOf(mainw);
    //debugPrint("hack $lcsentence , $mainw , $i");
    if (i >= 0 && i < start) {
      ret = sentence.replaceRange(i, mainw.length, "");
    }
  }
  ret = ret.trim();
  start = ret.indexOf("[[");
  if (start == 0 && ret.length > 2) {
    ret = ret.replaceRange(2, 3, ret.substring(2, 3).toUpperCase());
  }
  return ret;
}

String removeConnectorMarkers(String sentence, List<String> connectors) {
  if (connectors.isEmpty || !sentence.contains('[[')) return sentence;
  final set = connectors.map((c) => c.trim()).where((c) => c.isNotEmpty).toSet();
  if (set.isEmpty) return sentence;
  final markerRe = RegExp(r'\[\[([^\[\]]+)\]\]');
  return sentence.replaceAllMapped(markerRe, (m) {
    final token = m.group(1)!;
    return set.contains(token) ? token : m.group(0)!;
  });
}

String stripAllMarkersIfMultipleRemain(String sentence) {
  if (!sentence.contains('[[')) return sentence;
  final markerRe = RegExp(r'\[\[([^\[\]]+)\]\]');
  final count = markerRe.allMatches(sentence).length;
  if (count <= 1) return sentence;
  return sentence.replaceAllMapped(markerRe, (m) => m.group(1)!);
}

String normalizeMarkersWithConnectorPolicy(String sentence, List<String> connectors) {
  final s1 = removeConnectorMarkers(sentence, connectors);
  return stripAllMarkersIfMultipleRemain(s1);
}

String fingerprintSentences(List<WordSentence> sentences) {
  final parts = sentences.map((s) => '${s.l2}␟${s.l1}').join('␞');
  return parts.hashCode.toString(); // cheap + stable enough for this purpose
}

/// Live one-line report of what an in-flight AI call is doing — which model it
/// has fallen through to, or how long it is waiting out a rate limit.
///
/// Mounted **once**, by `MainScaffold`, so every AI call in the app reports
/// itself for free and a feature added later cannot forget to opt in. It is not
/// a snackbar: one call can try four models and sit through two backoffs, which
/// would be four snackbars covering the screen to say what one strip says
/// better, and a snackbar times out while the wait goes on.
///
/// It **floats** over the bottom of the content rather than taking layout
/// space: that is where the eye already is (the add-word row, the Generate
/// buttons), and overlaying means a `SnackBarBehavior.fixed` message — which is
/// laid out in that same strip — can't shunt the page up and down.
///
/// Renders nothing when idle, which is the normal state.
class AiActivityBanner extends StatefulWidget {
  const AiActivityBanner({super.key});

  @override
  State<AiActivityBanner> createState() => _AiActivityBannerState();
}

class _AiActivityBannerState extends State<AiActivityBanner> {
  String _text = '';

  /// True for a moment after the text changes. A fallback to another model is
  /// the whole point of this strip, and a quiet swap of one model name for
  /// another is exactly the kind of change that goes unnoticed — so the pill
  /// brightens and its text thickens when it happens.
  bool _flash = false;
  Timer? _flashTimer;

  /// How long a message is guaranteed to stay on screen.
  ///
  /// Without this the strip silently skips steps: a model that answers in
  /// milliseconds — an instant 429 is the common case — has its message
  /// overwritten before a frame is even drawn, so the user sees "asking 3.8",
  /// then "3.7 rate-limited, trying 3.6", and never learns what 3.8 did.
  static const Duration _minDisplay = Duration(milliseconds: 900);

  DateTime _shownAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _pending;
  Timer? _holdTimer;

  /// Which model attempt the currently shown text belongs to. The flash fires on
  /// a change of *this*, not of the text — the text also ticks with elapsed
  /// seconds during a long generation, and flashing amber every ten seconds
  /// would turn a status line into a strobe.
  int _shownStep = 0;

  @override
  void initState() {
    super.initState();
    _text = AiService.activity.value;
    AiService.activity.addListener(_onChange);
  }

  @override
  void dispose() {
    AiService.activity.removeListener(_onChange);
    _flashTimer?.cancel();
    _holdTimer?.cancel();
    super.dispose();
  }

  void _onChange() {
    final next = AiService.activity.value;
    if (next == _text && _pending == null) return;
    final waited = DateTime.now().difference(_shownAt);
    if (waited >= _minDisplay) {
      _apply(next);
      return;
    }
    // Too soon: hold it, and show it when the current message has had its time.
    // Only the newest pending value matters — intermediate ones are already
    // stale by the time the timer fires.
    _pending = next;
    _holdTimer ??= Timer(_minDisplay - waited, () {
      _holdTimer = null;
      final queued = _pending;
      _pending = null;
      if (queued != null && mounted) _apply(queued);
    });
  }

  void _apply(String next) {
    if (next == _text) return;
    // Only a real change of model announces itself; going quiet at the end of a
    // call should not flash.
    final step = AiService.activityStep.value;
    final announce = next.isNotEmpty && _text.isNotEmpty && step != _shownStep;
    _shownStep = step;
    setState(() {
      _text = next;
      _flash = announce;
    });
    _shownAt = DateTime.now();
    if (announce) {
      _flashTimer?.cancel();
      _flashTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _flash = false);
      });
    }
    // A value that arrived while this one was waiting its turn still needs
    // showing — re-arm from here.
    if (_pending != null && _holdTimer == null) {
      _holdTimer = Timer(_minDisplay, () {
        _holdTimer = null;
        final queued = _pending;
        _pending = null;
        if (queued != null && mounted) _apply(queued);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // A light panel like lpSnack's, in a different hue so the two are never
    // confused: that one is a message about what happened, this is a live
    // report of what is happening.
    const idle = Color.fromARGB(255, 205, 227, 255);
    const alert = Color.fromARGB(255, 255, 214, 165);
    return IgnorePointer(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _text.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                // A fixed height, so a message that wraps to two lines doesn't
                // make the pill jump up and down mid-call — the movement read as
                // a glitch rather than as information.
                child: AnimatedContainer(
                  height: 62,
                  duration: const Duration(milliseconds: 250),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: _flash ? alert : idle,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                          child: Center(
                            child: Text(
                              _text,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.black87,
                                fontWeight: _flash ? FontWeight.w600 : FontWeight.normal,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // A thin bar rather than a spinner: the buttons that
                      // trigger these calls already show a circular indicator,
                      // and two spinning circles at once is just noise.
                      const LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: Colors.black12,
                        color: Colors.black38,
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

void lpSnack(BuildContext context, String text, int ms, {bool center = true}) {
  Color bkcolor = Color.fromARGB(255, 255, 255, 176);
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(24),
          topRight: Radius.circular(24),
          // bottomLeft: Radius.circular(4),
          // bottomRight: Radius.circular(4),
        ),
      ),
      backgroundColor: bkcolor,
      // backgroundColor: Color.fromARGB(200,255,239,156),
      duration: Duration(milliseconds: ms),
      // behavior: SnackBarBehavior.floating,
      behavior: SnackBarBehavior.fixed,
      padding: EdgeInsets.zero,
      // margin: EdgeInsets.symmetric(horizontal: 16, vertical: 00),
      //content: Text(text, textAlign: center ? TextAlign.center : TextAlign.left,),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            // Horizontal padding matters: the SnackBar itself is given
            // EdgeInsets.zero, so without it a long message runs into both
            // screen edges and reads as spilling out of the bar.
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Text(text, textAlign: center ? TextAlign.center : TextAlign.left),
          ),
          // The narrow gradient line
          Container(
            height: 8.0, // Thickness of the narrow line
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [
                  Theme.of(context).bottomNavigationBarTheme.backgroundColor ?? Colors.black, // Nav Bar Color
                  bkcolor,
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
