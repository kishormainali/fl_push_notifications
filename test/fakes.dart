import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:push_notifications/src/config.dart';
import 'package:push_notifications/src/messages.g.dart';
import 'package:push_notifications/src/ports.dart';
import 'package:push_notifications/src/push_message.dart';

class FakeMessagingPort implements MessagingPort {
  RemoteMessage? initial;
  final onMessageCtl = StreamController<RemoteMessage>.broadcast();
  final openedCtl = StreamController<RemoteMessage>.broadcast();
  final tokenCtl = StreamController<String>.broadcast();
  int initialCalls = 0;
  bool? presentationAlert;
  Function? backgroundHandler;

  @override
  Future<RemoteMessage?> getInitialMessage() async {
    initialCalls++;
    return initial;
  }

  @override
  Stream<RemoteMessage> get onMessage => onMessageCtl.stream;
  @override
  Stream<RemoteMessage> get onMessageOpenedApp => openedCtl.stream;
  @override
  Future<String?> getToken() async => 'tok';
  @override
  Stream<String> get onTokenRefresh => tokenCtl.stream;
  @override
  Future<NotificationSettings> requestPermission() =>
      throw UnimplementedError();
  @override
  Future<void> setForegroundPresentation({
    required bool alert,
    required bool badge,
    required bool sound,
  }) async {
    presentationAlert = alert;
  }

  @override
  Future<void> subscribeToTopic(String t) async {}
  @override
  Future<void> unsubscribeFromTopic(String t) async {}
  @override
  void setBackgroundHandler(BackgroundMessageHandler handler) =>
      backgroundHandler = handler;
}

class FakeLocalPort implements LocalPort {
  String? launch;
  int launchCalls = 0;
  void Function(String?)? onTap;
  final shown = <(PushMessage, int)>[];
  Function? bgTap;

  /// When set, `show` records the call and then waits for it to complete.
  Completer<void>? showGate;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
    required Future<void> Function(NotificationResponse) onBackgroundTap,
  }) async {
    this.onTap = onTap;
    bgTap = onBackgroundTap;
  }

  @override
  Future<String?> launchPayload() async {
    launchCalls++;
    return launch;
  }

  @override
  Future<void> createChannel(PushChannel c) async {}
  @override
  Future<bool> requestAndroidPermission() async => true;
  @override
  Future<void> show(PushMessage m, {required int id}) async {
    shown.add((m, id));
    await showGate?.future;
  }
}

class FakeHostApi extends PushHostApi {
  String? lastLaunchId;
  String? nativeLaunchPayload;
  final channels = <ChannelConfig>[];
  final deleted = <String>[];
  bool failCreate = false;
  bool failLaunch = false;
  final setLaunchIds = <String>[];
  final savedConfigs = <BackgroundConfigMsg>[];
  BackgroundConfigMsg? storedConfig;
  final shownNotifications = <NotificationContent>[];
  int badgeIncrements = 0;
  bool failShow = false;

  @override
  Future<void> saveBackgroundConfig(BackgroundConfigMsg config) async =>
      savedConfigs.add(config);
  @override
  Future<BackgroundConfigMsg?> loadBackgroundConfig() async => storedConfig;
  @override
  Future<void> showNotification(NotificationContent content) async {
    if (failShow) throw StateError('show failed');
    shownNotifications.add(content);
  }

  @override
  Future<int> incrementBadge() async => ++badgeIncrements;

  final badgeSets = <int>[];
  int badgeClears = 0;
  bool badgeSupported = true;
  int? storedBadge;

  @override
  Future<bool> isBadgeSupported() async => badgeSupported;
  @override
  Future<void> setBadgeCount(int count) async => badgeSets.add(count);
  @override
  Future<void> clearBadge() async => badgeClears++;
  @override
  Future<int?> getBadgeCount() async => storedBadge;

  @override
  Future<void> createChannel(ChannelConfig c) async {
    if (failCreate) throw StateError('create failed');
    channels.add(c);
  }

  @override
  Future<void> deleteChannel(String id) async => deleted.add(id);
  @override
  Future<String?> getLastLaunchId() async {
    if (failLaunch) throw StateError('launch failed');
    return lastLaunchId;
  }

  @override
  Future<void> setLastLaunchId(String id) async {
    lastLaunchId = id;
    setLaunchIds.add(id);
  }

  @override
  Future<String?> consumeLaunchPayload() async {
    final p = nativeLaunchPayload;
    nativeLaunchPayload = null;
    return p;
  }
}
