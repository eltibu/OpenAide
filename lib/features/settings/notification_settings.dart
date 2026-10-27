/// Settings > Notifications, as on the web: a notification when a reply
/// finishes (on the phone, while the app is in the background), its sound,
/// and the webhooks the server calls for chats, channels and calendar
/// alerts (when the admin allows them).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart';
import '../chat/reply_notify.dart';
import 'settings_screen.dart';

/// The person's webhooks, or null when the server doesn't offer them.
final webhooksProvider = FutureProvider.autoDispose<List<Map>?>((ref) async {
  try {
    final res = await ref
        .watch(clientProvider)
        .send('GET', '/api/v1/notifications/targets');
    final list = res is Map ? res['targets'] : res;
    return [
      for (final t in list as List? ?? const [])
        if (t is Map) t,
    ];
  } on ApiException catch (e) {
    if (e.statusCode == 404 || e.statusCode == 403) return null;
    rethrow;
  }
});

/// What can trigger a webhook: name to label.
final webhookEventsProvider =
    FutureProvider.autoDispose<List<(String, String)>>((ref) async {
      final res = await ref
          .watch(clientProvider)
          .send('GET', '/api/v1/notifications/events');
      return [
        for (final e in (res as Map)['events'] as List? ?? const [])
          if (e is Map)
            ('${e['name'] ?? e['event']}', '${e['label'] ?? e['name']}'),
      ];
    });

void _say(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

class NotificationSettings extends ConsumerWidget {
  const NotificationSettings({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ui = ref.watch(uiSettingsProvider);
    final hooks = ref.watch(webhooksProvider);
    final muted = context.nexus.muted;
    final heading = Theme.of(context).textTheme.titleSmall;
    Future<void> set(Map<String, dynamic> fields) async {
      try {
        await ref.read(settingsApiProvider).patchUi(fields);
      } catch (e) {
        if (context.mounted) _say(context, '$e');
      }
      ref.invalidate(uiSettingsProvider);
      ref.invalidate(userSettingsProvider);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: ui.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Couldn\'t load your settings.\n$e'),
        ),
        data: (ui) => ListView(
          children: [
            SwitchListTile(
              title: const Text('Notify when a reply is ready'),
              subtitle: const Text(
                'When the app is in the background; tap it to open the chat',
              ),
              value: ui['notificationEnabled'] == true,
              onChanged: (on) async {
                if (on && !await askForNotifications()) {
                  if (context.mounted) {
                    _say(
                      context,
                      'Allow notifications for Nexus in Android settings',
                    );
                  }
                  return;
                }
                await set({'notificationEnabled': on});
              },
            ),
            SwitchListTile(
              title: const Text('Sound'),
              subtitle: const Text('Play a sound with the notification'),
              value: ui['notificationSound'] != false,
              onChanged: ui['notificationEnabled'] == true
                  ? (on) => set({'notificationSound': on})
                  : null,
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Row(
                children: [
                  Expanded(child: Text('Webhooks', style: heading)),
                  if (hooks.value != null)
                    TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add'),
                      onPressed: () => _edit(context, ref, null),
                    ),
                ],
              ),
            ),
            hooks.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => ListTile(title: Text('$e')),
              data: (list) => list == null
                  ? ListTile(
                      title: Text(
                        'Your server\'s admin hasn\'t turned on webhooks.',
                        style: TextStyle(color: muted),
                      ),
                    )
                  : list.isEmpty
                  ? ListTile(
                      title: Text(
                        'No webhooks. Add one to hear about finished chats, '
                        'channel messages or calendar alerts elsewhere.',
                        style: TextStyle(color: muted),
                      ),
                    )
                  : Column(
                      children: [for (final t in list) _Webhook(target: t)],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Webhook extends ConsumerWidget {
  const _Webhook({required this.target});
  final Map target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.watch(clientProvider);
    final id = '${target['id']}';
    final url = '${(target['config'] as Map?)?['url_masked'] ?? ''}';
    final events = (target['events'] as List? ?? const []).length;
    final away = target['delivery'] != 'always';
    Future<void> run(Future<void> Function() f, [String? done]) async {
      try {
        await f();
        if (done != null && context.mounted) _say(context, done);
      } catch (e) {
        if (context.mounted) _say(context, '$e');
      }
      ref.invalidate(webhooksProvider);
    }

    return ListTile(
      leading: Icon(
        target['is_default'] == true ? Icons.star : Icons.webhook_outlined,
      ),
      title: Text(url.isEmpty ? id : url, maxLines: 1),
      subtitle: Text(
        '$events event${events == 1 ? '' : 's'} · '
        '${away ? 'Only when away' : 'Always'}',
      ),
      onTap: () => _edit(context, ref, target),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: target['enabled'] != false,
            onChanged: (on) => run(
              () => client.send(
                'PUT',
                '/api/v1/notifications/targets/$id',
                body: {'enabled': on},
              ),
            ),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'test' => run(
                () => client.send(
                  'POST',
                  '/api/v1/notifications/targets/$id/test',
                ),
                'Test sent',
              ),
              'default' => run(
                () => client.send(
                  'PUT',
                  '/api/v1/notifications/targets/$id/default',
                ),
              ),
              _ => run(
                () =>
                    client.send('DELETE', '/api/v1/notifications/targets/$id'),
                'Webhook removed',
              ),
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'test', child: Text('Send test')),
              if (target['is_default'] != true)
                const PopupMenuItem(
                  value: 'default',
                  child: Text('Make default'),
                ),
              const PopupMenuItem(value: 'delete', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Adds a webhook ([target] null) or changes one.
Future<void> _edit(BuildContext context, WidgetRef ref, Map? target) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _WebhookSheet(target: target),
  );
  if (saved == true) ref.invalidate(webhooksProvider);
}

class _WebhookSheet extends ConsumerStatefulWidget {
  const _WebhookSheet({this.target});
  final Map? target;

  @override
  ConsumerState<_WebhookSheet> createState() => _WebhookSheetState();
}

class _WebhookSheetState extends ConsumerState<_WebhookSheet> {
  late final _url = TextEditingController(
    text: '${(widget.target?['config'] as Map?)?['url_masked'] ?? ''}',
  );
  late final Set<String> _events = {
    for (final e in widget.target?['events'] as List? ?? const []) '$e',
  };
  late bool _always = widget.target?['delivery'] == 'always';
  bool _saving = false;
  String? _problem;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    if (url.isEmpty) {
      setState(() => _problem = 'Enter the webhook address');
      return;
    }
    setState(() {
      _saving = true;
      _problem = null;
    });
    final body = {
      'type': 'webhook',
      'events': _events.toList(),
      'delivery': _always ? 'always' : 'away',
      // A masked address left as it was keeps the saved one.
      'config': {'url': url},
    };
    try {
      final client = ref.read(clientProvider);
      final id = widget.target?['id'];
      if (id == null) {
        await client.send(
          'POST',
          '/api/v1/notifications/targets',
          body: {...body, 'enabled': true},
        );
      } else {
        await client.send(
          'PUT',
          '/api/v1/notifications/targets/$id',
          body: body,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _problem = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final events = ref.watch(webhookEventsProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.target == null ? 'Add webhook' : 'Edit webhook',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Webhook address',
                hintText: 'https://…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text('Send for', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            events.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('$e'),
              data: (list) => Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final (name, label) in list)
                    FilterChip(
                      label: Text(label),
                      selected: _events.contains(name),
                      onSelected: (on) => setState(
                        () => on ? _events.add(name) : _events.remove(name),
                      ),
                    ),
                ],
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Even while I\'m using it'),
              subtitle: const Text('Off: only when you\'re away'),
              value: _always,
              onChanged: (on) => setState(() => _always = on),
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _problem!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _saving ? null : _save,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
