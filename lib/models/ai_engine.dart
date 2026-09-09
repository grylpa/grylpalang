/// Which Gemini generation the app talks to.
///
/// A generation, not a single model: each one is an ordered chain, tried in
/// turn when the one before returns 429. The chain steps *down* gradually and
/// stays in the family — dropping from the newest Flash straight to a Lite
/// skips the models closest to it, and a fallback generations older answers in
/// a different register, which shows up as the odd out-of-place sentence in an
/// otherwise consistent bank.
///
/// Free-tier limits are per model, so each extra link is a genuinely separate
/// allowance rather than a retry against the same one — and every Flash in the
/// chain is worth trying before the Lite at the end of it. The only cost is one
/// fast 429 round trip per link, paid on a request that is already blocked.
///
/// The generations do not take the same parameters, which is why this exists as
/// a type rather than a pair of endpoint strings: Gemini 3.x dropped
/// `temperature` / `top_p` / `top_k` and replaced the thinking budget with a
/// `thinkingLevel` enum. [AiService] adapts every request body to the selected
/// engine, so no individual call site has to know which is in use.
enum AiEngine {
  gemini25(
    id: '2.5',
    label: 'Gemini 2.5',
    description: 'Flash, falling back to Flash-Lite. The long-standing default.',
    models: ['gemini-2.5-flash', 'gemini-2.5-flash-lite'],
    acceptsSampling: true,
    thinkingLevel: null,
  ),
  gemini3(
    id: '3.x',
    label: 'Gemini 3.8',
    description: 'Newer and stronger: 3.8 Flash, stepping down through 3.7, 3.6 and 3.5 to 3.5 Flash-Lite.',
    models: ['gemini-3.8-flash', 'gemini-3.7-flash', 'gemini-3.6-flash', 'gemini-3.5-flash', 'gemini-3.5-flash-lite'],
    // Documented as removed for 3.8. Omitting a parameter is always accepted;
    // sending an unsupported one can 400 — and the worst place to discover that
    // is on the fallback path, so both models in the pair are treated alike.
    acceptsSampling: false,
    // 'medium' is the default and makes the model reason before every answer,
    // which costs output tokens and latency on work this short. Low is enough
    // for sentence generation and grading.
    thinkingLevel: 'low',
  );

  const AiEngine({
    required this.id,
    required this.label,
    required this.description,
    required this.models,
    required this.acceptsSampling,
    required this.thinkingLevel,
  });

  /// Stored in settings. Deliberately a generation ('2.5'), not a model id, so
  /// swapping which model a generation points at doesn't invalidate the setting.
  final String id;
  final String label;
  final String description;

  /// Primary first, then each fallback in order.
  final List<String> models;

  String get primaryModel => models.first;

  /// Whether `temperature` (and friends) may be sent.
  final bool acceptsSampling;

  /// `generationConfig.thinkingConfig.thinkingLevel`, or null where the model
  /// has no such control.
  final String? thinkingLevel;

  static AiEngine byId(String? id) => AiEngine.values.firstWhere((e) => e.id == id, orElse: () => AiEngine.gemini25);
}
