/// Run for Python code blocks in replies, as the web's code block: on the
/// server's Jupyter when that is its code engine, otherwise in Pyodide
/// (Python in a hidden web page on the phone).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/auth/session.dart';
import 'chat_controller.dart' show serverConfigProvider;
import '../../core/i18n/app_strings.dart';

/// Whether a block looks like Python, as the web decides when to offer Run.
bool isPythonBlock(String language, String code) {
  final l = language.toLowerCase();
  if (l == 'python' || l == 'py') return true;
  if (l.isNotEmpty) return false;
  return RegExp(
    r'^\s*(def |import |from \S+ import |print\(|class \w+[:(]|for \w+ in |if __name__)',
    multiLine: true,
  ).hasMatch(code);
}

/// What a run printed: text, the last value, errors and pictures.
class RunOutput {
  RunOutput({this.stdout = '', this.result = '', this.stderr = ''});
  String stdout, result, stderr;
  final images = <String>[];

  /// Lines that are pictures (`data:image/png;base64,…`) are shown as such.
  static RunOutput from(Map raw) {
    final out = RunOutput(stderr: '${raw['stderr'] ?? ''}');
    String pictures(String text) {
      final kept = <String>[];
      for (final line in text.split('\n')) {
        line.startsWith('data:image/') ? out.images.add(line) : kept.add(line);
      }
      return kept.join('\n');
    }

    out.stdout = pictures('${raw['stdout'] ?? ''}');
    out.result = pictures('${raw['result'] ?? ''}');
    return out;
  }
}

String pyodidePage(String code) {
  // Inside a <script>: a "</script>" in the code must not end it.
  final src = jsonEncode(code).replaceAll('</', r'<\/');
  return '''<!doctype html><html><head><meta charset="utf-8">
<script src="https://cdn.jsdelivr.net/pyodide/v0.27.2/full/pyodide.js"></script></head><body><script>
(async function(){
  var out='', err='';
  try {
    var py = await loadPyodide({stdout:function(t){out+=t+"\\n";}, stderr:function(t){err+=t+"\\n";}});
    var code = $src;
    await py.loadPackagesFromImports(code);
    var r = await py.runPythonAsync(code);
    Out.postMessage(JSON.stringify({stdout:out, stderr:err, result: r===undefined||r===null?'':String(r)}));
  } catch (e) {
    Out.postMessage(JSON.stringify({stdout:out, stderr:err+String(e&&e.message||e), result:''}));
  }
})();
</script></body></html>''';
}

/// Runs [code] and shows what it printed, under its block.
class CodeRunPanel extends ConsumerStatefulWidget {
  const CodeRunPanel({super.key, required this.code});
  final String code;

  @override
  ConsumerState<CodeRunPanel> createState() => _CodeRunPanelState();
}

class _CodeRunPanelState extends ConsumerState<CodeRunPanel> {
  RunOutput? _out;
  WebViewController? _web;
  Timer? _timeout;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final config = ref.read(serverConfigProvider).value;
    final engine = (config?['code'] as Map?)?['engine'];
    if (engine == 'jupyter') {
      try {
        final res = await ref
            .read(clientProvider)
            .send(
              'POST',
              '/api/v1/utils/code/execute',
              body: {'code': widget.code},
            );
        _done(RunOutput.from(res is Map ? res : const {}));
      } catch (e) {
        _done(RunOutput(stderr: '$e'));
      }
      return;
    }
    setState(
      () => _web = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted)
        ..addJavaScriptChannel(
          'Out',
          onMessageReceived: (m) {
            try {
              _done(RunOutput.from(jsonDecode(m.message) as Map));
            } catch (e) {
              _done(RunOutput(stderr: '$e'));
            }
          },
        )
        ..loadHtmlString(pyodidePage(widget.code)),
    );
    _timeout = Timer(const Duration(minutes: 2), () {
      if (_out == null) {
        _done(RunOutput(stderr: 'Timed out (is the phone offline?)'));
      }
    });
  }

  void _done(RunOutput out) {
    if (!mounted) return;
    _timeout?.cancel();
    setState(() {
      _out = out;
      _web = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final out = _out;
    final scheme = Theme.of(context).colorScheme;
    Widget part(String label, String text, {Color? color}) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          SelectableText(
            text.trimRight(),
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12.5,
              color: color,
            ),
          ),
        ],
      ),
    );
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (out == null) ...[
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  T('Running…'),
                ],
              ),
            ),
            // Pyodide runs in a page that has to be on screen to run.
            if (_web != null)
              SizedBox(height: 1, child: WebViewWidget(controller: _web!)),
          ] else ...[
            if (out.stdout.trim().isNotEmpty) part('STDOUT', out.stdout),
            if (out.stderr.trim().isNotEmpty)
              part('STDERR', out.stderr, color: scheme.error),
            if (out.result.trim().isNotEmpty) part('RESULT', out.result),
            for (final img in out.images)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Image.memory(
                  base64Decode(img.substring(img.indexOf(',') + 1)),
                ),
              ),
            if (out.stdout.trim().isEmpty &&
                out.stderr.trim().isEmpty &&
                out.result.trim().isEmpty &&
                out.images.isEmpty)
              part('RESULT', 'No output'),
          ],
        ],
      ),
    );
  }
}
