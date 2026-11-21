import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fl_push_notifications/src/badge.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test('emits lifecycle changes while listened to', () async {
    final seen = <AppLifecycleState>[];
    final sub = appLifecycleStates().listen(seen.add);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(
      seen,
      containsAllInOrder([
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]),
    );
  });

  test('stops emitting after the subscription is cancelled', () async {
    final seen = <AppLifecycleState>[];
    final sub = appLifecycleStates().listen(seen.add);
    await sub.cancel();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Future<void>.delayed(Duration.zero);
    expect(seen, isEmpty);
  });

  test('each listen adds exactly one observer (no duplicate events)', () async {
    final seen = <AppLifecycleState>[];
    final sub = appLifecycleStates().listen(seen.add);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    expect(seen.where((s) => s == AppLifecycleState.hidden), hasLength(1));
  });
}
