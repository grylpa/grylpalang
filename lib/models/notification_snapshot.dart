// lib/models/notification_snapshot.dart

class NotificationSnapshot {
  final int step; // global step index this notification corresponds to
  final DateTime firedAt; // when we *plan* to fire it (or did fire)

  NotificationSnapshot({required this.step, required this.firedAt});

  Map<String, dynamic> toJson() => {'step': step, 'firedAt': firedAt.toIso8601String()};

  factory NotificationSnapshot.fromJson(Map<String, dynamic> json) {
    return NotificationSnapshot(step: json['step'] as int, firedAt: DateTime.parse(json['firedAt'] as String));
  }
}
