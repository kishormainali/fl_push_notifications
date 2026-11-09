import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'push_message.dart';

/// Delivers notification taps to the app's [DecisionMaker], queueing until the
/// app is ready and de-duplicating by message id.
class TapDispatcher {
  TapDispatcher({this._decisionMaker, this.dedupeCapacity = 50})
    : assert(dedupeCapacity > 0, 'dedupeCapacity must be positive');

  final int dedupeCapacity;
  DecisionMaker? _decisionMaker;
  final List<PushMessage> _queue = [];
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  final StreamController<PushMessage> _controller =
      StreamController<PushMessage>.broadcast();
  bool _ready = false;
  bool _flushing = false;
  Future<void>? _flushDone;

  set decisionMaker(DecisionMaker? value) => _decisionMaker = value;

  Stream<PushMessage> get onTap => _controller.stream;

  Future<void> handleTap(PushMessage m) async {
    if (_seen.contains(m.id)) {
      debugPrint('push_notifications: duplicate tap ${m.id} dropped');
      // Refresh recency for LRU.
      _seen
        ..remove(m.id)
        ..add(m.id);
      return;
    }
    _seen.add(m.id);
    while (_seen.length > dedupeCapacity) {
      _seen.remove(_seen.first);
    }
    _queue.add(m);
    if (_ready) await _flush();
  }

  Future<void> markReady() async {
    _ready = true;
    // If a flush is already running, wait for it: its loop re-checks the queue
    // so it also delivers every tap queued before this call.
    final running = _flushDone;
    if (running != null) {
      await running;
      return;
    }
    await _flush();
  }

  Future<void> _flush() async {
    if (_decisionMaker == null) {
      if (_queue.isNotEmpty) {
        debugPrint(
          'push_notifications: ERROR tap received but no '
          'decisionMaker is set; ${_queue.length} tap(s) remain queued.',
        );
      }
      return;
    }
    // Single-flight: a running loop picks up newly queued taps itself.
    if (_flushing) return;
    _flushing = true;
    final done = Completer<void>();
    _flushDone = done.future;
    try {
      while (_queue.isNotEmpty && _decisionMaker != null) {
        final m = _queue.removeAt(0);
        _controller.add(m);
        try {
          await _decisionMaker!(m);
        } catch (e, st) {
          debugPrint('push_notifications: decisionMaker threw: $e\n$st');
        }
      }
    } finally {
      _flushing = false;
      _flushDone = null;
      done.complete();
    }
  }
}
