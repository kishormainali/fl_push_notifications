import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_push_notifications/src/push_notifications.dart';

import 'fakes.dart';

void main() {
  late FakeMessagingPort msg;

  PushNotifications build({required bool ios}) => PushNotifications.withPorts(
    msg,
    FakeLocalPort(),
    FakeHostApi(),
    isIOS: ios,
    registerFlutterApi: (_) {},
  );

  setUp(() => msg = FakeMessagingPort());

  group('Android', () {
    test('returns the FCM token and never calls getAPNSToken', () async {
      msg.fcmToken = 'fcm-android';
      final p = build(ios: false);
      expect(await p.getPlatformToken(), 'fcm-android');
      expect(await p.getPlatformToken(), await p.token);
      expect(msg.apnsCalls, 0);
    });

    test('getToken throwing => null, no throw', () async {
      msg.getTokenError = StateError('boom');
      expect(await build(ios: false).getPlatformToken(), isNull);
    });
  });

  group('iOS', () {
    test('returns the APNs token and never calls getToken', () async {
      msg.apnsResponses = ['apns-1'];
      expect(await build(ios: true).getPlatformToken(), 'apns-1');
      expect(msg.getTokenCalls, 0);
      expect(msg.apnsCalls, 1);
    });

    test('polls every 250 ms until available, then stops', () {
      fakeAsync((async) {
        msg.apnsResponses = [null, null, 'apns-late'];
        String? result;
        build(ios: true).getPlatformToken().then((t) => result = t);
        async.flushMicrotasks();
        expect(msg.apnsCalls, 1);
        async.elapse(const Duration(milliseconds: 249));
        expect(msg.apnsCalls, 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(msg.apnsCalls, 2);
        async.elapse(const Duration(milliseconds: 250));
        async.flushMicrotasks();
        expect(msg.apnsCalls, 3);
        expect(result, 'apns-late');
        async.elapse(const Duration(seconds: 10));
        expect(msg.apnsCalls, 3);
      });
    });

    test('never available within timeout => null, no throw', () async {
      final t = await build(ios: true)
          .getPlatformToken(apnsTimeout: const Duration(milliseconds: 50));
      expect(t, isNull);
      expect(msg.apnsCalls, greaterThanOrEqualTo(2));
      expect(msg.getTokenCalls, 0);
    });

    test('default 3 s timeout bounds polling', () {
      fakeAsync((async) {
        var done = false;
        String? result;
        build(ios: true).getPlatformToken().then((t) {
          result = t;
          done = true;
        });
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(result, isNull);
        expect(msg.apnsCalls, 13); // t=0, 250, ..., 3000
      });
    });

    test('zero timeout => exactly one APNs attempt', () async {
      final t = await build(ios: true)
          .getPlatformToken(apnsTimeout: Duration.zero);
      expect(msg.apnsCalls, 1);
      expect(t, isNull);
    });

    test('getAPNSToken throwing => null, no throw', () async {
      msg.apnsError = StateError('channel error');
      final t = await build(ios: true)
          .getPlatformToken(apnsTimeout: const Duration(milliseconds: 50));
      expect(t, isNull);
    });
  });

  test('existing token getter unchanged', () async {
    expect(await build(ios: true).token, 'tok');
    expect(msg.apnsCalls, 0);
  });
}
