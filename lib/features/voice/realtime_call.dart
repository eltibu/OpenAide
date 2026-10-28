import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/chat.dart';
import 'call_audio.dart';
import 'voice_avatar.dart' show activeAvatar;

const _uuid = Uuid();

/// What the call needs to know about the chat, read fresh each time.
class CallContext {
  const CallContext({
    required this.chatId,
    required this.modelId,
    required this.messages,
    this.voiceModel,
    this.voice,
  });

  final String? chatId;
  final String modelId;
  final String? voiceModel;
  final String? voice;

  /// The visible conversation, `{role, content}`, as the voice model sees it.
  final List<Map<String, String>> messages;
}

class BridgeSubmission {
  const BridgeSubmission(
    this.status, {
    this.assistantMessageId,
    this.taskIds = const [],
  });

  /// submitted, deferred or rejected.
  final String status;
  final String? assistantMessageId;
  final List<String> taskIds;
}

/// The chat side of a call: the web UI's Chat.svelte callbacks.
abstract class CallHost {
  CallContext context();

  /// Adds a spoken message to the chat (creating the chat if needed) and
  /// returns its id.
  Future<String> addMessage(
    String role,
    String text,
    Map<String, dynamic> voice, [
    String? parentId,
  ]);

  /// Has the chat model answer the already-saved user message.
  Future<BridgeSubmission> submit(
    String text, {
    required String userMessageId,
    required String modelId,
  });

  /// Stops the chat model's reply [messageId].
  Future<void> stop(String messageId);

  ChatMessage? message(String id);
  Future<void> saveVoice(String messageId, Map<String, dynamic> voice);
  void error(String message);
}

/// Where a chat-model reply stands, for the voice model.
String bridgeTurnState(ChatMessage? message) {
  if (message == null) return 'working';
  if (message.error != null) return 'failed';
  if (message.extra['bridgeCancelled'] == true) return 'cancelled';
  if (message.extra['bridgeStopping'] == true) return 'working';
  final output = (message.extra['output'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final results = {
    for (final item in output)
      if (item['type'] == 'function_call_output') item['call_id'],
  };
  final pending = output.where(
    (item) =>
        item['type'] == 'function_call' &&
        !results.contains(item['call_id'] ?? item['id']) &&
        !const ['rejected', 'cancelled', 'failed'].contains(item['status']),
  );
  if (pending.any(
    (item) =>
        const [
          'pending',
          'queued',
          'requires_approval',
        ].contains(item['status']) ||
        item['name'] == 'ask_user',
  )) {
    return 'approval';
  }
  if (pending.isNotEmpty || !message.done) return 'working';
  return 'completed';
}

class _VoiceTurn {
  _VoiceTurn({
    required this.callId,
    required this.inputId,
    required this.modelId,
  });
  final String callId;
  final String inputId;
  final String modelId;
  String userId = '';
  String? assistantId;
  List<String> taskIds = const [];
  bool finished = false;
  bool approval = false;
}

class _Input {
  _Input(this.text, this.userId, this.modelId);
  final String text;
  final Future<String> userId;
  final String modelId;
}

class _Response {
  _Response(this.id, this.metadata, this.statusCallId);
  final String id;
  final Map<String, dynamic> metadata;
  final String? statusCallId;
  final speech = <String, String>{};
  final audio = <String, Map<String, dynamic>>{};
  bool delegated = false;
  bool done = false;
  String? messageId;
}

/// One voice call through Open WebUI's Realtime bridge
/// (`/api/v1/audio/realtime`), a port of the web UI's `RealtimeCall`
/// (src/lib/utils/realtime.ts): the voice model listens and talks, and hands
/// real requests to the chat model, whose answers it then speaks. Spoken
/// turns are saved in the chat like the web UI saves them.
class RealtimeCall extends ChangeNotifier {
  RealtimeCall({
    required this.host,
    required this.audio,
    required this.baseUrl,
    this.cookie,
  });

  final CallHost host;
  final CallAudio audio;
  final String baseUrl;
  final String? cookie;

  bool connected = false;
  bool connecting = false;
  bool muted = false;
  bool speaking = false;
  bool playbackActive = false;
  bool userSpeaking = false;
  bool working = false;
  bool approval = false;
  String model = '';
  String voice = '';
  double inputLevel = 0;
  double outputLevel = 0;
  String error = '';

  WebSocket? _ws;
  StreamSubscription<dynamic>? _wsSub;
  StreamSubscription<Map<String, dynamic>>? _audioSub;
  Timer? _timer;
  int _session = 0;
  String _callId = '';
  String _token = '';
  String _configuration = '';
  String _chatContext = '';
  bool _cancelRequested = false;
  String _receivingSpeech = '';
  int _savingHistory = 0;
  DateTime _lastPong = DateTime.now();
  String _activeResponse = '';
  bool _responseRequested = false;
  final _speakingResponses = <String>{};
  final _interrupted = <String>{};
  final _responses = <String, _Response>{};
  final _inputs = <String, _Input>{};
  final _calls = <String, _VoiceTurn>{};
  _VoiceTurn? _pending;
  List<Map<String, dynamic>> _commands = [];
  Future<void> _delegation = Future.value();
  Future<void> _recording = Future.value();
  Future<void> _metadata = Future.value();
  int _clearId = 0;
  int _sentSamples = 0;
  final _clears = <int, Set<String>>{};
  bool _disposed = false;

  void _change() {
    if (!_disposed) notifyListeners();
  }

  Uri get _url {
    final base = Uri.parse(baseUrl);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/api/v1/audio/realtime',
    );
  }

  Future<void> connect(String token) async {
    if (connected || connecting) return;
    error = '';
    connecting = true;
    _change();
    final session = ++_session;
    _callId = _uuid.v4();
    try {
      final context = host.context();
      _token = token;
      _configuration = jsonEncode([
        context.modelId,
        context.voiceModel,
        context.voice,
      ]);
      if (context.modelId.isEmpty) {
        throw const _CallError('Choose a model first.');
      }
      final started = await audio.start();
      if (session != _session) return;
      if (started == 'denied') {
        throw const _CallError(
          'OpenAide needs the microphone for calls. Allow it in Android settings.',
        );
      }
      if (started != 'started') throw _CallError(started);
      _audioSub = audio.events.listen((e) {
        if (session == _session) _audioEvent(e);
      });
      final ws = await WebSocket.connect(
        _url.toString(),
        headers: {if (cookie != null && cookie!.isNotEmpty) 'Cookie': cookie!},
      );
      if (session != _session) {
        await ws.close();
        return;
      }
      _ws = ws;
      final opened = DateTime.now();
      _lastPong = opened;
      _send({
        'type': 'auth',
        'token': token,
        'chat_id': context.chatId,
        'model_id': context.modelId,
      });
      _wsSub = ws.listen(
        (data) {
          if (session != _session) return;
          try {
            _event((jsonDecode(data as String) as Map).cast<String, dynamic>());
          } on _CallError catch (e) {
            _fail(e.message);
          } catch (_) {
            _fail('Invalid voice event. The call has ended.');
          }
        },
        onError: (_) {
          if (session == _session) _fail('Voice connection failed.');
        },
        onDone: () {
          if (session == _session) _fail('Voice connection closed.');
        },
      );
      _timer = Timer.periodic(const Duration(seconds: 10), (_) {
        final now = DateTime.now();
        if (!connected && now.difference(opened).inSeconds > 45) {
          _fail('Voice connection timed out.');
        } else if (connected) {
          if (now.difference(_lastPong).inSeconds > 45) {
            _fail('Voice connection stopped responding.');
          } else {
            _send({'type': 'bridge.ping'});
          }
        }
      });
    } on _CallError catch (e) {
      if (session == _session) _fail(e.message);
    } catch (e) {
      if (session == _session) _fail(_readable(e));
    }
  }

  static String _readable(Object e) {
    if (e is WebSocketException || e is SocketException) {
      return "Can't reach the voice service. Check your connection.";
    }
    return '$e';
  }

  void _send(Map<String, dynamic> event) {
    final ws = _ws;
    if (ws != null && ws.readyState == WebSocket.open) {
      ws.add(jsonEncode(event));
    }
  }

  void _audioEvent(Map<String, dynamic> data) {
    switch (data['type']) {
      case 'button':
        // Headset button: stops the answer, or mutes and unmutes.
        speaking ? stopSpeaking() : mute();
      case 'input':
        if (connected && !muted) {
          _send({
            'type': 'input_audio_buffer.append',
            'audio': base64Encode(data['pcm'] as Uint8List),
          });
        }
      case 'playback':
        // Ignore reports from before an interruption cleared the audio.
        if (((data['clearId'] as num?) ?? 0) < _clearId) return;
        final active = data['playbackActive'] == true;
        final playbackChanged = playbackActive != active;
        playbackActive = active;
        final input = muted
            ? 0.0
            : ((data['inputLevel'] as num?) ?? 0).toDouble();
        final output = ((data['outputLevel'] as num?) ?? 0).toDouble();
        final levelsChanged =
            (input - inputLevel).abs() > 0.002 ||
            (output - outputLevel).abs() > 0.002;
        final next =
            ((data['queued'] as num?) ?? 0) > 0 ||
            _sentSamples > ((data['received'] as num?) ?? 0);
        final speakingChanged = speaking != next;
        speaking = next;
        if (!speaking && _activeResponse.isEmpty && !_responseRequested) {
          _speakingResponses.clear();
        }
        if (levelsChanged || speakingChanged || playbackChanged) {
          inputLevel = input;
          outputLevel = output;
          _change();
        }
        _flush();
      case 'error':
        _fail('${data['message'] ?? 'The microphone stopped.'}');
    }
  }

  void _cleared(Map<String, dynamic> data) {
    final id = (data['id'] as num?)?.toInt() ?? 0;
    final responses = _clears.remove(id);
    final latencyMs = ((data['latency_ms'] as num?) ?? 0).toInt();
    final rendered = (data['rendered'] as List? ?? const [])
        .whereType<Map>()
        .toList();
    for (final item in rendered) {
      if (!(responses?.contains(item['response_id']) ?? false)) continue;
      final samples = ((item['samples'] as num?) ?? 0).toInt();
      _send({
        'type': 'conversation.item.truncate',
        'item_id': item['item_id'],
        'content_index': item['content_index'],
        'audio_end_ms': math.max(0, samples ~/ 24 - latencyMs),
      });
    }
    // An item may have been queued but never played.
    for (final responseId in responses ?? const <String>{}) {
      for (final item
          in _responses[responseId]?.audio.values ??
              const <Map<String, dynamic>>[]) {
        final heard = rendered.any(
          (r) =>
              r['item_id'] == item['item_id'] &&
              r['content_index'] == item['content_index'],
        );
        if (!heard) {
          _send({
            'type': 'conversation.item.truncate',
            ...item,
            'audio_end_ms': 0,
          });
        }
      }
    }
    _flush();
  }

  void _enqueue(Map<String, dynamic> command) {
    if (command['type'] == 'bridge.status' &&
        _commands.any(
          (c) =>
              c['type'] == 'bridge.status' && c['status'] == command['status'],
        )) {
      return;
    }
    if (command['type'] == 'bridge.respond' && command['item_id'] != null) {
      // The newest reply hears every transcript; older unsent ones are moot.
      _commands = [command, ..._commands.where((c) => c['item_id'] == null)];
    } else {
      _commands.add(command);
    }
    _flush();
  }

  void _flush() {
    if (!connected ||
        _receivingSpeech.isNotEmpty ||
        _savingHistory > 0 ||
        _activeResponse.isNotEmpty ||
        _responseRequested ||
        speaking ||
        _clears.isNotEmpty) {
      return;
    }
    syncModel();
    if (!connected || _commands.isEmpty) return;
    final command = _commands.removeAt(0);
    _syncContext();
    _responseRequested = true;
    _send(command);
  }

  /// Restarts the call when the model or voice changed.
  void syncModel() {
    if (!connected ||
        _receivingSpeech.isNotEmpty ||
        _savingHistory > 0 ||
        working ||
        speaking ||
        _activeResponse.isNotEmpty ||
        _responseRequested ||
        _commands.isNotEmpty) {
      return;
    }
    final context = host.context();
    final configuration = jsonEncode([
      context.modelId,
      context.voiceModel,
      context.voice,
    ]);
    if (_configuration != configuration) {
      final token = _token;
      end();
      unawaited(connect(token));
    }
  }

  void _syncContext() {
    if (!connected) return;
    // Replace the bounded snapshot so answers and task status can't go stale.
    var budget = 64000;
    final all = host.context().messages;
    final recent = all.sublist(math.max(0, all.length - 100)).reversed;
    final picked = <Map<String, String>>[];
    for (final m in recent) {
      if (!const ['user', 'assistant'].contains(m['role']) || budget <= 0) {
        continue;
      }
      final text = m['content'] ?? '';
      final content = text.substring(
        0,
        math.min(text.length, math.min(32000, budget)),
      );
      budget -= content.length;
      if (content.isNotEmpty) {
        picked.add({'role': m['role']!, 'content': content});
      }
    }
    final messages = picked.reversed.toList();
    final snapshot = jsonEncode(messages);
    if (snapshot == _chatContext) return;
    _chatContext = snapshot;
    _send({'type': 'bridge.context', 'messages': messages});
  }

  void _event(Map<String, dynamic> event) {
    final type = event['type'];
    if (type == 'bridge.error') {
      _fail('${event['message'] ?? 'The call failed.'}');
      return;
    }
    if (type == 'bridge.pong') {
      _lastPong = DateTime.now();
      return;
    }
    if (type == 'bridge.ready') {
      if (event['sample_rate'] != 24000) {
        throw const _CallError('Wrong sample rate');
      }
      model = '${event['model'] ?? ''}';
      voice = '${event['voice'] ?? ''}';
      connected = true;
      connecting = false;
      _syncContext();
      unawaited(audio.capture(!muted));
    } else if (type == 'input_audio_buffer.speech_started') {
      if (muted) return;
      _receivingSpeech = '${event['item_id']}';
      userSpeaking = true;
      // Voice detection can be wrong: hold the reply, don't drop it yet.
      unawaited(audio.pause(true));
    } else if (type == 'input_audio_buffer.speech_stopped') {
      if (_receivingSpeech == '${event['item_id']}') userSpeaking = false;
    } else if (type == 'conversation.item.input_audio_transcription.failed' ||
        type == 'conversation.item.input_audio_transcription.completed') {
      _transcript(event, failed: type.endsWith('.failed'));
    } else if (type == 'response.created') {
      final response = (event['response'] as Map).cast<String, dynamic>();
      final id = '${response['id']}';
      _responseRequested = false;
      _activeResponse = id;
      if (_cancelRequested) {
        _cancelRequested = false;
        _interrupted.add(id);
        _send({'type': 'response.cancel', 'response_id': id});
      }
      _responses[id] = _Response(
        id,
        (response['metadata'] as Map?)?.cast<String, dynamic>() ?? {},
        _pending?.callId,
      );
    } else if (type == 'response.output_audio.delta') {
      final responseId = '${event['response_id']}';
      if (_interrupted.contains(responseId)) return;
      final bytes = base64Decode(event['delta'] as String);
      if (bytes.length.isOdd) throw const _CallError('Invalid PCM');
      final itemId = '${event['item_id']}';
      final contentIndex = (event['content_index'] as num?)?.toInt() ?? 0;
      _responses[responseId]?.audio['$itemId:$contentIndex'] = {
        'item_id': itemId,
        'content_index': contentIndex,
      };
      _sentSamples += bytes.length ~/ 2;
      _speakingResponses.add(responseId);
      speaking = true;
      unawaited(
        audio.play(
          bytes,
          responseId: responseId,
          itemId: itemId,
          contentIndex: contentIndex,
        ),
      );
    } else if (type == 'response.output_audio_transcript.delta') {
      final response = _responses['${event['response_id']}'];
      if (response != null) {
        final itemId = '${event['item_id']}';
        response.speech[itemId] =
            '${response.speech[itemId] ?? ''}${event['delta'] ?? ''}';
      }
    } else if (type == 'response.output_audio_transcript.done') {
      _responses['${event['response_id']}']?.speech['${event['item_id']}'] =
          '${event['transcript'] ?? ''}';
    } else if (type == 'response.output_item.done' &&
        event['item'] is Map &&
        (event['item'] as Map)['type'] == 'function_call' &&
        (event['item'] as Map)['status'] == 'completed') {
      _functionCall(event);
    } else if (type == 'response.done') {
      final response = (event['response'] as Map).cast<String, dynamic>();
      final id = '${response['id']}';
      if (_activeResponse == id) _activeResponse = '';
      _responseRequested = false;
      unawaited(audio.done(id));
      final r = _responses[id];
      if (r != null) {
        r.done = true;
        _saveSpeech(r);
      }
      if (const ['failed', 'incomplete'].contains(response['status'])) {
        host.error('The voice response did not complete.');
      }
      _flush();
    }
    _change();
  }

  void _transcript(Map<String, dynamic> event, {required bool failed}) {
    final itemId = '${event['item_id']}';
    // Transcripts of older segments can arrive during newer speech.
    if (_receivingSpeech == itemId) {
      _receivingSpeech = '';
      userSpeaking = false;
    }
    if (_inputs.containsKey(itemId)) return;
    final text = failed ? '' : '${event['transcript'] ?? ''}'.trim();
    if (text.isNotEmpty) stopSpeaking();
    if (_receivingSpeech.isEmpty) unawaited(audio.pause(false));
    if (text.isEmpty) {
      // Noise is not a request and gets no reply.
      if (failed) {
        host.error('That could not be understood. Please try again.');
      }
      _change();
      _flush();
      return;
    }
    final session = _session;
    final modelId = host.context().modelId;
    _savingHistory++;
    final userId = _recording.then<String>((_) async {
      if (session != _session) return '';
      return host.addMessage('user', text, {
        'call_id': _callId,
        'input_item_id': itemId,
        'model': model,
      });
    });
    _recording = userId.then((_) {}, onError: (_) {});
    _inputs[itemId] = _Input(text, userId, modelId);
    userId
        .whenComplete(() => _savingHistory--)
        .then((_) {
          if (session == _session) {
            _enqueue({'type': 'bridge.respond', 'item_id': itemId});
          }
        })
        .catchError((_) => _fail('Could not save the spoken message.'));
  }

  void _functionCall(Map<String, dynamic> event) {
    final item = (event['item'] as Map).cast<String, dynamic>();
    final responseId = '${event['response_id']}';
    final response = _responses[responseId];
    final callId = '${item['call_id']}';
    if (item['name'] == 'play_animation') {
      // A gesture on the avatar, when the call shows one.
      void result(String status) => _send({
        'type': 'bridge.animation.result',
        'call_id': callId,
        'status': status,
      });
      if (response == null || _interrupted.contains(responseId)) {
        result('cancelled');
        return;
      }
      String? name;
      try {
        name = (jsonDecode('${item['arguments']}') as Map?)?['name'] as String?;
      } catch (_) {}
      final avatar = activeAvatar;
      if (avatar == null || name == null) {
        result('unavailable');
        return;
      }
      avatar.gesture(name).then(result);
      return;
    }
    if (response == null ||
        item['name'] != 'generate_chat_completion' ||
        _calls.containsKey(callId)) {
      return;
    }
    final args = jsonDecode('${item['arguments']}');
    if (args is! Map ||
        args['request'] is! String ||
        (args['request'] as String).trim().isEmpty) {
      throw const _CallError('Invalid function arguments');
    }
    final inputId = '${response.metadata['input_item_id']}';
    final input = _inputs[inputId];
    if (input == null) throw const _CallError('Function has no input');
    response.delegated = true;
    if (_calls.values.any((c) => c.inputId == inputId)) {
      _send({
        'type': 'bridge.result',
        'call_id': callId,
        'status': 'cancelled',
        'answer': 'This input has already been delegated.',
      });
      return;
    }
    final turn = _VoiceTurn(
      callId: callId,
      inputId: inputId,
      modelId: input.modelId,
    );
    _calls[callId] = turn;
    // A new delegation drops any old result still waiting to be spoken.
    _commands = _commands.where((c) => c['call_id'] == null).toList();
    final session = _session;
    _delegation = _delegation
        .then((_) async {
          if (session != _session) return;
          final previous = _pending;
          if (previous != null &&
              !previous.finished &&
              previous.assistantId != null) {
            previous.finished = true;
            await host.stop(previous.assistantId!);
            _result(
              previous,
              'cancelled',
              'Superseded by a new request.',
              speak: false,
            );
            await host.saveVoice(previous.assistantId!, {'superseded': true});
          }
          turn.userId = await input.userId;
          // The chat model must see the previous spoken reply in history.
          await _metadata;
          if (session != _session) return;
          _pending = turn;
          working = true;
          _change();
          final result = await host.submit(
            input.text,
            userMessageId: turn.userId,
            modelId: turn.modelId,
          );
          if (session != _session) return;
          if (result.status != 'submitted' ||
              result.assistantMessageId == null) {
            _result(
              turn,
              result.status == 'deferred' ? 'deferred' : 'failed',
              'Complete the required steps in chat and try again.',
            );
            return;
          }
          turn.assistantId = result.assistantMessageId;
          turn.taskIds = result.taskIds;
          _saveSpeech(response);
          update();
        })
        .catchError((Object _) {
          _fail('Could not hand the request to the chat model.');
        });
  }

  /// Call whenever the chat changes: reports the chat model's progress and
  /// its answer to the voice model.
  void update() {
    _syncContext();
    final turn = _pending;
    if (turn?.assistantId == null || turn!.finished || !connected) return;
    final message = host.message(turn.assistantId!);
    final state = bridgeTurnState(message);
    approval = state == 'approval';
    if (state == 'approval' && !turn.approval) {
      _enqueue({'type': 'bridge.status', 'status': 'approval'});
    }
    turn.approval = approval;
    if (const ['completed', 'failed', 'cancelled'].contains(state)) {
      _result(
        turn,
        state,
        state == 'completed'
            ? visibleText(message!)
            : 'The backend request did not complete successfully.',
      );
    }
    _change();
  }

  void _result(
    _VoiceTurn turn,
    String status,
    String answer, {
    bool speak = true,
  }) {
    turn.finished = true;
    _send({
      'type': 'bridge.result',
      'call_id': turn.callId,
      'status': status,
      'answer': answer.length <= 100000
          ? answer
          : 'The complete answer is ready in chat. It is too long to read '
                'in this call.',
    });
    _commands = _commands.where((c) => c['type'] != 'bridge.status').toList();
    if (speak) _enqueue({'type': 'bridge.respond', 'call_id': turn.callId});
    if (identical(_pending, turn)) {
      working = false;
      approval = false;
    }
    _change();
  }

  void _saveSpeech(_Response response) {
    if (response.speech.isEmpty) return;
    final inputId = response.metadata['input_item_id'] as String?;
    final turn = response.metadata['status'] != null
        ? _calls[response.statusCallId]
        : response.metadata['call_id'] != null
        ? _calls[response.metadata['call_id']]
        : _calls.values.where((c) => c.inputId == inputId).firstOrNull;
    if (response.delegated && turn?.assistantId == null) return;
    final input = _inputs[inputId ?? turn?.inputId];
    final speech = [
      for (final e in response.speech.entries)
        {
          'item_id': e.key,
          'transcript': e.value,
          'response_id': response.id,
          'model': model,
          'interrupted': _interrupted.contains(response.id),
        },
    ];
    final metadata = <String, dynamic>{
      'call_id': _callId,
      'input_item_id': inputId ?? turn?.inputId,
      'function_call_id': turn?.callId,
      'task_ids': turn?.taskIds,
      'model': model,
      'speech': speech,
    };
    final savedChatId = host.context().chatId;
    _savingHistory++;
    _metadata = _metadata
        .then((_) async {
          if (savedChatId != host.context().chatId && savedChatId != null) {
            return;
          }
          if (turn?.assistantId != null) {
            await host.saveVoice(turn!.assistantId!, metadata);
          } else if (response.messageId == null) {
            response.messageId = await host.addMessage(
              'assistant',
              speech.map((s) => s['transcript']).join('\n'),
              metadata,
              input != null ? await input.userId : null,
            );
          } else {
            await host.saveVoice(response.messageId!, metadata);
          }
        })
        .catchError((Object _) {
          host.error('Could not save the voice transcript.');
        })
        .whenComplete(() {
          _savingHistory--;
          _flush();
        });
  }

  /// Interrupts the voice model (tap while it talks, or the person spoke).
  void stopSpeaking() {
    if (_responseRequested) _cancelRequested = true;
    final responses = _speakingResponses
        .where((id) => !_interrupted.contains(id))
        .toSet();
    if (_activeResponse.isNotEmpty && !_interrupted.contains(_activeResponse)) {
      responses.add(_activeResponse);
      _send({'type': 'response.cancel', 'response_id': _activeResponse});
    }
    for (final id in responses) {
      _interrupted.add(id);
      final response = _responses[id];
      if (response?.done ?? false) _saveSpeech(response!);
    }
    _speakingResponses.clear();
    speaking = false;
    playbackActive = false;
    outputLevel = 0;
    final id = ++_clearId;
    _clears[id] = responses;
    final session = _session;
    unawaited(
      audio
          .clear(id)
          .then((data) {
            if (session == _session) _cleared(data);
          })
          .catchError((Object _) {
            _clears.remove(id);
          }),
    );
    _commands = _commands
        .where(
          (c) =>
              c['type'] != 'bridge.status' &&
              c['type'] != 'bridge.animation.respond',
        )
        .toList();
    _change();
  }

  /// Stops the chat model's work for the current request.
  Future<void> stopBackend() async {
    final turn = _pending;
    if (turn?.assistantId == null || turn!.finished) return;
    turn.finished = true;
    try {
      await host.stop(turn.assistantId!);
      if (connected) {
        _result(
          turn,
          'cancelled',
          'The backend request was cancelled. Completed actions have not '
              'been undone.',
        );
      }
    } catch (_) {
      _fail('Stopping was not confirmed. Check the request in the chat.');
    }
  }

  void mute() {
    muted = !muted;
    if (muted) {
      inputLevel = 0;
      userSpeaking = false;
      _receivingSpeech = '';
      unawaited(audio.pause(false));
    }
    unawaited(audio.capture(connected && !muted));
    if (muted) {
      _send({'type': 'input_audio_buffer.clear'});
      _flush();
    }
    _change();
  }

  void _fail(String message) {
    error = message;
    host.error(message);
    end();
  }

  void end() {
    if (connected) {
      stopSpeaking();
      for (final response in _responses.values) {
        if (!response.done) _saveSpeech(response);
      }
    }
    ++_session;
    _timer?.cancel();
    _timer = null;
    unawaited(_wsSub?.cancel());
    _wsSub = null;
    unawaited(_ws?.close());
    _ws = null;
    unawaited(_audioSub?.cancel());
    _audioSub = null;
    unawaited(audio.stop());
    connected = connecting = speaking = working = approval = false;
    inputLevel = outputLevel = 0;
    playbackActive = false;
    _responseRequested = false;
    _cancelRequested = false;
    _receivingSpeech = '';
    userSpeaking = false;
    _activeResponse = '';
    _pending = null;
    _chatContext = '';
    _sentSamples = 0;
    _commands = [];
    _speakingResponses.clear();
    _interrupted.clear();
    _responses.clear();
    _inputs.clear();
    _calls.clear();
    _clears.clear();
    _clearId = 0;
    _change();
  }

  @override
  void dispose() {
    end();
    _disposed = true;
    super.dispose();
  }
}

/// What the person reads in a reply: the answer without folded details
/// (reasoning, tool calls).
String visibleText(ChatMessage message) {
  final output = ChatMessage.outputText(message.extra['output']);
  if (output.isNotEmpty) return output;
  return message.content
      .replaceAll(RegExp(r'<details[\s\S]*?</details>', multiLine: true), '')
      .trim();
}

class _CallError implements Exception {
  const _CallError(this.message);
  final String message;
  @override
  String toString() => message;
}
