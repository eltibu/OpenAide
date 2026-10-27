import 'dart:convert';

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
  String? parentId;
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

  /// Interactive results a tool showed in the reply (a video player, a
  /// chart...): HTML to show, or an address to open, as the web's embeds.
  List<String> get embeds {
    final out = <String>[];
    void add(Object? list) {
      if (list is! List) return;
      for (final e in list) {
        if (e is String && e.trim().isNotEmpty && !out.contains(e)) out.add(e);
      }
    }

    add(extra['embeds']);
    final output = extra['output'];
    if (output is List) {
      for (final item in output.whereType<Map>()) {
        add(item['embeds']);
      }
    }
    return out;
  }

  /// Photos and files sent with this message, and those its tools showed:
  /// pictures a tool returned, and files Nexus displayed from its terminal
  /// (`display_file`).
  List<Attachment> get attachments {
    final out = <Attachment>[];
    final seen = <String>{};
    void add(Map f) {
      final a = Attachment.fromJson(f.cast<String, dynamic>());
      final key = a.url ?? a.id ?? '';
      if (key.isNotEmpty && !seen.add(key)) return;
      out.add(a);
    }

    for (final f in (extra['files'] as List? ?? const []).whereType<Map>()) {
      add(f);
    }
    final output = extra['output'];
    if (output is List) {
      final calls = <String, String>{
        for (final item in output.whereType<Map>())
          if (item['type'] == 'function_call')
            '${item['call_id']}': '${item['name']}',
      };
      for (final item in output.whereType<Map>()) {
        if (item['type'] != 'function_call_output') continue;
        for (final f in (item['files'] as List? ?? const []).whereType<Map>()) {
          if (f['source'] == 'open_terminal') {
            final shown = terminalFile(f);
            if (shown != null) add(shown);
          } else if (f['url'] != null || f['id'] != null) {
            add(f);
          }
        }
        if (calls['${item['call_id']}'] != 'display_file') continue;
        for (final p
            in (item['output'] is List
                ? item['output'] as List
                : [item['output']])) {
          final text = p is Map ? p['text'] : p;
          if (text is! String || !text.trimLeft().startsWith('{')) continue;
          try {
            final j = jsonDecode(text);
            final shown = j is Map ? terminalFile(j) : null;
            if (shown != null) add(shown);
          } on FormatException {
            // Not the file's details.
          }
        }
      }
    }
    return out;
  }

  /// A file Nexus displayed from its terminal, as an attachment fetched
  /// through the server (`/api/v1/terminals/<id>/files/view`).
  static Map<String, dynamic>? terminalFile(Map f) {
    if (f['type'] != 'file' ||
        f['source'] != 'open_terminal' ||
        f['exists'] == false) {
      return null;
    }
    final terminal = f['terminal_id'] ?? f['terminal_selector'];
    final path = f['full_path'] ?? f['path'];
    if (terminal is! String ||
        terminal.isEmpty ||
        terminal.startsWith('http') ||
        path is! String ||
        path.isEmpty) {
      return null;
    }
    final type = '${f['content_type'] ?? f['mime_type'] ?? ''}';
    return {
      'type': type.startsWith('image/') && !type.contains('svg')
          ? 'image'
          : 'file',
      'name': '${f['name'] ?? path.split('/').last}',
      'url':
          '/api/v1/terminals/${Uri.encodeComponent(terminal)}/files/view'
          '?path=${Uri.encodeQueryComponent(path)}',
      if (type.isNotEmpty) 'content_type': type,
    };
  }

  /// Web pages, files and knowledge the reply drew on.
  List<Source> get sources {
    final raw = extra['sources'];
    if (raw is! List) return const [];
    final out = <Source>[];
    final seen = <String>{};
    final byKey = <String, Source>{};
    for (final s in raw.whereType<Map>()) {
      final src = (s['source'] as Map?) ?? const {};
      final metas = (s['metadata'] as List?)?.toList() ?? const [];
      final docs = (s['document'] as List?)?.toList() ?? const [];
      final scores = (s['distances'] as List?)?.toList() ?? const [];
      final count = metas.isEmpty ? 1 : metas.length;
      for (var i = 0; i < count; i++) {
        final m = metas.isEmpty ? src : (metas[i] as Map? ?? const {});
        final url = '${m['source'] ?? src['url'] ?? ''}';
        final name = '${m['name'] ?? m['title'] ?? src['name'] ?? url}';
        if (name.isEmpty) continue;
        final key = '$name|$url';
        final source = byKey[key] ??= Source(
          name: name,
          url: url.startsWith('http') ? url : null,
        );
        if (seen.add(key)) out.add(source);
        final text = i < docs.length ? '${docs[i] ?? ''}'.trim() : '';
        if (text.isNotEmpty) {
          final score = i < scores.length ? scores[i] : null;
          source.passages.add((
            text: text,
            relevance: score is num && score >= 0 && score <= 1
                ? score.toDouble()
                : null,
          ));
        }
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

/// A chat folder; folders nest through [parentId].
class Folder {
  const Folder({required this.id, required this.name, this.parentId});

  factory Folder.fromJson(Map<String, dynamic> json) => Folder(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    parentId: json['parent_id'] as String?,
  );

  final String id;
  final String name;
  final String? parentId;
}

class ToolCall {
  const ToolCall({required this.name, required this.arguments, this.result});
  final String name;
  final String arguments;
  final String? result;
}

class Source {
  Source({required this.name, this.url});
  final String name;
  final String? url;

  /// The text the model read from it, with how relevant the server found it.
  final List<({String text, double? relevance})> passages = [];
}

/// A photo or file on a message, in the web UI's shape: `id` and `url` are
/// the server file id; `type` is `image` for inline images (data URLs) and
/// `file` otherwise, with `content_type` telling photos apart.
class Attachment {
  Attachment({
    required this.type,
    required this.name,
    this.id,
    this.url,
    this.contentType,
    this.size,
    Map<String, dynamic>? raw,
  }) : raw = raw ?? {};

  factory Attachment.fromJson(Map<String, dynamic> json) => Attachment(
    type: json['type'] as String? ?? 'file',
    name: json['name'] as String? ?? '',
    id: json['id'] as String?,
    url: json['url'] as String?,
    contentType: json['content_type'] as String?,
    size: (json['size'] as num?)?.toInt(),
    raw: json,
  );

  /// Builds the entry for a file the server just stored ([uploaded] is the
  /// upload response), exactly as the web UI adds it to a message.
  factory Attachment.uploaded(Map<String, dynamic> uploaded, {int? size}) {
    final meta = (uploaded['meta'] as Map?) ?? const {};
    final id = uploaded['id'] as String;
    final name = '${meta['name'] ?? uploaded['filename'] ?? 'file'}';
    final contentType = (meta['content_type'] ?? uploaded['content_type'])
        ?.toString();
    final collection =
        meta['collection_name'] ?? uploaded['collection_name'] ?? '';
    final json = <String, dynamic>{
      'type': 'file',
      'file': uploaded,
      'id': id,
      'url': id,
      'name': name,
      'collection_name': collection,
      'status': 'uploaded',
      'size': size ?? meta['size'],
      'error': '',
      'content_type': ?contentType,
    };
    return Attachment.fromJson(json);
  }

  final String type;
  final String name;
  final String? id;
  final String? url;
  final String? contentType;
  final int? size;

  /// The entry as the server stores it, written back unchanged.
  final Map<String, dynamic> raw;

  /// Photos the model looks at (SVG is text, not a picture).
  bool get isImage {
    if (type == 'image') return true;
    final base = (contentType ?? '').split(';').first.trim().toLowerCase();
    return base.startsWith('image/') && base != 'image/svg+xml';
  }

  /// Videos, played in the app.
  bool get isVideo {
    final base = (contentType ?? '').split(';').first.trim().toLowerCase();
    if (base.startsWith('video/')) return true;
    return RegExp(
      r'\.(mp4|m4v|mov|webm|mkv|3gp)$',
      caseSensitive: false,
    ).hasMatch(name);
  }

  /// Sound, such as a voice note: played in the app.
  bool get isAudio {
    final base = (contentType ?? '').split(';').first.trim().toLowerCase();
    if (base.startsWith('audio/')) return true;
    return RegExp(
      r'\.(wav|mp3|m4a|aac|ogg|oga|opus|flac)$',
      caseSensitive: false,
    ).hasMatch(name);
  }

  /// A data: URL to show directly, when the image is inline.
  String? get dataUrl => url != null && url!.startsWith('data:') ? url : null;

  /// The server file id to fetch the bytes from, if it lives on the server.
  /// Generated images carry only their content path
  /// (`/api/v1/files/<id>/content`), so the id is read from that.
  String? get fileId {
    if (id != null) return id;
    final u = url;
    if (u == null || u.startsWith('data:') || u.startsWith('http')) {
      return null;
    }
    return fileIdFromPath(u) ?? (u.startsWith('/') ? null : u);
  }

  /// A server path (starting with `/`) that isn't a file's content.
  String? get serverPath {
    final u = url;
    if (u == null || !u.startsWith('/') || fileIdFromPath(u) != null) {
      return null;
    }
    return u;
  }

  Map<String, dynamic> toJson() => raw;
}

/// The file id in a server content path such as `/api/v1/files/<id>/content`.
String? fileIdFromPath(String path) =>
    RegExp(r'/api/v1/files/([^/?#]+)').firstMatch(path)?.group(1);
