import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/auth/session.dart';
import '../../core/models/chat.dart';
import '../../core/theme.dart';
import 'chat_controller.dart' show userSettingsProvider;
import 'side_panel.dart';
import '../../core/i18n/app_strings.dart';

/// Something a reply built that can be shown live, as in the web UI's
/// Artifacts panel: a web page (its HTML, CSS and JS blocks together) or a
/// picture drawn in SVG.
class Artifact {
  const Artifact({
    required this.isSvg,
    required this.content,
    required this.messageId,
  });
  final bool isSvg;
  final String content;
  final String messageId;

  /// The document the viewer shows.
  String get page => isSvg
      ? '<!DOCTYPE html><html><head><meta charset="UTF-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1.0">'
            '<style>html,body{margin:0;height:100%;background:#fff}'
            'body{display:flex;align-items:center;justify-content:center}'
            'svg{max-width:100%;max-height:100%;height:auto}</style>'
            '</head><body>$content</body></html>'
      : content;
}

final _details = RegExp(r'<details[\s\S]*?</details>');
final _fence = RegExp(r'```[\s\S]*?```');

/// The web UI's getCodeBlockContents: each html block starts a page and the
/// css and js blocks after it join that page; without code blocks, inline
/// `<html>`, `<style>` and `<script>` are used. SVG blocks count when there is no
/// page.
List<Artifact> artifactsOf(String content, String messageId) {
  content = content.replaceAll(_details, '');
  final groups = <({StringBuffer html, StringBuffer css, StringBuffer js})>[];
  void group() {
    if (groups.isEmpty) {
      groups.add((
        html: StringBuffer(),
        css: StringBuffer(),
        js: StringBuffer(),
      ));
    }
  }

  final svgs = <String>[];
  final blocks = _fence.allMatches(content).toList();
  if (blocks.isNotEmpty) {
    for (final b in blocks) {
      final text = b.group(0)!;
      final nl = text.indexOf('\n');
      if (nl < 0) continue;
      final lang = text.substring(3, nl).trim().toLowerCase();
      final code = text.substring(nl + 1, text.length - 3);
      switch (lang) {
        case 'html':
          groups.add((
            html: StringBuffer('$code\n'),
            css: StringBuffer(),
            js: StringBuffer(),
          ));
        case 'css':
          group();
          groups.last.css.write('$code\n');
        case 'javascript' || 'js':
          group();
          groups.last.js.write('$code\n');
        case 'svg':
          svgs.add(code);
        case 'xml' when code.contains('<svg'):
          svgs.add(code);
      }
    }
  } else {
    for (final m in RegExp(
      r'<html>[\s\S]*?</html>',
      caseSensitive: false,
    ).allMatches(content)) {
      groups.add((
        html: StringBuffer(
          '${m.group(0)!.replaceAll(RegExp(r'</?html>', caseSensitive: false), '')}\n',
        ),
        css: StringBuffer(),
        js: StringBuffer(),
      ));
    }
    for (final (tag, pick) in [
      ('style', (g) => g.css as StringBuffer),
      ('script', (g) => g.js as StringBuffer),
    ]) {
      for (final m in RegExp(
        '<$tag>[\\s\\S]*?</$tag>',
        caseSensitive: false,
      ).allMatches(content)) {
        group();
        pick(groups.last).write(
          '${m.group(0)!.replaceAll(RegExp('</?$tag>', caseSensitive: false), '')}\n',
        );
      }
    }
  }
  final pages = [
    for (final g in groups)
      if ('${g.html}${g.css}${g.js}'.trim().isNotEmpty)
        Artifact(
          isSvg: false,
          messageId: messageId,
          content:
              '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="UTF-8">\n'
              '<meta name="viewport" content="width=device-width, initial-scale=1.0">\n'
              '<style>\nbody { background-color: white; }\n${g.css}</style>\n'
              '</head>\n<body>\n${g.html}\n<script>\n${g.js}</script>\n</body>\n</html>\n',
        ),
  ];
  if (pages.isNotEmpty) return pages;
  return [
    for (final s in svgs)
      Artifact(isSvg: true, content: s, messageId: messageId),
  ];
}

/// Every artifact in the conversation, oldest first, as the web UI numbers
/// its versions.
List<Artifact> artifactsOfChat(List<ChatMessage> messages) => [
  for (final m in messages)
    if (m.role != 'user' && m.content.trim().isNotEmpty)
      ...artifactsOf(m.content, m.id),
];

/// The card under a reply that made something to look at.
class ArtifactCard extends StatelessWidget {
  const ArtifactCard({super.key, required this.all, required this.messageId});
  final List<Artifact> all;
  final String messageId;

  @override
  Widget build(BuildContext context) {
    final mine = [
      for (var i = 0; i < all.length; i++)
        if (all[i].messageId == messageId) i,
    ];
    if (mine.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final i in mine)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Material(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => showBeside(
                    context,
                    'artifact:$messageId:$i',
                    (_) => ArtifactScreen(all: all, index: i),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          all[i].isSvg ? Icons.image_outlined : Icons.web,
                          color: NexusColors.accent,
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              all[i].isSvg ? 'Drawing' : 'Web page',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              'Artifact ${i + 1} of ${all.length} · tap to open',
                              style: TextStyle(
                                color: context.nexus.muted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Icon(
                          Icons.open_in_full,
                          size: 18,
                          color: context.nexus.muted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The artifact, running, with its versions and its code.
class ArtifactScreen extends ConsumerStatefulWidget {
  const ArtifactScreen({super.key, required this.all, required this.index});
  final List<Artifact> all;
  final int index;

  @override
  ConsumerState<ArtifactScreen> createState() => _ArtifactScreenState();
}

/// Script run in each artifact page, for Settings > Interface's iframe
/// sandbox switches: without forms, submitting does nothing; with
/// downloads, a download link hands its file to the app.
String artifactGuards({required bool forms, required bool downloads}) => [
  if (!forms)
    "document.addEventListener('submit', function (e) { e.preventDefault(); "
        "e.stopPropagation(); }, true);",
  if (downloads)
    '''
document.addEventListener('click', function (e) {
  var a = e.target && e.target.closest && e.target.closest('a[download]');
  if (!a || !window.NexusDownload) return;
  e.preventDefault();
  var name = a.getAttribute('download') || 'download';
  fetch(a.href).then(function (r) { return r.blob(); }).then(function (b) {
    var reader = new FileReader();
    reader.onload = function () {
      NexusDownload.postMessage(JSON.stringify({name: name, data: reader.result}));
    };
    reader.readAsDataURL(b);
  });
}, true);
''',
].join('\n');

/// The name and bytes a page sent: {name, data: a data: URL}.
(String, Uint8List) downloadFromPage(String message) {
  final m = jsonDecode(message) as Map;
  final data = '${m['data']}';
  final comma = data.indexOf(',');
  final body = data.substring(comma + 1);
  final bytes = data.substring(0, comma).endsWith(';base64')
      ? base64Decode(body)
      : utf8.encode(Uri.decodeComponent(body));
  final name = '${m['name'] ?? ''}'.trim();
  return (name.isEmpty ? 'download' : name, Uint8List.fromList(bytes));
}

class _ArtifactScreenState extends ConsumerState<ArtifactScreen> {
  late int _index = widget.index;
  bool _code = false;
  // Settings > Interface > Artifacts and embeds: scripts, and whether the
  // page counts as the server's own (same origin).
  late final Map<String, dynamic> _ui =
      ((ref.read(userSettingsProvider).value?['ui'] as Map?) ?? const {})
          .cast<String, dynamic>();
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(
      _ui['iframeSandboxAllowScripts'] == false
          ? JavaScriptMode.disabled
          : JavaScriptMode.unrestricted,
    )
    ..setBackgroundColor(Colors.white)
    ..addJavaScriptChannel('NexusDownload', onMessageReceived: _download)
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) => _web.runJavaScript(
          artifactGuards(
            forms: _ui['iframeSandboxAllowForms'] != false,
            downloads: _ui['iframeSandboxAllowDownloads'] != false,
          ),
        ),
        // Links stay inside the artifact, as in the web UI.
        onNavigationRequest: (r) =>
            r.url.startsWith('about:') || r.url.startsWith('data:')
            ? NavigationDecision.navigate
            : NavigationDecision.prevent,
      ),
    );

  Artifact get _artifact => widget.all[_index];

  /// A file the page offers to download, saved where the person picks.
  Future<void> _download(JavaScriptMessage m) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final (name, bytes) = downloadFromPage(m.message);
      final saved = await FilePicker.saveFile(fileName: name, bytes: bytes);
      if (saved != null) {
        messenger.showSnackBar(SnackBar(content: Text('Saved $name')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't save: $e")));
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() => _web.loadHtmlString(
    _artifact.page,
    baseUrl: _ui['iframeSandboxAllowSameOrigin'] == true
        ? ref.read(clientProvider).baseUrl
        : null,
  );

  void _go(int to) {
    setState(() => _index = to);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.all.length;
    return Scaffold(
      appBar: AppBar(
        leading: panelLeading(context),
        title: Text(total > 1 ? 'Version ${_index + 1} of $total' : 'Artifact'),
        actions: [
          IconButton(
            tooltip: tr('Previous version'),
            onPressed: _index > 0 ? () => _go(_index - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          IconButton(
            tooltip: tr('Next version'),
            onPressed: _index < total - 1 ? () => _go(_index + 1) : null,
            icon: const Icon(Icons.chevron_right),
          ),
          IconButton(
            tooltip: _code ? 'Show the result' : 'Show the code',
            isSelected: _code,
            onPressed: () => setState(() => _code = !_code),
            icon: const Icon(Icons.code),
          ),
          IconButton(
            tooltip: tr('Copy the code'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: _artifact.content));
              if (context.mounted) {
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: T('Copied')));
              }
            },
            icon: const Icon(Icons.copy),
          ),
          IconButton(
            tooltip: tr('Reload'),
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: IndexedStack(
        index: _code ? 1 : 0,
        children: [
          WebViewWidget(controller: _web),
          SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _artifact.content,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5),
            ),
          ),
        ],
      ),
    );
  }
}
