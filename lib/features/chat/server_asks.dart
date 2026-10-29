/// What a tool or function asks you while a reply runs, as the web shows
/// it: a question (`ask_user` in a temporary chat), a yes/no, a value to
/// type, a tool to allow, or a form from an MCP server. The server waits
/// on the answer, so each one gets one.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api/chat_socket.dart';
import '../../core/auth/session.dart';
import 'tool_approval.dart';
import '../settings/direct_connections.dart';
import '../settings/tool_servers.dart';
import '../terminal/terminal_api.dart' show TerminalServer;
import '../terminal/terminal_screen.dart' show terminalServersProvider;
import '../voice/voice_avatar.dart' show activeAvatar;
import 'chat_controller.dart' show serverConfigProvider, userSettingsProvider;
import '../../core/i18n/app_strings.dart';
import '../../core/widgets/hideable.dart';

/// What the app answers for events it can't do (running JavaScript, or a
/// tool that lives in a browser), so the server isn't left waiting.
const cantRunHere = {'error': "The OpenAide app can't run this here."};

/// The kinds of ask the app shows.
const askTypes = {
  'confirmation',
  'input',
  'request:user_input',
  'request:elicitation',
};

/// An option of an `input` select: a string, or {label, value}.
({String label, String value}) inputOption(Object? o) => o is Map
    ? (label: '${o['label'] ?? o['value']}', value: '${o['value']}')
    : (label: '$o', value: '$o');

/// One field of an MCP elicitation form.
class AskField {
  AskField(this.name, this.schema, {required this.required});
  final String name;
  final Map<String, dynamic> schema;
  final bool required;

  String get type => '${schema['type'] ?? 'string'}';
  String get title => '${schema['title'] ?? name}';
  String get description => '${schema['description'] ?? ''}';

  /// Choices: enum (with enumNames), or oneOf/anyOf {const, title}; for an
  /// array, those of its items.
  List<({String value, String title})> get options {
    final s = type == 'array'
        ? ((schema['items'] as Map?) ?? const {}).cast<String, dynamic>()
        : schema;
    final values = s['enum'];
    if (values is List) {
      final names = s['enumNames'] as List?;
      return [
        for (final (i, v) in values.indexed)
          (
            value: '$v',
            title: names != null && i < names.length ? '${names[i]}' : '$v',
          ),
      ];
    }
    final one = s['oneOf'] ?? s['anyOf'];
    return [
      if (one is List)
        for (final o in one.whereType<Map>())
          (value: '${o['const']}', title: '${o['title'] ?? o['const']}'),
    ];
  }

  bool get supported => type == 'array'
      ? options.isNotEmpty
      : const {'string', 'number', 'integer', 'boolean'}.contains(type);
}

List<AskField> formFields(Map<String, dynamic> body) {
  final schema = ((body['requestedSchema'] ?? body['requested_schema']) as Map?)
      ?.cast<String, dynamic>();
  final required = {...?(schema?['required'] as List?)?.map((e) => '$e')};
  return [
    for (final e in ((schema?['properties'] as Map?) ?? const {}).entries)
      AskField(
        '${e.key}',
        (e.value as Map).cast<String, dynamic>(),
        required: required.contains('${e.key}'),
      ),
  ];
}

/// The form's answers as the server checks them: numbers as numbers, and
/// fields left empty left out. Null when a required one is missing.
Map<String, dynamic>? formContent(
  List<AskField> fields,
  Map<String, Object?> values,
) {
  final out = <String, dynamic>{};
  for (final f in fields) {
    var v = values[f.name];
    if (v is String && v.trim().isEmpty) v = null;
    if (v is List && v.isEmpty && !f.required) v = null;
    if (v != null && (f.type == 'number' || f.type == 'integer')) {
      v = f.type == 'integer' ? int.tryParse('$v') : num.tryParse('$v');
      if (v == null) return null;
    }
    if (v == null) {
      if (f.required) return null;
      continue;
    }
    if (f.type == 'array') {
      final n = (v as List).length;
      final min = (f.schema['minItems'] as num?) ?? 0;
      final max = f.schema['maxItems'] as num?;
      if (n < min || (max != null && n > max)) return null;
    }
    out[f.name] = v;
  }
  return out;
}

/// Shows each ask over whatever screen is open.
class ServerAsks extends ConsumerStatefulWidget {
  const ServerAsks({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<ServerAsks> createState() => _ServerAsksState();
}

class _ServerAsksState extends ConsumerState<ServerAsks> {
  final _subs = <StreamSubscription>[];
  final _queue = <SocketCall>[];
  SocketCall? _open;
  BuildContext? _dialog;

  @override
  void initState() {
    super.initState();
    try {
      final socket = ref.read(chatSocketProvider);
      _subs
        ..add(socket.calls.listen(_onCall))
        ..add(socket.events.listen(_onEvent));
    } catch (_) {
      // Signed out.
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  void _onCall(SocketCall call) {
    switch (call.type) {
      case 'request:chat:completion':
        _direct(call);
        return;
      case 'execute:tool':
        _tool(call);
        return;
      case 'request:terminal':
        _terminal(call);
        return;
      case 'voice:play_animation':
        // A gesture for the avatar on the call showing, if one is.
        final name = '${call.body['name'] ?? ''}';
        final avatar = activeAvatar;
        if (avatar == null || name.isEmpty) {
          call.reply({'status': 'unavailable'});
        } else {
          avatar.gesture(name).then((status) => call.reply({'status': status}));
        }
        return;
    }
    if (!askTypes.contains(call.type)) {
      call.reply(cantRunHere);
      return;
    }
    _queue.add(call);
    _next();
  }

  /// A chat with one of your own connections: the phone sends it.
  Future<void> _direct(SocketCall call) async {
    try {
      final list = directConnectionsOf(
        await ref.read(userSettingsProvider.future),
        await ref.read(serverConfigProvider.future),
      );
      await runDirectCompletion(call, list, ref.read(chatSocketProvider).emit);
    } catch (e) {
      call.reply({'error': '$e'});
    }
  }

  /// One of your own tool servers' (or terminals') tools: the phone runs it.
  Future<void> _tool(SocketCall call) async {
    try {
      final config = await ref.read(serverConfigProvider.future);
      if ((config['features'] as Map?)?['enable_tool_servers'] != true) {
        call.reply({'error': 'Tool servers are disabled'});
        return;
      }
      final settings = await ref.read(userSettingsProvider.future);
      List<Map<String, dynamic>> data;
      try {
        data = [
          ...await ref.read(userToolServersDataProvider.future),
          ...await ref.read(userTerminalsDataProvider.future),
        ];
      } catch (_) {
        data = const [];
      }
      await answerExecuteTool(
        call,
        ui: settings['ui'] as Map?,
        sessionToken: ref.read(sessionProvider).value?.token,
        data: data,
      );
    } catch (e) {
      call.reply({'error': '$e'});
    }
  }

  Future<void> _terminal(SocketCall call) async {
    try {
      final settings = await ref.read(userSettingsProvider.future);
      final session = ref.read(sessionProvider).value;
      final system = await ref
          .read(terminalServersProvider.future)
          .catchError((_) => const <TerminalServer>[]);
      await answerTerminalRequest(
        call,
        ui: settings['ui'] as Map?,
        serverUrl: session?.serverUrl ?? '',
        sessionToken: session?.token,
        systemTerminal: system.any((t) => t.id == call.body['terminal_id']),
      );
    } catch (e) {
      call.reply({'error': '$e'});
    }
  }

  /// The server gave up waiting (or another device answered): close it.
  void _onEvent(Map<String, dynamic> e) {
    final data = (e['data'] as Map?) ?? const {};
    if (data['type'] != 'request:interaction:done') return;
    final id = (data['data'] as Map?)?['interaction_id'];
    _queue.removeWhere((c) => c.interactionId == id);
    final open = _open;
    if (open != null && open.interactionId == id) {
      open.reply(null);
      final d = _dialog;
      if (d != null && d.mounted) Navigator.of(d).pop();
    }
  }

  Future<void> _next() async {
    if (_open != null || _queue.isEmpty || !mounted) return;
    final call = _open = _queue.removeAt(0);
    final answer = await showDialog<Object?>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        _dialog = ctx;
        return AskDialog(call: call);
      },
    );
    _dialog = null;
    call.reply(answer ?? cancelAnswer(call));
    _open = null;
    _next();
  }
}

/// What closing an ask without answering sends, as the web.
Object? cancelAnswer(SocketCall call) => switch (call.type) {
  'request:user_input' => {'status': 'cancelled', 'answers': {}},
  'request:elicitation' => {'action': 'cancel'},
  _ => false,
};

class AskDialog extends StatefulWidget {
  const AskDialog({super.key, required this.call});
  final SocketCall call;

  @override
  State<AskDialog> createState() => _AskDialogState();
}

class _AskDialogState extends State<AskDialog> {
  late final Map<String, dynamic> _body = widget.call.body;
  late final _text = TextEditingController(text: '${_body['value'] ?? ''}');
  late final _fields = formFields(_body);
  late final Map<String, Object?> _values = {
    for (final f in _fields) f.name: f.schema['default'],
  };
  String? _picked;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done(Object? v) => Navigator.pop(context, v);

  Widget _close() => IconButton(
    tooltip: tr('Close'),
    icon: const Icon(Icons.close),
    onPressed: () => _done(null),
  );

  Widget _title(String text) => Row(
    children: [
      Expanded(child: Text(text)),
      _close(),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    switch (widget.call.type) {
      case 'request:user_input':
        final questions = PendingCall(
          callId: '',
          name: 'ask_user',
          arguments: _body,
        ).questions;
        return Dialog(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: AskUserCard(
              questions: questions,
              onAnswer: (answers) =>
                  _done({'status': 'answered', 'answers': answers}),
              onSkip: () => _done(null),
            ),
          ),
        );
      case 'confirmation' when _body['tool_call'] is Map:
        final tool = (_body['tool_call'] as Map).cast<String, dynamic>();
        return AlertDialog(
          title: _title('Tool Permissions'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${tool['name']}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                SelectableText(
                  const JsonEncoder.withIndent('  ')
                      .convert(tool['arguments'] ?? const {}),
                  style: TextStyle(fontFamily: 'monospace', color: muted),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => _done(false), child: const T('Deny')),
            FilledButton(onPressed: () => _done(true), child: const T('Allow')),
          ],
        );
      case 'confirmation':
        return AlertDialog(
          title: _title('${_body['title'] ?? 'Confirm'}'),
          content: SingleChildScrollView(
            child: SelectableText('${_body['message'] ?? ''}'),
          ),
          actions: [
            TextButton(onPressed: () => _done(false), child: const T('Cancel')),
            FilledButton(
              onPressed: () => _done(true),
              child: const T('Confirm'),
            ),
          ],
        );
      case 'input':
        final input = (_body['input'] as Map?) ?? const {};
        final kind = '${input['type'] ?? _body['type'] ?? ''}';
        final options = [
          for (final o
              in (input['options'] ?? _body['options']) as List? ?? const [])
            inputOption(o),
        ];
        final select = kind == 'select' && options.isNotEmpty;
        return AlertDialog(
          title: _title('${_body['title'] ?? 'Input'}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if ('${_body['message'] ?? ''}'.isNotEmpty) ...[
                  SelectableText('${_body['message']}'),
                  const SizedBox(height: 12),
                ],
                if (select)
                  DropdownButtonFormField<String>(
                    initialValue:
                        _picked ??
                        (options.any((o) => o.value == _text.text)
                            ? _text.text
                            : null),
                    isExpanded: true,
                    hint: Text('${_body['placeholder'] ?? 'Choose'}'),
                    items: [
                      for (final o in options)
                        DropdownMenuItem(value: o.value, child: Text(o.label)),
                    ],
                    onChanged: (v) => setState(() => _picked = v),
                  )
                else
                  Hideable(
                    secret: kind == 'password',
                    builder: (obscure, eye) => TextField(
                      controller: _text,
                      autofocus: true,
                      obscureText: obscure,
                      minLines: 1,
                      maxLines: kind == 'password' ? 1 : 6,
                      decoration: InputDecoration(
                        suffixIcon: eye,
                        hintText: '${_body['placeholder'] ?? ''}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => _done(false), child: const T('Cancel')),
            FilledButton(
              onPressed: () =>
                  _done(select ? (_picked ?? _text.text) : _text.text),
              child: const T('Confirm'),
            ),
          ],
        );
      default:
        return _elicitation(muted);
    }
  }

  Widget _elicitation(Color muted) {
    final server = '${_body['server_name'] ?? 'Tool'}';
    final message = '${_body['message'] ?? ''}';
    if (_body['mode'] == 'url') {
      final url = '${_body['url'] ?? ''}';
      return AlertDialog(
        title: _title(server),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.isNotEmpty) SelectableText(message),
            const SizedBox(height: 8),
            T('Open this link to continue:', style: TextStyle(color: muted)),
            Text(
              url,
              style: const TextStyle(decoration: TextDecoration.underline),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => _done({'action': 'decline'}),
            child: const T('Decline'),
          ),
          FilledButton(
            onPressed: () {
              final uri = Uri.tryParse(url);
              if (uri != null) {
                launchUrl(uri, mode: LaunchMode.externalApplication);
              }
              _done({'action': 'accept'});
            },
            child: const T('Open'),
          ),
        ],
      );
    }
    final supported = _fields.every((f) => f.supported);
    return AlertDialog(
      title: _title(server),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.isNotEmpty) SelectableText(message),
            if (!supported)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: T(
                  "This request uses a form the app can't show yet.",
                  style: TextStyle(color: muted),
                ),
              )
            else
              for (final f in _fields) _field(f, muted),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => _done({'action': 'decline'}),
          child: const T('Decline'),
        ),
        if (supported)
          FilledButton(
            onPressed: () {
              final content = formContent(_fields, _values);
              if (content == null) {
                setState(() => _error = 'Fill in each required field.');
                return;
              }
              _done({'action': 'accept', 'content': content});
            },
            child: const T('Submit'),
          ),
      ],
    );
  }

  Widget _field(AskField f, Color muted) {
    final label = f.required ? '${f.title} *' : f.title;
    final help = f.description.isEmpty ? null : f.description;
    final options = f.options;
    Widget input;
    if (f.type == 'array') {
      final chosen = {...?(_values[f.name] as List?)?.map((e) => '$e')};
      input = Wrap(
        spacing: 6,
        children: [
          for (final o in options)
            FilterChip(
              label: Text(o.title),
              selected: chosen.contains(o.value),
              onSelected: (on) => setState(
                () => _values[f.name] = [
                  for (final x in options)
                    if (x.value == o.value ? on : chosen.contains(x.value))
                      x.value,
                ],
              ),
            ),
        ],
      );
    } else if (f.type == 'boolean') {
      input = SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(label),
        subtitle: help == null ? null : Text(help),
        value: _values[f.name] == true,
        onChanged: (v) => setState(() => _values[f.name] = v),
      );
      return input;
    } else if (options.isNotEmpty) {
      input = DropdownButtonFormField<String>(
        initialValue: options.any((o) => o.value == '${_values[f.name]}')
            ? '${_values[f.name]}'
            : null,
        isExpanded: true,
        hint: const T('Select an option'),
        items: [
          for (final o in options)
            DropdownMenuItem(value: o.value, child: Text(o.title)),
        ],
        onChanged: (v) => setState(() => _values[f.name] = v),
      );
    } else {
      final number = f.type == 'number' || f.type == 'integer';
      input = TextFormField(
        initialValue: _values[f.name] == null ? '' : '${_values[f.name]}',
        keyboardType: number
            ? const TextInputType.numberWithOptions(decimal: true, signed: true)
            : null,
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
        ),
        onChanged: (v) => _values[f.name] = v,
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          if (help != null)
            Text(help, style: TextStyle(color: muted, fontSize: 12)),
          const SizedBox(height: 4),
          input,
        ],
      ),
    );
  }
}
