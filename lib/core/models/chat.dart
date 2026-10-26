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
    this.structuredContent,
  }) : _loadedText = content,
       childrenIds = childrenIds ?? [],
       timestamp = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
       extra = extra ?? {};

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    const known = {
      'id',
      'role',
      'content',
      'parentId',
      'childrenIds',
      'model',
      'timestamp',
    };
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String? ?? 'user',
      content: _contentText(json['content']).isNotEmpty
          ? _contentText(json['content'])
          : outputText(json['output']),
      parentId: json['parentId'] as String?,
      childrenIds:
          (json['childrenIds'] as List?)?.whereType<String>().toList() ?? [],
      model: json['model'] as String?,
      timestamp: (json['timestamp'] as num?)?.toInt(),
      structuredContent: json['content'] is String ? null : json['content'],
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

  /// The server's `content` when it isn't plain text (images, other parts).
  /// Written back as it was, so saving never drops those parts.
  final Object? structuredContent;
  final String _loadedText;

  /// Fields we don't model yet (files, sources, usage, statusHistory...).
  /// Preserved verbatim so saving from the app never drops server data.
  final Map<String, dynamic> extra;

  /// True once the server has finished writing this reply.
  bool get done => extra['done'] == true;

  /// The server's error for this reply, if it failed.
  String? get error {
    final e = extra['error'];
    if (e is Map) return '${e['content'] ?? e['message'] ?? e}';
    return e?.toString();
  }

  /// Tools the model called for this reply, with what each returned.
  List<ToolCall> get toolCalls {
    final output = extra['output'];
    if (output is! List) return const [];
    final results = <String, String>{
      for (final item in output.whereType<Map>())
        if (item['type'] == 'function_call_output')
          '${item['call_id']}': [
            for (final p
                in (item['output'] is List
                    ? item['output'] as List
                    : [item['output']]))
              if (p is Map && p['text'] is String)
                p['text'] as String
              else if (p is String)
                p,
          ].join('\n'),
    };
    return [
      for (final item in output.whereType<Map>())
        if (item['type'] == 'function_call')
          ToolCall(
            name: '${item['name']}',
            arguments: '${item['arguments'] ?? ''}',
            result: results['${item['call_id']}'],
          ),
    ];
  }

  /// Web pages, files and knowledge the reply drew on.
  List<Source> get sources {
    final raw = extra['sources'];
    if (raw is! List) return const [];
    final out = <Source>[];
    final seen = <String>{};
    for (final s in raw.whereType<Map>()) {
      final src = (s['source'] as Map?) ?? const {};
      final metas = (s['metadata'] as List?)?.whereType<Map>() ?? const [];
      final entries = metas.isEmpty ? [src] : metas;
      for (final m in entries) {
        final url = '${m['source'] ?? src['url'] ?? ''}';
        final name = '${m['name'] ?? m['title'] ?? src['name'] ?? url}';
        if (name.isEmpty || !seen.add('$name|$url')) continue;
        out.add(Source(name: name, url: url.startsWith('http') ? url : null));
      }
    }
    return out;
  }

  /// Text from an Open WebUI `output` list (Responses-style items), which
  /// newer servers fill alongside or instead of `content`.
  static String outputText(Object? output) {
    if (output is! List) return '';
    return [
      for (final item in output.whereType<Map>())
        if (item['type'] == 'message')
          for (final part in (item['content'] as List? ?? []).whereType<Map>())
            if (part['text'] is String) part['text'] as String,
    ].join('\n');
  }

  Map<String, dynamic> toJson() => {
    ...extra,
    'id': id,
    'role': role,
    'content': structuredContent != null && content == _loadedText
        ? structuredContent
        : content,
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
  }) : models = models ?? [],
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

  /// Empty until the server has created the chat.
  String id;
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

  /// Ids of [message] and its alternatives (edits, regenerations), oldest
  /// first.
  List<String> siblingsOf(ChatMessage message) {
    final parent = messages[message.parentId];
    if (parent != null) return parent.childrenIds;
    return [
      for (final m in messages.values)
        if (m.parentId == null) m.id,
    ]..sort((a, b) => messages[a]!.timestamp.compareTo(messages[b]!.timestamp));
  }

  /// The tip reached from [id] by always taking the newest child, which is
  /// what the web UI shows after switching to a branch.
  String latestUnder(String id) {
    var cursor = id;
    final seen = <String>{};
    while (seen.add(cursor)) {
      final children = messages[cursor]?.childrenIds ?? const [];
      if (children.isEmpty) break;
      cursor = children.last;
    }
    return cursor;
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

class ToolCall {
  const ToolCall({required this.name, required this.arguments, this.result});
  final String name;
  final String arguments;
  final String? result;
}

class Source {
  const Source({required this.name, this.url});
  final String name;
  final String? url;
}
