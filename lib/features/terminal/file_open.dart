import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_panel.dart' show showChatPanel;
import 'file_links.dart';
import 'terminal_api.dart';
import 'terminal_screen.dart';
import '../../core/i18n/app_strings.dart';

/// Opens the file [file] names in the Files browser of a terminal server:
/// [terminalId] when given (the chat's), else the first one. A full path
/// opens at once; a bare name is looked up first, and when several files
/// have it, the person picks one.
Future<void> openFileRef(
  BuildContext context,
  WidgetRef ref,
  FileRef file, {
  String? terminalId,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  void say(String text) {
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(tr(text)),
          action: SnackBarAction(
            label: 'Copy',
            onPressed: () =>
                Clipboard.setData(ClipboardData(text: file.toString())),
          ),
        ),
      );
  }

  final List<TerminalServer> servers;
  try {
    servers = await ref.read(terminalServersProvider.future);
  } catch (_) {
    say("Couldn't reach the server's Files");
    return;
  }
  if (servers.isEmpty) {
    say('No Files server is connected to Open WebUI');
    return;
  }
  final server =
      servers.where((s) => s.id == terminalId).firstOrNull ?? servers.first;
  final api = TerminalApi(ref.read(clientProvider), server);

  void open(String path, {bool isDir = false}) {
    messenger.hideCurrentSnackBar();
    if (!context.mounted) return;
    // In the chat's side drawer, so the chat stays in view.
    showChatPanel(
      context,
      tab: 1,
      serverId: server.id,
      openPath: path,
      openIsDir: isDir,
    );
  }

  String home;
  try {
    home = (await api.cwd()).home;
  } catch (e) {
    say("Couldn't open Files: $e");
    return;
  }

  var lookFor = file;
  if (file.path != null) {
    var path = file.path!;
    if (path.startsWith('~/')) path = joinPath(home, path.substring(2));
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    final name = path.split('/').last;
    try {
      final listing = await api.list(parentPath(path));
      final entry = listing.entries.where((e) => e.name == name).firstOrNull;
      if (entry != null) {
        open(entry.path, isDir: entry.isDir);
        return;
      }
    } catch (_) {
      // Not there (or not allowed); look the name up instead.
    }
    if (fileRefIn(name)?.name == null) {
      say("Couldn't find $path");
      return;
    }
    lookFor = FileRef.name(name);
  }

  final name = lookFor.name!;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text('Looking for $name…'),
        duration: const Duration(seconds: 20),
      ),
    );
  final List<({String path, String name, bool isDir})> hits;
  try {
    hits = await api.search(name, dir: home);
  } catch (e) {
    say("Couldn't search Files: $e");
    return;
  }
  final found = rankMatches(lookFor, [
    for (final h in hits) (path: h.path, name: h.name),
  ]);
  final dirs = {
    for (final h in hits)
      if (h.isDir) h.path,
  };
  if (found.paths.isEmpty) {
    say("Couldn't find $name in ${server.name}");
    return;
  }
  if (found.exact && found.paths.length == 1) {
    final p = found.paths.single;
    open(p, isDir: dirs.contains(p));
    return;
  }
  messenger.hideCurrentSnackBar();
  if (!context.mounted) return;
  final picked = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                found.exact
                    ? '${found.paths.length} files are called $name'
                    : 'No file is called $name. Close matches:',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final p in found.paths.take(30))
                    ListTile(
                      leading: Icon(
                        dirs.contains(p)
                            ? Icons.folder
                            : Icons.description_outlined,
                      ),
                      title: Text(p.split('/').last),
                      subtitle: Text(
                        parentPath(p),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => Navigator.pop(context, p),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  if (picked != null) open(picked, isDir: dirs.contains(picked));
}

/// Reply Markdown where `inline code` that names a file looks like a link
/// and opens it in Files when tapped ([onFile]), and links to files do the
/// same. Selecting the text to copy it still works as before.
MarkdownGenerator withFileTaps(
  MarkdownGenerator base,
  void Function(FileRef file) onFile,
) => MarkdownGenerator(
  inlineSyntaxList: base.inlineSyntaxList,
  blockSyntaxList: base.blockSyntaxList,
  generators: [
    ...base.generators,
    SpanNodeGeneratorWithTag(
      tag: MarkdownTag.code.name,
      generator: (e, config, visitor) =>
          FileCodeNode(e.textContent, config.code, onFile),
    ),
  ],
);

/// [base] whose links open files in Files, and the web as before.
/// [onLink] goes first and says whether it opened the link itself.
MarkdownConfig withFileLinks(
  MarkdownConfig base,
  void Function(FileRef file) onFile, {
  bool Function(String url)? onLink,
}) => base.copy(
  configs: [
    LinkConfig(
      style: base.a.style,
      onTap: (url) {
        if (onLink?.call(url) == true) return;
        final file = fileRefIn(url);
        if (file != null) {
          onFile(file);
        } else {
          final uri = Uri.tryParse(url);
          if (uri != null) {
            launchUrl(uri);
          }
        }
      },
    ),
  ],
);

/// Inline code; a file's name or path is tappable.
class FileCodeNode extends ElementNode {
  FileCodeNode(this.text, this.codeConfig, this.onFile);
  final String text;
  final CodeConfig codeConfig;
  final void Function(FileRef file) onFile;

  @override
  InlineSpan build() {
    final file = fileRefIn(text);
    if (file == null) return TextSpan(style: style, text: text);
    return TextSpan(
      text: text,
      style: style.merge(
        const TextStyle(
          color: NexusColors.accent,
          decoration: TextDecoration.underline,
          decorationStyle: TextDecorationStyle.dotted,
          decorationColor: NexusColors.accent,
        ),
      ),
      recognizer: TapGestureRecognizer()..onTap = () => onFile(file),
      mouseCursor: SystemMouseCursors.click,
    );
  }

  @override
  TextStyle get style => codeConfig.style.merge(parentStyle);
}
