import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/theme.dart';
import 'listen.dart';
import 'studio_api.dart';
import 'studio_doc.dart';
import 'studio_screen.dart' show StudioEditor, studioModel, studioDocsProvider;

String _clock(Duration d) {
  String two(int n) => n.toString().padLeft(2, '0');
  final h = d.inHours;
  final m = d.inMinutes % 60;
  final s = d.inSeconds % 60;
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
}

String _micProblem(String status) => status == 'denied'
    ? 'Nexus needs the microphone. Allow it in Android Settings > Apps > '
          'Nexus > Permissions.'
    : status;

/// A breathing circle that grows with the voice.
class _Meter extends StatelessWidget {
  const _Meter({required this.level, required this.on, this.size = 120});
  final double level;
  final bool on;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final grow = on ? math.min(1.0, level * 9) : 0.0;
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: size * (0.55 + 0.45 * grow),
          height: size * (0.55 + 0.45 * grow),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on
                ? scheme.primary.withValues(alpha: 0.18 + 0.3 * grow)
                : scheme.surfaceContainerHigh,
          ),
          child: Icon(
            on ? Icons.mic : Icons.mic_off_outlined,
            size: size * 0.3,
            color: on ? scheme.primary : context.nexus.muted,
          ),
        ),
      ),
    );
  }
}

/// Speak instead of typing: listens and returns what was said, or null.
Future<String?> dictate(BuildContext context, OpenWebUiClient client) =>
    showModalBottomSheet<String>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: true,
      builder: (_) => _DictateSheet(client: client),
    );

class _DictateSheet extends StatefulWidget {
  const _DictateSheet({required this.client});
  final OpenWebUiClient client;

  @override
  State<_DictateSheet> createState() => _DictateSheetState();
}

class _DictateSheetState extends State<_DictateSheet> {
  late final SpeechListener _listener;
  final _pieces = <String>[];
  double _level = 0;
  int _waiting = 0;
  String? _problem;
  bool _on = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    _listener = SpeechListener(
      widget.client,
      // Short pieces, so words show soon after they are said.
      cutter: Cutter(
        shortest: const Duration(seconds: 2),
        longest: const Duration(seconds: 15),
        pause: const Duration(milliseconds: 600),
      ),
      onText: (t) {
        if (mounted) setState(() => _pieces.add(t));
      },
    );
    _listener.level.stream.listen((l) {
      if (mounted) setState(() => _level = l);
    });
    _listener.waiting.stream.listen((n) {
      if (mounted) setState(() => _waiting = n);
    });
    _listener.errors.stream.listen((e) {
      if (mounted) setState(() => _problem = e);
    });
    _start();
  }

  Future<void> _start() async {
    final status = await _listener.start();
    if (!mounted) return;
    setState(() {
      _on = status == 'started';
      if (!_on) _problem = _micProblem(status);
    });
  }

  @override
  void dispose() {
    if (!_finishing) unawaited(_listener.cancel());
    super.dispose();
  }

  Future<void> _done() async {
    setState(() => _finishing = true);
    await _listener.stop();
    if (mounted) Navigator.pop(context, _pieces.join(' ').trim());
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final text = _pieces.join(' ');
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _finishing
                  ? 'Finishing the last words…'
                  : _on
                  ? 'Listening… speak, then tap Done'
                  : 'Starting the microphone…',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Center(
              child: _Meter(level: _level, on: _on && !_finishing),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                reverse: true,
                child: Text(
                  text.isEmpty
                      ? (_waiting > 0
                            ? 'Turning it into text…'
                            : 'Your words show here.')
                      : _waiting > 0
                      ? '$text …'
                      : text,
                  style: TextStyle(
                    fontSize: 16,
                    color: text.isEmpty ? muted : null,
                  ),
                ),
              ),
            ),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _problem!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: _finishing ? null : () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: _finishing || !_on ? null : _done,
                  icon: const Icon(Icons.check),
                  label: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- Notes from a recording ----

enum _Phase { ready, recording, finishing, writing }

/// Records a meeting, a class or a thought, shows the words as they come,
/// then has the AI turn them into minutes, notes or a document. The
/// transcript is saved on the server as it grows, so nothing is lost.
class RecordNotesScreen extends ConsumerStatefulWidget {
  const RecordNotesScreen({super.key});

  @override
  ConsumerState<RecordNotesScreen> createState() => _RecordNotesScreenState();
}

class _RecordNotesScreenState extends ConsumerState<RecordNotesScreen> {
  String _kind = 'Meeting minutes';
  _Phase _phase = _Phase.ready;
  SpeechListener? _listener;
  final _pieces = <String>[];
  double _level = 0;
  int _waiting = 0;
  String? _problem;
  bool _paused = false;
  String? _docId;
  String _title = '';
  String _draft = '';
  final _watch = Stopwatch();
  Timer? _tick;
  late final StudioApi _api = StudioApi(ref.read(clientProvider));

  @override
  void dispose() {
    _tick?.cancel();
    if (_phase == _Phase.recording) unawaited(_listener?.cancel());
    super.dispose();
  }

  String get _transcript => _pieces.join('\n\n');

  String _stamp() {
    final l = MaterialLocalizations.of(context);
    final now = DateTime.now();
    return '${l.formatMediumDate(now)}, ${l.formatTimeOfDay(TimeOfDay.fromDateTime(now))}';
  }

  Future<void> _saveTranscript() async {
    final id = _docId;
    if (id == null) return;
    try {
      await _api.save(
        id,
        title: _title,
        markdown: '## Transcript\n\n$_transcript',
      );
    } catch (_) {
      // The next piece tries again.
    }
  }

  Future<void> _record() async {
    setState(() {
      _problem = null;
      _pieces.clear();
    });
    _title = '$_kind · ${_stamp()}';
    try {
      _docId = (await _api.create(_title, '## Transcript')).id;
    } catch (e) {
      setState(() => _problem = 'Couldn\'t start a document on the server: $e');
      return;
    }
    final listener = SpeechListener(
      ref.read(clientProvider),
      onText: (t) {
        if (!mounted) return;
        setState(() => _pieces.add(t));
        unawaited(_saveTranscript());
      },
    );
    listener.level.stream.listen((l) {
      if (mounted) setState(() => _level = l);
    });
    listener.waiting.stream.listen((n) {
      if (mounted) setState(() => _waiting = n);
    });
    listener.errors.stream.listen((e) {
      if (mounted) setState(() => _problem = e);
    });
    final status = await listener.start();
    if (!mounted) return;
    if (status != 'started') {
      setState(() => _problem = _micProblem(status));
      return;
    }
    _listener = listener;
    _watch
      ..reset()
      ..start();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    setState(() {
      _phase = _Phase.recording;
      _paused = false;
    });
  }

  void _pause() {
    final on = !_paused;
    _listener?.pause(on);
    on ? _watch.stop() : _watch.start();
    setState(() => _paused = on);
  }

  Future<void> _stop() async {
    _tick?.cancel();
    _watch.stop();
    setState(() => _phase = _Phase.finishing);
    await _listener?.stop();
    await _saveTranscript();
    await _write();
  }

  Future<void> _fromFile() async {
    try {
      final files = await FilePicker.pickFiles(type: FileType.audio);
      if (files.isEmpty || !mounted) return;
      final f = files.first;
      setState(() {
        _phase = _Phase.finishing;
        _problem = null;
      });
      final name = f.name.toLowerCase().endsWith('.mpeg')
          ? '${f.name}.mp3'
          : f.name;
      final text = await transcribe(
        ref.read(clientProvider),
        await f.readAsBytes(),
        name,
      );
      if (!mounted) return;
      if (text.isEmpty) throw 'no words were found in it';
      _pieces
        ..clear()
        ..add(text);
      _title = '$_kind · ${f.name}';
      _docId = (await _api.create(_title, '## Transcript\n\n$text')).id;
      await _write();
    } catch (e) {
      if (mounted) {
        setState(() {
          _phase = _Phase.ready;
          _problem = 'Couldn\'t turn that file into text: $e';
        });
      }
    }
  }

  Future<void> _write() async {
    final id = _docId!;
    final transcript = _transcript;
    if (transcript.trim().isEmpty) {
      setState(() {
        _phase = _Phase.ready;
        _problem = 'No words were heard, so there is nothing to write up.';
      });
      await _api.delete(id).catchError((_) {});
      return;
    }
    var markdown = '## Transcript\n\n$transcript';
    var label = 'Recorded';
    final model = studioModel(ref);
    if (_kind != 'Just the transcript' && model != null) {
      setState(() {
        _phase = _Phase.writing;
        _draft = '';
      });
      try {
        await for (final d
            in ref
                .read(clientProvider)
                .streamCompletion(
                  model: model,
                  messages: notesPrompt(kind: _kind, transcript: transcript),
                )) {
          if (mounted) setState(() => _draft += d);
        }
        final (title, body) = titleAndBody(cleanAiText(_draft));
        if (title.isNotEmpty) _title = title;
        markdown = '$body\n\n---\n\n$markdown';
        label = 'Notes made by AI';
      } catch (e) {
        // The transcript is kept; the notes can be asked for again in
        // the Studio ("Edit all with AI").
        if (mounted) {
          setState(() => _problem = 'The AI couldn\'t write the notes: $e');
        }
      }
    }
    try {
      await _api.save(
        id,
        title: _title,
        markdown: markdown,
        versions: [
          Version(
            markdown: markdown,
            title: _title,
            at: DateTime.now(),
            label: label,
          ),
        ],
      );
    } catch (e) {
      if (mounted) setState(() => _problem = 'Not saved: $e');
      return;
    }
    if (!mounted) return;
    ref.invalidate(studioDocsProvider);
    await Navigator.pushReplacement(
      context,
      MaterialPageRoute<void>(builder: (_) => StudioEditor(id: id)),
    );
  }

  Future<bool> _leave() async {
    if (_phase != _Phase.recording) return _phase == _Phase.ready;
    final choice = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Stop recording?'),
        content: const Text(
          'What was said so far is saved as a transcript in the Studio.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, 'keep'),
            child: const Text('Keep recording'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, 'stop'),
            child: const Text('Stop and write it up'),
          ),
        ],
      ),
    );
    if (choice == 'stop') await _stop();
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = context.nexus.muted;
    final recording = _phase == _Phase.recording;
    return PopScope(
      canPop: _phase == _Phase.ready,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Record notes')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_phase == _Phase.ready) ...[
                  Text(
                    'What should it become?',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final k in noteKinds.keys)
                        ChoiceChip(
                          label: Text(k),
                          selected: _kind == k,
                          onSelected: (_) => setState(() => _kind = k),
                        ),
                    ],
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _kind,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (recording)
                        Text(
                          _paused
                              ? 'Paused · ${_clock(_watch.elapsed)}'
                              : _clock(_watch.elapsed),
                          style: TextStyle(
                            fontFeatures: const [FontFeature.tabularFigures()],
                            color: _paused ? muted : scheme.error,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: _phase == _Phase.writing
                        ? SingleChildScrollView(
                            reverse: true,
                            child: MarkdownBlock(
                              data: cleanAiText(_draft).isEmpty
                                  ? '_The AI is writing it up…_'
                                  : cleanAiText(_draft),
                              config:
                                  Theme.of(context).brightness ==
                                      Brightness.dark
                                  ? MarkdownConfig.darkConfig
                                  : MarkdownConfig.defaultConfig,
                            ),
                          )
                        : _pieces.isEmpty
                        ? Center(
                            child: Text(
                              _phase == _Phase.ready
                                  ? 'Tap Record and put the phone where it can hear. '
                                        'The words show here as they are said, and are '
                                        'saved as you go. When you stop, the AI writes '
                                        'it up as ${_kind.toLowerCase()}.'
                                  : _phase == _Phase.finishing
                                  ? 'Turning it into text…'
                                  : 'Listening…',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: muted),
                            ),
                          )
                        : SingleChildScrollView(
                            reverse: true,
                            child: Text(
                              _waiting > 0 ? '$_transcript …' : _transcript,
                              style: const TextStyle(fontSize: 15, height: 1.4),
                            ),
                          ),
                  ),
                ),
                if (_problem != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _problem!,
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                const SizedBox(height: 12),
                if (_phase == _Phase.ready) ...[
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: _record,
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('Record'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _fromFile,
                    icon: const Icon(Icons.audio_file_outlined),
                    label: const Text('Use an audio file instead'),
                  ),
                ] else if (recording)
                  Row(
                    children: [
                      _Meter(level: _level, on: !_paused, size: 56),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: _pause,
                          icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                          label: Text(_paused ? 'Resume' : 'Pause'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.icon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                          ),
                          onPressed: _stop,
                          icon: const Icon(Icons.stop),
                          label: const Text('Stop'),
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        _phase == _Phase.writing
                            ? 'Writing it up…'
                            : 'Finishing the last words…',
                        style: TextStyle(color: muted),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
