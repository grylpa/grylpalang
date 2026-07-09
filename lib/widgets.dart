import 'package:flutter/material.dart';
import 'models/word_sentence.dart';

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
    String mainw = lcsentence.substring(start+2, end);
    int i = lcsentence.indexOf(mainw);
    //debugPrint("hack $lcsentence , $mainw , $i");
    if (i >= 0 && i < start) {
      ret = sentence.replaceRange(i, mainw.length, "");
    }
  }
  ret = ret.trim();
  start = ret.indexOf("[[");
  if (start == 0 && ret.length > 2) {
    ret = ret.replaceRange(2, 3, ret.substring(2,3).toUpperCase());
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

void lpSnack(BuildContext context, String text, int ms, {bool center = true}) {
  Color bkcolor = Color.fromARGB(255,255,255,176);
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
              padding: const EdgeInsets.fromLTRB(0,8,0,4),
              child: Text(text, textAlign: center ? TextAlign.center : TextAlign.left,),
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
      ));
}