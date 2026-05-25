import 'word_entry.dart';
import 'word_sentence.dart';

class ScheduledSentence {
  final WordEntry word;
  final int index;
  final WordSentence data;

  ScheduledSentence({required this.word, required this.index, required this.data});
}
