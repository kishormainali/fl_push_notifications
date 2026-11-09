import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_push_notifications/src/push_notifications.dart';

import 'fakes.dart';

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeMessagingPort msg;
  late FakeLocalPort local;
  late FakeHostApi host;
  late StreamController<AppLifecycleState> lifecycleCtl;

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
    lifecycleCtl = StreamController<AppLifecycleState>.broadcast();
  });
  tearDown(() => lifecycleCtl.close());

  test('init does not listen to port onTokenRefresh', () async {
    final p = build();
    await p.init(decisionMaker: (_) {});
    expect(msg.tokenCtl.hasListener, isFalse);
    expect(msg.tokenListens, 0);
  });

  test('init with autoRegister false does not listen either', () async {
    final p = build();
    await p.init(decisionMaker: (_) {}, autoRegister: false);
    expect(msg.tokenListens, 0);
  });

  test('first listener attaches once; second shares it', () async {
    final p = build();
    await p.init(decisionMaker: (_) {});
    final a = <String>[], b = <String>[];
    final s1 = p.onTokenChanged.listen(a.add);
    final s2 = p.onTokenChanged.listen(b.add);
    expect(msg.tokenListens, 1);
    msg.tokenCtl.add('t1');
    await pump();
    expect(a, ['t1']);
    expect(b, ['t1']);
    await s1.cancel();
    expect(msg.tokenCancels, 0);
    msg.tokenCtl.add('t2');
    await pump();
    expect(a, ['t1']);
    expect(b, ['t1', 't2']);
    await s2.cancel();
  });

  test(
    'cancelling all cancels the port subscription; re-listen re-attaches',
    () async {
      final p = build();
      await p.init(decisionMaker: (_) {});
      final s1 = p.onTokenChanged.listen((_) {});
      final s2 = p.onTokenChanged.listen((_) {});
      await s1.cancel();
      await s2.cancel();
      expect(msg.tokenCancels, 1);
      expect(msg.tokenCtl.hasListener, isFalse);
      final got = <String>[];
      final s3 = p.onTokenChanged.listen(got.add);
      expect(msg.tokenListens, 2);
      msg.tokenCtl.add('again');
      await pump();
      expect(got, ['again']);
      await s3.cancel();
    },
  );

  test('token emitted with no listener is not buffered', () async {
    final p = build();
    await p.init(decisionMaker: (_) {});
    msg.tokenCtl.add('lost');
    await pump();
    final got = <String>[];
    final s = p.onTokenChanged.listen(got.add);
    await pump();
    expect(got, isEmpty);
    await s.cancel();
  });

  test('resubscribing listeners get each token exactly once', () async {
    final p = build();
    await p.init(decisionMaker: (_) {});
    final got = <String>[];
    var s = p.onTokenChanged.listen(got.add);
    await s.cancel();
    s = p.onTokenChanged.listen(got.add);
    msg.tokenCtl.add('x');
    await pump();
    expect(got, ['x']);
    await s.cancel();
  });

  test('port stream errors are forwarded as stream errors', () async {
    final p = build();
    await p.init(decisionMaker: (_) {});
    final errors = <Object>[];
    final got = <String>[];
    final s = p.onTokenChanged.listen(got.add, onError: errors.add);
    msg.tokenCtl.addError(StateError('boom'));
    msg.tokenCtl.add('after');
    await pump();
    expect(errors, hasLength(1));
    expect(got, ['after']);
    await s.cancel();
  });

  test('listening before init works after init completes', () async {
    final p = build();
    final got = <String>[];
    final s = p.onTokenChanged.listen(got.add);
    expect(msg.tokenListens, 1);
    await p.init(decisionMaker: (_) {});
    expect(msg.tokenListens, 1);
    msg.tokenCtl.add('t');
    await pump();
    expect(got, ['t']);
    await s.cancel();
  });

  test('port throwing on listen does not throw; next listen retries', () async {
    final p = build();
    msg.tokenRefreshError = StateError('no firebase');
    final s1 = p.onTokenChanged.listen((_) {});
    expect(msg.tokenListens, 0);
    msg.tokenRefreshError = null;
    // Retry happens when the controller next goes from 0 to 1 listeners.
    await s1.cancel();
    final got = <String>[];
    final s2 = p.onTokenChanged.listen(got.add);
    expect(msg.tokenListens, 1);
    msg.tokenCtl.add('ok');
    await pump();
    expect(got, ['ok']);
    await s1.cancel();
    await s2.cancel();
  });

  test(
    'failed init then retry leaves exactly one token subscription',
    () async {
      final p = build();
      final got = <String>[];
      final s = p.onTokenChanged.listen(got.add);
      host.failLaunch = true;
      await expectLater(p.init(decisionMaker: (_) {}), throwsA(anything));
      // The init cleanup must not drop the live token subscription.
      expect(msg.tokenCancels, 0);
      host.failLaunch = false;
      await p.init(decisionMaker: (_) {});
      expect(msg.tokenListens, 1);
      msg.tokenCtl.add('t');
      await pump();
      expect(got, ['t']);
      await s.cancel();
      expect(msg.tokenCancels, 1);
    },
  );
}
