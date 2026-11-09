import 'dart:collection';
import 'dart:ui' show CallbackHandle, PluginUtilities;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'messages.g.dart';
import 'push_message.dart';

/// FCM background entry point (runs in a background isolate).
@pragma('vm:entry-point')
Future<void> pushBackgroundHandler(RemoteMessage m) =>
    handleBackgroundMessage(m);

/// Local notification background tap entry point. Action buttons are out of
/// scope for v1, so this only logs.
@pragma('vm:entry-point')
Future<void> pushLocalBackgroundTap(NotificationResponse r) async {
  debugPrint('push_notifications: background tap ${r.id} ignored');
}

/// Single builder for native notification content, shared by the background
/// handler and the Android foreground image path.
NotificationContent buildNativeContent({
  required String? messageId,
  required String? title,
  required String? body,
  required String channelId,
  required Map<String, String?> data,
  String? imageUrl,
}) {
  final hasImage = imageUrl != null && imageUrl.isNotEmpty;
  return NotificationContent(
    id: stableLocalId(messageId ?? ''),
    title: title,
    body: body,
    channelId: channelId,
    data: data.map((k, v) => MapEntry<String?, String?>(k, v)),
    imageUrl: hasImage ? imageUrl : null,
    imageStyle: hasImage ? ImageStyle.bigPicture : ImageStyle.none,
    // Native tap payload uses this as its `id` so taps dedupe by messageId.
    extras: messageId != null ? {'messageId': messageId} : const {},
  );
}

/// Builds the native notification content for a data-only [m].
NotificationContent contentFromRemote(
  RemoteMessage m, {
  String imageKey = 'image',
  String titleKey = 'title',
  String bodyKey = 'body',
  required String channelId,

  /// Id to use instead of [RemoteMessage.messageId] (the handler passes a
  /// generated fallback for id-less messages).
  String? messageId,
}) => buildNativeContent(
  messageId: messageId ?? m.messageId,
  title: m.data[titleKey]?.toString(),
  body: m.data[bodyKey]?.toString(),
  channelId: channelId,
  data: m.data.map((k, v) => MapEntry<String, String?>(k, v?.toString())),
  imageUrl: m.data[imageKey]?.toString(),
);

final LinkedHashSet<String> _seen = LinkedHashSet<String>();
const int _seenCapacity = 50;

Future<void> _defaultInitFirebase() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
}

Future<void> Function(RemoteMessage)? _defaultResolveHook(int handle) {
  final cb = PluginUtilities.getCallbackFromHandle(
    CallbackHandle.fromRawHandle(handle),
  );
  return cb as Future<void> Function(RemoteMessage)?;
}

/// Testable body of [pushBackgroundHandler]. Never throws.
Future<void> handleBackgroundMessage(
  RemoteMessage m, {
  PushHostApi? host,
  Future<void> Function()? initFirebase,
  Future<void> Function(RemoteMessage)? Function(int handle)? resolveHook,
}) async {
  try {
    final api = host ?? PushHostApi();
    final config = await api.loadBackgroundConfig();
    final defaultChannel = config?.defaultChannelId ?? 'default';
    final channelKey = config?.channelKey ?? 'channel_id';

    // Id-less messages get one unique fallback id, used for both the
    // notification id and the tap payload id. The same id-less object
    // delivered twice therefore shows twice: there is nothing to dedupe on.
    final id = m.messageId;
    final effectiveId = (id == null || id.isEmpty) ? generateMessageId() : id;
    final duplicate = id != null && _seen.contains(id);

    // A notification block is displayed by the OS; never display twice.
    if (m.notification == null && !duplicate) {
      final content = contentFromRemote(
        m,
        imageKey: config?.imageKey ?? 'image',
        titleKey: config?.titleKey ?? 'title',
        bodyKey: config?.bodyKey ?? 'body',
        channelId: m.data[channelKey]?.toString().isNotEmpty == true
            ? m.data[channelKey].toString()
            : defaultChannel,
        messageId: effectiveId,
      );
      final empty =
          (content.title ?? '').isEmpty && (content.body ?? '').isEmpty;
      if (empty) {
        debugPrint('push_notifications: data-only message has no title/body');
      } else {
        try {
          await api.showNotification(content);
          // Record only after a successful show so a redelivery can retry.
          if (id != null) {
            _seen.add(id);
            while (_seen.length > _seenCapacity) {
              _seen.remove(_seen.first);
            }
          }
        } catch (e) {
          debugPrint('push_notifications: showNotification failed: $e');
        }
      }
    }

    if (config?.autoIncrementOnPush ?? false) {
      try {
        await api.incrementBadge();
      } catch (e) {
        debugPrint('push_notifications: incrementBadge failed: $e');
      }
    }

    final handle = config?.hookHandle;
    if (handle != null) {
      try {
        // Firebase is only needed by the user hook, so init lazily here.
        try {
          await (initFirebase ?? _defaultInitFirebase)();
        } catch (e) {
          debugPrint(
            'push_notifications: Firebase init failed, hook skipped: $e',
          );
          return;
        }
        final hook = (resolveHook ?? _defaultResolveHook)(handle);
        await hook?.call(m);
      } catch (e) {
        debugPrint('push_notifications: background hook failed: $e');
      }
    }
  } catch (e) {
    debugPrint('push_notifications: background handler failed: $e');
  }
}
