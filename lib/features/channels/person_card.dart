/// Someone in a channel, as the web's card on a person's name: their status,
/// bio, groups, when they were last seen, and Message to talk one to one.
library;

import 'package:flutter/material.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/theme.dart';
import '../notes/notes_api.dart' show fromServerTime;

class PersonInfo {
  const PersonInfo({
    required this.id,
    required this.name,
    this.active = false,
    this.statusEmoji,
    this.statusMessage,
    this.bio,
    this.lastSeen,
    this.timezone,
    this.groups = const [],
  });

  factory PersonInfo.fromJson(Map j) {
    String? text(Object? v) =>
        v is String && v.trim().isNotEmpty ? v.trim() : null;
    return PersonInfo(
      id: '${j['id']}',
      name: '${j['name'] ?? ''}',
      active: j['is_active'] == true,
      statusEmoji: text(j['status_emoji']),
      statusMessage: text(j['status_message']),
      bio: text(j['bio']),
      lastSeen: j['last_active_at'] is num
          ? fromServerTime(j['last_active_at'] as num)
          : null,
      timezone: text(j['timezone']),
      groups: [
        for (final g in (j['groups'] as List? ?? const []).whereType<Map>())
          if (g['name'] != null) '${g['name']}',
      ],
    );
  }

  final String id;
  final String name;
  final bool active;
  final String? statusEmoji;
  final String? statusMessage;
  final String? bio;
  final DateTime? lastSeen;
  final String? timezone;
  final List<String> groups;
}

Future<PersonInfo> personInfo(OpenWebUiClient client, String userId) async =>
    PersonInfo.fromJson(
      await client.send(
        'GET',
        '/api/v1/users/${Uri.encodeComponent(userId)}/info',
      ) as Map,
    );

/// "5 minutes ago", as the web's last seen.
String sinceLabel(DateTime at, [DateTime? now]) {
  final d = (now ?? DateTime.now()).difference(at);
  String n(int v, String unit) => '$v $unit${v == 1 ? '' : 's'} ago';
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return n(d.inMinutes, 'minute');
  if (d.inDays < 1) return n(d.inHours, 'hour');
  if (d.inDays < 30) return n(d.inDays, 'day');
  if (d.inDays < 365) return n(d.inDays ~/ 30, 'month');
  return n(d.inDays ~/ 365, 'year');
}

/// Shows [name]'s card; [onMessage] (left out for yourself) opens a direct
/// message with them.
Future<void> showPersonCard(
  BuildContext context,
  OpenWebUiClient client, {
  required String userId,
  required String name,
  VoidCallback? onMessage,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  builder: (sheet) => SafeArea(
    child: FutureBuilder<PersonInfo>(
      future: personInfo(client, userId),
      builder: (context, snap) {
        final p = snap.data;
        final muted = context.nexus.muted;
        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    child: Text(
                      name.isEmpty ? '?' : name.characters.first.toUpperCase(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p?.name ?? name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        if (p != null)
                          Row(
                            children: [
                              Icon(
                                Icons.circle,
                                size: 9,
                                color: p.active ? Colors.green : muted,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                p.active ? 'Active' : 'Away',
                                style: TextStyle(color: muted, fontSize: 12),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
              if (snap.connectionState != ConnectionState.done)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (p != null) ...[
                if (p.statusEmoji != null || p.statusMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text([?p.statusEmoji, ?p.statusMessage].join(' ')),
                  ),
                if (p.bio != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(p.bio!, style: TextStyle(color: muted)),
                  ),
                if (p.groups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final g in p.groups)
                          Chip(
                            label: Text(g),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ),
                if (p.lastSeen != null && !p.active)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.history, size: 18),
                    title: Text('Last seen ${sinceLabel(p.lastSeen!)}'),
                  ),
                if (p.timezone != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: const Icon(Icons.public, size: 18),
                    title: Text(p.timezone!),
                  ),
              ],
              if (snap.hasError)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    "Couldn't load their details.",
                    style: TextStyle(color: muted),
                  ),
                ),
              if (onMessage != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.chat_bubble_outline),
                    label: const Text('Message'),
                    onPressed: () {
                      Navigator.pop(sheet);
                      onMessage();
                    },
                  ),
                ),
              ],
            ],
          ),
        );
      },
    ),
  ),
);
