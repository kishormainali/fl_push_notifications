import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Describes an Android notification channel to be registered.
class PushChannel {
  /// Creates a channel description. Only [id] and [name] are required.
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

  /// Unique channel id. Messages select a channel by this id.
  String id;

  /// User-visible channel name, shown in system settings.
  String name;

  /// Optional user-visible description of the channel.
  String? description;

  /// Importance (interruption level) of notifications on this channel.
  Importance importance;

  /// Whether notifications on this channel play a sound.
  bool playSound;

  /// Whether notifications on this channel vibrate the device.
  bool enableVibration;

  /// Whether notifications on this channel contribute to the app icon badge.
  bool showBadge;

  /// Optional id of the channel group this channel belongs to.
  String? groupId;
}

/// App icon badge behaviour.
class BadgeConfig {
  /// Creates a badge configuration; both behaviours are off by default.
  BadgeConfig({
    this.autoIncrementOnPush = false,
    this.autoClearOnForeground = false,
  });

  /// Whether the badge count is incremented for each incoming push.
  bool autoIncrementOnPush;

  /// Whether the badge is cleared when the app returns to the foreground.
  bool autoClearOnForeground;
}
