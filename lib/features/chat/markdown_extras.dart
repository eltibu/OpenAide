import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:markdown_widget/markdown_widget.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'chat_controller.dart' show serverConfigProvider;
import 'code_run.dart';

/// What the web UI draws in replies beyond plain Markdown: math (KaTeX
/// syntax: `$…$`, `$$…$$`, `\(…\)`, `\[…\]`), Mermaid diagrams, and code
/// blocks with their language and a copy button.
MarkdownGenerator replyMarkdownGenerator() => MarkdownGenerator(
  inlineSyntaxList: [LatexSyntax()],
  generators: [
    SpanNodeGeneratorWithTag(
      tag: LatexSyntax.tag,
      generator: (e, config, visitor) => LatexNode(
        e.attributes['tex'] ?? '',
        display: e.attributes['display'] == 'true',
        raw: e.textContent,
      ),
    ),
  ],
);

/// [base] with code blocks that show their language and a copy button, and
/// Mermaid blocks drawn as diagrams.
/// With [collapse], code blocks start folded to one line.
MarkdownConfig withReplyCode(
  MarkdownConfig base,
  bool dark, {
  bool collapse = false,
}) {
  final pre = dark ? PreConfig.darkConfig : const PreConfig();
  return base.copy(
    configs: [
      pre.copy(
        wrapper: (child, code, language) => language == 'mermaid'
            ? MermaidView(code: code, dark: dark)
            : CodeFrame(
                code: code,
                language: language,
                collapsed: collapse,
                child: child,
              ),
      ),
    ],
  );
}

/// Finds math the way the web UI's KaTeX extension does. A single `$` needs
/// text right next to both signs and no digit after the closing one, so
/// prices like "$5 and $10" stay text.
class LatexSyntax extends m.InlineSyntax {
  LatexSyntax()
    : super(
        r'\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)'
        r'|\$(?![\s$])((?:\\.|[^$\n\\])+?)(?<![\s\\])\$(?!\d)',
      );

  static const tag = 'latex';

  @override
  bool onMatch(m.InlineParser parser, Match match) {
    final display = match[1] != null || match[2] != null;
    final tex = (match[1] ?? match[2] ?? match[3] ?? match[4] ?? '').trim();
    parser.addNode(
      m.Element.text(tag, match[0]!)
        ..attributes['tex'] = tex
        ..attributes['display'] = '$display',
    );
    return true;
  }
}

class LatexNode extends SpanNode {
  LatexNode(this.tex, {required this.display, required this.raw});
  final String tex;
  final bool display;
  final String raw;

  @override
  InlineSpan build() {
    final style = parentStyle ?? const TextStyle();
    final math = Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: style,
      onErrorFallback: (_) => Text(raw, style: style),
    );
    if (!display) {
      return WidgetSpan(alignment: PlaceholderAlignment.middle, child: math);
    }
    return WidgetSpan(
      child: SizedBox(
        width: double.infinity,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: math,
        ),
      ),
    );
  }
}

/// A code block with its language on top and a copy button; [collapsed]
/// starts it folded to a line that opens it.
class CodeFrame extends ConsumerStatefulWidget {
  const CodeFrame({
    super.key,
    required this.code,
    required this.language,
    required this.child,
    this.collapsed = false,
  });
  final String code;
  final String language;
  final Widget child;
  final bool collapsed;

  @override
  ConsumerState<CodeFrame> createState() => _CodeFrameState();
}

class _CodeFrameState extends ConsumerState<CodeFrame> {
  late bool _folded = widget.collapsed;

  /// Bumped for each Run, so a new run replaces the last one's output.
  int _runs = 0;

  bool get _canRun =>
      ((ref.watch(serverConfigProvider).value?['features']
                  as Map?)?['enable_code_execution'] ??
              true) ==
          true &&
      isPythonBlock(widget.language, widget.code);

  void _expand() => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => _CodePage(
        code: widget.code,
        language: widget.language,
        canRun: _canRun,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final code = widget.code;
    final language = widget.language;
    final child = widget.child;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    if (_folded) {
      final lines = '\n'.allMatches(code.trimRight()).length + 1;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _folded = false),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.code, size: 18, color: muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${language.isEmpty ? 'Code' : language} · '
                      '$lines line${lines == 1 ? '' : 's'}',
                      style: TextStyle(color: muted),
                    ),
                  ),
                  Icon(Icons.expand_more, size: 18, color: muted),
                ],
              ),
            ),
          ),
        ),
      );
    }
    Widget small(String tip, IconData icon, VoidCallback onTap) => IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 16,
      color: muted,
      icon: Icon(icon),
      onPressed: onTap,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            child,
            Positioned(
              top: 2,
              right: 2,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (language.isNotEmpty)
                    Text(
                      language,
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: muted),
                    ),
                  if (_canRun)
                    small(
                      'Run',
                      Icons.play_arrow_rounded,
                      () => setState(() => _runs++),
                    ),
                  small('Expand', Icons.open_in_full, _expand),
                  small('Copy code', Icons.copy_outlined, () {
                    Clipboard.setData(ClipboardData(text: code));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Code copied')),
                    );
                  }),
                ],
              ),
            ),
          ],
        ),
        if (_runs > 0) CodeRunPanel(key: ValueKey(_runs), code: code),
      ],
    );
  }
}

/// A code block full screen: wraps long lines, selectable, with Run.
class _CodePage extends StatefulWidget {
  const _CodePage({
    required this.code,
    required this.language,
    required this.canRun,
  });
  final String code;
  final String language;
  final bool canRun;

  @override
  State<_CodePage> createState() => _CodePageState();
}

class _CodePageState extends State<_CodePage> {
  int _runs = 0;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.language.isEmpty ? 'Code' : widget.language),
      actions: [
        if (widget.canRun)
          IconButton(
            tooltip: 'Run',
            icon: const Icon(Icons.play_arrow_rounded),
            onPressed: () => setState(() => _runs++),
          ),
        IconButton(
          tooltip: 'Copy code',
          icon: const Icon(Icons.copy_outlined),
          onPressed: () => Clipboard.setData(ClipboardData(text: widget.code)),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SelectableText(
          widget.code,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        const SizedBox(height: 12),
        if (_runs > 0) CodeRunPanel(key: ValueKey(_runs), code: widget.code),
      ],
    ),
  );
}

/// The page that draws one Mermaid diagram, as the web UI does with
/// mermaid.js, and reports its height so the card fits it.
String mermaidPage(String code, {required bool dark}) {
  final escaped = const HtmlEscape().convert(code);
  return '''<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html,body{margin:0;background:transparent}#d{display:flex;justify-content:center}
#e{font:13px sans-serif;color:#b03a2e;white-space:pre-wrap;padding:8px}</style>
<script src="https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.min.js"></script></head>
<body><div id="d"><pre class="mermaid">$escaped</pre></div><div id="e"></div><script>
function size(){Size.postMessage(String(Math.ceil(document.body.scrollHeight)));}
try{mermaid.initialize({startOnLoad:false,theme:'${dark ? 'dark' : 'default'}',securityLevel:'strict'});
mermaid.run().then(size).catch(function(err){document.getElementById('e').textContent=String(err&&err.message||err);size();});}
catch(err){document.getElementById('e').textContent='Could not load the diagram drawer (offline?)';size();}
</script></body></html>''';
}

/// A Mermaid diagram from a reply; tap for full screen, long-press for the
/// code.
class MermaidView extends StatefulWidget {
  const MermaidView({super.key, required this.code, required this.dark});
  final String code;
  final bool dark;

  @override
  State<MermaidView> createState() => _MermaidViewState();
}

class _MermaidViewState extends State<MermaidView> {
  double _height = 220;
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(Colors.transparent)
    ..addJavaScriptChannel(
      'Size',
      onMessageReceived: (msg) {
        final h = double.tryParse(msg.message);
        if (h != null && mounted) {
          setState(() => _height = h.clamp(80, 900).toDouble());
        }
      },
    )
    ..loadHtmlString(mermaidPage(widget.code, dark: widget.dark));

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _height,
            child: WebViewWidget(controller: _web),
          ),
          Row(
            children: [
              const SizedBox(width: 12),
              Text('Diagram', style: Theme.of(context).textTheme.labelSmall),
              const Spacer(),
              IconButton(
                tooltip: 'Copy the diagram code',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_outlined),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: widget.code)),
              ),
              IconButton(
                tooltip: 'Full screen',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.open_in_full),
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Diagram')),
                      body: WebViewWidget(
                        controller: WebViewController()
                          ..setJavaScriptMode(JavaScriptMode.unrestricted)
                          ..addJavaScriptChannel(
                            'Size',
                            onMessageReceived: (_) {},
                          )
                          ..loadHtmlString(
                            mermaidPage(widget.code, dark: widget.dark),
                          ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Markdown tables in [text] as CSV, one block per table, like the web UI's
/// "Export to CSV" on a table.
List<String> markdownTablesAsCsv(String text) {
  final tables = <String>[];
  final lines = text.split('\n');
  var i = 0;
  bool isRow(String l) => l.trim().startsWith('|') || l.contains(' | ');
  bool isRule(String l) =>
      RegExp(r'^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$').hasMatch(l);
  List<String> cells(String l) {
    var s = l.trim();
    if (s.startsWith('|')) s = s.substring(1);
    if (s.endsWith('|') && !s.endsWith(r'\|')) s = s.substring(0, s.length - 1);
    return s
        .split(RegExp(r'(?<!\\)\|'))
        .map((c) => c.trim().replaceAll(r'\|', '|'))
        .toList();
  }

  String csv(String c) =>
      RegExp(r'[",\n]').hasMatch(c) ? '"${c.replaceAll('"', '""')}"' : c;
  while (i < lines.length - 1) {
    if (isRow(lines[i]) && isRule(lines[i + 1])) {
      final rows = [cells(lines[i])];
      i += 2;
      while (i < lines.length &&
          isRow(lines[i]) &&
          lines[i].trim().isNotEmpty) {
        rows.add(cells(lines[i]));
        i++;
      }
      tables.add(rows.map((r) => r.map(csv).join(',')).join('\n'));
    } else {
      i++;
    }
  }
  return tables;
}
