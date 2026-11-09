import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_push_notifications/src/config.dart';
import 'package:fl_push_notifications/src/messages.g.dart';
import 'package:fl_push_notifications/src/push_message.dart';
import 'package:fl_push_notifications/src/push_notifications.dart';

import 'fakes.dart';

RemoteMessage rm(
  String id, {
  String? title = 't',
  Map<String, dynamic> data = const {},
}) => RemoteMessage(
  messageId: id,
  data: data,
  notification: RemoteNotification(title: title, body: 'b'),
);

void main() {
  late FakeMessagingPort msg;
  late FakeLocalPort local;
  late FakeHostApi host;
  late List<PushMessage> taps;
  PushFlutterApi? nativeApi;
  AppLifecycleState? lifecycle;
  late StreamController<AppLifecycleState> lifecycleCtl;

  /// Reports a lifecycle change the way WidgetsBinding does: the current
  /// state changes and the observer stream emits it.
  Future<void> moveTo(AppLifecycleState s) async {
    lifecycle = s;
    lifecycleCtl.add(s);
    await pump();
  }

  PushNotifications build({bool isIOS = false}) => PushNotifications.withPorts(
    msg,
    local,
    host,
    isIOS: isIOS,
    registerFlutterApi: (a) => nativeApi = a,
    currentLifecycleState: () => lifecycle,
    lifecycleStates: () => lifecycleCtl.stream,
  );

  Future<PushNotifications> started({
    bool isIOS = false,
    bool show = true,
    bool ready = true,
    List<PushChannel>? channels,
    String defaultId = 'default',
    String imageKey = 'image',
    String titleKey = 'title',
    String bodyKey = 'body',
  }) async {
    final p = build(isIOS: isIOS);
    await p.init(
      titleKey: titleKey,
      bodyKey: bodyKey,
      imageKey: imageKey,
      decisionMaker: taps.add,
      showForegroundNotifications: show,
      channels: channels ?? [PushChannel(id: 'default', name: 'General')],
      defaultChannelId: defaultId,
    );
    if (ready) p.markReady();
    await pump();
    return p;
  }

  setUp(() {
    msg = FakeMessagingPort();
    local = FakeLocalPort();
    host = FakeHostApi();
    taps = [];
    nativeApi = null;
    lifecycle = AppLifecycleState.resumed;
    lifecycleCtl = StreamController<AppLifecycleState>.broadcast();
  });

  tearDown(() => lifecycleCtl.close());

  test(
    'init persists background config once with the configured values',
    () async {
      final p = build();
      await p.init(
        decisionMaker: taps.add,
        channels: [PushChannel(id: 'c1', name: 'C')],
        defaultChannelId: 'c1',
        channelKey: 'ck',
        imageKey: 'pic',
        imageHttpsOnly: false,
        badge: BadgeConfig(autoIncrementOnPush: true),
      );
      expect(host.savedConfigs, hasLength(1));
      final c = host.savedConfigs.single;
      expect(c.defaultChannelId, 'c1');
      expect(c.channelKey, 'ck');
      expect(c.imageKey, 'pic');
      expect(c.titleKey, 'title');
      expect(c.bodyKey, 'body');
      expect(c.imageHttpsOnly, isFalse);
      expect(c.autoIncrementOnPush, isTrue);
      expect(c.autoClearOnForeground, isFalse);
      expect(c.hookHandle, isNull);
    },
  );

  test('init reads getInitialMessage and local launch payload once, as '
      'terminated taps, queued until markReady', () async {
    msg.initial = rm('a');
    local.launch = PushMessage(
      id: 'b',
      channelId: 'default',
      source: MessageSource.local,
      appState: PushAppState.terminated,
    ).toLocalPayload();
    final p = await started(ready: false);
    expect(taps, isEmpty);
    expect(msg.initialCalls, 1);
    expect(local.launchCalls, 1);
    p.markReady();
    await pump();
    expect(taps.map((m) => m.id), ['a', 'b']);
    expect(taps.every((m) => m.appState == PushAppState.terminated), isTrue);
    expect(taps[1].source, MessageSource.local);
  });

  test(
    'onMessageOpenedApp after the app was paused is a background tap',
    () async {
      await started();
      await moveTo(AppLifecycleState.paused);
      await moveTo(AppLifecycleState.inactive);
      msg.openedCtl.add(rm('x'));
      await pump();
      expect(taps.single.appState, PushAppState.background);
      expect(taps.single.source, MessageSource.remote);
    },
  );

  test('local port tap becomes a tap with source local', () async {
    await started();
    local.onTap!(
      PushMessage(
        id: 'l1',
        channelId: 'default',
        source: MessageSource.local,
        appState: PushAppState.terminated,
      ).toLocalPayload(),
    );
    await pump();
    expect(taps.single.source, MessageSource.local);
    expect(taps.single.appState, PushAppState.foreground);
    expect(taps.single.id, 'l1');
  });

  group('live tap appState follows the last non-inactive lifecycle state', () {
    test('resumed -> inactive -> local tap is foreground', () async {
      await started();
      await moveTo(AppLifecycleState.inactive);
      local.onTap!('{"id":"l1"}');
      await pump();
      expect(taps.single.appState, PushAppState.foreground);
    });

    test('paused -> inactive -> local tap is background', () async {
      await started();
      await moveTo(AppLifecycleState.paused);
      await moveTo(AppLifecycleState.inactive);
      local.onTap!('{"id":"l1"}');
      await pump();
      expect(taps.single.appState, PushAppState.background);
    });

    test('hidden counts as background, resumed again as foreground', () async {
      await started();
      await moveTo(AppLifecycleState.hidden);
      local.onTap!('{"id":"l1"}');
      await moveTo(AppLifecycleState.inactive);
      await moveTo(AppLifecycleState.resumed);
      local.onTap!('{"id":"l2"}');
      await pump();
      expect(taps.map((m) => m.appState), [
        PushAppState.background,
        PushAppState.foreground,
      ]);
    });

    test('inactive first, never resumed, is background', () async {
      lifecycle = AppLifecycleState.inactive;
      await started();
      await moveTo(AppLifecycleState.inactive);
      local.onTap!('{"id":"l1"}');
      await pump();
      expect(taps.single.appState, PushAppState.background);
    });

    test('no lifecycle state known is background', () async {
      lifecycle = null;
      await started();
      local.onTap!('{"id":"l1"}');
      await pump();
      expect(taps.single.appState, PushAppState.background);
    });

    test('onMessageOpenedApp uses the same rule', () async {
      await started();
      await moveTo(AppLifecycleState.inactive);
      msg.openedCtl.add(rm('o1'));
      await pump();
      await moveTo(AppLifecycleState.paused);
      await moveTo(AppLifecycleState.inactive);
      msg.openedCtl.add(rm('o2'));
      await pump();
      expect(taps.map((m) => m.appState), [
        PushAppState.foreground,
        PushAppState.background,
      ]);
    });

    test(
      'native tap uses the natively captured state, not the lifecycle',
      () async {
        await started();
        // The Dart lifecycle may have moved on before the native tap arrives
        // (e.g. resumed overtaking a background tap), so it is ignored.
        await moveTo(AppLifecycleState.paused);
        nativeApi!.onNativeTap('{"id":"n1"}', true);
        await moveTo(AppLifecycleState.resumed);
        nativeApi!.onNativeTap('{"id":"n2"}', false);
        await pump();
        expect(taps.map((m) => m.appState), [
          PushAppState.foreground,
          PushAppState.background,
        ]);
      },
    );

    test('native rest taps arriving before the launch reply stay after the '
        'launch head', () async {
      host.nativeLaunchPayload = '{"id":"head"}';
      host.beforeConsumeReply = () =>
          nativeApi!.onNativeTap('{"id":"rest"}', false);
      await started();
      expect(taps.map((m) => m.id), ['head', 'rest']);
      expect(taps.map((m) => m.appState), [
        PushAppState.terminated,
        PushAppState.background,
      ]);
    });

    test('native rest taps after the launch head when markReady came first '
        'and the decision maker is async', () async {
      msg.initial = rm('initial');
      host.nativeLaunchPayload = '{"id":"head"}';
      host.beforeConsumeReply = () =>
          nativeApi!.onNativeTap('{"id":"rest"}', true);
      final p = build();
      p.markReady();
      await p.init(
        decisionMaker: (m) async {
          taps.add(m);
          await pump();
        },
        channels: [PushChannel(id: 'default', name: 'General')],
      );
      for (var i = 0; i < 5; i++) {
        await pump();
      }
      expect(taps.map((m) => m.id), ['initial', 'head', 'rest']);
      expect(taps.last.appState, PushAppState.foreground);
    });

    test('launch taps stay terminated even while resumed', () async {
      host.nativeLaunchPayload = '{"id":"n3"}';
      local.launch = '{"id":"l5"}';
      msg.initial = rm('r1');
      await started();
      expect(taps.map((m) => m.appState), [
        PushAppState.terminated,
        PushAppState.terminated,
        PushAppState.terminated,
      ]);
    });
  });

  test('native tap payload becomes a local tap', () async {
    await started();
    nativeApi!.onNativeTap('{"id":"n1","title":"hi"}', true);
    await pump();
    expect(taps.single.id, 'n1');
    expect(taps.single.source, MessageSource.local);
  });

  test('native launch payload is delivered as terminated tap', () async {
    host.nativeLaunchPayload = '{"id":"n2"}';
    await started();
    expect(taps.single.id, 'n2');
    expect(taps.single.appState, PushAppState.terminated);
  });

  test('same message id from getInitialMessage and local launch is '
      'delivered once', () async {
    msg.initial = rm('same');
    local.launch = '{"id":"same"}';
    await started();
    expect(taps, hasLength(1));
  });

  test('foreground on Android shows a local notification and emits', () async {
    final p = await started();
    final emitted = <PushMessage>[];
    p.onForegroundMessage.listen(emitted.add);
    msg.onMessageCtl.add(rm('f1'));
    await pump();
    expect(local.shown, hasLength(1));
    expect(local.shown.single.$2, greaterThanOrEqualTo(0));
    expect(emitted.single.appState, PushAppState.foreground);
  });

  group('foreground data-only', () {
    RemoteMessage dataOnly(String id, Map<String, dynamic> data) =>
        RemoteMessage(messageId: id, data: data);

    test('Android data-only title/body shown locally and emitted', () async {
      final p = await started();
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      msg.onMessageCtl.add(dataOnly('d1', {'title': 'T', 'body': 'B'}));
      await pump();
      expect(local.shown, hasLength(1));
      expect(local.shown.single.$1.title, 'T');
      expect(local.shown.single.$1.body, 'B');
      expect(emitted, hasLength(1));
    });

    test('custom titleKey/bodyKey honored and persisted', () async {
      await started(titleKey: 'tt', bodyKey: 'bb');
      msg.onMessageCtl.add(dataOnly('d2', {'tt': 'T', 'bb': 'B'}));
      await pump();
      expect(local.shown.single.$1.title, 'T');
      expect(host.savedConfigs.single.titleKey, 'tt');
      expect(host.savedConfigs.single.bodyKey, 'bb');
    });

    test('notification block wins over data', () async {
      await started();
      msg.onMessageCtl.add(
        RemoteMessage(
          messageId: 'd3',
          data: {'title': 'D', 'body': 'D'},
          notification: RemoteNotification(title: 'N', body: 'M'),
        ),
      );
      await pump();
      expect(local.shown.single.$1.title, 'N');
      expect(local.shown.single.$1.body, 'M');
    });

    test('iOS data-only with title/body is shown via the host once', () async {
      final p = await started(isIOS: true);
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      msg.onMessageCtl.add(
        dataOnly('d4', {'title': 'T', 'body': 'B', 'image': 'https://x/y.png'}),
      );
      msg.onMessageCtl.add(dataOnly('d4', {'title': 'T', 'body': 'B'}));
      await pump();
      final c = host.shownNotifications.single;
      expect(c.title, 'T');
      expect(c.body, 'B');
      expect(c.id, stableLocalId('d4'));
      expect(c.extras['messageId'], 'd4');
      expect(c.imageUrl, 'https://x/y.png');
      expect(c.imageStyle, ImageStyle.bigPicture);
      expect(local.shown, isEmpty);
      expect(emitted, hasLength(1));
    });

    test('iOS data-only with only a body is shown via the host', () async {
      await started(isIOS: true);
      msg.onMessageCtl.add(dataOnly('d5', {'body': 'B'}));
      await pump();
      expect(host.shownNotifications.single.body, 'B');
      expect(host.shownNotifications.single.imageStyle, ImageStyle.none);
    });

    test('iOS data-only without title/body is not shown', () async {
      await started(isIOS: true);
      msg.onMessageCtl.add(dataOnly('d6', {'k': 'v'}));
      await pump();
      expect(host.shownNotifications, isEmpty);
      expect(local.shown, isEmpty);
    });

    test('iOS data-only respects showForegroundNotifications false', () async {
      await started(isIOS: true, show: false);
      msg.onMessageCtl.add(dataOnly('d7', {'title': 'T'}));
      await pump();
      expect(host.shownNotifications, isEmpty);
    });

    test('iOS data-only host failure is swallowed and still emitted', () async {
      final p = await started(isIOS: true);
      host.failShow = true;
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      msg.onMessageCtl.add(dataOnly('d8', {'title': 'T'}));
      await pump();
      expect(emitted, hasLength(1));
      expect(local.shown, isEmpty);
    });
  });

  group('foreground images', () {
    const url = 'https://x/y.png';

    test('Android image message goes through native bigPicture', () async {
      final p = await started();
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      msg.onMessageCtl.add(rm('i1', data: {'image': url}));
      await pump();
      final c = host.shownNotifications.single;
      expect(c.imageUrl, url);
      expect(c.imageStyle, ImageStyle.bigPicture);
      expect(c.id, stableLocalId('i1'));
      expect(c.extras['messageId'], 'i1');
      expect(c.channelId, 'default');
      expect(local.shown, isEmpty);
      expect(emitted, hasLength(1));
    });

    test('Android text-only message still uses LocalPort', () async {
      await started();
      msg.onMessageCtl.add(rm('t1'));
      await pump();
      expect(local.shown, hasLength(1));
      expect(host.shownNotifications, isEmpty);
    });

    test('host.showNotification failure falls back to LocalPort', () async {
      final p = await started();
      host.failShow = true;
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      msg.onMessageCtl.add(rm('i2', data: {'image': url}));
      await pump();
      expect(local.shown, hasLength(1));
      expect(emitted, hasLength(1));
    });

    test('custom imageKey is honored', () async {
      await started(imageKey: 'pic');
      msg.onMessageCtl.add(rm('i3', data: {'pic': url, 'image': 'ignored'}));
      await pump();
      expect(host.shownNotifications.single.imageUrl, url);
    });

    test('iOS foreground with image does no native or local show', () async {
      final p = await started(isIOS: true);
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      msg.onMessageCtl.add(rm('i4', data: {'image': url}));
      await pump();
      expect(host.shownNotifications, isEmpty);
      expect(local.shown, isEmpty);
      expect(emitted, hasLength(1));
    });

    test('same messageId with image displays once', () async {
      await started();
      msg.onMessageCtl.add(rm('i5', data: {'image': url}));
      msg.onMessageCtl.add(rm('i5', data: {'image': url}));
      await pump();
      expect(host.shownNotifications, hasLength(1));
    });
  });

  test(
    'foreground on iOS with a notification block is OS-presented only',
    () async {
      final p = await started(isIOS: true);
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      msg.onMessageCtl.add(rm('f1'));
      await pump();
      expect(msg.presentationAlert, isTrue);
      expect(local.shown, isEmpty);
      expect(host.shownNotifications, isEmpty);
      expect(emitted, hasLength(1));
    },
  );

  test(
    'onForegroundMessage is emitted before a slow display finishes',
    () async {
      final p = await started();
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      local.showGate = Completer<void>();
      msg.onMessageCtl.add(rm('slow'));
      await pump();
      expect(local.shown, hasLength(1), reason: 'display has started');
      expect(emitted, hasLength(1), reason: 'emitted while display is pending');
      local.showGate!.complete();
      await pump();
      expect(emitted, hasLength(1));
    },
  );

  test('showForegroundNotifications false skips the local display', () async {
    final p = await started(show: false);
    final emitted = <PushMessage>[];
    p.onForegroundMessage.listen(emitted.add);
    msg.onMessageCtl.add(rm('f1'));
    await pump();
    expect(local.shown, isEmpty);
    expect(emitted, hasLength(1));
  });

  test('init twice does not duplicate listeners', () async {
    final p = await started();
    await p.init(decisionMaker: taps.add);
    final emitted = <PushMessage>[];
    p.onForegroundMessage.listen(emitted.add);
    msg.onMessageCtl.add(rm('f1'));
    await pump();
    expect(emitted, hasLength(1));
    expect(local.shown, hasLength(1));
    expect(msg.initialCalls, 1);
    expect(local.launchCalls, 1);
    expect(msg.onMessageCtl.hasListener, isTrue);
  });

  test('onTokenChanged forwards onTokenRefresh', () async {
    final p = await started();
    final tokens = <String>[];
    p.onTokenChanged.listen(tokens.add);
    msg.tokenCtl.add('new');
    await pump();
    expect(tokens, ['new']);
  });

  test('init creates every configured channel via the host API', () async {
    await started(
      channels: [
        PushChannel(id: 'default', name: 'G', description: 'desc'),
        PushChannel(id: 'chat', name: 'Chat', importance: Importance.max),
      ],
    );
    expect(host.channels.map((c) => c.id), ['default', 'chat']);
    expect(host.channels[0].channelDescription, 'desc');
    expect(host.channels[1].importance, Importance.max.value);
  });

  test(
    'default channel must be in the list or init throws ArgumentError',
    () async {
      final p = build();
      expect(
        () => p.init(
          decisionMaker: taps.add,
          channels: [PushChannel(id: 'chat', name: 'Chat')],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'createChannel adds at runtime; deleteChannel of default throws',
    () async {
      final p = await started();
      await p.createChannel(PushChannel(id: 'promo', name: 'Promo'));
      expect(host.channels.map((c) => c.id), contains('promo'));
      await p.deleteChannel('promo');
      expect(host.deleted, ['promo']);
      expect(() => p.deleteChannel('default'), throwsArgumentError);
    },
  );

  test('foreground message is displayed on its resolved channel', () async {
    await started(
      channels: [
        PushChannel(id: 'default', name: 'G'),
        PushChannel(id: 'chat', name: 'Chat'),
      ],
    );
    msg.onMessageCtl.add(rm('c1', data: {'channel_id': 'chat'}));
    msg.onMessageCtl.add(rm('c2', data: {'channel_id': 'nope'}));
    await pump();
    expect(local.shown.map((s) => s.$1.channelId), ['chat', 'default']);
  });

  test('same messageId on onMessage twice displays once', () async {
    final p = await started();
    final emitted = <PushMessage>[];
    p.onForegroundMessage.listen(emitted.add);
    msg.onMessageCtl.add(rm('dup'));
    msg.onMessageCtl.add(rm('dup'));
    await pump();
    expect(local.shown, hasLength(1));
    expect(emitted, hasLength(1));
  });

  test(
    'persisted last launch id suppresses a stale getInitialMessage',
    () async {
      host.lastLaunchId = 'old';
      msg.initial = rm('old');
      await started();
      expect(taps, isEmpty);
    },
  );

  test('launch id is persisted after the first delivery', () async {
    msg.initial = rm('fresh');
    await started();
    expect(host.setLaunchIds, contains('fresh'));
    expect(host.lastLaunchId, 'fresh');
  });

  test('tap with no decisionMaker is retained, not dropped', () async {
    // Dispatcher keeps the queue; verified through the facade by setting the
    // decision maker late via a second dispatcher-less path is not exposed,
    // so assert that a tap queued before markReady survives until then.
    msg.initial = rm('keep');
    final p = await started(ready: false);
    expect(taps, isEmpty);
    p.markReady();
    await pump();
    expect(taps.single.id, 'keep');
  });

  test(
    'init failure then retry succeeds with exactly one set of listeners',
    () async {
      final p = build();
      host.failCreate = true;
      await expectLater(p.init(decisionMaker: taps.add), throwsA(anything));
      host.failCreate = false;
      await p.init(decisionMaker: taps.add);
      final emitted = <PushMessage>[];
      p.onForegroundMessage.listen(emitted.add);
      msg.onMessageCtl.add(rm('r1'));
      await pump();
      expect(emitted, hasLength(1));
      expect(local.shown, hasLength(1));
    },
  );

  test(
    'failure after listeners attach does not duplicate them on retry',
    () async {
      final p = build();
      host.failLaunch = true;
      await expectLater(p.init(decisionMaker: taps.add), throwsA(anything));
      host.failLaunch = false;
      await p.init(decisionMaker: taps.add);
      msg.onMessageCtl.add(rm('r2'));
      await pump();
      expect(local.shown, hasLength(1));
    },
  );

  test('two concurrent init calls run setup once', () async {
    final p = build();
    await Future.wait([
      p.init(decisionMaker: taps.add),
      p.init(decisionMaker: taps.add),
    ]);
    expect(host.channels, hasLength(1));
    expect(msg.initialCalls, 1);
  });

  test(
    'all launch ids are persisted; restart does not redeliver either',
    () async {
      msg.initial = rm('a');
      local.launch = '{"id":"b"}';
      await started();
      expect(taps.map((m) => m.id), ['a', 'b']);
      expect(host.lastLaunchId!.split('\n'), ['a', 'b']);
      // Simulated restart: same persisted ids, getInitialMessage still 'a'.
      taps = [];
      local.launch = null;
      msg = FakeMessagingPort()..initial = rm('a');
      await started();
      expect(taps, isEmpty);
    },
  );

  test('registers background entry points', () async {
    await started();
    expect(msg.backgroundHandler, isNotNull);
    expect(local.bgTap, isNotNull);
  });
}

Future<void> pump() => Future<void>.delayed(Duration.zero);
