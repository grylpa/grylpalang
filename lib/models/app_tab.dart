import 'package:flutter/material.dart';

/// The bottom-nav destinations, in their fixed on-screen order.
///
/// Identified by [id], never by position: tabs can be hidden (Settings →
/// "Tabs"), so an index into the *visible* list means nothing once the user
/// changes that set, and inserting a destination here would silently re-point
/// anything that had saved a raw index.
enum AppTab {
  dashboard('active', 'Active', Icons.spellcheck_outlined, Icons.spellcheck),
  history('history', 'History', Icons.history_outlined, Icons.history),
  predict('predict', 'Predict', Icons.psychology_outlined, Icons.psychology),
  sentences('sentences', 'Sentences', Icons.menu_book_outlined, Icons.menu_book),
  books('books', 'Books', Icons.auto_stories_outlined, Icons.auto_stories),
  listen('listen', 'Listen', Icons.hearing_outlined, Icons.hearing),
  settings('settings', 'Settings', Icons.settings_outlined, Icons.settings);

  const AppTab(this.id, this.label, this.icon, this.activeIcon);

  final String id;
  final String label;
  final IconData icon;
  final IconData activeIcon;

  /// Everything except Settings can be hidden — that one stays, since it holds
  /// the switches that bring the others back.
  bool get canHide => this != AppTab.settings;

  static AppTab? byId(String id) {
    for (final t in AppTab.values) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// The visible destinations, in enum order. An unknown id in [hiddenIds] is
  /// ignored, so a tab removed from a future build can't strand the list.
  static List<AppTab> visibleFrom(List<String> hiddenIds) => [
    for (final t in AppTab.values)
      if (!t.canHide || !hiddenIds.contains(t.id)) t,
  ];

  /// Tab order from before tabs became hideable. Used once, to translate a
  /// saved `lastTabIndex` into an id the new code understands.
  static const List<AppTab> legacyOrder = [
    AppTab.dashboard,
    AppTab.history,
    AppTab.predict,
    AppTab.sentences,
    AppTab.books,
    AppTab.settings,
  ];
}
