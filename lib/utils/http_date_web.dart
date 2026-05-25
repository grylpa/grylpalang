Duration? parseDelay(String v) {
  try {
    final whenUtc = DateTime.parse(v).toUtc();
    final nowUtc = DateTime.now().toUtc();
    final d = whenUtc.difference(nowUtc);
    return d.isNegative ? Duration.zero : d;
  } catch (_) {
    return null;
  }
}
