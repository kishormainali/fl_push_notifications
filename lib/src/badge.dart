import 'dart:async';

import 'package:flutter/widgets.dart';

/// App lifecycle changes as a stream. A [WidgetsBindingObserver] is added
/// when the stream is listened to and removed when the subscription is
/// cancelled, so the facade can tie it to its other subscriptions.
Stream<AppLifecycleState> appLifecycleStates() {
  late final _LifecycleObserver observer;
  late final StreamController<AppLifecycleState> ctl;
  ctl = StreamController<AppLifecycleState>(
    onListen: () => WidgetsBinding.instance.addObserver(observer),
    onCancel: () => WidgetsBinding.instance.removeObserver(observer),
  );
  observer = _LifecycleObserver(ctl.add);
  return ctl.stream;
}

class _LifecycleObserver with WidgetsBindingObserver {
  _LifecycleObserver(this._onState);
  final void Function(AppLifecycleState) _onState;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onState(state);
}
