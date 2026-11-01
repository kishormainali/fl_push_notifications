import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    kotlinOut:
        'android/src/main/kotlin/com/kishormainali/push_notifications/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'com.kishormainali.push_notifications'),
    swiftOut:
        'ios/push_notifications/Sources/push_notifications/Messages.g.swift',
  ),
)
enum ImageStyle { none, bigPicture }

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
  @async
  void showNotification(NotificationContent content);
  @async
  String? downloadImage(String url, int timeoutMs, int maxBytes, bool httpsOnly);
}

@FlutterApi()
abstract class PushFlutterApi {
  /// A tap on a notification posted by this plugin. [appWasActive] is the
  /// app's state captured natively when the tap was received (it labels
  /// `PushMessage.appState`; Dart's lifecycle may have changed since).
  void onNativeTap(String payload, bool appWasActive);
}
