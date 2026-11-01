import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// FCM background entry point. Filled in by a later task.
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage m) async {}

/// Local notification background tap entry point. Filled in by a later task.
@pragma('vm:entry-point')
Future<void> pushLocalBackgroundTap(NotificationResponse r) async {}
