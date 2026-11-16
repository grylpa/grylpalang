/// How long the silence after a spoken clip should be, derived from the clip.
///
/// The gaps in a playlist are what separate *listening* from *practice*. Being
/// told what a sentence means immediately after hearing it is re-exposure, and
/// re-exposure is the weakest use of a repetition: the retention comes from
/// attempting the meaning first and only then being confirmed (the testing
/// effect), and the attempt needs room to be made — and to fail, which is where
/// most of the benefit sits (desirable difficulty). A gap also has to be long
/// enough to say the sentence back into, which is the one thing a walk is
/// unusually good for: hands and eyes are busy, the mouth is free, and
/// repeating aloud after the model is the best-supported single exercise in the
/// listening literature.
///
/// A gap fixed in whole seconds cannot do any of that, because what is being
/// retrieved ranges from three words to five sentences. The Sentence Bank's
/// `auto_source_pause` defaults to **1s** and Listen's "thinking time" to
/// **3s**, both read against material that can take half a minute to speak — so
/// in practice the learner was never given time to try, whatever the exercise
/// was meant to be. These helpers size the gap to the utterance instead.
///
/// Every gap keeps the user's own setting as its **floor**: this only ever
/// lengthens a silence, never shortens one, so no stepper in any settings sheet
/// is overridden and turning the numbers up still works.
library;

// Characters per second of speech, the divisor behind [spokenSeconds].
//
// An estimate, not a measurement: synthesized speech in this app's languages
// runs somewhere around 12–15 characters a second at normal rate, varying by
// engine, voice and language. 13 sits in the middle of that, and the precision
// actually needed here is low — the result is rounded to whole seconds, floored
// at the user's setting and capped, so being a second out either way changes
// nothing about the exercise.
const double _kCharsPerSecond = 13.0;

/// Rough number of seconds it takes to speak [text].
///
/// Counted in characters rather than words on purpose: the app's languages
/// differ far too much in word length to compare that way (Greek compounds
/// against English particles), while characters per second holds steady enough
/// across them for sizing a silence.
double spokenSeconds(String text) => text.trim().length / _kCharsPerSecond;

/// The silence to leave after [text], in whole seconds.
///
/// [factor] is how much of the utterance's own duration the learner gets —
/// 1.0 means "as long as it took to say". [cap] bounds the result so one long
/// text cannot leave a silence that reads as the audio having stopped, and
/// [floor] is the user's own setting.
///
/// The order of those two is the whole contract and is **cap first, floor
/// second**: [cap] limits how far this function may *lengthen* a gap, so it
/// must not also shorten one the user asked for. Applied the other way round, a
/// 700-character text with the stepper on 30s came back as 15s — the cap
/// silently overriding a setting this is documented never to undercut.
int retrievalGapSec(String text, {required int floor, required int cap, required double factor}) {
  final want = (spokenSeconds(text) * factor).round();
  final capped = want > cap ? cap : want;
  return capped < floor ? floor : capped;
}

/// Factor for the gap between the two languages of a single sentence
/// (Sentences mode).
///
/// 1.0 — as long as the sentence took to say. The unit of work here *is* the
/// sentence, and at this length the learner can realistically repeat the whole
/// thing, so the gap doubles as the shadowing window. Anything much shorter
/// only leaves room to notice the sentence went past.
const double kGapFactorSentence = 1.0;

/// Cap for [kGapFactorSentence]. A bank sentence is short, so this bites only
/// on an unusually long one, where a full re-say is not what is wanted anyway.
const int kGapCapSentence = 12;

/// Factor for Listen's gap before the known-language pass.
///
/// Below 1.0 because the unit is a whole text rather than one sentence: the
/// learner is assembling the gist, not holding every clause to repeat it back,
/// and the passes on either side already give the text twice. 0.6 is enough to
/// commit to a reading of it before the translation settles the matter.
const double kGapFactorText = 0.6;

/// Cap for [kGapFactorText]. A long story part would otherwise buy 25s of
/// silence, which on a walk reads as the audio having died.
const int kGapCapText = 15;

/// Factor for the gap after Listen's final full-speed pass.
///
/// Smallest of the three: by here the meaning is known and the text has been
/// heard three or four times, so this is consolidation (and a chance to say a
/// line back) rather than retrieval, and the next text follows it.
const double kGapFactorConsolidate = 0.25;

/// Cap for [kGapFactorConsolidate].
const int kGapCapConsolidate = 10;
