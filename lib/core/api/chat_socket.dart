import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

/// Open WebUI's live channel (Socket.IO at `/ws/socket.io`).
///
/// The server runs each reply as a background task (tools, memory, filters,
/// title) and pushes its progress here as `events`, the same feed the web UI
/// listens to.
class ChatSocket {
  ChatSocket({required String baseUrl, required String token, String? cookie}) {
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
        for (final c in _waiting) {
          if (!c.isCompleted) c.complete(_socket.id);
        }
        _waiting.clear();
      })
      ..on('events', (data) {
        if (data is Map && !_events.isClosed) {
          _events.add(data.cast<String, dynamic>());
        }
      })
      ..connect();
  }

  late final io.Socket _socket;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _waiting = <Completer<String?>>[];

  Stream<Map<String, dynamic>> get events => _events.stream;

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
  }
}
