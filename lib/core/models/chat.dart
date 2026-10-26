/// Chat data in the exact shape Open WebUI stores it, so chats created in the
/// app open normally in the web UI and vice versa.
///
/// Open WebUI keeps a message tree (`history.messages`, keyed by id, with
/// `parentId`/`childrenIds`) plus `history.currentId` pointing at the visible
/// branch tip. Regenerations and edits are siblings in that tree.
class ChatMessage {
  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    this.parentId,
    List<String>? childrenIds,
    this.model,
    int? timestamp,
    Map<String, dynamic>? extra,
  })  : childrenIds = childrenIds ?? [],
        timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
        extra = extra ?? {};

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    const known = {
      'id', 'role', 'content', 'parentId', 'childrenIds', 'model', 'timestamp'
    };
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String? ?? 'user',
      content: _contentText(json['content']),
      parentId: json['parentId'] as String?,
      childrenIds:
          (json['childrenIds'] as List?)?.whereType<String>().toList() ?? [],
      model: json['model'] as String?,
      timestamp: (json['timestamp'] as num?)?.toInt(),
      extra: {
        for (final e in json.entries)
          if (!known.contains(e.key)) e.key: e.value,
      },
    );
  }

  final String id;
  final String role;
  String content;
  final String? parentId;
  final List<String> childrenIds;
  final String? model;
  final int timestamp;

  /// Fields we don't model yet (files, sources, usage, statusHistory...).
  /// Preserved verbatim so saving from the app never drops server data.
  final Map<String, dynamic> extra;

  Map<String, dynamic> toJson() => {
        ...extra,
        'id': id,
        'role': role,
        'content': content,
        'parentId': parentId,
        'childrenIds': childrenIds,
        'timestamp': timestamp,
        if (model != null) 'model': model,
      };

  static String _contentText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .where((p) => p['type'] == 'text')
          .map((p) => p['text'])
          .whereType<String>()
          .join('\n');
    }
    return '';
  }
}

class Chat {
  Chat({
    required this.id,
    required this.title,
    required this.messages,
    this.currentId,
    List<String>? models,
    Map<String, dynamic>? extra,
  })  : models = models ?? [],
        extra = extra ?? {};

  /// Builds from a `/api/v1/chats/{id}` response.
  factory Chat.fromServer(Map<String, dynamic> json) {
    final body = (json['chat'] as Map?)?.cast<String, dynamic>() ?? {};
    final history = (body['history'] as Map?)?.cast<String, dynamic>() ?? {};
    final rawMessages =
        (history['messages'] as Map?)?.cast<String, dynamic>() ?? {};
    const known = {'id', 'title', 'models', 'history', 'messages'};
    return Chat(
      id: json['id'] as String,
      title: json['title'] as String? ?? body['title'] as String? ?? 'New Chat',
      messages: {
        for (final e in rawMessages.entries)
          e.key: ChatMessage.fromJson((e.value as Map).cast<String, dynamic>()),
      },
      currentId: history['currentId'] as String?,
      models: (body['models'] as List?)?.whereType<String>().toList(),
      extra: {
        for (final e in body.entries)
          if (!known.contains(e.key)) e.key: e.value,
      },
    );
  }

  final String id;
  String title;
  final Map<String, ChatMessage> messages;
  String? currentId;
  List<String> models;
  final Map<String, dynamic> extra;

  /// The visible conversation: walk from [currentId] up to the root.
  List<ChatMessage> get thread {
    final out = <ChatMessage>[];
    var cursor = currentId;
    final seen = <String>{};
    while (cursor != null && seen.add(cursor)) {
      final m = messages[cursor];
      if (m == null) break;
      out.add(m);
      cursor = m.parentId;
    }
    return out.reversed.toList();
  }

  /// Appends [message] under the current tip and makes it the new tip.
  void append(ChatMessage message) {
    final parent = message.parentId == null ? null : messages[message.parentId];
    parent?.childrenIds.add(message.id);
    messages[message.id] = message;
    currentId = message.id;
  }

  /// The `chat` object Open WebUI expects in create/update calls.
  Map<String, dynamic> toServerBody() => {
        ...extra,
        'id': id,
        'title': title,
        'models': models,
        'history': {
          'messages': {for (final e in messages.entries) e.key: e.value.toJson()},
          'currentId': currentId,
        },
        'messages': [for (final m in thread) m.toJson()],
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
}

class ChatSummary {
  ChatSummary({required this.id, required this.title, required this.updatedAt});

  factory ChatSummary.fromJson(Map<String, dynamic> json) => ChatSummary(
        id: json['id'] as String,
        title: json['title'] as String? ?? 'New Chat',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          ((json['updated_at'] as num?)?.toInt() ?? 0) * 1000,
        ),
      );

  final String id;
  final String title;
  final DateTime updatedAt;
}
