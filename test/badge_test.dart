import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:push_notifications/src/config.dart';
import 'package:push_notifications/src/push_notifications.dart';

import 'fakes.dart';

void main() {
  late FakeMessagingPort msg;
  late FakeLocalPort local;
  late FakeHostApi host;
  late StreamController<AppLifecycleState> lifecycle;

  PushNotifications build() => PushNotifications.withPorts(
    msg,
    local,
    host,
    lifecycleStates: () => lifecycle.stream,
  );

  Future<PushNotifications> started(BadgeConfig badge) async {
    final p = build();
    await p.init(decisionMaker: (_) {}, badge: badge);
    p.markReady();
    await pump();
    return p;
  }

  setUp(() {
    msg = FakeMessagingPort();
    local = FakeLocalPort();
    host = FakeHostApi();
    lifecycle = StreamController<AppLifecycleState>.broadcast();
  });

  tearDown(() => lifecycle.close());

  test('setBadgeCount clamps negatives to 0', () async {
    final p = build();
    await p.setBadgeCount(-3);
    await p.setBadgeCount(4);
    expect(host.badgeSets, [0, 4]);
  });

  test('clearBadge calls clearBadge on host', () async {
    await build().clearBadge();
    expect(host.badgeClears, 1);
  });

  test('getBadgeCount and isBadgeSupported delegate to host', () async {
    final p = build();
    host.storedBadge = 7;
    host.badgeSupported = false;
    expect(await p.getBadgeCount(), 7);
    expect(await p.isBadgeSupported(), isFalse);
    host.storedBadge = null;
    host.badgeSupported = true;
    expect(await p.getBadgeCount(), isNull);
    expect(await p.isBadgeSupported(), isTrue);
  });

  test('autoClearOnForeground clears once at init', () async {
    await started(BadgeConfig(autoClearOnForeground: true));
    expect(host.badgeClears, 1);
  });

  test('autoClearOnForeground clears on AppLifecycleState.resumed', () async {
    await started(BadgeConfig(autoClearOnForeground: true));
    lifecycle.add(AppLifecycleState.paused);
    await pump();
    expect(host.badgeClears, 1);
    lifecycle.add(AppLifecycleState.resumed);
    await pump();
    expect(host.badgeClears, 2);
  });

  test('autoClearOnForeground off: no clear at init or on resume', () async {
    await started(BadgeConfig());
    lifecycle.add(AppLifecycleState.resumed);
    await pump();
    expect(host.badgeClears, 0);
    expect(lifecycle.hasListener, isFalse);
  });

  test('lifecycle listener is removed when init fails', () async {
    host.failLaunch = true;
    final p = build();
    await expectLater(
      p.init(
        decisionMaker: (_) {},
        badge: BadgeConfig(autoClearOnForeground: true),
      ),
      throwsStateError,
    );
    await pump();
    expect(lifecycle.hasListener, isFalse);
  });

  test(
    'autoIncrementOnPush does not increment for a foreground push',
    () async {
      await started(BadgeConfig(autoIncrementOnPush: true));
      msg.onMessageCtl.add(
        const RemoteMessage(
          messageId: 'm1',
          notification: RemoteNotification(title: 't', body: 'b'),
        ),
      );
      await pump();
      expect(host.badgeIncrements, 0);
      expect(host.badgeSets, isEmpty);
    },
  );
}

Future<void> pump() => Future<void>.delayed(Duration.zero);
