import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/com/kishormainali/fl_push_notifications/Messages.g.kt',
    kotlinOptions: KotlinOptions(
      package: 'com.kishormainali.fl_push_notifications',
    ),
    swiftOut: 'ios/fl_push_notifications/Sources/fl_push_notifications/Messages.g.swift',
  ),
)
enum ImageStyle { none, bigPicture }

/// A button on a notification. Pressing it opens the app and reports [id].
class NotificationAction {
  NotificationAction({required this.id, required this.title});

  String id;
  String title;
}

class NotificationContent {
  NotificationContent({
    required this.id,
    this.title,
    this.body,
    required this.channelId,
    required this.data,
    this.imageUrl,
    required this.imageStyle,
    this.badge,
    required this.extras,
    this.groupKey,
    required this.actions,
  });

  int id;
  String? title;
  String? body;
  String channelId;
  Map<String?, String?> data;
  String? imageUrl;
  ImageStyle imageStyle;
  int? badge;
  Map<String?, Object?> extras;

  /// Notifications with the same key are grouped (Android group + summary,
  /// iOS thread identifier).
  String? groupKey;
  List<NotificationAction> actions;
}

class ChannelConfig {
  ChannelConfig({
    required this.id,
    required this.name,
    this.channelDescription,
    required this.importance,
    required this.playSound,
    required this.enableVibration,
    required this.showBadge,
    this.groupId,
  });

  String id;
  String name;
  String? channelDescription;
  int importance;
  bool playSound;
  bool enableVibration;
  bool showBadge;
  String? groupId;
}

class BackgroundConfigMsg {
  BackgroundConfigMsg({
    required this.defaultChannelId,
    required this.channelKey,
    required this.imageKey,
    required this.titleKey,
    required this.bodyKey,
    required this.imageHttpsOnly,
    required this.autoIncrementOnPush,
    required this.autoClearOnForeground,
    this.hookHandle,
  });

  String defaultChannelId;
  String channelKey;
  String imageKey;
  String titleKey;
  String bodyKey;
  bool imageHttpsOnly;
  bool autoIncrementOnPush;
  bool autoClearOnForeground;
  int? hookHandle;
}

@HostApi()
abstract class PushHostApi {
  bool isBadgeSupported();
  void setBadgeCount(int count);
  int? getBadgeCount();
  void clearBadge();
  int incrementBadge();
  void createChannel(ChannelConfig c);
  void deleteChannel(String id);
  String? getLastLaunchId();
  void setLastLaunchId(String id);
  void saveBackgroundConfig(BackgroundConfigMsg config);
  BackgroundConfigMsg? loadBackgroundConfig();
  String? consumeLaunchPayload();

  /// Looks up the app string named [key] (an Android string resource, or an
  /// iOS `Localizable.strings` entry) and formats [args] into it. Returns
  /// `null` when there is no such string.
  String? resolveLocalizedString(String key, List<String> args);
  @async
  void showNotification(NotificationContent content);
  @async
  String? downloadImage(
    String url,
    int timeoutMs,
    int maxBytes,
    bool httpsOnly,
  );
}

@FlutterApi()
abstract class PushFlutterApi {
  /// A tap on a notification posted by this plugin. [appWasActive] is the
  /// app's state captured natively when the tap was received (it labels
  /// `PushMessage.appState`; Dart's lifecycle may have changed since).
  void onNativeTap(String payload, bool appWasActive);

  /// The user dismissed (swiped away) a notification posted by this plugin;
  /// [payload] is its tap payload.
  void onNativeDismiss(String payload);
}
