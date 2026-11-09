import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Where a [PushMessage] originated.
enum MessageSource {
  /// Delivered by Firebase Cloud Messaging.
  remote,

  /// Posted locally by this plugin.
  local,
}

/// The app's lifecycle state when a [PushMessage] was received or tapped.
enum PushAppState {
  /// The app was visible and in use.
  foreground,

  /// The app was running but not visible.
  background,

  /// The app process was not running.
  terminated,
}

/// Called when the user taps a notification.
typedef DecisionMaker = FutureOr<void> Function(PushMessage message);

String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

int _idCounter = 0;
/// Unique-per-call fallback id (internal; not exported from the package).
String generateMessageId() =>
    'gen-${DateTime.now().microsecondsSinceEpoch}-${_idCounter++}';

/// Picks the channel for [m]: android channelId, then `data[channelKey]`,
/// then [defaultId]. Unknown ids log a warning and fall back to [defaultId].
String resolveChannelId(
  RemoteMessage m, {
  required Set<String> known,
  required String defaultId,
  required String channelKey,
}) {
  final candidate =
      m.notification?.android?.channelId ?? m.data[channelKey]?.toString();
  if (candidate == null || candidate.isEmpty) return defaultId;
  if (known.contains(candidate)) return candidate;
  debugPrint(
    'push_notifications: unknown channel "$candidate", using "$defaultId"',
  );
  return defaultId;
}

/// Stable positive 31-bit FNV-1a hash of a message id, used as the local
/// notification id.
int stableLocalId(String id) {
  var h = 0x811c9dc5;
  for (final u in id.codeUnits) {
    h = ((h ^ u) * 0x01000193) & 0xffffffff;
  }
  return h & 0x7fffffff;
}

/// A notification message, normalized across remote (FCM) and local sources.
class PushMessage {
  /// Creates a message. Most apps receive instances rather than build them.
  const PushMessage({
    required this.id,
    this.title,
    this.body,
    this.data = const {},
    this.imageUrl,
    required this.channelId,
    required this.source,
    required this.appState,
    this.raw,
  });

  /// Message id: the FCM message id, or a generated id when absent.
  final String id;

  /// Notification title, if any.
  final String? title;

  /// Notification body, if any.
  final String? body;

  /// Custom data payload, with all values converted to strings.
  final Map<String, String> data;

  /// URL of the notification image, if any.
  final String? imageUrl;

  /// Id of the channel the notification is shown on.
  final String channelId;

  /// Whether the message came from FCM or was posted locally.
  final MessageSource source;

  /// App state when the message was received or tapped.
  final PushAppState appState;

  /// The original source object (a [RemoteMessage] for remote messages, the
  /// raw payload for local ones), or `null`.
  final Object? raw;

  /// [knownChannels] null means channel ids are not validated.
  factory PushMessage.fromRemote(
    RemoteMessage m,
    PushAppState state, {
    String imageKey = 'image',
    String titleKey = 'title',
    String bodyKey = 'body',
    String channelKey = 'channel_id',
    String defaultChannelId = 'default',
    Set<String>? knownChannels,
  }) {
    final data = m.data.map((k, v) => MapEntry(k, v?.toString() ?? ''));
    final channelId = knownChannels == null
        ? (m.notification?.android?.channelId ??
              m.data[channelKey]?.toString() ??
              defaultChannelId)
        : resolveChannelId(
            m,
            known: knownChannels,
            defaultId: defaultChannelId,
            channelKey: channelKey,
          );
    return PushMessage(
      id: m.messageId ?? generateMessageId(),
      title: _nonEmpty(m.notification?.title) ?? _nonEmpty(data[titleKey]),
      body: _nonEmpty(m.notification?.body) ?? _nonEmpty(data[bodyKey]),
      data: data,
      imageUrl: m.notification?.android?.imageUrl ?? data[imageKey],
      channelId: channelId,
      source: MessageSource.remote,
      appState: state,
      raw: m,
    );
  }

  /// Never throws: a corrupt payload yields a minimal message so a tap is
  /// never dropped.
  factory PushMessage.fromLocalPayload(
    String payload,
    PushAppState state, {
    String defaultChannelId = 'default',
  }) {
    try {
      final j = jsonDecode(payload);
      if (j is Map) {
        final rawData = j['data'];
        final data = rawData is Map
            ? rawData.map((k, v) => MapEntry(k.toString(), v?.toString() ?? ''))
            : <String, String>{};
        final id = j['id']?.toString();
        final channel = j['channelId']?.toString();
        return PushMessage(
          id: (id == null || id.isEmpty) ? generateMessageId() : id,
          title: j['title']?.toString(),
          body: j['body']?.toString(),
          data: data,
          imageUrl: j['imageUrl']?.toString(),
          channelId: (channel == null || channel.isEmpty)
              ? defaultChannelId
              : channel,
          source: MessageSource.local,
          appState: state,
          raw: payload,
        );
      }
    } catch (e) {
      debugPrint('push_notifications: corrupt local payload: $e');
    }
    return PushMessage(
      id: generateMessageId(),
      channelId: defaultChannelId,
      source: MessageSource.local,
      appState: state,
      raw: payload,
    );
  }

  /// Serializes this message to the JSON payload attached to a local
  /// notification.
  String toLocalPayload() => jsonEncode({
    'id': id,
    'title': title,
    'body': body,
    'data': data,
    'imageUrl': imageUrl,
    'channelId': channelId,
  });
}
