import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'config.dart';
import 'push_message.dart';

/// Thin seam over FirebaseMessaging so the facade can be unit tested.
abstract class MessagingPort {
  Future<RemoteMessage?> getInitialMessage();
  Stream<RemoteMessage> get onMessage;
  Stream<RemoteMessage> get onMessageOpenedApp;
  Future<String?> getToken();
  Stream<String> get onTokenRefresh;
  Future<NotificationSettings> requestPermission();
  Future<void> setForegroundPresentation({
    required bool alert,
    required bool badge,
    required bool sound,
  });
  Future<void> subscribeToTopic(String t);
  Future<void> unsubscribeFromTopic(String t);
  void setBackgroundHandler(BackgroundMessageHandler handler);
}

/// Thin seam over FlutterLocalNotificationsPlugin.
abstract class LocalPort {
  Future<void> initialize({
    required void Function(String? payload) onTap,
    required Future<void> Function(NotificationResponse) onBackgroundTap,
  });
  Future<String?> launchPayload();
  Future<void> createChannel(PushChannel c);
  Future<bool> requestAndroidPermission();
  Future<void> show(PushMessage m, {required int id});
}
