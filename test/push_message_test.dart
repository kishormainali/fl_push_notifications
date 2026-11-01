import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:push_notifications/src/push_message.dart';
import 'package:push_notifications/src/tap_dispatcher.dart';

void main() {
  test('fromRemote builds with null notification and empty data', () {
    final m = PushMessage.fromRemote(
      const RemoteMessage(messageId: 'x'),
      PushAppState.terminated,
    );
    expect(m.id, 'x');
    expect(m.title, isNull);
    expect(m.body, isNull);
    expect(m.data, isEmpty);
    expect(m.imageUrl, isNull);
    expect(m.channelId, 'default');
    expect(m.source, MessageSource.remote);
    expect(m.appState, PushAppState.terminated);
  });

  test('fromRemote generates an id when messageId is null', () {
    final a = PushMessage.fromRemote(
      const RemoteMessage(),
      PushAppState.foreground,
    );
    expect(a.id, isNotEmpty);
  });

  test('local payload round-trips through toLocalPayload/fromLocalPayload', () {
    final m = PushMessage(
      id: 'i1',
      title: 't',
      body: 'b',
      data: const {'k': 'v'},
      imageUrl: 'http://x/y.png',
      channelId: 'c',
      source: MessageSource.remote,
      appState: PushAppState.foreground,
    );
    final r = PushMessage.fromLocalPayload(
      m.toLocalPayload(),
      PushAppState.background,
    );
    expect(r.id, 'i1');
    expect(r.title, 't');
    expect(r.body, 'b');
    expect(r.data, {'k': 'v'});
    expect(r.imageUrl, 'http://x/y.png');
    expect(r.channelId, 'c');
    expect(r.source, MessageSource.local);
    expect(r.appState, PushAppState.background);
  });

  test(
    'imageUrl read from notification.android.imageUrl, then data[imageKey]',
    () {
      final a = PushMessage.fromRemote(
        const RemoteMessage(
          data: {'image': 'data-url'},
          notification: RemoteNotification(
            android: AndroidNotification(imageUrl: 'android-url'),
          ),
        ),
        PushAppState.foreground,
      );
      expect(a.imageUrl, 'android-url');
      final b = PushMessage.fromRemote(
        const RemoteMessage(data: {'pic': 'data-url'}),
        PushAppState.foreground,
        imageKey: 'pic',
      );
      expect(b.imageUrl, 'data-url');
    },
  );

  test(
    'resolveChannelId prefers android channelId, then data key, then default',
    () {
      const known = {'default', 'a', 'b'};
      String r(RemoteMessage m) => resolveChannelId(
        m,
        known: known,
        defaultId: 'default',
        channelKey: 'channel_id',
      );
      expect(
        r(
          const RemoteMessage(
            data: {'channel_id': 'b'},
            notification: RemoteNotification(
              android: AndroidNotification(channelId: 'a'),
            ),
          ),
        ),
        'a',
      );
      expect(r(const RemoteMessage(data: {'channel_id': 'b'})), 'b');
      expect(r(const RemoteMessage()), 'default');
    },
  );

  test(
    'unknown channel id falls back to default and still builds the message',
    () {
      final id = resolveChannelId(
        const RemoteMessage(data: {'channel_id': 'nope'}),
        known: {'default'},
        defaultId: 'default',
        channelKey: 'channel_id',
      );
      expect(id, 'default');
      final m = PushMessage.fromRemote(
        const RemoteMessage(messageId: 'm', data: {'channel_id': 'nope'}),
        PushAppState.foreground,
        knownChannels: {'default'},
      );
      expect(m.channelId, 'default');
      expect(m.id, 'm');
    },
  );

  test('data-only message routes via default channel_id key', () {
    final m = PushMessage.fromRemote(
      const RemoteMessage(messageId: 'd', data: {'channel_id': 'alerts'}),
      PushAppState.foreground,
      knownChannels: {'default', 'alerts'},
    );
    expect(m.channelId, 'alerts');
  });

  test(
    'corrupt local payload yields a minimal PushMessage instead of throwing',
    () {
      for (final p in ['not json', '[1,2]', '{"id": 5, "data": 7}', '']) {
        final m = PushMessage.fromLocalPayload(
          p,
          PushAppState.terminated,
          defaultChannelId: 'dflt',
        );
        expect(m.id, isNotEmpty);
        expect(m.data, isEmpty);
        expect(m.channelId, 'dflt');
        expect(m.source, MessageSource.local);
      }
    },
  );

  test('fromLocalPayload reads channelId, falling back to the default', () {
    final withChannel = PushMessage.fromLocalPayload(
      '{"id":"1","channelId":"chat"}',
      PushAppState.background,
      defaultChannelId: 'dflt',
    );
    expect(withChannel.channelId, 'chat');
    for (final p in [
      '{"id":"2"}',
      '{"id":"3","channelId":null}',
      '{"id":"4","channelId":""}',
    ]) {
      final m = PushMessage.fromLocalPayload(
        p,
        PushAppState.background,
        defaultChannelId: 'dflt',
      );
      expect(m.channelId, 'dflt', reason: p);
    }
  });

  test('toLocalPayload includes channelId', () {
    final m = PushMessage(
      id: 'i',
      channelId: 'chat',
      source: MessageSource.remote,
      appState: PushAppState.foreground,
    );
    expect(jsonDecode(m.toLocalPayload())['channelId'], 'chat');
  });

  test('native payload contract parses into a PushMessage', () {
    const native =
        '{"id":"fcm-1","title":"T","body":null,"data":{"k":"v"},'
        '"imageUrl":null,"channelId":"default"}';
    final m = PushMessage.fromLocalPayload(native, PushAppState.background);
    expect(
      (m.id, m.title, m.body, m.imageUrl, m.channelId),
      ('fcm-1', 'T', null, null, 'default'),
    );
    expect(m.data, {'k': 'v'});
  });

  test('tap with unknown channel is still delivered', () async {
    final seen = <String>[];
    final d = TapDispatcher(decisionMaker: (m) => seen.add(m.id));
    await d.markReady();
    await d.handleTap(
      PushMessage.fromRemote(
        const RemoteMessage(messageId: 'u', data: {'channel_id': 'zzz'}),
        PushAppState.background,
        knownChannels: {'default'},
      ),
    );
    expect(seen, ['u']);
  });
}
