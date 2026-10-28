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
        for (final c in _waiting) {
          if (!c.isCompleted) c.complete(_socket.id);
        }
        _waiting.clear();
      })
      ..on('events', (data) {
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
      ..on('events:channel', (data) {
        if (data is Map && !_channelEvents.isClosed) {
          _channelEvents.add(data.cast<String, dynamic>());
        }
      })
      ..connect();
  }

  late final io.Socket _socket;
  final String _token;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _channelEvents = StreamController<Map<String, dynamic>>.broadcast();
  final _waiting = <Completer<String?>>[];
  final _encryption = StreamController<Map<String, dynamic>>.broadcast();
  final _calls = StreamController<SocketCall>.broadcast();

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
    _channelEvents.close();
    _encryption.close();
    _calls.close();
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
