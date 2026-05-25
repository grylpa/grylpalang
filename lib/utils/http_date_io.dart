import 'dart:io';

Duration? parseDelay(String v) {
  final whenUtc = HttpDate.parse(v);
  final nowUtc = DateTime.now().toUtc();
  final d = whenUtc.difference(nowUtc);
  return d.isNegative ? Duration.zero : d;
}
