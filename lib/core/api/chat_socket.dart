import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

/// Open WebUI's live channel (Socket.IO at `/ws/socket.io`).
///
/// The server runs each reply as a background task (tools, memory, filters,
/// title) and pushes its progress here as `events`, the same feed the web UI
/// listens to.
class ChatSocket {
  ChatSocket({required String baseUrl, required String token, String? cookie})
    : _token = token {
    final uri = Uri.parse(baseUrl);
    _socket = io.io(
      uri.origin,
      io.OptionBuilder()
          // Keeps a sub-path such as http://host/chat working.
          .setPath('${uri.path}/ws/socket.io')
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .setExtraHeaders({
            if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
          })
          .disableAutoConnect()
          .enableForceNew()
          .enableReconnection()
          .build(),
    );
    _socket
      ..onConnect((_) {
        _socket.emit('user-join', {
          'auth': {'token': token},
        });
        joinChannels();
        for (final id in _notes) {
          _joinNote(id);
        }
        for (final r in _commentRooms.entries) {
          _joinComments(r.key, r.value);
        }
        for (final c in _waiting) {
          if (!c.isCompleted) c.complete(_socket.id);
        }
        _waiting.clear();
      })
      ..on('events', (data) {
        if (data is Map && _typedEvent(data.cast<String, dynamic>())) {
          return;
        }
        if (data is Map && !_events.isClosed) {
          _events.add(data.cast<String, dynamic>());
        } else if (data is List &&
            data.length > 1 &&
            data.first is Map &&
            data.last is Function &&
            !_calls.isClosed) {
          // The server waits on an answer: a question, a confirmation or a
          // form from a tool or function.
          final reply = data.last as Function;
          _calls.add(
            SocketCall((data.first as Map).cast<String, dynamic>(), (v) {
              reply(v);
            }),
          );
        }
      })
      ..on('encryption:available', (data) {
        if (data is Map && !_encryption.isClosed) {
          _encryption.add(data.cast<String, dynamic>());
        }
      })
      ..on('encryption:event', (data) {
        if (data is Map && !_encryptionEvents.isClosed) {
          _encryptionEvents.add(data.cast<String, dynamic>());
        }
      })
      ..onDisconnect((_) {
        if (!_dropped.isClosed) _dropped.add(null);
      })
      ..on('access:updated', (_) {
        if (!_dropped.isClosed) _dropped.add(null);
      })
      ..on('note:presence', (data) {
        if (data is Map && !_notePresence.isClosed) {
          _notePresence.add(data.cast<String, dynamic>());
        }
      })
      ..on('events:note', (data) {
        if (data is Map && !_noteEvents.isClosed) {
          _noteEvents.add(data.cast<String, dynamic>());
        }
      })
      // Open WebUI 0.13: the inbox changed (a comment, mention, reply,
      // failed automation or coming event); only a nudge, no content.
      ..on('notifications:changed', (_) {
        if (!_inbox.isClosed) _inbox.add(null);
      })
      // Comments on something open here changed.
      ..on('comments:changed', (data) {
        if (data is Map && !_comments.isClosed) {
          _comments.add(data.cast<String, dynamic>());
        }
      })
      ..on('events:channel', (data) {
        if (data is Map && !_channelEvents.isClosed) {
          _channelEvents.add(data.cast<String, dynamic>());
        }
      })
      ..connect();
  }

  /// Open WebUI 0.13.4 sends notes, comments, inbox, access and
  /// encrypted-chat updates as typed messages on `events` (no chat id)
  /// instead of their own event names. Hands them to the same streams as
  /// the old names (still heard for older servers); true when it was one.
  bool _typedEvent(Map<String, dynamic> m) {
    final t = typedSocketEvent(m);
    if (t == null) return false;
    final d = t.$2;
    void add(StreamController<Map<String, dynamic>> c) {
      if (d != null && !c.isClosed) c.add(d);
    }

    switch (t.$1) {
      case 'note:presence':
        add(_notePresence);
      case 'note:updated':
        add(_noteEvents);
      case 'notifications:changed':
        if (!_inbox.isClosed) _inbox.add(null);
      case 'comments:changed':
        add(_comments);
      case 'comments:unavailable':
        // Access to a joined comment room ended; nothing to refresh.
        break;
      case 'access:updated':
        if (!_dropped.isClosed) _dropped.add(null);
      case 'encryption:available':
        add(_encryption);
      case 'terminals:changed':
        if (!_terminals.isClosed) _terminals.add(null);
      default:
        return false;
    }
    return true;
  }

  late final io.Socket _socket;
  final _terminals = StreamController<void>.broadcast();

  /// The terminals you can use changed (0.13.4: one was created, shared,
  /// started or stopped, or a Tether computer came or went).
  Stream<void> get terminalsChanged => _terminals.stream;
  final String _token;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _channelEvents = StreamController<Map<String, dynamic>>.broadcast();
  final _waiting = <Completer<String?>>[];
  final _encryption = StreamController<Map<String, dynamic>>.broadcast();
  final _calls = StreamController<SocketCall>.broadcast();
  final _encryptionEvents = StreamController<Map<String, dynamic>>.broadcast();
  final _dropped = StreamController<void>.broadcast();
  final _notePresence = StreamController<Map<String, dynamic>>.broadcast();
  final _noteEvents = StreamController<Map<String, dynamic>>.broadcast();
  final _notes = <String>{};
  final _inbox = StreamController<void>.broadcast();
  final _comments = StreamController<Map<String, dynamic>>.broadcast();
  final _commentRooms = <String, (String, String)>{};

  /// The inbox changed: count and list are worth fetching again.
  Stream<void> get inboxChanged => _inbox.stream;

  /// Comments changed on {resource_type, resource_id} of a joined room.
  Stream<Map<String, dynamic>> get commentsChanged => _comments.stream;

  /// Hears comment changes on [type]/[id] (under [subscription], as the web
  /// keeps one per open panel), again after a reconnect.
  void joinComments(String subscription, String type, String id) {
    _commentRooms[subscription] = (type, id);
    if (_socket.connected) _joinComments(subscription, (type, id));
  }

  void _joinComments(String subscription, (String, String) r) =>
      _socket.emit('comments:join', {
        'resource_type': r.$1,
        'resource_id': r.$2,
        'subscription_id': subscription,
      });

  void leaveComments(String subscription) {
    if (_commentRooms.remove(subscription) != null && _socket.connected) {
      _socket.emit('comments:leave', {'subscription_id': subscription});
    }
  }

  /// Who has a note open (0.12.5): {note_id, users: [{id, name, page_id}]}.
  Stream<Map<String, dynamic>> get notePresence => _notePresence.stream;

  /// A note changed elsewhere (its pages, title or text), as the web hears.
  Stream<Map<String, dynamic>> get noteEvents => _noteEvents.stream;

  /// Opens note [id]'s live room, again after a reconnect.
  void joinNote(String id) {
    _notes.add(id);
    if (_socket.connected) _joinNote(id);
  }

  void _joinNote(String id) => _socket.emit('note:join', {
    'note_id': id,
    'auth': {'token': _token},
  });

  void leaveNote(String id) {
    _notes.remove(id);
    if (_socket.connected) _socket.emit('note:leave', {'note_id': id});
  }

  /// An encrypted chat's packets and changes, for the people in it.
  Stream<Map<String, dynamic>> get encryptionEvents => _encryptionEvents.stream;

  /// The connection dropped or your access changed: an encrypted chat ends.
  Stream<void> get dropped => _dropped.stream;

  /// Asks the server's encrypted-chat relay for [action] (start, join,
  /// bind, packet, ping, leave), as the web. Throws when it refuses.
  Future<Map<String, dynamic>> encryption(String action, Map data) async {
    if (!_socket.connected) throw StateError('Encrypted chat is unavailable.');
    final done = Completer<Map<String, dynamic>>();
    _socket.emitWithAck(
      'encryption:$action',
      data,
      ack: (res) {
        final r = res is List && res.isNotEmpty ? res.first : res;
        if (done.isCompleted) return;
        if (r is Map && r['ok'] == true) {
          done.complete(r.cast<String, dynamic>());
        } else {
          done.completeError(StateError('Encrypted chat ended.'));
        }
      },
    );
    return done.future.timeout(const Duration(seconds: 10));
  }

  /// Events the server waits on an answer for.
  Stream<SocketCall> get calls => _calls.stream;

  /// An encrypted chat started or ended in a channel: {channel, session}.
  Stream<Map<String, dynamic>> get encryptionAvailable => _encryption.stream;

  /// The encrypted chat going on in [channel] to join, or null for none
  /// (or when the server doesn't offer encrypted chats).
  Future<String?> encryptedChatIn(String channel) async {
    if (!_socket.connected) return null;
    final done = Completer<String?>();
    _socket.emitWithAck(
      'encryption:status',
      {'channel': channel},
      ack: (res) {
        final r = res is List && res.isNotEmpty ? res.first : res;
        if (!done.isCompleted) {
          done.complete(
            r is Map && r['ok'] == true && r['available'] == true
                ? '${r['session']}'
                : null,
          );
        }
      },
    );
    return done.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => null,
    );
  }

  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Channel activity: new, changed and deleted messages and reactions.
  Stream<Map<String, dynamic>> get channelEvents => _channelEvents.stream;

  /// Live messages from the channels the person is in; again after joining
  /// one, since opening a channel makes them a member.
  void joinChannels() => _socket.emit('join-channels', {
    'auth': {'token': _token},
  });

  /// Tells the server you have read chat [chatId] (clears its unread dot
  /// here and on the web).
  /// Sends [data] on [event], as replies from your own connections go back.
  void emit(String event, Object? data) => _socket.emit(event, data);

  void markRead(String chatId) => _socket.emit('events:chat', {
    'chat_id': chatId,
    'data': {'type': 'last_read_at'},
  });

  /// The connection's session id, or null if it can't connect in [timeout].
  /// Replies still run and are saved without it; only live text is lost.
  Future<String?> ready({Duration timeout = const Duration(seconds: 3)}) async {
    if (_socket.connected) return _socket.id;
    final c = Completer<String?>();
    _waiting.add(c);
    return c.future.timeout(timeout, onTimeout: () => null);
  }

  void dispose() {
    _socket.dispose();
    _events.close();
    _terminals.close();
    _channelEvents.close();
    _encryption.close();
    _calls.close();
    _encryptionEvents.close();
    _dropped.close();
    _notePresence.close();
    _noteEvents.close();
    _inbox.close();
    _comments.close();
  }
}

/// An event the server waits on: answer it once with [reply].
class SocketCall {
  SocketCall(this.event, this._reply);
  final Map<String, dynamic> event;
  final void Function(Object? value) _reply;
  var _answered = false;

  Map<String, dynamic> get data =>
      ((event['data'] as Map?) ?? const {}).cast<String, dynamic>();
  String get type => '${data['type'] ?? ''}';
  Map<String, dynamic> get body =>
      ((data['data'] as Map?) ?? const {}).cast<String, dynamic>();
  String? get chatId => event['chat_id'] as String?;
  String? get interactionId => body['interaction_id'] as String?;
  bool get answered => _answered;

  void reply(Object? value) {
    if (_answered) return;
    _answered = true;
    _reply(value);
  }
}

/// The (type, data) of a 0.13.4 typed socket message that isn't about a
/// chat reply, or null. Pure so it can be tested.
(String, Map<String, dynamic>?)? typedSocketEvent(Map<String, dynamic> m) {
  if (m['chat_id'] != null || m['channel_id'] != null) return null;
  final inner = m['data'];
  if (inner is! Map) return null;
  final type = inner['type'];
  if (type is! String || !_typedEventNames.contains(type)) return null;
  final d = inner['data'];
  return (type, d is Map ? d.cast<String, dynamic>() : null);
}

const _typedEventNames = {
  'note:presence',
  'note:updated',
  'notifications:changed',
  'comments:changed',
  'comments:unavailable',
  'access:updated',
  'encryption:available',
  'terminals:changed',
};
