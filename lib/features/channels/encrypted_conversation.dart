/// One encrypted chat, as the web's Conversation (src/lib/encryption): the
/// server only relays sealed packets between the people in it, and nothing
/// is kept once it ends. Any step that doesn't check out ends it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/api/chat_socket.dart';
import 'mls.dart';

/// The server's relay for encrypted chats: [ChatSocket] in the app.
abstract class EncryptionRelay {
  Future<Map<String, dynamic>> request(String action, Map data);
  Stream<Map<String, dynamic>> get events;

  /// The connection dropped or access changed.
  Stream<void> get dropped;
}

class SocketRelay implements EncryptionRelay {
  SocketRelay(this.socket);
  final ChatSocket socket;
  @override
  Future<Map<String, dynamic>> request(String action, Map data) =>
      socket.encryption(action, data);
  @override
  Stream<Map<String, dynamic>> get events => socket.encryptionEvents;
  @override
  Stream<void> get dropped => socket.dropped;
}

enum EncryptedStatus { joining, active, ended }

class EncryptedMember {
  const EncryptedMember(this.identity, this.fingerprint, this.name);
  final Map<String, dynamic> identity;
  final String fingerprint;
  final String name;
  String get participation => '${identity['participation']}';
  String get user => '${identity['user']}';
}

class EncryptedMessage {
  const EncryptedMessage({
    required this.id,
    required this.sender,
    required this.userId,
    required this.userName,
    required this.text,
    this.joined = false,
    this.expected = const [],
    this.received = const [],
    this.relayed = true,
    required this.at,
  });
  final String id;
  final String sender;
  final String userId;
  final String userName;
  final String text;

  /// "Someone joined", not a message.
  final bool joined;

  /// Who should get it, and who said they did (your own messages).
  final List<String> expected;
  final List<String> received;

  /// Sent on to the server.
  final bool relayed;
  final DateTime at;

  EncryptedMessage copyWith({List<String>? received, bool? relayed}) =>
      EncryptedMessage(
        id: id,
        sender: sender,
        userId: userId,
        userName: userName,
        text: text,
        joined: joined,
        expected: expected,
        received: received ?? this.received,
        relayed: relayed ?? this.relayed,
        at: at,
      );
}

const _uuid = Uuid();
final _idPattern = RegExp(r'^[a-f0-9-]{36}$');
const _maxText = 16384;

class EncryptedConversation extends ChangeNotifier {
  /// Starts one in [channel], or joins [session] when given.
  EncryptedConversation(
    this._relay, {
    required this.channel,
    required this.user,
    String? session,
    MlsSession Function(Map<String, String> identity, String host)? mls,
  }) : _newMls = mls ?? MlsSession.new {
    final start = session == null;
    _subs.add(
      _relay.events.listen((e) {
        if (e['channel'] != channel ||
            (e['session'] != null && e['session'] != _view?['session'])) {
          return;
        }
        if (e['kind'] == 'ended') return close();
        _enqueue(() => _receive(e));
      }),
    );
    _subs.add(_relay.dropped.listen((_) => close()));
    _joinTimer = Timer(const Duration(seconds: 30), close);
    _enqueue(() async {
      final result = await _relay.request(
        start ? 'start' : 'join',
        start
            ? {'channel': channel, 'action': 'start'}
            : {'channel': channel, 'action': 'join', 'session': session},
      );
      if (_stopped) {
        unawaited(
          _relay
              .request('leave', {
                'channel': channel,
                'session': result['session'],
                'participation': result['participation'],
              })
              .then((_) {}, onError: (_) {}),
        );
        return;
      }
      _view = result;
      _participation = '${result['participation']}';
      final host = '${result['host']}';
      _mls = _newMls({
        'channel': channel,
        'session': '${result['session']}',
        'user': user,
        'participation': _participation,
      }, host);
      if (start) _crypto('create');
      final key = _crypto('public_key');
      final packet = start ? null : _crypto('key_package');
      _view = await _send('bind', {'key': key, 'packet': ?packet});
      self = _participation;
      this.host = host;
      _changed();
      if (start) _activate();
      if (_stopped) return;
      _ping = Timer.periodic(
        const Duration(seconds: 15),
        (_) => _enqueue(() async {
          await _send('ping', {});
        }),
      );
    });
  }

  final EncryptionRelay _relay;
  final String channel;
  final String user;
  final MlsSession Function(Map<String, String>, String) _newMls;

  EncryptedStatus status = EncryptedStatus.joining;
  List<EncryptedMessage> messages = [];
  List<EncryptedMember> members = [];
  List<String> typing = [];
  String self = '';
  String host = '';

  MlsSession? _mls;
  Map<String, dynamic>? _view;
  String _participation = '';
  int _sequence = 0;
  bool _stopped = false;
  Future<void> _chain = Future.value();
  final _subs = <StreamSubscription<void>>[];
  Timer? _joinTimer;
  Timer? _ping;
  final _seenIds = <String>{};
  DateTime? _lastTyping;
  final _typingTimers = <String, Timer>{};

  bool get isHost => self.isNotEmpty && self == host;

  /// The name shown for [participation].
  String nameOf(String participation) =>
      members
          .where((m) => m.participation == participation)
          .firstOrNull
          ?.name ??
      'Participant';

  void _changed() {
    if (!_stopped) notifyListeners();
  }

  Future<void> _enqueue(Future<void> Function() step) => _chain = _chain
      .then((_) async {
        if (!_stopped) await step();
      })
      .catchError((Object _) => close());

  String? _crypto(
    String method, [
    String a = '',
    String b = '',
    String c = '',
  ]) {
    final mls = _mls;
    if (_stopped || mls == null) throw const MlsException();
    return mls.call(method, a, b, c) as String?;
  }

  Future<Map<String, dynamic>> _send(String action, Map data) async {
    final view = _view;
    if (_stopped || view == null) throw const MlsException();
    final result = await _relay.request(action, {
      ...data,
      'channel': channel,
      'session': view['session'],
      'participation': _participation,
    });
    if (_stopped) throw const MlsException();
    return result;
  }

  String get _bindings => jsonEncode(_view?['bindings'] ?? const []);

  void _members() {
    final list = jsonDecode(_crypto('members')!) as List;
    if (_stopped) return;
    final before = {for (final m in members) m.participation};
    final participants = [
      for (final p in _view?['participants'] as List? ?? const [])
        if (p is Map) p,
    ];
    members = [
      for (final m in list.whereType<Map>())
        EncryptedMember(
          (m['identity'] as Map).cast<String, dynamic>(),
          '${m['fingerprint']}',
          '${participants.where((p) => p['participation'] == (m['identity'] as Map)['participation']).firstOrNull?['name'] ?? 'Participant'}',
        ),
    ];
    for (final id in [...typing]) {
      if (!members.any((m) => m.participation == id)) _removeTyping(id);
    }
    if (status == EncryptedStatus.active) {
      for (final m in members) {
        if (before.contains(m.participation)) continue;
        _append(
          id: _uuid.v4(),
          sender: m.participation,
          text: '',
          joined: true,
        );
      }
    }
    _changed();
  }

  void _activate() {
    _joinTimer?.cancel();
    _members();
    status = EncryptedStatus.active;
    _changed();
  }

  Future<void> _receive(Map<String, dynamic> e) async {
    if (_view == null ||
        e['session'] != _view!['session'] ||
        e['sequence'] != _sequence + 1) {
      throw const MlsException();
    }
    _sequence = e['sequence'] as int;
    _view = e;
    final bindings = _bindings;
    switch (e['kind']) {
      case 'candidate':
        final added = jsonDecode(
          _crypto('add', '${e['packet']}', '${e['sender']}', bindings)!,
        ) as Map;
        _view = await _send('packet', {
          'kind': 'admit',
          'target': e['sender'],
          'packet': added['commit'],
          'welcome': added['welcome'],
        });
        _members();
      case 'welcome':
        if (e['sender'] != e['host'] || status != EncryptedStatus.joining) {
          throw const MlsException();
        }
        _crypto('join', '${e['packet']}', bindings);
        _activate();
      case 'departed':
        _removeTyping('${e['participation']}');
        if (e['admitted'] == true && _participation == e['host']) {
          final packet = _crypto('remove', '${e['participation']}', bindings);
          await _send('packet', {'kind': 'mls', 'packet': packet});
          _members();
        }
      case 'mls':
        final result = jsonDecode(
          _crypto('process', '${e['packet']}', '${e['sender']}', bindings)!,
        ) as Map;
        switch (result['kind']) {
          case 'application':
            await _application(
              (result['sender'] as Map).cast<String, dynamic>(),
              '${result['text']}',
            );
          case 'proposal' when _participation == e['host']:
            final packet = _crypto('commit_updates');
            await _send('packet', {'kind': 'mls', 'packet': packet});
            _members();
          case 'commit':
            _members();
        }
      default:
        throw const MlsException();
    }
  }

  void _append({
    required String id,
    required String sender,
    required String text,
    bool joined = false,
    List<String> expected = const [],
    bool relayed = true,
  }) {
    final who = members.where((m) => m.participation == sender).firstOrNull;
    messages = [
      ...messages,
      EncryptedMessage(
        id: id,
        sender: sender,
        userId: who?.user ?? '',
        userName: who?.name ?? 'Participant',
        text: text,
        joined: joined,
        expected: expected,
        relayed: relayed,
        at: DateTime.now(),
      ),
    ];
    // As the web: the newest 500, at most 8 MB.
    var bytes = messages.fold<int>(0, (n, m) => n + utf8.encode(m.text).length);
    while (messages.length > 500 || bytes > 8 * 1024 * 1024) {
      bytes -= utf8.encode(messages.first.text).length;
      messages = messages.sublist(1);
    }
    _changed();
  }

  Future<void> _application(Map<String, dynamic> sender, String text) async {
    final data = jsonDecode(text);
    if (data is! Map ||
        data['session'] != _view?['session'] ||
        data['channel'] != channel ||
        data['id'] is! String ||
        !_idPattern.hasMatch(data['id'] as String)) {
      throw const MlsException();
    }
    final from = '${sender['participation']}';
    switch (data['type']) {
      case 'typing':
        if (data['typing'] is! bool) throw const MlsException();
        if (from == _participation ||
            !members.any((m) => m.participation == from)) {
          return;
        }
        if (data['typing'] == true) {
          _typingTimers[from]?.cancel();
          _typingTimers[from] = Timer(
            const Duration(seconds: 5),
            () => _removeTyping(from),
          );
          if (!typing.contains(from)) {
            typing = [...typing, from];
            _changed();
          }
        } else {
          _removeTyping(from);
        }
      case 'receipt':
        messages = [
          for (final m in messages)
            m.id == data['id'] &&
                    m.sender == _participation &&
                    m.expected.contains(from)
                ? m.copyWith(received: {...m.received, from}.toList())
                : m,
        ];
        _changed();
      case 'text':
        final body = data['text'];
        if (body is! String ||
            utf8.encode(body).length > _maxText ||
            _seenIds.contains(data['id'])) {
          throw const MlsException();
        }
        _seenIds.add(data['id'] as String);
        _removeTyping(from);
        if (_seenIds.length > 1000) _seenIds.remove(_seenIds.first);
        _append(id: data['id'] as String, sender: from, text: body);
        final packet = _crypto(
          'encrypt',
          jsonEncode({
            'type': 'receipt',
            'id': data['id'],
            'channel': channel,
            'session': _view!['session'],
          }),
        );
        await _send('packet', {'kind': 'mls', 'packet': packet});
      default:
        throw const MlsException();
    }
  }

  void _removeTyping(String id) {
    _typingTimers.remove(id)?.cancel();
    if (typing.contains(id)) {
      typing = [
        for (final t in typing)
          if (t != id) t,
      ];
      _changed();
    }
  }

  /// Tells the others you are (or stopped) typing; at most every 2 seconds.
  Future<void>? sendTyping(bool on) {
    if (status != EncryptedStatus.active) return null;
    final now = DateTime.now();
    if (on
        ? _lastTyping != null &&
              now.difference(_lastTyping!) < const Duration(seconds: 2)
        : _lastTyping == null) {
      return null;
    }
    _lastTyping = on ? now : null;
    return _enqueue(() async {
      final packet = _crypto(
        'encrypt',
        jsonEncode({
          'type': 'typing',
          'id': _uuid.v4(),
          'typing': on,
          'channel': channel,
          'session': _view!['session'],
        }),
      );
      await _send('packet', {'kind': 'mls', 'packet': packet});
    });
  }

  Future<void>? sendText(String text) {
    if (status != EncryptedStatus.active ||
        text.trim().isEmpty ||
        utf8.encode(text).length > _maxText) {
      return null;
    }
    sendTyping(false);
    return _enqueue(() async {
      final id = _uuid.v4();
      _append(
        id: id,
        sender: _participation,
        text: text,
        expected: [
          for (final m in members)
            if (m.participation != _participation) m.participation,
        ],
        relayed: false,
      );
      final packet = _crypto(
        'encrypt',
        jsonEncode({
          'type': 'text',
          'id': id,
          'text': text,
          'channel': channel,
          'session': _view!['session'],
        }),
      );
      await _send('packet', {'kind': 'mls', 'packet': packet});
      messages = [
        for (final m in messages) m.id == id ? m.copyWith(relayed: true) : m,
      ];
      _changed();
    });
  }

  /// New keys for everyone (the web's Update keys).
  Future<void> updateKeys() => _enqueue(() async {
    final packet = _crypto('update');
    await _send('packet', {'kind': 'mls', 'packet': packet});
  });

  /// Leaves, and forgets everything in it.
  void close() {
    if (_stopped) return;
    _stopped = true;
    _ping?.cancel();
    _joinTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _mls?.dispose();
    _mls = null;
    _seenIds.clear();
    for (final t in _typingTimers.values) {
      t.cancel();
    }
    _typingTimers.clear();
    _lastTyping = null;
    final view = _view;
    if (view != null && _participation.isNotEmpty) {
      _relay
          .request('leave', {
            'channel': channel,
            'session': view['session'],
            'participation': _participation,
          })
          .then((_) {}, onError: (_) {});
    }
    _view = null;
    status = EncryptedStatus.ended;
    messages = [];
    members = [];
    typing = [];
    self = '';
    host = '';
    notifyListeners();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }
}
