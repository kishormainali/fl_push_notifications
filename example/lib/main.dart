import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:push_notifications/push_notifications.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Taps seen so far, newest first (shown by the "recent taps" button).
final ValueNotifier<List<PushMessage>> recentTaps = ValueNotifier(const []);

/// Optional app hook for background messages. It runs in a background isolate
/// (no UI, no app state), so it must be a top-level function.
@pragma('vm:entry-point')
Future<void> onBackgroundMessage(RemoteMessage message) async {
  debugPrint('background message: ${message.messageId}');
}

/// Decides which screen a tap opens, based on `data['type']`.
///
/// Returns promptly: taps are delivered one at a time, so the navigation is
/// started but not awaited (a pushed route's future completes only when the
/// route is popped).
void decisionMaker(PushMessage m) {
  recentTaps.value = [m, ...recentTaps.value].take(20).toList();
  final nav = navigatorKey.currentState;
  if (nav == null) return;
  final route = m.data['type'] == 'chat' ? '/chat' : '/detail';
  nav.pushNamed(route, arguments: m);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The example ships without google-services.json / GoogleService-Info.plist,
  // so Firebase setup fails here until you add your own. The UI still renders.
  String? startupError;
  try {
    await Firebase.initializeApp();
    await PushNotifications.instance.init(
      decisionMaker: decisionMaker,
      channels: [
        PushChannel(
          id: 'default',
          name: 'General',
          importance: Importance.high,
        ),
        PushChannel(id: 'chat', name: 'Messages', importance: Importance.max),
      ],
      defaultChannelId: 'default',
      onBackgroundMessage: onBackgroundMessage,
    );
  } catch (e) {
    startupError = e.toString();
  }

  runApp(ExampleApp(startupError: startupError));

  // The navigator exists after the first frame: release any queued cold-start
  // taps.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    PushNotifications.instance.markReady();
  });
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, this.startupError});

  final String? startupError;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'push_notifications example',
      home: HomePage(startupError: startupError),
      onGenerateRoute: (settings) {
        final m = settings.arguments as PushMessage?;
        if (m == null) return null;
        return MaterialPageRoute<void>(
          settings: settings,
          builder: (_) => settings.name == '/chat'
              ? ChatPage(message: m)
              : DetailPage(message: m),
        );
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.startupError});

  final String? startupError;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = '';
  int _badge = 3;
  final List<StreamSubscription<String>> _fidSubs = [];

  @override
  void initState() {
    super.initState();
    final push = PushNotifications.instance;
    // Rebuild to show the latest installationId when it changes.
    _fidSubs.addAll([
      push.onRegistered.listen((_) => setState(() {})),
      push.onUnregistered.listen((_) => setState(() {})),
    ]);
  }

  @override
  void dispose() {
    for (final s in _fidSubs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _run(String label, Future<Object?> Function() action) async {
    try {
      final result = await action();
      setState(() => _status = '$label: ${result ?? 'ok'}');
    } catch (e) {
      setState(() => _status = '$label failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final push = PushNotifications.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('push_notifications')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.startupError != null)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Startup error: ${widget.startupError}'),
              ),
            ),
          FilledButton(
            onPressed: () => _run('permission', () async {
              return (await push.requestPermission()).name;
            }),
            child: const Text('Request permission'),
          ),
          FilledButton(
            onPressed: () => _run('token', () => push.token),
            child: const Text('Show token'),
          ),
          FilledButton(
            onPressed: () => _run('platform token', () async {
              final t = await push.getPlatformToken();
              return t == null ? 'null' : 'present (${t.length} chars)';
            }),
            child: const Text('Platform token'),
          ),
          Text('FID: ${push.installationId ?? 'none yet'}'),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => _run('register', push.register),
                  child: const Text('Register'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => _run('unregister', push.unregister),
                  child: const Text('Unregister'),
                ),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                onPressed: () =>
                    setState(() => _badge = _badge > 0 ? _badge - 1 : 0),
                icon: const Icon(Icons.remove),
              ),
              Text('$_badge'),
              IconButton(
                onPressed: () => setState(() => _badge++),
                icon: const Icon(Icons.add),
              ),
              Expanded(
                child: FilledButton(
                  onPressed: () => _run('set badge', () async {
                    await push.setBadgeCount(_badge);
                    return _badge;
                  }),
                  child: Text('Set badge $_badge'),
                ),
              ),
            ],
          ),
          FilledButton(
            onPressed: () => _run('clear badge', push.clearBadge),
            child: const Text('Clear badge'),
          ),
          FilledButton(
            onPressed: () =>
                _run('subscribe', () => push.subscribeToTopic('news')),
            child: const Text('Subscribe to topic "news"'),
          ),
          FilledButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => const RecentTaps(),
            ),
            child: const Text('Recent taps'),
          ),
          const SizedBox(height: 16),
          SelectableText(_status),
        ],
      ),
    );
  }
}

class RecentTaps extends StatelessWidget {
  const RecentTaps({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<PushMessage>>(
      valueListenable: recentTaps,
      builder: (context, taps, _) {
        if (taps.isEmpty) {
          return const Center(child: Text('No taps yet'));
        }
        return ListView(
          children: [
            for (final m in taps)
              ListTile(
                title: Text(m.title ?? '(no title)'),
                subtitle: Text(
                  '${m.appState.name} / ${m.source.name} / ${m.id}',
                ),
              ),
          ],
        );
      },
    );
  }
}

class DetailPage extends StatelessWidget {
  const DetailPage({super.key, required this.message});

  final PushMessage message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notification')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('title: ${message.title}'),
          Text('body: ${message.body}'),
          Text('data: ${message.data}'),
          Text('state: ${message.appState.name}'),
          Text('source: ${message.source.name}'),
          Text('channel: ${message.channelId}'),
        ],
      ),
    );
  }
}

class ChatPage extends StatelessWidget {
  const ChatPage({super.key, required this.message});

  final PushMessage message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Chat ${message.data['chat_id'] ?? ''}')),
      body: Center(child: Text(message.body ?? '')),
    );
  }
}
