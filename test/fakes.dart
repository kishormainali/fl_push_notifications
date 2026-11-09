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
  late final tokenCtl = StreamController<String>.broadcast(
    onListen: () => tokenListens++,
    onCancel: () => tokenCancels++,
  );
  int tokenListens = 0;
  int tokenCancels = 0;

  /// When set, [onTokenRefresh] throws it (e.g. Firebase not initialized).
  Object? tokenRefreshError;
  final registeredCtl = StreamController<String>.broadcast();
  final unregisteredCtl = StreamController<String>.broadcast();
  int initialCalls = 0;
  int registerCalls = 0;
  int unregisterCalls = 0;
  bool failRegister = false;

  /// Whether onRegistered/onUnregistered had listeners at each register call.
  final listenersAtRegister = <(bool, bool)>[];
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

  /// Value returned by [getToken]; ignored when [getTokenError] is set.
  String? fcmToken = 'tok';
  Object? getTokenError;
  int getTokenCalls = 0;

  /// Successive getAPNSToken results; the last one repeats once exhausted.
  List<String?> apnsResponses = [null];
  int apnsCalls = 0;
  Object? apnsError;

  @override
  Future<String?> getToken() async {
    getTokenCalls++;
    final e = getTokenError;
    if (e != null) throw e;
    return fcmToken;
  }

  @override
  Future<String?> getAPNSToken() async {
    apnsCalls++;
    final err = apnsError;
    if (err != null) throw err;
    final i = apnsCalls - 1 < apnsResponses.length
        ? apnsCalls - 1
        : apnsResponses.length - 1;
    return apnsResponses[i];
  }

  @override
  Stream<String> get onTokenRefresh {
    final e = tokenRefreshError;
    if (e != null) throw e;
    return tokenCtl.stream;
  }

  @override
  Future<void> register() async {
    registerCalls++;
    listenersAtRegister.add((
      registeredCtl.hasListener,
      unregisteredCtl.hasListener,
    ));
    if (failRegister) throw StateError('register failed');
  }

  @override
  Future<void> unregister() async => unregisterCalls++;
  @override
  Stream<String> get onRegistered => registeredCtl.stream;
  @override
  Stream<String> get onUnregistered => unregisteredCtl.stream;
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

  /// When set, showNotification waits on it before recording.
  Completer<void>? showGate;

  @override
  Future<void> saveBackgroundConfig(BackgroundConfigMsg config) async =>
      savedConfigs.add(config);
  @override
  Future<BackgroundConfigMsg?> loadBackgroundConfig() async => storedConfig;
  @override
  Future<void> showNotification(NotificationContent content) async {
    final gate = showGate;
    if (gate != null) await gate.future;
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

  /// Runs before the reply, modelling a native side that sends live taps
  /// before answering consumeLaunchPayload.
  void Function()? beforeConsumeReply;

  @override
  Future<String?> consumeLaunchPayload() async {
    final p = nativeLaunchPayload;
    nativeLaunchPayload = null;
    beforeConsumeReply?.call();
    return p;
  }
}
