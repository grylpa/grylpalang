// lib/screens/notification_history_tab.dart
// import 'dart:convert';
// import 'dart:math';
import 'package:flutter/material.dart';
import 'package:katalaveno/models/history_entry.dart';
import 'package:katalaveno/models/word_sentence.dart';
import 'package:provider/provider.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../state/app_state.dart';
import '../widgets.dart';

class NotificationHistoryTab extends StatefulWidget {
  const NotificationHistoryTab({super.key});

  @override
  State<NotificationHistoryTab> createState() => _NotificationHistoryTabState();
}

class _NotificationHistoryTabState extends State<NotificationHistoryTab> with SingleTickerProviderStateMixin {
  final ItemScrollController _scrollCtl = ItemScrollController();
  final ItemPositionsListener _posListener = ItemPositionsListener.create();
  bool scrollInFlight = false;
  bool _postFrameScheduled = false;

  bool _isIndexComfortablyVisible(int index) {
    final Iterable<ItemPosition> positions = _posListener.itemPositions.value;
    for (final ItemPosition p in positions) {
      if (p.index != index) continue;
      const double topMargin = 0.05;
      const double bottomMargin = 0.95;
      return p.itemLeadingEdge >= topMargin && p.itemTrailingEdge <= bottomMargin;
    }
    return false;
  }

  Widget _buildSentenceTile(BuildContext context, HistoryEntry entry, WordSentence s, int i, AppState state, String noTranslation) {
    // final theme = Theme.of(context);
    // final cs = theme.colorScheme;
    // final isDark = theme.brightness == Brightness.dark;
    // final revealBg = Color.alphaBlend(
    //   isDark ? const Color(0x14FFFFFF) : const Color(0x0F000000),
    //   cs.surface,
    // );

    // this is needed to avoid the ugly top and bottom horizontal lines
    final tileShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
      side: BorderSide.none,
    );

    var (titleText, expandedText) = state.prepareSentenceToShow(entry.sentences, s, noTranslation);
    // final localSeed = entry.fingerprint.hashCode ^ i ^ s.l2.hashCode ^ s.l1.hashCode;
    // final random = Random(localSeed);
    // String expandedText = s.l1.isEmpty ? noTranslation : s.l1;
    // String cleanedL2 = normalizeMarkersWithConnectorPolicy(s.l2, state.settings.connectorWords);
    // cleanedL2 = removeDuplicateMainWord(cleanedL2);
    // final cleaned = sentenceCleanup(cleanedL2);
    // String titleText = cleaned["clean"] ?? cleanedL2;
    // bool reverseTranslation = s.l1.isNotEmpty && random.nextInt(5) < 1;
    // if (reverseTranslation) {
    //   expandedText = titleText;
    //   titleText = s.l1;
    // } else {
    //   final bool useCloze = random.nextInt(10) < 7;   // 70% recall
    //   if (useCloze && cleaned["cloze"] != null && cleaned["clean"] != cleaned["cloze"]) {
    //     expandedText = "${cleaned["clean"]}\n$expandedText";
    //     // titleText = "${cleaned["cloze"]}  (${s.word})";
    //     titleText = "${cleaned["cloze"]}  (${s.translatedWord})";
    //   }
    // }

    return ExpansionTile(
      key: PageStorageKey('hx_${entry.fingerprint}_$i'),
      tilePadding: const EdgeInsets.symmetric(horizontal: 2.0),
      childrenPadding: const EdgeInsets.fromLTRB(2, 0, 0, 0),
      expandedAlignment: Alignment.centerLeft,
      shape: tileShape,
      collapsedShape: tileShape,
      title: Text(titleText,
        textAlign: TextAlign.left,
        style: DefaultTextStyle
            .of(context)
            .style
            .apply(fontSizeDelta: 2.0, fontWeightDelta: 2),
      ),
      children: [
        Text(expandedText,
          style: Theme
              .of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(
            fontStyle: s.l1.isEmpty ? FontStyle.italic : null,
            color: Theme
                .of(context)
                .colorScheme
                .onSurfaceVariant,),),
      ],
    );
  }

  Widget oneHistoryItem(BuildContext context, int index, AppState state, String noTranslation) {
    final history = state.history;
    final entry = history[index];
    final sentences = entry.sentences;
    final isHighlighted = state.highlightHistoryFingerprint != null && entry.fingerprint == state.highlightHistoryFingerprint;

    final cs = Theme.of(context).colorScheme;
    final cardColor = cs.surfaceContainerHigh;

    final Widget content = Padding(
      padding: const EdgeInsets.only(left: 4, right: 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < sentences.length; i++)
            _buildSentenceTile(context, entry, sentences[i], i, state, noTranslation),
        ],
      ),
    );

    final Color borderColor = isHighlighted ? Colors.blue : cs.outlineVariant;
    final double width = isHighlighted ? 1.5 : 1.0;
    return Card(
      key: ValueKey(entry.fingerprint),
      color: cardColor,
      shadowColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12.0),
        side: BorderSide(color: borderColor, width: width),
      ),
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 0),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    // final Random random = Random(seed);
    final state = context.watch<AppState>();
    final history = state.history;
    // final history = [...state.history]..sort((a, b) => b.tappedAt.compareTo(a.tappedAt));
    final noTranslation = noTranslationTextFor(state.settings.knownLanguage);

    if (history.isEmpty) {
      return const Center(
        child: Text(
          'No notification history yet.\n\n'
          'When you tap on notifications, they will appear here.',
          textAlign: TextAlign.center,
        ),
      );
    }

    if (!_postFrameScheduled && !state.scrolledToHighlight) {
      _postFrameScheduled = true;
      state.scrolledToHighlight = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        _postFrameScheduled = false;
        if (!mounted) return;
        if (scrollInFlight) return;
        if (!_scrollCtl.isAttached) return;

        // Re-read current state to avoid stale captured values.
        final s = context.read<AppState>();
        final highlightFp = s.highlightHistoryFingerprint;

        // Highlight already cleared or replaced → do nothing.
        if (highlightFp == null) return;

        // IMPORTANT: use current history (not captured)
        // final currentHistory = [...s.history]..sort((a, b) => b.tappedAt.compareTo(a.tappedAt));
        final currentHistory = s.history;
        final idx = currentHistory.indexWhere((e) => e.fingerprint == highlightFp);
        if (idx < 0) return;

        // if (s.notificationTapToken == s.lastTokenScrolledTo)
        //   return;
        // s.lastTokenScrolledTo = s.notificationTapToken;
        if (!_isIndexComfortablyVisible(idx)) {
          scrollInFlight = true;
          try {
            await _scrollCtl.scrollTo(index: idx, alignment: 0.15, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
            if (!mounted) return;
          } finally {
            scrollInFlight = false;
          }
        }
      });
    }

    return ScrollablePositionedList.builder(
      itemScrollController: _scrollCtl, itemPositionsListener: _posListener,
      key: const PageStorageKey('history_list'),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      itemCount: history.length,
      itemBuilder: (context, index) {
        return oneHistoryItem(context, index, state, noTranslation);
      },
    );
  }
}
