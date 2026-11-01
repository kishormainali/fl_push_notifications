import 'package:flutter_test/flutter_test.dart';
import 'package:push_notifications/src/push_message.dart';
import 'package:push_notifications/src/tap_dispatcher.dart';

PushMessage msg(String id) => PushMessage(
  id: id,
  data: const {},
  channelId: 'default',
  source: MessageSource.remote,
  appState: PushAppState.background,
);

void main() {
  test('queues taps before markReady and flushes in order', () async {
    final seen = <String>[];
    final d = TapDispatcher(decisionMaker: (m) => seen.add(m.id));
    await d.handleTap(msg('a'));
    await d.handleTap(msg('b'));
    expect(seen, isEmpty);
    await d.markReady();
    expect(seen, ['a', 'b']);
  });

  test('delivers immediately after markReady', () async {
    final seen = <String>[];
    final d = TapDispatcher(decisionMaker: (m) => seen.add(m.id));
    await d.markReady();
    await d.handleTap(msg('a'));
    expect(seen, ['a']);
  });

  test('drops a second tap with an already-delivered id', () async {
    final seen = <String>[];
    final d = TapDispatcher(decisionMaker: (m) => seen.add(m.id));
    await d.markReady();
    await d.handleTap(msg('a'));
    await d.handleTap(msg('a'));
    expect(seen, ['a']);
  });

  test('drops a duplicate enqueued before ready once', () async {
    final seen = <String>[];
    final d = TapDispatcher(decisionMaker: (m) => seen.add(m.id));
    await d.handleTap(msg('a'));
    await d.handleTap(msg('a'));
    await d.markReady();
    expect(seen, ['a']);
  });

  test(
    'keeps queued and does not throw when no decisionMaker is set',
    () async {
      final seen = <String>[];
      final d = TapDispatcher();
      await d.markReady();
      await d.handleTap(msg('a'));
      expect(seen, isEmpty);
      d.decisionMaker = (m) => seen.add(m.id);
      await d.markReady();
      expect(seen, ['a']);
    },
  );

  test('decisionMaker exception does not block the next tap', () async {
    final seen = <String>[];
    final d = TapDispatcher(
      decisionMaker: (m) {
        if (m.id == 'a') throw StateError('boom');
        seen.add(m.id);
      },
    );
    await d.markReady();
    await d.handleTap(msg('a'));
    await d.handleTap(msg('b'));
    expect(seen, ['b']);
  });

  test('onTap stream emits delivered messages', () async {
    final d = TapDispatcher(decisionMaker: (_) {});
    final future = d.onTap.first;
    await d.markReady();
    await d.handleTap(msg('a'));
    expect((await future).id, 'a');
  });

  test('LRU evicts oldest id beyond capacity', () async {
    final seen = <String>[];
    final d = TapDispatcher(
      decisionMaker: (m) => seen.add(m.id),
      dedupeCapacity: 2,
    );
    await d.markReady();
    await d.handleTap(msg('a'));
    await d.handleTap(msg('b'));
    await d.handleTap(msg('c')); // evicts a
    await d.handleTap(msg('a')); // delivered again
    await d.handleTap(msg('c')); // still known
    expect(seen, ['a', 'b', 'c', 'a']);
  });
}
