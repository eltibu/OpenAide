import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../chat/chat_controller.dart';
import 'call_audio.dart';
import 'classic_call_view.dart';
import '../../core/models/model_info.dart';
import 'voice_avatar.dart';
import 'realtime_call.dart';

/// The chat as the call sees it, and the chat actions it takes.
class ChatCallHost implements CallHost {
  ChatCallHost(this.read, this.onError);

  /// `ref.read` of a widget, or of a ProviderContainer in tests.
  final T Function<T>(ProviderListenable<T> provider) read;
  final void Function(String message) onError;

  ChatController get _chat => read(chatControllerProvider.notifier);

  @override
  CallContext context() {
    final state = read(chatControllerProvider);
    final config = read(serverConfigProvider).value;
    final realtime =
        ((config?['audio'] as Map?)?['realtime'] as Map?) ?? const {};
    final model = read(modelsProvider).value
        ?.where((m) => m.id == state.modelId)
        .firstOrNull;
    final chatId = state.chat?.id;
    return CallContext(
      chatId: chatId == null || chatId.isEmpty ? null : chatId,
      modelId: state.modelId ?? '',
      voiceModel: realtime['model'] as String?,
      voice:
          (model?.meta['voice'] as Map?)?['voice'] as String? ??
          realtime['voice'] as String?,
      messages: [for (final m in state.messages) _forVoice(m)],
    );
  }

  /// As the web UI describes a message to the voice model: chat-model
  /// answers carry their state, spoken replies are marked as transcripts.
  static Map<String, String> _forVoice(ChatMessage m) {
    final voice = (m.extra['meta'] as Map?)?['voice'] as Map?;
    final output = m.extra['output'];
    final spoken =
        voice != null &&
        m.model == voice['model'] &&
        !(output is List && output.isNotEmpty);
    final speech = !spoken
        ? [
            for (final s
                in (voice?['speech'] as List? ?? const []).whereType<Map>())
              if ('${s['transcript'] ?? ''}'.isNotEmpty) '${s['transcript']}',
          ].join('\n')
        : '';
    var content = visibleText(m);
    if (m.role == 'assistant') {
      final state = bridgeTurnState(m);
      final source = spoken
          ? 'Historical voice transcript, not current task status'
          : 'Chat model';
      content =
          '[$source; message_id=${m.id}; state=$state]\n'
          '${state == 'completed' ? content : ''}';
      if (speech.isNotEmpty) {
        content +=
            '\n[Historical voice transcript, not current task status]\n'
            '$speech';
      }
    }
    return {'role': m.role, 'content': content};
  }

  @override
  Future<String> addMessage(
    String role,
    String text,
    Map<String, dynamic> voice, [
    String? parentId,
  ]) => _chat.addVoiceMessage(role, text, voice, parentId);

  @override
  Future<BridgeSubmission> submit(
    String text, {
    required String userMessageId,
    required String modelId,
  }) => _chat.submitVoice(userMessageId: userMessageId, modelId: modelId);

  @override
  Future<void> stop(String messageId) => _chat.stopReply(messageId);

  @override
  ChatMessage? message(String id) =>
      read(chatControllerProvider).chat?.messages[id];

  @override
  Future<void> saveVoice(String messageId, Map<String, dynamic> voice) =>
      _chat.saveVoice(messageId, voice);

  @override
  void error(String message) => onError(message);
}

/// A voice call with the chosen model, like the web UI's call button: talk,
/// interrupt by talking or tapping, and everything said lands in the chat.
class CallScreen extends ConsumerStatefulWidget {
  const CallScreen({super.key});

  @override
  ConsumerState<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends ConsumerState<CallScreen> {
  RealtimeCall? _call;
  String? _notice;
  bool _classic = false;
  late final ChatController _controller;
  final _avatar = AvatarHandle();
  bool _avatarFailed = false;

  bool get _realtimeOn {
    final config = ref.read(serverConfigProvider).value;
    return ((config?['audio'] as Map?)?['realtime'] as Map?)?['enabled'] ==
        true;
  }

  @override
  void initState() {
    super.initState();
    _controller = ref.read(chatControllerProvider.notifier);
    activeAvatar = _avatar;
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    try {
      await ref.read(serverConfigProvider.future);
    } catch (_) {}
    if (!mounted) return;
    // No Realtime calls on this server: the classic call, as on the web.
    if (!_realtimeOn) {
      setState(() => _classic = true);
      return;
    }
    final client = ref.read(clientProvider);
    final token = client.token;
    if (token == null) return;
    _controller.voiceCall = true;
    final call = _call ??= RealtimeCall(
      host: ChatCallHost(ref.read, (m) {
        if (mounted) setState(() => _notice = m);
      }),
      audio: AndroidCallAudio(),
      baseUrl: client.baseUrl,
      cookie: client.cookie,
    );
    setState(() => _notice = null);
    await call.connect(token);
  }

  @override
  void dispose() {
    if (activeAvatar == _avatar) activeAvatar = null;
    _controller.voiceCall = false;
    _call?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_classic) return const ClassicCallView();
    // Every change in the chat may be the chat model's answer.
    ref.listen(chatControllerProvider, (_, _) => _call?.update());
    final model = ref
        .watch(modelsProvider)
        .value
        ?.where((m) => m.id == ref.watch(chatControllerProvider).modelId)
        .firstOrNull;
    final call = _call;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: call == null
            ? _body(context, null, model)
            : ListenableBuilder(
                listenable: call,
                builder: (context, _) => _body(context, call, model),
              ),
      ),
    );
  }

  Widget _body(BuildContext context, RealtimeCall? call, ModelInfo? model) {
    final modelName = model?.name;
    final avatar = _avatarFailed
        ? null
        : VoiceAvatarConfig.fromMeta(model?.meta);
    final text = Theme.of(context).textTheme;
    final live = call != null && (call.connected || call.connecting);
    final status = call == null
        ? ''
        : call.connecting
        ? 'Connecting…'
        : !call.connected
        ? 'Call ended'
        : call.muted
        ? 'Muted'
        : call.userSpeaking
        ? 'Listening…'
        : call.speaking
        ? 'Speaking — tap to interrupt'
        : call.approval
        ? 'Waiting for your OK in the chat'
        : call.working
        ? 'Working on it…'
        : 'Listening';
    final level = call == null
        ? 0.0
        : math.max(call.outputLevel * 4, call.inputLevel * 3).clamp(0.0, 1.0);
    return Column(
      children: [
        const SizedBox(height: 24),
        Text(
          modelName ?? 'Voice call',
          style: text.titleLarge?.copyWith(color: Colors.white),
        ),
        const SizedBox(height: 8),
        Text(status, style: text.bodyMedium?.copyWith(color: Colors.white70)),
        Expanded(
          child: Center(
            child: GestureDetector(
              onTap: call != null && call.speaking ? call.stopSpeaking : null,
              child: avatar != null
                  ? SizedBox.expand(
                      child: VoiceAvatarView(
                        client: ref.read(clientProvider),
                        config: avatar,
                        handle: _avatar,
                        speaking: call?.speaking ?? false,
                        listening: call?.userSpeaking ?? false,
                        level: (call?.outputLevel ?? 0) * 4,
                        onFailed: (why) => setState(() {
                          _avatarFailed = true;
                          _notice = why;
                        }),
                      ),
                    )
                  : AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      width: 160 + 80 * level,
                      height: 160 + 80 * level,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            call?.speaking ?? false
                                ? Colors.lightBlueAccent
                                : Colors.white,
                            call?.working ?? false
                                ? Colors.deepPurple
                                : Colors.blueGrey.shade800,
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ),
        if (_notice != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              _notice!,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: Colors.orangeAccent),
            ),
          ),
        if (call != null && call.working && call.connected)
          TextButton(
            onPressed: call.stopBackend,
            child: const Text('Stop the request'),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              if (live)
                IconButton.filledTonal(
                  iconSize: 32,
                  tooltip: call.muted ? 'Unmute' : 'Mute',
                  onPressed: call.mute,
                  icon: Icon(call.muted ? Icons.mic_off : Icons.mic),
                )
              else if (_realtimeOn)
                IconButton.filledTonal(
                  iconSize: 32,
                  tooltip: 'Call again',
                  onPressed: _start,
                  icon: const Icon(Icons.call),
                ),
              IconButton.filled(
                iconSize: 32,
                tooltip: 'Hang up',
                style: IconButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () {
                  call?.end();
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.call_end),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
