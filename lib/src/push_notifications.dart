import 'dart:async';
import 'dart:collection';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'background_handler.dart';
import 'config.dart';
import 'messages.g.dart';
import 'ports.dart';
import 'ports_impl.dart';
import 'push_message.dart';
import 'tap_dispatcher.dart';

enum PermissionStatus { granted, provisional, denied, notDetermined }

/// Optional app hook run for background messages. Must be a top-level function.
typedef BackgroundMessageHook = Future<void> Function(RemoteMessage);

/// Unified entry point for push notifications.
class PushNotifications {
  PushNotifications._()
    : this.withPorts(
        FirebaseMessagingPort(),
        FlutterLocalPort(),
        PushHostApi(),
        isIOS: defaultTargetPlatform == TargetPlatform.iOS,
        registerFlutterApi: PushFlutterApi.setUp,
      );

  @visibleForTesting
  PushNotifications.withPorts(
    this._messaging,
    this._local,
    this._host, {
    this.isIOS = false,
    void Function(PushFlutterApi?)? registerFlutterApi,
  }) : _registerFlutterApi = registerFlutterApi ?? ((_) {});

  static final PushNotifications instance = PushNotifications._();

  final MessagingPort _messaging;
  final LocalPort _local;
  final PushHostApi _host;
  @visibleForTesting
  final bool isIOS;
  final void Function(PushFlutterApi?) _registerFlutterApi;

  final TapDispatcher _dispatcher = TapDispatcher();
  final StreamController<PushMessage> _foreground =
      StreamController<PushMessage>.broadcast();
  final LinkedHashSet<String> _displayed = LinkedHashSet<String>();
  static const int _displayedCapacity = 50;

  bool _initialized = false;
  bool _showForeground = true;
  String _defaultChannelId = 'default';
  String _channelKey = 'channel_id';
  String _imageKey = 'image';
  // ignore: unused_field
  BadgeConfig _badge = BadgeConfig();
  final Set<String> _channelIds = {};

  Future<void> init({
    required DecisionMaker decisionMaker,
    List<PushChannel> channels = const [],
    String defaultChannelId = 'default',
    String channelKey = 'channel_id',
    bool showForegroundNotifications = true,
    BackgroundMessageHook? onBackgroundMessage,
    BadgeConfig? badge,
    String imageKey = 'image',
    bool imageHttpsOnly = true,
  }) async {
    if (_initialized) return;
    final list = channels.isEmpty
        ? [PushChannel(id: defaultChannelId, name: 'General')]
        : channels;
    if (!list.any((c) => c.id == defaultChannelId)) {
      throw ArgumentError.value(
        defaultChannelId,
        'defaultChannelId',
        'must be one of the configured channels',
      );
    }
    _initialized = true;
    _dispatcher.decisionMaker = decisionMaker;
    _defaultChannelId = defaultChannelId;
    _channelKey = channelKey;
    _imageKey = imageKey;
    _showForeground = showForegroundNotifications;
    _badge = badge ?? BadgeConfig();

    for (final c in list) {
      await createChannel(c);
    }

    await _local.initialize(
      onTap: _onLocalTap,
      onBackgroundTap: pushLocalBackgroundTap,
    );
    if (isIOS) {
      await _messaging.setForegroundPresentation(
        alert: true,
        badge: true,
        sound: true,
      );
    }
    _messaging.setBackgroundHandler(pushBackgroundHandler);
    _registerFlutterApi(_NativeTapHandler(_onNativeTap));

    _messaging.onMessage.listen(_onForegroundMessage);
    _messaging.onMessageOpenedApp.listen(
      (m) => _dispatcher.handleTap(_fromRemote(m, PushAppState.background)),
    );
    _messaging.onTokenRefresh.listen(_tokens.add);

    await _deliverLaunchTaps();
  }

  final StreamController<String> _tokens = StreamController<String>.broadcast();

  void markReady() {
    unawaited(_dispatcher.markReady());
  }

  Future<PermissionStatus> requestPermission() async {
    final s = await _messaging.requestPermission();
    var status = switch (s.authorizationStatus) {
      AuthorizationStatus.authorized => PermissionStatus.granted,
      AuthorizationStatus.provisional => PermissionStatus.provisional,
      AuthorizationStatus.denied => PermissionStatus.denied,
      AuthorizationStatus.notDetermined => PermissionStatus.notDetermined,
      _ => PermissionStatus.denied,
    };
    if (!isIOS && !await _local.requestAndroidPermission()) {
      status = PermissionStatus.denied;
    }
    return status;
  }

  Future<String?> get token => _messaging.getToken();
  Stream<String> get onTokenChanged => _tokens.stream;
  Stream<PushMessage> get onForegroundMessage => _foreground.stream;
  Stream<PushMessage> get onTap => _dispatcher.onTap;

  Future<void> subscribeToTopic(String topic) =>
      _messaging.subscribeToTopic(topic);
  Future<void> unsubscribeFromTopic(String topic) =>
      _messaging.unsubscribeFromTopic(topic);

  /// Creates (or updates) a channel at runtime.
  Future<void> createChannel(PushChannel c) async {
    await _host.createChannel(
      ChannelConfig(
        id: c.id,
        name: c.name,
        channelDescription: c.description,
        importance: c.importance.value,
        playSound: c.playSound,
        enableVibration: c.enableVibration,
        showBadge: c.showBadge,
        groupId: c.groupId,
      ),
    );
    _channelIds.add(c.id);
  }

  Future<void> deleteChannel(String id) async {
    if (id == _defaultChannelId) {
      throw ArgumentError.value(
        id,
        'id',
        'the default channel cannot be deleted',
      );
    }
    await _host.deleteChannel(id);
    _channelIds.remove(id);
  }

  PushMessage _fromRemote(RemoteMessage m, PushAppState state) =>
      PushMessage.fromRemote(
        m,
        state,
        imageKey: _imageKey,
        channelKey: _channelKey,
        defaultChannelId: _defaultChannelId,
        knownChannels: _channelIds,
      );

  PushMessage _fromPayload(String payload, PushAppState state) =>
      PushMessage.fromLocalPayload(
        payload,
        state,
        defaultChannelId: _defaultChannelId,
      );

  void _onLocalTap(String? payload, PushAppState state) {
    if (payload == null) return;
    unawaited(_dispatcher.handleTap(_fromPayload(payload, state)));
  }

  void _onNativeTap(String payload) => unawaited(
    _dispatcher.handleTap(_fromPayload(payload, PushAppState.background)),
  );

  Future<void> _onForegroundMessage(RemoteMessage rm) async {
    final id = rm.messageId;
    if (id != null) {
      if (_displayed.contains(id)) {
        debugPrint('push_notifications: duplicate message $id ignored');
        return;
      }
      _displayed.add(id);
      while (_displayed.length > _displayedCapacity) {
        _displayed.remove(_displayed.first);
      }
    }
    final m = _fromRemote(rm, PushAppState.foreground);
    if (!isIOS && _showForeground && (m.title != null || m.body != null)) {
      await _local.show(m, id: _localId(m.id));
    }
    _foreground.add(m);
  }

  /// Stable positive 31-bit FNV-1a hash of the message id.
  static int _localId(String id) {
    var h = 0x811c9dc5;
    for (final u in id.codeUnits) {
      h = ((h ^ u) * 0x01000193) & 0xffffffff;
    }
    return h & 0x7fffffff;
  }

  Future<void> _deliverLaunchTaps() async {
    final lastId = await _host.getLastLaunchId();
    final launch = <PushMessage>[];
    final initial = await _messaging.getInitialMessage();
    if (initial != null) {
      launch.add(_fromRemote(initial, PushAppState.terminated));
    }
    final localPayload = await _local.launchPayload();
    if (localPayload != null) {
      launch.add(_fromPayload(localPayload, PushAppState.terminated));
    }
    final nativePayload = await _host.consumeLaunchPayload();
    if (nativePayload != null) {
      launch.add(_fromPayload(nativePayload, PushAppState.terminated));
    }
    for (final m in launch) {
      if (m.id == lastId) {
        debugPrint('push_notifications: stale launch tap ${m.id} dropped');
        continue;
      }
      await _dispatcher.handleTap(m);
      await _host.setLastLaunchId(m.id);
    }
  }
}

class _NativeTapHandler implements PushFlutterApi {
  _NativeTapHandler(this._onTap);
  final void Function(String payload) _onTap;
  @override
  void onNativeTap(String payload) => _onTap(payload);
}
