import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Describes an Android notification channel to be registered.
class PushChannel {
  PushChannel({
    required this.id,
    required this.name,
    this.description,
    this.importance = Importance.defaultImportance,
    this.playSound = true,
    this.enableVibration = true,
    this.showBadge = true,
    this.groupId,
  });

  String id;
  String name;
  String? description;
  Importance importance;
  bool playSound;
  bool enableVibration;
  bool showBadge;
  String? groupId;
}

/// App icon badge behaviour.
class BadgeConfig {
  BadgeConfig({
    this.autoIncrementOnPush = false,
    this.autoClearOnForeground = false,
  });

  bool autoIncrementOnPush;
  bool autoClearOnForeground;
}
