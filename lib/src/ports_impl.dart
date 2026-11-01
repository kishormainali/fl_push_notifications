import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'config.dart';
import 'ports.dart';
import 'push_message.dart';

class FirebaseMessagingPort implements MessagingPort {
  FirebaseMessaging get _fm => FirebaseMessaging.instance;

  @override
  Future<RemoteMessage?> getInitialMessage() => _fm.getInitialMessage();
  @override
  Stream<RemoteMessage> get onMessage => FirebaseMessaging.onMessage;
  @override
  Stream<RemoteMessage> get onMessageOpenedApp =>
      FirebaseMessaging.onMessageOpenedApp;
  // The register()/onRegistered replacement yields an installation id, not
  // the FCM token, so the deprecated token API is intentionally kept.
  @override
  // ignore: deprecated_member_use
  Future<String?> getToken() => _fm.getToken();
  @override
  // ignore: deprecated_member_use
  Stream<String> get onTokenRefresh => _fm.onTokenRefresh;
  @override
  Future<NotificationSettings> requestPermission() => _fm.requestPermission();
  @override
  Future<void> setForegroundPresentation({
    required bool alert,
    required bool badge,
    required bool sound,
  }) => _fm.setForegroundNotificationPresentationOptions(
    alert: alert,
    badge: badge,
    sound: sound,
  );
  @override
  Future<void> subscribeToTopic(String t) => _fm.subscribeToTopic(t);
  @override
  Future<void> unsubscribeFromTopic(String t) => _fm.unsubscribeFromTopic(t);
  @override
  void setBackgroundHandler(BackgroundMessageHandler handler) =>
      FirebaseMessaging.onBackgroundMessage(handler);
}

class FlutterLocalPort implements LocalPort {
  FlutterLocalPort([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;

  @override
  Future<void> initialize({
    required void Function(String? payload) onTap,
    required Future<void> Function(NotificationResponse) onBackgroundTap,
  }) async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (r) => onTap(r.payload),
      onDidReceiveBackgroundNotificationResponse: onBackgroundTap,
    );
  }

  @override
  Future<String?> launchPayload() async {
    final d = await _plugin.getNotificationAppLaunchDetails();
    if (d == null || !d.didNotificationLaunchApp) return null;
    return d.notificationResponse?.payload;
  }

  AndroidFlutterLocalNotificationsPlugin? get _android => _plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  @override
  Future<void> createChannel(PushChannel c) async {
    await _android?.createNotificationChannel(
      AndroidNotificationChannel(
        c.id,
        c.name,
        description: c.description,
        groupId: c.groupId,
        importance: c.importance,
        playSound: c.playSound,
        enableVibration: c.enableVibration,
        showBadge: c.showBadge,
      ),
    );
  }

  @override
  Future<bool> requestAndroidPermission() async =>
      await _android?.requestNotificationsPermission() ?? true;

  @override
  Future<void> show(PushMessage m, {required int id}) => _plugin.show(
    id: id,
    title: m.title,
    body: m.body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(m.channelId, m.channelId),
    ),
    payload: m.toLocalPayload(),
  );
}
