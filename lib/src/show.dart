/// A button on a notification posted with `PushNotifications.show`.
///
/// Pressing it opens the app and delivers the tap to the `decisionMaker` with
/// `PushMessage.actionId` set to [id]. It does not run Dart code while the
/// app is closed.
class PushAction {
  /// Creates a button with a stable [id] and a user-visible [title].
  const PushAction({required this.id, required this.title});

  /// Reported as `PushMessage.actionId` when the button is pressed.
  final String id;

  /// Button label.
  final String title;
}

/// A notification to post from app code with `PushNotifications.show`.
class PushNotification {
  /// Creates a notification; give at least a [title] or a [body].
  const PushNotification({
    this.id,
    this.title,
    this.body,
    this.data = const {},
    this.imageUrl,
    this.channelId,
    this.groupKey,
    this.actions = const [],
  });

  /// Message id. Showing the same id again replaces the earlier notification.
  /// A unique one is generated when null.
  final String? id;

  /// Notification title.
  final String? title;

  /// Notification body.
  final String? body;

  /// Custom data, delivered back on tap.
  final Map<String, String> data;

  /// Optional image URL (downloaded natively).
  final String? imageUrl;

  /// Android channel id; the default channel when null or unknown.
  final String? channelId;

  /// Notifications sharing a key are grouped.
  final String? groupKey;

  /// Buttons shown on the notification.
  final List<PushAction> actions;
}
