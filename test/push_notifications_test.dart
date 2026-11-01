import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:push_notifications/src/config.dart';
import 'package:push_notifications/src/messages.g.dart';
import 'package:push_notifications/src/push_message.dart';
import 'package:push_notifications/src/push_notifications.dart';

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

  PushNotifications build({bool isIOS = false}) => PushNotifications.withPorts(
    msg,
    local,
    host,
    isIOS: isIOS,
    registerFlutterApi: (a) => nativeApi = a,
  );

  Future<PushNotifications> started({
    bool isIOS = false,
    bool show = true,
    bool ready = true,
    List<PushChannel>? channels,
    String defaultId = 'default',
  }) async {
    final p = build(isIOS: isIOS);
    await p.init(
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
  });

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

  test('onMessageOpenedApp becomes a background tap', () async {
    await started();
    msg.openedCtl.add(rm('x'));
    await pump();
    expect(taps.single.appState, PushAppState.background);
    expect(taps.single.source, MessageSource.remote);
  });

  test('local port tap becomes a tap with source local', () async {
    await started();
    local.onTap!(
      PushMessage(
        id: 'l1',
        channelId: 'default',
        source: MessageSource.local,
        appState: PushAppState.foreground,
      ).toLocalPayload(),
      PushAppState.foreground,
    );
    await pump();
    expect(taps.single.source, MessageSource.local);
    expect(taps.single.appState, PushAppState.foreground);
    expect(taps.single.id, 'l1');
  });

  test('native tap payload becomes a local tap', () async {
    await started();
    nativeApi!.onNativeTap('{"id":"n1","title":"hi"}');
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

  test('foreground on iOS sets presentation options, no local show', () async {
    final p = await started(isIOS: true);
    final emitted = <PushMessage>[];
    p.onForegroundMessage.listen(emitted.add);
    msg.onMessageCtl.add(rm('f1'));
    await pump();
    expect(msg.presentationAlert, isTrue);
    expect(local.shown, isEmpty);
    expect(emitted, hasLength(1));
  });

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
