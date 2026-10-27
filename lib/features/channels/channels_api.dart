import 'package:uuid/uuid.dart';

import '../../core/api/openwebui_client.dart';
import '../notes/notes_api.dart' show fromServerTime;

class Channel {
  const Channel({
    required this.id,
    required this.name,
    required this.type,
    this.description,
    this.unread = 0,
    this.lastMessageAt,
    this.members = const [],
  });

  factory Channel.fromJson(Map j) => Channel(
    id: '${j['id']}',
    name: '${j['name'] ?? ''}',
    type: '${j['type'] ?? ''}',
    description: j['description'] as String?,
    unread: (j['unread_count'] as num?)?.toInt() ?? 0,
    lastMessageAt: j['last_message_at'] is num
        ? fromServerTime(j['last_message_at'] as num)
        : null,
    members: [
      for (final u in (j['users'] as List? ?? const []).whereType<Map>())
        '${u['name'] ?? ''}',
    ],
  );

  final String id;
  final String name;

  /// '' or null for a regular channel, 'group' or 'dm'.
  final String type;
  final String? description;
  final int unread;
  final DateTime? lastMessageAt;

  /// Who is in a direct message.
  final List<String> members;

  bool get isDm => type == 'dm';

  /// What to call it: a DM is named by the other people in it.
  String title(String? me) => isDm
      ? (members.where((m) => m != me).join(', ').isEmpty
            ? 'Direct message'
            : members.where((m) => m != me).join(', '))
      : name;
}

class Reaction {
  const Reaction({
    required this.name,
    required this.count,
    required this.userIds,
  });

  factory Reaction.fromJson(Map j) => Reaction(
    name: '${j['name']}',
    count: (j['count'] as num?)?.toInt() ?? 0,
    userIds: [
      for (final u in (j['users'] as List? ?? const []))
        u is Map ? '${u['id']}' : '$u',
    ],
  );

  final String name;
  final int count;
  final List<String> userIds;
}

class ChannelMessage {
  const ChannelMessage({
    required this.id,
    required this.content,
    required this.at,
    this.userId,
    this.userName,
    this.modelName,
    this.parentId,
    this.replyCount = 0,
    this.reactions = const [],
    this.done = true,
    this.edited = false,
    this.tempId,
  });

  factory ChannelMessage.fromJson(Map j) {
    final meta = (j['meta'] as Map?) ?? const {};
    final user = j['user'] as Map?;
    return ChannelMessage(
      id: '${j['id']}',
      content: '${j['content'] ?? ''}',
      at: fromServerTime((j['created_at'] as num?) ?? 0),
      userId: j['user_id'] as String?,
      userName: user?['name'] as String?,
      modelName: meta['model_id'] != null
          ? '${meta['model_name'] ?? meta['model_id']}'
          : null,
      parentId: j['parent_id'] as String?,
      replyCount: (j['reply_count'] as num?)?.toInt() ?? 0,
      reactions: [
        for (final r in (j['reactions'] as List? ?? const []).whereType<Map>())
          Reaction.fromJson(r),
      ],
      // A model's reply is written into the message as it streams.
      done: meta['model_id'] == null || meta['done'] == true,
      edited: j['updated_at'] != null && j['updated_at'] != j['created_at'],
      tempId: j['temp_id'] as String?,
    );
  }

  final String id;
  final String content;
  final DateTime at;
  final String? userId;
  final String? userName;

  /// Set when a model wrote it.
  final String? modelName;
  final String? parentId;
  final int replyCount;
  final List<Reaction> reactions;
  final bool done;
  final bool edited;
  final String? tempId;

  String get author => modelName ?? userName ?? 'Someone';

  ChannelMessage copyWith({
    String? content,
    int? replyCount,
    List<Reaction>? reactions,
    bool? done,
  }) => ChannelMessage(
    id: id,
    content: content ?? this.content,
    at: at,
    userId: userId,
    userName: userName,
    modelName: modelName,
    parentId: parentId,
    replyCount: replyCount ?? this.replyCount,
    reactions: reactions ?? this.reactions,
    done: done ?? this.done,
    edited: edited,
    tempId: tempId,
  );
}

/// `<@M:id|Name>` mentions, as the web UI writes them, shown as `@Name`.
final mentionPattern = RegExp(r'<@([A-Z]):([^|>]+)(?:\|([^>]+))?>');

String showMentions(String text) =>
    text.replaceAllMapped(mentionPattern, (m) => '**@${m[3] ?? m[2]}**');

class ChannelsApi {
  ChannelsApi(this.client);
  final OpenWebUiClient client;

  static const _base = '/api/v1/channels';
  String _c(String id) => '$_base/${Uri.encodeComponent(id)}';

  Future<List<Channel>> list() async {
    final res = await client.send('GET', '$_base/');
    return [
      for (final c in (res as List? ?? const []).whereType<Map>())
        Channel.fromJson(c),
    ];
  }

  Future<Channel> get(String id) async =>
      Channel.fromJson((await client.send('GET', _c(id)) as Map));

  /// Newest first.
  Future<List<ChannelMessage>> messages(String id, {int skip = 0}) async {
    final res = await client.send(
      'GET',
      '${_c(id)}/messages',
      query: {'skip': '$skip', 'limit': '50'},
    );
    return [
      for (final m in (res as List? ?? const []).whereType<Map>())
        ChannelMessage.fromJson(m),
    ];
  }

  /// A thread's replies, newest first.
  Future<List<ChannelMessage>> thread(String id, String messageId) async {
    final res = await client.send(
      'GET',
      '${_c(id)}/messages/${Uri.encodeComponent(messageId)}/thread',
      query: {'skip': '0', 'limit': '100'},
    );
    return [
      for (final m in (res as List? ?? const []).whereType<Map>())
        if ('${m['id']}' != messageId) ChannelMessage.fromJson(m),
    ];
  }

  Future<ChannelMessage> message(String id, String messageId) async =>
      ChannelMessage.fromJson(
        await client.send(
          'GET',
          '${_c(id)}/messages/${Uri.encodeComponent(messageId)}',
        ) as Map,
      );

  Future<ChannelMessage> post(
    String id,
    String content, {
    String? parentId,
  }) async => ChannelMessage.fromJson(
    await client.send(
      'POST',
      '${_c(id)}/messages/post',
      body: {
        'temp_id': const Uuid().v4(),
        'content': content,
        'parent_id': ?parentId,
        'data': <String, dynamic>{},
      },
    ) as Map,
  );

  Future<void> edit(String id, String messageId, String content) => client.send(
    'POST',
    '${_c(id)}/messages/${Uri.encodeComponent(messageId)}/update',
    body: {'content': content},
  );

  Future<void> delete(String id, String messageId) => client.send(
    'DELETE',
    '${_c(id)}/messages/${Uri.encodeComponent(messageId)}/delete',
  );

  Future<void> react(String id, String messageId, String name, bool add) =>
      client.send(
        'POST',
        '${_c(id)}/messages/${Uri.encodeComponent(messageId)}/reactions/'
            '${add ? 'add' : 'remove'}',
        body: {'name': name},
      );
}
