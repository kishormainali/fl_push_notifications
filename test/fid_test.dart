import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:push_notifications/src/push_message.dart';
import 'package:push_notifications/src/push_notifications.dart';

import 'fakes.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeMessagingPort msg;
  late FakeLocalPort local;
  late FakeHostApi host;
  late StreamController<AppLifecycleState> lifecycleCtl;
  final taps = <PushMessage>[];

  PushNotifications build() => PushNotifications.withPorts(
    msg,
    local,
    host,
    registerFlutterApi: (_) {},
    currentLifecycleState: () => AppLifecycleState.resumed,
    lifecycleStates: () => lifecycleCtl.stream,
  );

  setUp(() {
    msg = FakeMessagingPort();
    local = FakeLocalPort();
    host = FakeHostApi();
    taps.clear();
    lifecycleCtl = StreamController<AppLifecycleState>.broadcast();
  });

  tearDown(() => lifecycleCtl.close());

  group('autoRegister (default)', () {
    test('subscribes before calling register, then tracks the FID', () async {
      final p = build();
      await p.init(decisionMaker: taps.add);
      expect(msg.registerCalls, 1);
      expect(msg.listenersAtRegister.single, (true, true));
      expect(p.installationId, isNull);
      msg.registeredCtl.add('fid-1');
      await pump();
      expect(p.installationId, 'fid-1');
    });

    test('onRegistered forwards port events (broadcast)', () async {
      final p = build();
      await p.init(decisionMaker: taps.add);
      final a = <String>[], b = <String>[];
      p.onRegistered.listen(a.add);
      p.onRegistered.listen(b.add);
      msg.registeredCtl.add('fid-1');
      await pump();
      expect(a, ['fid-1']);
      expect(b, ['fid-1']);
    });

    test('a new FID replaces the previous one', () async {
      final p = build();
      await p.init(decisionMaker: taps.add);
      msg.registeredCtl.add('fid-1');
      msg.registeredCtl.add('fid-2');
      await pump();
      expect(p.installationId, 'fid-2');
    });

    test(
      'register failure does not fail init; token API still works',
      () async {
        msg.failRegister = true;
        final p = build();
        await p.init(decisionMaker: taps.add);
        expect(msg.registerCalls, 1);
        expect(await p.token, 'tok');
        final tokens = <String>[];
        p.onTokenChanged.listen(tokens.add);
        msg.tokenCtl.add('new');
        await pump();
        expect(tokens, ['new']);
      },
    );

    test('idempotent init registers once', () async {
      final p = build();
      await p.init(decisionMaker: taps.add);
      await p.init(decisionMaker: taps.add);
      await Future.wait([
        p.init(decisionMaker: taps.add),
        p.init(decisionMaker: taps.add),
      ]);
      expect(msg.registerCalls, 1);
    });

    test('init retry after failure does not duplicate FID listeners', () async {
      final p = build();
      host.failLaunch = true;
      await expectLater(p.init(decisionMaker: taps.add), throwsA(anything));
      host.failLaunch = false;
      await p.init(decisionMaker: taps.add);
      final seen = <String>[];
      p.onRegistered.listen(seen.add);
      msg.registeredCtl.add('fid-1');
      await pump();
      expect(seen, ['fid-1']);
      expect(p.installationId, 'fid-1');
    });

    test('FID listeners are cancelled when init fails', () async {
      final p = build();
      host.failLaunch = true;
      await expectLater(p.init(decisionMaker: taps.add), throwsA(anything));
      await pump();
      expect(msg.registeredCtl.hasListener, isFalse);
      expect(msg.unregisteredCtl.hasListener, isFalse);
    });
  });

  group('autoRegister: false', () {
    test('init does not register; manual register attaches once', () async {
      final p = build();
      await p.init(decisionMaker: taps.add, autoRegister: false);
      expect(msg.registerCalls, 0);
      expect(msg.registeredCtl.hasListener, isFalse);

      await p.register();
      await p.register();
      expect(msg.registerCalls, 2);
      expect(msg.listenersAtRegister.first, (true, true));

      final seen = <String>[];
      p.onRegistered.listen(seen.add);
      msg.registeredCtl.add('fid-1');
      await pump();
      expect(seen, ['fid-1']);
      expect(p.installationId, 'fid-1');
    });

    test('manual register before init does not duplicate on init', () async {
      final p = build();
      await p.register();
      await p.init(decisionMaker: taps.add, autoRegister: false);
      final seen = <String>[];
      p.onRegistered.listen(seen.add);
      msg.registeredCtl.add('fid-1');
      await pump();
      expect(seen, ['fid-1']);
    });
  });

  group('unregister', () {
    test('calls the port', () async {
      final p = build();
      await p.init(decisionMaker: taps.add);
      await p.unregister();
      expect(msg.unregisterCalls, 1);
    });

    test('onUnregistered of the current FID clears installationId', () async {
      final p = build();
      await p.init(decisionMaker: taps.add);
      final gone = <String>[];
      p.onUnregistered.listen(gone.add);
      msg.registeredCtl.add('fid-1');
      await pump();
      msg.unregisteredCtl.add('fid-1');
      await pump();
      expect(gone, ['fid-1']);
      expect(p.installationId, isNull);
    });

    test('unregister alone (autoRegister false) forwards the FID', () async {
      final p = build();
      await p.init(decisionMaker: taps.add, autoRegister: false);
      final gone = <String>[];
      p.onUnregistered.listen(gone.add);
      await p.unregister();
      expect(msg.unregisteredCtl.hasListener, isTrue);
      msg.unregisteredCtl.add('fid-old');
      await pump();
      expect(gone, ['fid-old']);
    });

    test('register, failing init, then unregister still forwards', () async {
      final p = build();
      await p.register();
      host.failLaunch = true;
      await expectLater(p.init(decisionMaker: taps.add), throwsA(anything));
      await pump();
      expect(msg.unregisteredCtl.hasListener, isFalse);
      final gone = <String>[];
      p.onUnregistered.listen(gone.add);
      await p.unregister();
      msg.unregisteredCtl.add('fid-1');
      await pump();
      expect(gone, ['fid-1']);
      expect(p.installationId, isNull);
    });

    test('onUnregistered of another FID leaves installationId', () async {
      final p = build();
      await p.init(decisionMaker: taps.add);
      msg.registeredCtl.add('fid-2');
      await pump();
      msg.unregisteredCtl.add('fid-1');
      await pump();
      expect(p.installationId, 'fid-2');
    });
  });
}
