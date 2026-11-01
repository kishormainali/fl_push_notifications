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

  /// The APNs device token on iOS/macOS; `null` elsewhere or when APNs has not
  /// delivered one yet (it does not wait).
  Future<String?> getAPNSToken();
  Stream<String> get onTokenRefresh;

  /// Registers this app instance with FCM; the Firebase Installation ID (FID)
  /// is then delivered on [onRegistered].
  Future<void> register();
  Future<void> unregister();

  /// FID events. Not replayed: only events after listening are delivered.
  Stream<String> get onRegistered;
  Stream<String> get onUnregistered;
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
