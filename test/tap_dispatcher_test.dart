import 'dart:async';

import 'package:flutter/foundation.dart';
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

  test('a dropped duplicate tap is logged', () async {
    final logs = <String>[];
    final original = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => logs.add(m ?? '');
    addTearDown(() => debugPrint = original);
    final d = TapDispatcher(decisionMaker: (_) {});
    await d.markReady();
    await d.handleTap(msg('a'));
    expect(logs, isEmpty);
    await d.handleTap(msg('a'));
    expect(logs.single, contains('duplicate tap a dropped'));
  });

  test('dedupeCapacity must be positive', () {
    expect(() => TapDispatcher(dedupeCapacity: 0), throwsAssertionError);
  });

  group('single-flight flush', () {
    test(
      'async decision maker never runs for two taps concurrently, in order',
      () async {
        final events = <String>[];
        final gates = <String, Completer<void>>{};
        var active = 0;
        var maxActive = 0;
        final d = TapDispatcher(
          decisionMaker: (m) async {
            active++;
            if (active > maxActive) maxActive = active;
            events.add('start ${m.id}');
            gates[m.id] = Completer<void>();
            await gates[m.id]!.future;
            events.add('end ${m.id}');
            active--;
          },
        );
        await d.markReady();
        final f1 = d.handleTap(msg('a'));
        final f2 = d.handleTap(msg('b'));
        await pumpEventQueue();
        expect(events, ['start a']);
        gates['a']!.complete();
        await pumpEventQueue();
        expect(events, ['start a', 'end a', 'start b']);
        gates['b']!.complete();
        await Future.wait([f1, f2]);
        await pumpEventQueue();
        expect(events, ['start a', 'end a', 'start b', 'end b']);
        expect(maxActive, 1);
      },
    );

    test('a throwing decision maker does not block the next tap', () async {
      final seen = <String>[];
      final d = TapDispatcher(
        decisionMaker: (m) {
          seen.add(m.id);
          if (m.id == 'a') throw StateError('boom');
        },
      );
      await d.markReady();
      await d.handleTap(msg('a'));
      await d.handleTap(msg('b'));
      expect(seen, ['a', 'b']);
    });

    test(
      'taps queued while flushing are delivered once by the running loop',
      () async {
        final seen = <String>[];
        final gate = Completer<void>();
        final d = TapDispatcher(
          decisionMaker: (m) async {
            seen.add(m.id);
            if (m.id == 'a') await gate.future;
          },
        );
        await d.markReady();
        final f1 = d.handleTap(msg('a'));
        await d.handleTap(msg('b'));
        await d.handleTap(msg('c'));
        await pumpEventQueue();
        expect(seen, ['a']);
        gate.complete();
        await f1;
        await pumpEventQueue();
        expect(seen, ['a', 'b', 'c']);
      },
    );

    test('markReady after taps queued before ready delivers in order and '
        'awaits completion', () async {
      final seen = <String>[];
      final d = TapDispatcher(
        decisionMaker: (m) async {
          await Future<void>.delayed(Duration.zero);
          seen.add(m.id);
        },
      );
      await d.handleTap(msg('a'));
      await d.handleTap(msg('b'));
      await d.markReady();
      expect(seen, ['a', 'b']);
    });

    test(
      'markReady during a running flush waits for the queue to drain',
      () async {
        final seen = <String>[];
        final gate = Completer<void>();
        final d = TapDispatcher(
          decisionMaker: (m) async {
            if (m.id == 'a') await gate.future;
            seen.add(m.id);
          },
        );
        await d.markReady();
        unawaited(d.handleTap(msg('a')));
        await d.handleTap(msg('b'));
        var done = false;
        final f = d.markReady().then((_) => done = true);
        await pumpEventQueue();
        expect(done, isFalse);
        gate.complete();
        await f;
        expect(seen, ['a', 'b']);
      },
    );

    test('a tap added while the last queued tap is pending is delivered once, '
        'in order', () async {
      final seen = <String>[];
      final gate = Completer<void>();
      final d = TapDispatcher(
        decisionMaker: (m) async {
          seen.add(m.id);
          if (m.id == 'b') await gate.future;
        },
      );
      await d.markReady();
      final f = d.handleTap(msg('a'));
      await d.handleTap(msg('b'));
      await pumpEventQueue();
      expect(seen, ['a', 'b']);
      await d.handleTap(msg('c'));
      gate.complete();
      await f;
      await pumpEventQueue();
      expect(seen, ['a', 'b', 'c']);
    });

    test(
      'no decision maker leaves the dispatcher usable once one is set',
      () async {
        final seen = <String>[];
        final d = TapDispatcher();
        await d.markReady();
        await d.handleTap(msg('a'));
        d.decisionMaker = (m) => seen.add(m.id);
        await d.handleTap(msg('b'));
        expect(seen, ['a', 'b']);
      },
    );
  });
}
