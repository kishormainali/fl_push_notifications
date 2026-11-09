import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';
import 'package:push_notifications/src/background_handler.dart';
import 'package:push_notifications/src/messages.g.dart';
import 'package:push_notifications/src/push_message.dart';

import 'fakes.dart';

BackgroundConfigMsg cfg({bool inc = false, int? hook}) => BackgroundConfigMsg(
  defaultChannelId: 'default',
  channelKey: 'channel_id',
  imageKey: 'image',
  titleKey: 'title',
  bodyKey: 'body',
  imageHttpsOnly: true,
  autoIncrementOnPush: inc,
  autoClearOnForeground: false,
  hookHandle: hook,
);

void main() {
  late FakeHostApi host;
  var firebaseCalls = 0;

  Future<void> run(
    RemoteMessage m, {
    Future<void> Function(RemoteMessage)? hook,
    Future<void> Function()? initFirebase,
    TargetPlatform? platform,
  }) => handleBackgroundMessage(
    m,
    host: host,
    initFirebase: initFirebase ?? () async => firebaseCalls++,
    resolveHook: (_) => hook,
    platform: platform,
  );

  setUp(() {
    host = FakeHostApi();
    firebaseCalls = 0;
  });

  test('data-only message is shown via showNotification with title/body '
      'from data keys', () async {
    await run(
      const RemoteMessage(
        messageId: 'm1',
        data: {'title': 'Hi', 'body': 'There', 'image': 'https://x/y.png'},
      ),
    );
    expect(firebaseCalls, 0, reason: 'Firebase only needed for the hook');
    expect(host.shownNotifications, hasLength(1));
    final c = host.shownNotifications.single;
    expect(c.title, 'Hi');
    expect(c.body, 'There');
    expect(c.imageUrl, 'https://x/y.png');
    expect(c.imageStyle, ImageStyle.bigPicture);
    expect(c.channelId, 'default');
  });

  test('uses defaults when no persisted config, none image style without '
      'image', () async {
    await run(const RemoteMessage(messageId: 'm2', data: {'title': 'T'}));
    final c = host.shownNotifications.single;
    expect(c.imageStyle, ImageStyle.none);
    expect(c.imageUrl, isNull);
  });

  test('notification message (has notification block) is not displayed '
      'again by the handler', () async {
    await run(
      const RemoteMessage(
        messageId: 'm3',
        data: {'title': 'x'},
        notification: RemoteNotification(title: 'T', body: 'B'),
      ),
    );
    expect(host.shownNotifications, isEmpty);
  });

  test('null notification and empty data does not throw and shows '
      'nothing', () async {
    await run(const RemoteMessage(messageId: 'm4'));
    expect(host.shownNotifications, isEmpty);
  });

  test('data-only message is shown on the channel from data[channelKey], '
      'else the default', () async {
    await run(
      const RemoteMessage(
        messageId: 'm5',
        data: {'title': 'a', 'channel_id': 'promo'},
      ),
    );
    await run(const RemoteMessage(messageId: 'm6', data: {'title': 'a'}));
    expect(host.shownNotifications[0].channelId, 'promo');
    expect(host.shownNotifications[1].channelId, 'default');
  });

  test('uses persisted config keys', () async {
    host.storedConfig = BackgroundConfigMsg(
      defaultChannelId: 'dflt',
      channelKey: 'ch',
      imageKey: 'pic',
      titleKey: 'tt',
      bodyKey: 'bb',
      imageHttpsOnly: true,
      autoIncrementOnPush: false,
      autoClearOnForeground: false,
    );
    await run(
      const RemoteMessage(
        messageId: 'm7',
        data: {'tt': 'T', 'bb': 'B', 'pic': 'https://i/p.png', 'ch': 'z'},
      ),
    );
    final c = host.shownNotifications.single;
    expect((c.title, c.body, c.channelId), ('T', 'B', 'z'));
    expect(c.imageUrl, 'https://i/p.png');
  });

  test('local notification id is derived deterministically from the message '
      'id', () async {
    await run(const RemoteMessage(messageId: 'abc', data: {'title': 'a'}));
    expect(host.shownNotifications.single.id, stableLocalId('abc'));
    expect(stableLocalId('abc'), stableLocalId('abc'));
    expect(stableLocalId('abc'), isNot(stableLocalId('abd')));
    expect(stableLocalId('abc'), greaterThanOrEqualTo(0));
  });

  test('content carries the FCM messageId in extras for the tap '
      'payload', () async {
    await run(const RemoteMessage(messageId: 'mid-1', data: {'title': 'a'}));
    expect(host.shownNotifications.single.extras, {'messageId': 'mid-1'});
    final c = contentFromRemote(
      const RemoteMessage(data: {'title': 'a'}),
      channelId: 'default',
    );
    expect(c.extras, isEmpty);
  });

  test('same messageId twice shows once', () async {
    const m = RemoteMessage(messageId: 'dup', data: {'title': 'a'});
    await run(m);
    await run(m);
    expect(host.shownNotifications, hasLength(1));
  });

  test('autoIncrementOnPush increments badge for background data-only '
      'messages, and not when off', () async {
    host.storedConfig = cfg(inc: true);
    await run(const RemoteMessage(messageId: 'b1', data: {'title': 'a'}));
    expect(host.badgeIncrements, 1);
    host.storedConfig = cfg(inc: false);
    await run(const RemoteMessage(messageId: 'b2', data: {'title': 'a'}));
    expect(host.badgeIncrements, 1);
  });

  group('badge on the shown notification (autoIncrementOnPush)', () {
    test('iOS: data-only message carries the incremented count, '
        'incremented before the show', () async {
      host.storedConfig = cfg(inc: true);
      host.badgeIncrements = 4;
      await run(
        const RemoteMessage(messageId: 'nb1', data: {'title': 'a'}),
        platform: TargetPlatform.iOS,
      );
      expect(host.hostCalls, ['increment', 'show']);
      expect(host.shownNotifications.single.badge, 5);
    });

    test('Android: increments before the show but sets no badge (launchers '
        'sum setNumber)', () async {
      host.storedConfig = cfg(inc: true);
      host.badgeIncrements = 2;
      await run(
        const RemoteMessage(messageId: 'nb1a', data: {'title': 'a'}),
        platform: TargetPlatform.android,
      );
      expect(host.hostCalls, ['increment', 'show']);
      expect(host.badgeIncrements, 3);
      expect(host.shownNotifications.single.badge, isNull);
    });

    test('autoIncrementOnPush off: no badge on the content', () async {
      host.storedConfig = cfg(inc: false);
      await run(
        const RemoteMessage(messageId: 'nb2', data: {'title': 'a'}),
        platform: TargetPlatform.iOS,
      );
      expect(host.hostCalls, ['show']);
      expect(host.shownNotifications.single.badge, isNull);
    });

    test('increment failure still shows, without a badge', () async {
      host.storedConfig = cfg(inc: true);
      host.failIncrement = true;
      await run(
        const RemoteMessage(messageId: 'nb3', data: {'title': 'a'}),
        platform: TargetPlatform.iOS,
      );
      expect(host.shownNotifications, hasLength(1));
      expect(host.shownNotifications.single.badge, isNull);
    });

    test('notification-block message increments but is not shown', () async {
      host.storedConfig = cfg(inc: true);
      await run(
        const RemoteMessage(
          messageId: 'nb4',
          notification: RemoteNotification(title: 'T', body: 'B'),
        ),
      );
      expect(host.badgeIncrements, 1);
      expect(host.shownNotifications, isEmpty);
    });

    test(
      'duplicate increments again (as before) but is not shown again',
      () async {
        host.storedConfig = cfg(inc: true);
        const m = RemoteMessage(messageId: 'nb5', data: {'title': 'a'});
        await run(m, platform: TargetPlatform.iOS);
        await run(m, platform: TargetPlatform.iOS);
        expect(host.badgeIncrements, 2);
        expect(host.shownNotifications, hasLength(1));
        expect(host.shownNotifications.single.badge, 1);
        expect(host.hostCalls, ['increment', 'show', 'increment']);
      },
    );
  });

  test('buildNativeContent passes an optional badge through', () {
    NotificationContent build({int? badge}) => buildNativeContent(
      messageId: 'x',
      title: 't',
      body: null,
      channelId: 'c',
      data: const {},
      badge: badge,
    );
    expect(build().badge, isNull);
    expect(build(badge: 3).badge, 3);
  });

  test('user hook is called after display; hook exception does not '
      'escape', () async {
    host.storedConfig = cfg(hook: 42);
    final order = <String>[];
    await run(
      const RemoteMessage(messageId: 'h1', data: {'title': 'a'}),
      hook: (m) async {
        order.add('hook:${host.shownNotifications.length}');
      },
    );
    expect(order, ['hook:1']);
    await run(
      const RemoteMessage(messageId: 'h2', data: {'title': 'a'}),
      hook: (m) async => throw StateError('boom'),
    );
  });

  test('handler never throws if host.showNotification throws', () async {
    host.failShow = true;
    await run(const RemoteMessage(messageId: 'f1', data: {'title': 'a'}));
  });

  test('messages without a messageId get distinct notification ids, used '
      'for both id and extras', () async {
    await run(const RemoteMessage(data: {'title': 'a'}));
    await run(const RemoteMessage(data: {'title': 'b'}));
    final a = host.shownNotifications[0];
    final b = host.shownNotifications[1];
    expect(a.id, isNot(b.id));
    expect(a.id, isNot(stableLocalId('')));
    expect(a.extras['messageId'], isNotEmpty);
    expect(a.extras['messageId'], isNot(b.extras['messageId']));
    expect(a.id, stableLocalId(a.extras['messageId']! as String));
  });

  test('the same id-less RemoteMessage object processed twice is shown '
      'twice (no id to dedupe on)', () async {
    const m = RemoteMessage(data: {'title': 'a'});
    await run(m);
    await run(m);
    expect(host.shownNotifications, hasLength(2));
    expect(host.shownNotifications[0].id, isNot(host.shownNotifications[1].id));
  });

  test('a failed show does not suppress a redelivery of the same '
      'messageId', () async {
    const m = RemoteMessage(messageId: 'retry-1', data: {'title': 'a'});
    host.failShow = true;
    await run(m);
    expect(host.shownNotifications, isEmpty);
    host.failShow = false;
    await run(m);
    expect(host.shownNotifications, hasLength(1));
    await run(m);
    expect(host.shownNotifications, hasLength(1));
  });

  test('Firebase init failure still shows and increments badge, and skips '
      'the hook', () async {
    host.storedConfig = cfg(inc: true, hook: 7);
    var hookCalls = 0;
    await run(
      const RemoteMessage(messageId: 'fb1', data: {'title': 'a'}),
      initFirebase: () async => throw StateError('no firebase'),
      hook: (m) async => hookCalls++,
    );
    expect(host.shownNotifications, hasLength(1));
    expect(host.badgeIncrements, 1);
    expect(hookCalls, 0);
  });

  test('Firebase is initialized before the hook runs', () async {
    host.storedConfig = cfg(hook: 7);
    var hookCalls = 0;
    await run(
      const RemoteMessage(messageId: 'fb2', data: {'title': 'a'}),
      hook: (m) async => hookCalls++,
    );
    expect(firebaseCalls, 1);
    expect(hookCalls, 1);
  });

  test('overlapping invocations with the same messageId show once', () async {
    host.showGate = Completer<void>();
    const m = RemoteMessage(messageId: 'race-1', data: {'title': 'a'});
    final f1 = run(m);
    final f2 = run(m);
    await pumpEventQueue();
    host.showGate!.complete();
    await Future.wait([f1, f2]);
    expect(host.shownNotifications, hasLength(1));
  });

  test('overlapping invocations with different ids both show', () async {
    host.showGate = Completer<void>();
    final f1 = run(const RemoteMessage(messageId: 'r-a', data: {'title': 'a'}));
    final f2 = run(const RemoteMessage(messageId: 'r-b', data: {'title': 'b'}));
    await pumpEventQueue();
    host.showGate!.complete();
    await Future.wait([f1, f2]);
    expect(host.shownNotifications, hasLength(2));
  });

  test(
    'overlapping same id: failed first show still allows redelivery',
    () async {
      host.showGate = Completer<void>();
      host.failShow = true;
      const m = RemoteMessage(messageId: 'race-2', data: {'title': 'a'});
      final f1 = run(m);
      await pumpEventQueue();
      host.showGate!.complete();
      await f1;
      host.failShow = false;
      await run(m);
      expect(host.shownNotifications, hasLength(1));
    },
  );

  test('empty-string messageIds are treated as absent: both show with '
      'different ids', () async {
    await run(const RemoteMessage(messageId: '', data: {'title': 'a'}));
    await run(const RemoteMessage(messageId: '', data: {'title': 'b'}));
    expect(host.shownNotifications, hasLength(2));
    expect(host.shownNotifications[0].id, isNot(host.shownNotifications[1].id));
  });
}
