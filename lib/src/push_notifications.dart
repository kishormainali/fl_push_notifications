import 'dart:async';
import 'dart:collection';
import 'dart:ui' show PluginUtilities;

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import 'badge.dart';

import 'background_handler.dart';
import 'config.dart';
import 'messages.g.dart';
import 'ports.dart';
import 'ports_impl.dart';
import 'push_message.dart';
import 'tap_dispatcher.dart';

/// Result of [PushNotifications.requestPermission].
enum PushPermissionStatus {
  /// The user allowed notifications.
  granted,

  /// Notifications are allowed quietly (iOS provisional authorization).
  provisional,

  /// The user denied notifications.
  denied,

  /// The user has not been asked yet.
  notDetermined,
}

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

  /// Creates an instance with injected ports, for tests.
  @visibleForTesting
  PushNotifications.withPorts(
    this._messaging,
    this._local,
    this._host, {
    this.isIOS = false,
    void Function(PushFlutterApi?)? registerFlutterApi,
    Stream<AppLifecycleState> Function()? lifecycleStates,
    AppLifecycleState? Function()? currentLifecycleState,
  }) : _registerFlutterApi = registerFlutterApi ?? ((_) {}),
       _lifecycleStates = lifecycleStates ?? appLifecycleStates,
       _currentLifecycleState =
           currentLifecycleState ??
           (() => WidgetsBinding.instance.lifecycleState);

  /// The shared plugin instance.
  static final PushNotifications instance = PushNotifications._();

  final MessagingPort _messaging;
  final LocalPort _local;
  final PushHostApi _host;
  /// Whether the iOS code path is used; overridable for tests.
  @visibleForTesting
  final bool isIOS;
  final void Function(PushFlutterApi?) _registerFlutterApi;
  final Stream<AppLifecycleState> Function() _lifecycleStates;
  final AppLifecycleState? Function() _currentLifecycleState;

  final TapDispatcher _dispatcher = TapDispatcher();
  final StreamController<PushMessage> _foreground =
      StreamController<PushMessage>.broadcast();
  final LinkedHashSet<String> _displayed = LinkedHashSet<String>();
  static const int _displayedCapacity = 50;

  Future<void>? _initFuture;
  final List<StreamSubscription<Object?>> _subs = [];
  bool _showForeground = true;
  String _defaultChannelId = 'default';
  String _channelKey = 'channel_id';
  String _imageKey = 'image';
  String _titleKey = 'title';
  String _bodyKey = 'body';
  BadgeConfig _badge = BadgeConfig();
  final Set<String> _channelIds = {};

  /// Last lifecycle state other than `inactive` seen since init (seeded from
  /// the state at init). Labels Dart-side live taps; see [_liveTapState].
  AppLifecycleState? _lastActiveOrHidden;

  /// Native taps that arrive while init has not yet delivered the launch
  /// taps; released after them so the launch taps come first. Non-null only
  /// during that window.
  List<(String, bool)>? _heldNativeTaps;

  /// Initializes the plugin; call once after `Firebase.initializeApp()`.
  ///
  /// [decisionMaker] is called when the user taps a notification. [channels]
  /// are registered on Android, and [defaultChannelId] is used when a message
  /// names no known channel (it is read from the data key [channelKey]).
  /// [showForegroundNotifications] controls whether messages received in the
  /// foreground are displayed. [onBackgroundMessage] is an optional top-level
  /// hook run for background messages. [badge] configures app icon badges.
  /// [imageKey], [titleKey] and [bodyKey] name the data keys used when the
  /// notification payload lacks an image, title or body. [imageHttpsOnly]
  /// restricts image downloads to https. When [autoRegister] is true the app
  /// is registered with FCM, delivering its installation id on [onRegistered].
  ///
  /// Repeat calls return the first call's future; a failed call may be retried.
  Future<void> init({
    required DecisionMaker decisionMaker,
    List<PushChannel> channels = const [],
    String defaultChannelId = 'default',
    String channelKey = 'channel_id',
    bool showForegroundNotifications = true,
    BackgroundMessageHook? onBackgroundMessage,
    BadgeConfig? badge,
    String imageKey = 'image',
    String titleKey = 'title',
    String bodyKey = 'body',
    bool imageHttpsOnly = true,
    bool autoRegister = true,
  }) {
    // Repeat and concurrent calls share the in-flight (or finished) future. A
    // failure clears it so a retry can run again.
    final existing = _initFuture;
    if (existing != null) return existing;
    final f = _init(
      decisionMaker: decisionMaker,
      channels: channels,
      defaultChannelId: defaultChannelId,
      channelKey: channelKey,
      showForegroundNotifications: showForegroundNotifications,
      badge: badge,
      imageKey: imageKey,
      titleKey: titleKey,
      bodyKey: bodyKey,
      imageHttpsOnly: imageHttpsOnly,
      onBackgroundMessage: onBackgroundMessage,
      autoRegister: autoRegister,
    );
    _initFuture = f;
    f.catchError((Object _) {
      if (identical(_initFuture, f)) _initFuture = null;
      for (final sub in _subs) {
        unawaited(sub.cancel());
      }
      _subs.clear();
      _fidAttached = false;
    });
    return f;
  }

  Future<void> _init({
    required DecisionMaker decisionMaker,
    required List<PushChannel> channels,
    required String defaultChannelId,
    required String channelKey,
    required bool showForegroundNotifications,
    required BadgeConfig? badge,
    required String imageKey,
    required String titleKey,
    required String bodyKey,
    required bool imageHttpsOnly,
    required BackgroundMessageHook? onBackgroundMessage,
    required bool autoRegister,
  }) async {
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
    _dispatcher.decisionMaker = decisionMaker;
    _defaultChannelId = defaultChannelId;
    _channelKey = channelKey;
    _imageKey = imageKey;
    _titleKey = titleKey;
    _bodyKey = bodyKey;
    _showForeground = showForegroundNotifications;
    _badge = badge ?? BadgeConfig();

    // Tracked before anything can deliver a tap; cancelled with the other
    // subscriptions if init fails.
    _lastActiveOrHidden = null;
    _noteLifecycle(_currentLifecycleState());
    _subs.add(
      _lifecycleStates().listen((s) {
        _noteLifecycle(s);
        if (_badge.autoClearOnForeground && s == AppLifecycleState.resumed) {
          unawaited(_clearBadgeSafely());
        }
      }),
    );

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
    await _saveBackgroundConfig(imageHttpsOnly, onBackgroundMessage);
    _messaging.setBackgroundHandler(pushBackgroundHandler);
    // A native side may send a live tap before (or while) Dart reads the
    // launch taps, e.g. Android before consumeLaunchPayload replies; hold it
    // until they are delivered.
    _heldNativeTaps = [];
    _registerFlutterApi(_NativeTapHandler(_onNativeTap));

    try {
      _subs.addAll([
        _messaging.onMessage.listen(_onForegroundMessage),
        _messaging.onMessageOpenedApp.listen(
          (m) => _dispatcher.handleTap(_fromRemote(m, _liveTapState())),
        ),
      ]);

      if (_badge.autoClearOnForeground) {
        // The app is in the foreground while init runs, so clear once now; the
        // lifecycle listener above clears again every time it resumes.
        await _clearBadgeSafely();
      }

      await _deliverLaunchTaps();

      if (autoRegister) {
        // Listeners first so the registration event cannot be missed. Not
        // awaited: registration may need the network and must not delay init.
        unawaited(_registerSafely());
      }
    } finally {
      _releaseNativeTaps();
    }
  }

  Future<void> _saveBackgroundConfig(
    bool imageHttpsOnly,
    BackgroundMessageHook? hook,
  ) async {
    int? handle;
    if (hook != null) {
      handle = PluginUtilities.getCallbackHandle(hook)?.toRawHandle();
      if (handle == null) {
        debugPrint(
          'push_notifications: onBackgroundMessage must be a top-level '
          'function; the hook will not run in the background isolate',
        );
      }
    }
    await _host.saveBackgroundConfig(
      BackgroundConfigMsg(
        defaultChannelId: _defaultChannelId,
        channelKey: _channelKey,
        imageKey: _imageKey,
        titleKey: _titleKey,
        bodyKey: _bodyKey,
        imageHttpsOnly: imageHttpsOnly,
        autoIncrementOnPush: _badge.autoIncrementOnPush,
        autoClearOnForeground: _badge.autoClearOnForeground,
        hookHandle: handle,
      ),
    );
  }

  /// Backs [onTokenChanged]. The port's `onTokenRefresh` (deprecated upstream)
  /// is subscribed only while this has listeners, so apps that use only the
  /// FID API never touch it.
  late final StreamController<String> _tokens =
      StreamController<String>.broadcast(
        onListen: _attachTokenRefresh,
        onCancel: _detachTokenRefresh,
      );

  /// Lives outside [_subs] on purpose: it follows the listeners of
  /// [onTokenChanged], not the init lifecycle, so init-failure cleanup must not
  /// cancel it.
  StreamSubscription<String>? _tokenSub;

  void _attachTokenRefresh() {
    if (_tokenSub != null) return;
    try {
      _tokenSub = _messaging.onTokenRefresh.listen(
        _tokens.add,
        onError: _tokens.addError,
      );
    } catch (e) {
      // E.g. Firebase not initialized yet. Retried on the next listen.
      debugPrint('push_notifications: cannot listen to token refresh: $e');
    }
  }

  void _detachTokenRefresh() {
    final sub = _tokenSub;
    _tokenSub = null;
    if (sub != null) unawaited(sub.cancel());
  }

  final StreamController<String> _registered =
      StreamController<String>.broadcast();
  final StreamController<String> _unregistered =
      StreamController<String>.broadcast();
  bool _fidAttached = false;
  String? _installationId;

  /// Subscribes to the port's FID streams once; cancelled with [_subs].
  void _attachFidListeners() {
    if (_fidAttached) return;
    _fidAttached = true;
    _subs.addAll([
      _messaging.onRegistered.listen((fid) {
        _installationId = fid;
        _registered.add(fid);
      }),
      _messaging.onUnregistered.listen((fid) {
        if (_installationId == fid) _installationId = null;
        _unregistered.add(fid);
      }),
    ]);
  }

  Future<void> _registerSafely() async {
    try {
      _attachFidListeners();
      await _messaging.register();
    } catch (e) {
      debugPrint('push_notifications: register failed: $e');
    }
  }

  /// Registers this app instance with FCM so a Firebase Installation ID (FID)
  /// is delivered on [onRegistered]. `init` does this by default
  /// (`autoRegister`); call it manually when `autoRegister` is false. Throws
  /// if registration fails.
  Future<void> register() {
    _attachFidListeners();
    return _messaging.register();
  }

  /// Unregisters this app instance; the FID that is no longer active is then
  /// delivered on [onUnregistered].
  Future<void> unregister() {
    _attachFidListeners();
    return _messaging.unregister();
  }

  /// The Firebase Installation ID (FID) of this app instance each time it is
  /// registered. Broadcast, not replayed; read [installationId] for the latest.
  Stream<String> get onRegistered => _registered.stream;

  /// Emits the FID that is no longer active after [unregister].
  Stream<String> get onUnregistered => _unregistered.stream;

  /// The most recent FID seen on [onRegistered] since listeners were attached,
  /// or `null` before the first event and after that FID is unregistered.
  String? get installationId => _installationId;

  /// Signals that the app can navigate; queued taps are then delivered to the
  /// `decisionMaker` in order.
  void markReady() {
    unawaited(_dispatcher.markReady());
  }

  /// Asks the user for notification permission (on Android also the
  /// `POST_NOTIFICATIONS` runtime permission) and returns the outcome.
  Future<PushPermissionStatus> requestPermission() async {
    final s = await _messaging.requestPermission();
    var status = switch (s.authorizationStatus) {
      AuthorizationStatus.authorized => PushPermissionStatus.granted,
      AuthorizationStatus.provisional => PushPermissionStatus.provisional,
      AuthorizationStatus.denied => PushPermissionStatus.denied,
      AuthorizationStatus.notDetermined => PushPermissionStatus.notDetermined,
      _ => PushPermissionStatus.denied,
    };
    if (!isIOS && !await _local.requestAndroidPermission()) {
      status = PushPermissionStatus.denied;
    }
    return status;
  }

  /// The FCM registration token, or `null` if unavailable.
  Future<String?> get token => _messaging.getToken();

  /// Emits the new FCM token whenever it is refreshed.
  Stream<String> get onTokenChanged => _tokens.stream;

  /// The native platform token: the FCM token on Android, the APNs device
  /// token on iOS. Unlike [token], which is always the FCM token.
  ///
  /// On iOS the APNs token is polled every 250 ms for up to [apnsTimeout] (a
  /// zero timeout makes a single attempt), because firebase_messaging's
  /// `getAPNSToken` returns `null` immediately while APNs has not delivered
  /// one. The APNs token needs the app to have registered for remote
  /// notifications; iOS simulators may never return one.
  ///
  /// Never throws: returns `null` when the token is unavailable (errors are
  /// logged without the token), so callers can retry.
  Future<String?> getPlatformToken({
    Duration apnsTimeout = const Duration(seconds: 3),
  }) async {
    if (isIOS) return _waitForApnsToken(apnsTimeout);
    try {
      return await token;
    } catch (e) {
      debugPrint('push_notifications: getPlatformToken: FCM token failed: $e');
      return null;
    }
  }

  static const _apnsPollInterval = Duration(milliseconds: 250);

  Future<String?> _waitForApnsToken(Duration timeout) async {
    var waited = Duration.zero;
    while (true) {
      try {
        final t = await _messaging.getAPNSToken();
        if (t != null) return t;
      } catch (e) {
        debugPrint('push_notifications: getAPNSToken failed: $e');
      }
      final remaining = timeout - waited;
      if (remaining <= Duration.zero) return null;
      final step = remaining < _apnsPollInterval
          ? remaining
          : _apnsPollInterval;
      await Future<void>.delayed(step);
      waited += step;
    }
  }

  /// Messages received while the app is in the foreground.
  Stream<PushMessage> get onForegroundMessage => _foreground.stream;
  /// Emits every notification tap, for observation such as analytics. Taps are
  /// handled by the `decisionMaker` passed to [init].
  Stream<PushMessage> get onTap => _dispatcher.onTap;

  /// Subscribes this device to the FCM [topic].
  Future<void> subscribeToTopic(String topic) =>
      _messaging.subscribeToTopic(topic);
  /// Unsubscribes this device from the FCM [topic].
  Future<void> unsubscribeFromTopic(String topic) =>
      _messaging.unsubscribeFromTopic(topic);

  /// Whether the app icon badge can be set on this device. Always `true` on
  /// iOS; on Android only for recognized launchers (best effort).
  Future<bool> isBadgeSupported() => _host.isBadgeSupported();

  /// Sets the app icon badge. Negative values are clamped to 0.
  Future<void> setBadgeCount(int count) =>
      _host.setBadgeCount(count < 0 ? 0 : count);

  /// Clears the app icon badge and resets the stored counter.
  Future<void> clearBadge() => _host.clearBadge();

  /// The current badge count on iOS; `null` on Android, where launchers do
  /// not expose it.
  Future<int?> getBadgeCount() => _host.getBadgeCount();

  Future<void> _clearBadgeSafely() async {
    try {
      await clearBadge();
    } catch (e) {
      debugPrint('push_notifications: clearBadge failed: $e');
    }
  }

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

  /// Deletes the Android channel [id]. Throws [ArgumentError] for the default
  /// channel.
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
        titleKey: _titleKey,
        bodyKey: _bodyKey,
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

  void _noteLifecycle(AppLifecycleState? s) {
    if (s != null && s != AppLifecycleState.inactive) _lastActiveOrHidden = s;
  }

  /// App state of a live (not launch) tap delivered by a Dart plugin
  /// (flutter_local_notifications responses, `onMessageOpenedApp`):
  /// `foreground` if the last lifecycle state other than `inactive` was
  /// `resumed`, otherwise `background`.
  ///
  /// `inactive` is skipped because it is transitional on both sides of a tap:
  /// opening the shade or tapping a notification of a resumed app makes it
  /// inactive just before the tap reaches Dart (window focus loss reports
  /// inactive, and Android may also pause the activity around
  /// `onNewIntent`), and an app returning from the background passes through
  /// inactive before resumed. The state the app was in before that
  /// transition is the one the user tapped from.
  PushAppState _liveTapState() =>
      _lastActiveOrHidden == AppLifecycleState.resumed
      ? PushAppState.foreground
      : PushAppState.background;

  void _onLocalTap(String? payload) {
    if (payload == null) return;
    unawaited(_dispatcher.handleTap(_fromPayload(payload, _liveTapState())));
  }

  /// A tap posted natively by this plugin. Its state was captured natively
  /// when the tap was received (iOS: active since it last became active and
  /// not backgrounded since; Android: host activity resumed since it was last
  /// started), because the Dart lifecycle can change before this call
  /// arrives.
  void _onNativeTap(String payload, bool appWasActive) {
    final held = _heldNativeTaps;
    if (held != null) {
      held.add((payload, appWasActive));
      return;
    }
    _dispatchNativeTap(payload, appWasActive);
  }

  void _releaseNativeTaps() {
    final held = _heldNativeTaps;
    _heldNativeTaps = null;
    for (final (payload, appWasActive) in held ?? const <(String, bool)>[]) {
      _dispatchNativeTap(payload, appWasActive);
    }
  }

  void _dispatchNativeTap(String payload, bool appWasActive) => unawaited(
    _dispatcher.handleTap(
      _fromPayload(
        payload,
        appWasActive ? PushAppState.foreground : PushAppState.background,
      ),
    ),
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
    // Emitted first: the display may wait on an image download (~10 s).
    _foreground.add(m);
    if (!_showForeground || (m.title == null && m.body == null)) return;
    if (!isIOS) return _displayForeground(m);
    // iOS: a message with a `notification` block is presented by the OS
    // (setForegroundPresentation; an image only if the Notification Service
    // Extension ran), so it is not shown again here. A data-only message gets
    // no OS presentation, so the plugin posts it natively.
    if (rm.notification == null) await _displayNativeIOS(m);
  }

  Future<void> _displayNativeIOS(PushMessage m) async {
    try {
      await _host.showNotification(
        buildNativeContent(
          messageId: m.id,
          title: m.title,
          body: m.body,
          channelId: m.channelId,
          data: m.data,
          imageUrl: m.imageUrl,
        ),
      );
    } catch (e) {
      debugPrint('push_notifications: foreground show failed: $e');
    }
  }

  Future<void> _displayForeground(PushMessage m) async {
    final image = m.imageUrl;
    if (image != null && image.isNotEmpty) {
      // Native BigPicture. Image failure must never lose the notification.
      try {
        await _host.showNotification(
          buildNativeContent(
            messageId: m.id,
            title: m.title,
            body: m.body,
            channelId: m.channelId,
            data: m.data,
            imageUrl: image,
          ),
        );
        return;
      } catch (e) {
        debugPrint(
          'push_notifications: native image show failed, text-only: $e',
        );
      }
    }
    try {
      await _local.show(m, id: stableLocalId(m.id));
    } catch (e) {
      debugPrint('push_notifications: foreground show failed: $e');
    }
  }

  Future<void> _deliverLaunchTaps() async {
    final lastIds = (await _host.getLastLaunchId() ?? '')
        .split('\n')
        .where((e) => e.isNotEmpty)
        .toSet();
    final delivered = <String>[];
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
      if (lastIds.contains(m.id)) {
        debugPrint('push_notifications: stale launch tap ${m.id} dropped');
        continue;
      }
      await _dispatcher.handleTap(m);
      delivered.add(m.id);
    }
    // Tradeoff: ids are persisted as soon as the tap is handed to the
    // dispatcher, which may still hold it queued before markReady(). All ids
    // from this init are stored (newline-joined) so a later cold start that
    // re-reports any of them is treated as stale.
    if (delivered.isNotEmpty) {
      await _host.setLastLaunchId(delivered.join('\n'));
    }
  }
}

class _NativeTapHandler implements PushFlutterApi {
  _NativeTapHandler(this._onTap);
  final void Function(String payload, bool appWasActive) _onTap;
  @override
  void onNativeTap(String payload, bool appWasActive) =>
      _onTap(payload, appWasActive);
}
