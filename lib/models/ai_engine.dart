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
/// That premise is what makes a **deprecated** model id actively harmful here
/// rather than merely stale. Google retires a model by auto-routing its id to
/// the successor, so the old id keeps answering 200 and nothing in the app can
/// tell — but the traffic is metered against the *target's* quota. Such a link
/// is therefore a guaranteed 429 whenever the link it aliases is blocked, with
/// the whole prompt uploaded to earn it, re-paid on every pass `queryModel`
/// makes. `gemini-3.7-flash` (routed to 3.8) and `gemini-3.5-flash` (routed to
/// 3.6) were both dropped for this on 2026-10-11; a shut-down id would have
/// been harmless by comparison, since a 404 is skipped on the first try. **So
/// a model is only worth a link while it is a model**: check the deprecation
/// table before adding one, and prefer a stable id to a preview, which can be
/// withdrawn in months (`gemini-3-pro-preview` lasted from 2025-11-18 to
/// 2026-03-09).
///
/// Generations have not historically taken the same parameters, which is why
/// this is a type rather than a pair of endpoint strings: Gemini 3.x dropped
/// `temperature` / `top_p` / `top_k` and replaced the thinking budget with a
/// `thinkingLevel` enum, and `AiService._adaptBody` reshapes every request to
/// whichever engine is live so no call site has to know. Both entries are now
/// 3.x and so take the same parameters, which makes that machinery dormant
/// rather than unnecessary — it is what let the second engine be swapped off
/// 2.5 by editing this file alone, and the next divergence will land the same
/// way.
enum AiEngine {
  // Default, and listed first so the dropdown opens on it. 3.8 has held up in
  // use once the Listen generators stopped forcing its thinking level down —
  // their word-budget counting is reasoning work, and it does that better than
  // any model before it.
  gemini3(
    id: '3.x',
    label: 'Gemini 3.8',
    description: 'The default: 3.8 Flash, stepping down through 3.6 Flash to 3.5 Flash-Lite.',
    // Three links, three models. It was five until 3.7-flash and 3.5-flash were
    // deprecated into aliases of 3.8 and 3.6 — see the note above on why an
    // alias is worse than an absence. Every id here is documented stable with
    // no shutdown date. Deliberately not included: 'gemini-3.1-flash-lite'
    // (stable, but the only one carrying a real shutdown date, and its own
    // documented replacement is the lite already at the tail), the Pro models
    // (another tier — far tighter free-tier allowance, much slower) and
    // anything '-preview'.
    models: ['gemini-3.8-flash', 'gemini-3.6-flash', 'gemini-3.5-flash-lite'],
    // Documented as removed for 3.8. Omitting a parameter is always accepted;
    // sending an unsupported one can 400 — and the worst place to discover that
    // is on the fallback path, so every model in the chain is treated alike.
    acceptsSampling: false,
    // 'medium' is the default and makes the model reason before every answer,
    // which costs output tokens and latency on work this short. Low is enough
    // for sentence generation and grading; the Listen generators override it
    // per call, since counting new words against the seed list *is* reasoning.
    thinkingLevel: 'low',
  ),
  // The escape hatch: pin to the generation *before* the default when the
  // default's register is wrong for learners — which is a real complaint, not a
  // hypothetical one (3.8 wrote harder texts than its predecessor until the
  // Listen generators' thinking level was raised).
  //
  // This used to be the Gemini 2.5 pair, and it was replaced because it had
  // quietly stopped being an option **for anyone but this developer**: since
  // 2026-09-18 Google restricts 2.5 to keys that have actively used it before.
  // This project's key qualifies, since 2.5 was the original chain; a learner
  // who pastes a fresh key gets a 404 from every 2.5 link, so the picker was
  // offering a repair that could only work on the machine it was tested on. A
  // fallback has to be reachable by every install or it isn't one.
  //
  // So the hatch is now the previous-generation Flash, which any key can reach.
  // The overlap with [gemini3]'s own tail is deliberate and not redundancy: the
  // chain reaches 3.6 only after 3.8 has refused a request, while this *starts*
  // there and never asks 3.8 at all — the 429 fallback and the deliberate pin
  // are different jobs.
  geminiPrev(
    // Not '3.6': the id is stored, and this entry means "the generation below
    // the default" rather than one particular model, so it must survive 3.6
    // being swapped out the way 2.5 just was.
    id: 'prev',
    // Named for the model, to stay parallel with the entry above it in a
    // two-item dropdown — 'Gemini 3.8' beside 'Previous generation' reads as
    // two different kinds of answer. The *role* is in the description, which
    // has to be rewritten alongside [models] anyway; only [id] is stored, so
    // only [id] has to outlive a swap.
    label: 'Gemini 3.6',
    description: 'The generation below the default: 3.6 Flash, falling back to 3.5 Flash-Lite.',
    models: ['gemini-3.6-flash', 'gemini-3.5-flash-lite'],
    // Every generally-available model has now dropped sampling, so nothing sets
    // this true any more. Kept because it is what *stops* a `temperature` the
    // call sites still pass from reaching the wire, and because the day a model
    // takes one again is the day this has to be expressible.
    acceptsSampling: false,
    // Both accept 'low'; both also accept 'minimal', which 3.8 does not, and
    // 3.5-flash-lite defaults to it. Asking for 'low' therefore makes the Lite
    // think slightly harder than it would by default — which is the point of it
    // being the last link rather than the first.
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

  /// Stored in settings. Deliberately a generation ('prev'), not a model id, so
  /// swapping which model a generation points at doesn't invalidate the setting
  /// — which has now happened twice, and both times cost nothing.
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

  /// '2.5' is what an install that chose the old second engine still holds.
  /// It resolves to [geminiPrev] rather than to the [gemini3] default, because
  /// that choice meant "the generation below the newest" and still can — the
  /// models behind it changed, which is precisely what [id] is a generation
  /// rather than a model id for. Falling through to the default would instead
  /// move someone who deliberately stepped *down* onto the newest model.
  static AiEngine byId(String? id) => switch (id) {
    '2.5' => AiEngine.geminiPrev,
    _ => AiEngine.values.firstWhere((e) => e.id == id, orElse: () => AiEngine.gemini3),
  };
}
