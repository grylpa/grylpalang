/// Turns display text into what a text-to-speech engine should be given.
///
/// Engines stumble on abbreviations: "Mr." comes out spelled or mangled, and —
/// worse — the abbreviation's dot is read as a full stop, so the voice pauses
/// in the middle of a sentence. The screen keeps the text exactly as written;
/// only speech is rewritten.
///
/// Applied inside the synth and fetch services themselves rather than at call
/// sites, so every mode that speaks (Sentences, Listen, Books, previews) gets it
/// without having to remember to — and so the audio cache is keyed by what is
/// actually spoken.
String speakable(String text, String langCode) {
  final rules = _rules[langCode.toLowerCase()];
  if (rules == null) return text;
  var out = text;
  for (final (pattern, replacement) in rules) {
    out = out.replaceAll(pattern, replacement);
  }
  return out;
}

/// [speakable] for callers holding a locale ("el-GR") rather than a bare
/// language code — the Books reader, Predict and the voice previews.
String speakableForLocale(String text, String? locale) =>
    locale == null || locale.isEmpty ? text : speakable(text, locale.split(RegExp('[-_]')).first);

// Abbreviations that can open a sentence carry their capital explicitly
// ([Ee], [Δδ]…) instead of a case-insensitive flag: under that flag \p{Lu}
// matches lowercase too, which would defeat the two guards below.

// A title is always followed by a name, so the titles only expand before a
// capitalised word. That keeps them safe where the same letters mean something
// else ("Elm Dr." is a street, not a doctor).
const String _beforeName = r'(?=\s+\p{Lu})';
// Not preceded by a letter: the abbreviation starts a word.
const String _wordStart = r'(?<!\p{L})';
// At the very end of a sentence the dot is doing double duty, so the expansion
// keeps one — otherwise the natural pause after the sentence would be lost.
const String _sentenceEnd = r'(?=\s*$|\s+\p{Lu})';

RegExp _re(String source) => RegExp(source, unicode: true);

final Map<String, List<(RegExp, String)>> _rules = {
  'en': [
    (_re('${_wordStart}Mr\\.$_beforeName'), 'Mister'),
    (_re('${_wordStart}Mrs\\.$_beforeName'), 'Missus'),
    (_re('${_wordStart}Ms\\.$_beforeName'), 'Miz'),
    (_re('${_wordStart}Dr\\.$_beforeName'), 'Doctor'),
    (_re('${_wordStart}Prof\\.$_beforeName'), 'Professor'),
    (_re('${_wordStart}Jr\\.'), 'Junior'),
    (_re('${_wordStart}Sr\\.'), 'Senior'),
    (_re('$_wordStart[Ee]\\.g\\.'), 'for example'),
    (_re('$_wordStart[Ii]\\.e\\.'), 'that is'),
    (_re('$_wordStart[Vv]s\\.'), 'versus'),
    // Order matters: the sentence-final form first, so the plain one doesn't
    // swallow its full stop.
    (_re('${_wordStart}etc\\.$_sentenceEnd'), 'et cetera.'),
    (_re('${_wordStart}etc\\.'), 'et cetera'),
  ],
  'es': [
    (_re('${_wordStart}Srta\\.$_beforeName'), 'señorita'),
    (_re('${_wordStart}Sra\\.$_beforeName'), 'señora'),
    (_re('${_wordStart}Sr\\.$_beforeName'), 'señor'),
    (_re('${_wordStart}Dra\\.$_beforeName'), 'doctora'),
    (_re('${_wordStart}Dr\\.$_beforeName'), 'doctor'),
    (_re('${_wordStart}Sta\\.$_beforeName'), 'santa'),
    (_re('${_wordStart}Sto\\.$_beforeName'), 'santo'),
    // Usted is a pronoun, not a title: it expands wherever it stands.
    (_re('$_wordStart[Uu]ds\\.'), 'ustedes'),
    (_re('$_wordStart[Uu]d\\.'), 'usted'),
    (_re('$_wordStart[Pp]\\. ?ej\\.'), 'por ejemplo'),
    (_re('${_wordStart}aprox\\.'), 'aproximadamente'),
    (_re('${_wordStart}etc\\.$_sentenceEnd'), 'etcétera.'),
    (_re('${_wordStart}etc\\.'), 'etcétera'),
  ],
  'it': [
    // The feminine forms carry letters after the dot (Sig.ra, Dott.ssa), so
    // they can never be mistaken for the plain title followed by a space.
    (_re('${_wordStart}Sig\\.ra$_beforeName'), 'signora'),
    (_re('${_wordStart}Sig\\.na$_beforeName'), 'signorina'),
    (_re('${_wordStart}Sig\\.$_beforeName'), 'signor'),
    (_re('${_wordStart}Dott\\.ssa$_beforeName'), 'dottoressa'),
    (_re('${_wordStart}Dott\\.$_beforeName'), 'dottor'),
    (_re('${_wordStart}Prof\\.ssa$_beforeName'), 'professoressa'),
    (_re('${_wordStart}Prof\\.$_beforeName'), 'professor'),
    (_re('${_wordStart}Avv\\.$_beforeName'), 'avvocato'),
    (_re('${_wordStart}Ing\\.$_beforeName'), 'ingegner'),
    // "per es." and "p.es." first, so the bare "es." rule can't split them.
    (_re('$_wordStart[Pp]er es\\.'), 'per esempio'),
    (_re('$_wordStart[Pp]\\. ?es\\.'), 'per esempio'),
    (_re('${_wordStart}es\\.'), 'ad esempio'),
    (_re('${_wordStart}ecc\\.$_sentenceEnd'), 'eccetera.'),
    (_re('${_wordStart}ecc\\.'), 'eccetera'),
  ],
  'el': [
    // κ. before a surname is κύριος; anywhere else it is left alone.
    (_re('${_wordStart}κ\\.$_beforeName'), 'κύριος'),
    (_re('$_wordStart[Ππ]\\.χ\\.'), 'παραδείγματος χάρη'),
    (_re('${_wordStart}(?:κ\\.λ\\.π\\.|κ\\.λπ\\.|κλπ\\.)$_sentenceEnd'), 'και λοιπά.'),
    (_re('${_wordStart}(?:κ\\.λ\\.π\\.|κ\\.λπ\\.|κλπ\\.)'), 'και λοιπά'),
    (_re('$_wordStart[Δδ]ηλ\\.'), 'δηλαδή'),
  ],
};
