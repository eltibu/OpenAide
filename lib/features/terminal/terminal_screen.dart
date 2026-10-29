import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../chat/chat_controller.dart' show userSettingsProvider;
import '../chat/file_details.dart' show PdfViewScreen;
import '../server/server_page.dart';
import 'file_tools.dart';
import 'sqlite_view.dart';
import 'terminal_api.dart';
import '../studio/office_preview.dart';
import '../../core/i18n/app_strings.dart';

/// The terminal servers this user may use; empty when none is set up.
final terminalServersProvider = FutureProvider<List<TerminalServer>>((
  ref,
) async {
  try {
    return await terminalServers(ref.watch(clientProvider));
  } catch (_) {
    return const [];
  }
});

/// The admin's terminals and your own (Settings > Terminal connections),
/// for the shell and Files. Chats use the admin's only, as on the web.
final allTerminalsProvider = FutureProvider<List<TerminalServer>>((ref) async {
  final system = await ref.watch(terminalServersProvider.future);
  Map? ui;
  try {
    ui = (await ref.watch(userSettingsProvider.future))['ui'] as Map?;
  } catch (_) {
    // Settings unreachable: the admin's terminals still work.
  }
  return [...system, ...userTerminals(ui)];
});

/// A terminal server's shell and files, like the web UI's terminal panel:
/// a real shell on one tab, a file browser on the other.
class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({
    super.key,
    required this.server,
    this.startInFiles,
    this.openPath,
    this.openIsDir = false,
    this.embedded = false,
    this.onAskFile,
  });
  final TerminalServer server;

  /// Inside a chat: files can be sent to it with a question.
  final AskAboutFile? onAskFile;

  /// Inside the chat's side drawer: only the Terminal / Files switch on
  /// top, no title bar of its own.
  final bool embedded;
  final bool? startInFiles;

  /// A file (opened, in its folder) or folder to show in Files at once.
  final String? openPath;
  final bool openIsDir;

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen>
    with SingleTickerProviderStateMixin {
  late final TerminalApi _api = TerminalApi(
    ref.read(clientProvider),
    widget.server,
  );
  late final TabController _tabs = TabController(
    length: 2,
    vsync: this,
    initialIndex: widget.startInFiles == true || widget.openPath != null
        ? 1
        : 0,
  );
  final _shell = GlobalKey<_ShellViewState>();

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _cdInShell(String dir) {
    _tabs.animateTo(0);
    _shell.currentState?.type("cd '${dir.replaceAll("'", "'\\''")}'\r");
  }

  @override
  Widget build(BuildContext context) {
    final tabs = TabBar(
      controller: _tabs,
      tabs: widget.embedded
          ? const [
              Tab(height: 36, text: 'Terminal'),
              Tab(height: 36, text: 'Files'),
            ]
          : const [
              Tab(icon: Icon(Icons.terminal), text: 'Terminal'),
              Tab(icon: Icon(Icons.folder_outlined), text: 'Files'),
            ],
    );
    return Scaffold(
      appBar: widget.embedded
          ? PreferredSize(
              preferredSize: const Size.fromHeight(37),
              child: Material(child: tabs),
            )
          : AppBar(title: Text(widget.server.name), bottom: tabs),
      body: TabBarView(
        controller: _tabs,
        physics: const NeverScrollableScrollPhysics(),
        children: [
          _ShellView(key: _shell, api: _api),
          FileBrowser(
            api: _api,
            onOpenInTerminal: _cdInShell,
            openPath: widget.openPath,
            openIsDir: widget.openIsDir,
            onAskFile: widget.onAskFile,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- the shell

class _ShellView extends StatefulWidget {
  const _ShellView({super.key, required this.api});
  final TerminalApi api;

  @override
  State<_ShellView> createState() => _ShellViewState();
}

class _ShellViewState extends State<_ShellView>
    with AutomaticKeepAliveClientMixin {
  final _terminal = Terminal(maxLines: 10000);
  final _focus = FocusNode();
  WebSocket? _ws;
  StreamSubscription<dynamic>? _sub;
  String? _id;
  String? _problem;
  bool _connecting = true;
  bool _ctrl = false;
  late final Sink<List<int>> _decoder = const Utf8Decoder(allowMalformed: true)
      .startChunkedConversion(_TerminalSink(_terminal));

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _terminal.onOutput = _output;
    _terminal.onResize = (cols, rows, _, _) =>
        _send(jsonEncode({'type': 'resize', 'cols': cols, 'rows': rows}));
    _connect();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _problem = null;
    });
    try {
      final id = await widget.api.openShell();
      final ws = await widget.api.connect(id);
      _id = id;
      _ws = ws;
      _sub = ws.listen(
        (data) {
          if (data is List<int>) _decoder.add(data);
        },
        onDone: () {
          if (mounted) setState(() => _problem = 'The shell has ended.');
        },
        onError: (_) {
          if (mounted) setState(() => _problem = 'Lost the connection.');
        },
      );
      _send(
        jsonEncode({
          'type': 'resize',
          'cols': _terminal.viewWidth,
          'rows': _terminal.viewHeight,
        }),
      );
      if (mounted) setState(() => _connecting = false);
      _focus.requestFocus();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _problem = '$e';
        });
      }
    }
  }

  void _send(Object data) {
    final ws = _ws;
    if (ws != null && ws.readyState == WebSocket.open) ws.add(data);
  }

  /// What the user types; with Ctrl armed, a letter becomes its control code.
  void _output(String data) {
    if (_ctrl && data.length == 1) {
      final c = data.toUpperCase().codeUnitAt(0);
      if (c >= 0x40 && c <= 0x5f) data = String.fromCharCode(c & 0x1f);
      setState(() => _ctrl = false);
    }
    _send(utf8.encode(data));
  }

  /// Types [text] into the shell, as if from the keyboard.
  void type(String text) => _send(utf8.encode(text));

  Future<void> _reconnect() async {
    await _sub?.cancel();
    await _ws?.close();
    if (_id != null) unawaited(widget.api.closeShell(_id!));
    _terminal.write('\r\n');
    await _connect();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ws?.close();
    if (_id != null) unawaited(widget.api.closeShell(_id!));
    _focus.dispose();
    super.dispose();
  }

  Widget _key(Object label, VoidCallback onTap, {bool on = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: Material(
      color: on ? NexusColors.accent : Colors.white12,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
          _focus.requestFocus();
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: label is IconData
              ? Icon(label, color: Colors.white, size: 18)
              : Text(
                  '$label',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ColoredBox(
      color: const Color(0xFF141413),
      child: Column(
        children: [
          if (_connecting) const LinearProgressIndicator(minHeight: 2),
          if (_problem != null)
            MaterialBanner(
              content: Text(_problem!),
              actions: [
                TextButton(onPressed: _reconnect, child: const T('Reconnect')),
              ],
            ),
          Expanded(
            child: TerminalView(
              _terminal,
              focusNode: _focus,
              autofocus: true,
              padding: const EdgeInsets.all(6),
              keyboardType: TextInputType.visiblePassword,
              deleteDetection: true,
              theme: const TerminalTheme(
                cursor: Color(0xFFF5F4EE),
                selection: Color(0x66C96442),
                foreground: Color(0xFFF5F4EE),
                background: Color(0xFF141413),
                black: Color(0xFF141413),
                red: Color(0xFFE5534B),
                green: Color(0xFF6BC46D),
                yellow: Color(0xFFE2C08D),
                blue: Color(0xFF6CB6FF),
                magenta: Color(0xFFDCBDFB),
                cyan: Color(0xFF76E3EA),
                white: Color(0xFFD0CFC8),
                brightBlack: Color(0xFF6E6D68),
                brightRed: Color(0xFFFF938A),
                brightGreen: Color(0xFF8DDB8C),
                brightYellow: Color(0xFFF0D399),
                brightBlue: Color(0xFF96D0FF),
                brightMagenta: Color(0xFFEECCFF),
                brightCyan: Color(0xFFB3F0FF),
                brightWhite: Color(0xFFFFFFFF),
                searchHitBackground: Color(0xFFC96442),
                searchHitBackgroundCurrent: Color(0xFFE08A6A),
                searchHitForeground: Color(0xFF141413),
              ),
            ),
          ),
          // Keys a phone keyboard doesn't have.
          SafeArea(
            top: false,
            child: SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                children: [
                  _key('Esc', () => _terminal.keyInput(TerminalKey.escape)),
                  _key('Tab', () => _terminal.keyInput(TerminalKey.tab)),
                  _key('Ctrl', () => setState(() => _ctrl = !_ctrl), on: _ctrl),
                  _key(
                    Icons.keyboard_arrow_up,
                    () => _terminal.keyInput(TerminalKey.arrowUp),
                  ),
                  _key(
                    Icons.keyboard_arrow_down,
                    () => _terminal.keyInput(TerminalKey.arrowDown),
                  ),
                  _key(
                    Icons.keyboard_arrow_left,
                    () => _terminal.keyInput(TerminalKey.arrowLeft),
                  ),
                  _key(
                    Icons.keyboard_arrow_right,
                    () => _terminal.keyInput(TerminalKey.arrowRight),
                  ),
                  for (final c in ['|', '~', '/', '-', '>', '\$', '&'])
                    _key(c, () => _terminal.textInput(c)),
                  _key('^C', () => type('\x03')),
                  _key('Paste', () async {
                    final clip = await Clipboard.getData('text/plain');
                    final text = clip?.text;
                    if (text != null) _terminal.paste(text);
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalSink implements Sink<String> {
  _TerminalSink(this.terminal);
  final Terminal terminal;
  @override
  void add(String data) => terminal.write(data);
  @override
  void close() {}
}

// ---------------------------------------------------------------- the files

/// Browses, opens, edits, uploads and organizes the terminal server's files.
class FileBrowser extends StatefulWidget {
  const FileBrowser({
    super.key,
    required this.api,
    this.onOpenInTerminal,
    this.openPath,
    this.openIsDir = false,
    this.onAskFile,
  });
  final TerminalApi api;
  final void Function(String dir)? onOpenInTerminal;
  final AskAboutFile? onAskFile;

  /// Where to start instead of the server's own folder: a folder, or a file
  /// that opens on top of its folder (with its row marked).
  final String? openPath;
  final bool openIsDir;

  @override
  State<FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<FileBrowser>
    with AutomaticKeepAliveClientMixin {
  String? _home;
  String? _dir;
  TerminalListing? _listing;
  Object? _error;
  bool _busy = true;

  /// The file a reply pointed at, marked in its folder.
  String? _marked;

  // How the list is shown; kept while the app runs.
  static FileSort _sortBy = FileSort.name;
  static bool _descending = false;
  static bool _showHidden = false;
  static bool _grid = false;

  /// Folders visited, to go back and forward like the web's Files.
  final _back = <String>[];
  final _forward = <String>[];

  /// Picked rows (paths); while any are, taps pick instead of open.
  final _picked = <String>{};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      final at = await widget.api.cwd();
      _home = at.home;
      final target = widget.openPath;
      if (target == null) {
        await _open(at.cwd);
      } else if (widget.openIsDir) {
        await _open(target);
      } else {
        _marked = target;
        await _open(parentPath(target));
        if (mounted && _dir != null) {
          await _openFile(target, target.split('/').last);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _busy = false;
        });
      }
    }
  }

  /// Opens [dir] as a new step: back returns here, forward is cleared.
  Future<void> _go(String dir) {
    final at = _dir;
    if (at != null && at != dir) {
      _back.add(at);
      _forward.clear();
    }
    return _open(dir);
  }

  Future<void> _goBack() {
    final at = _dir;
    if (at != null) _forward.add(at);
    return _open(_back.removeLast());
  }

  Future<void> _goForward() {
    final at = _dir;
    if (at != null) _back.add(at);
    return _open(_forward.removeLast());
  }

  Future<void> _open(String dir) async {
    setState(() => _busy = true);
    try {
      final listing = await widget.api.list(dir);
      if (!mounted) return;
      setState(() {
        if (listing.dir != _dir) _picked.clear();
        _listing = listing;
        _dir = listing.dir;
        _error = null;
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _busy = false;
        });
      }
    }
  }

  Future<void> _refresh() => _open(_dir ?? _home ?? '.');

  void _toast(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(message))));

  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
      if (mounted) _toast(done);
    } catch (e) {
      if (mounted) _toast('$e');
    }
    await _refresh();
  }

  Future<String?> _ask(String title, {String initial = ''}) {
    final text = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: text,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text.trim()),
            child: const T('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _upload() async {
    final dir = _dir;
    if (dir == null) return;
    final picked = await FilePicker.pickFiles();
    for (final f in picked) {
      await _run(
        () async => widget.api.upload(dir, await f.readAsBytes(), f.name),
        'Uploaded ${f.name}',
      );
    }
  }

  /// A folder from the phone, with everything in it, into this folder.
  Future<void> _uploadFolder() async {
    final dir = _dir;
    if (dir == null) return;
    final from = await FilePicker.getDirectoryPath();
    if (from == null) return;
    final root = Directory(from);
    final name = root.uri.pathSegments.where((p) => p.isNotEmpty).last;
    List<File> files;
    try {
      files = [
        for (final f in root.listSync(recursive: true, followLinks: false))
          if (f is File &&
              !f.path
                  .substring(from.length)
                  .split('/')
                  .any((p) => p.startsWith('.')))
            f,
      ];
    } catch (e) {
      _toast("Couldn't read that folder: $e");
      return;
    }
    if (files.isEmpty) {
      _toast(
        "Nothing in $name could be read. Android may keep this "
        "folder private; try picking the files instead.",
      );
      return;
    }
    setState(() => _busy = true);
    var sent = 0;
    final made = <String>{};
    for (final f in files) {
      final rel = f.path.substring(from.length).replaceFirst(RegExp('^/'), '');
      final parts = rel.split('/');
      var target = joinPath(dir, name);
      for (final p in [null, ...parts.take(parts.length - 1)]) {
        if (p != null) target = joinPath(target, p);
        if (made.add(target)) {
          try {
            await widget.api.mkdir(target);
          } catch (_) {
            // Already there.
          }
        }
      }
      try {
        await widget.api.upload(target, await f.readAsBytes(), parts.last);
        sent++;
      } catch (e) {
        if (mounted) _toast('${parts.last}: $e');
      }
    }
    if (mounted) _toast('Uploaded $sent of ${files.length} files from $name');
    await _refresh();
  }

  Future<void> _newFolder() async {
    final name = await _ask('New folder');
    if (name == null || name.isEmpty || _dir == null) return;
    await _run(() => widget.api.mkdir(joinPath(_dir!, name)), 'Created $name');
  }

  Future<void> _newFile() async {
    final name = await _ask('New file');
    if (name == null || name.isEmpty || _dir == null) return;
    final path = joinPath(_dir!, name);
    await _run(() => widget.api.write(path, ''), 'Created $name');
    if (mounted) await _openFile(path, name);
  }

  Future<void> _entryMenu(TerminalEntry e) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  e.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(e.path),
              ),
              if (e.isDir && widget.onOpenInTerminal != null)
                ListTile(
                  leading: const Icon(Icons.terminal),
                  title: const T('Open in terminal'),
                  onTap: () => Navigator.pop(context, 'terminal'),
                ),
              if (!e.isDir)
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: const T('Download to phone'),
                  onTap: () => Navigator.pop(context, 'download'),
                ),
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const T('Select'),
                onTap: () => Navigator.pop(context, 'select'),
              ),
              ListTile(
                leading: const Icon(Icons.copy),
                title: const T('Copy path'),
                onTap: () => Navigator.pop(context, 'copy'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline),
                title: const T('Rename'),
                onTap: () => Navigator.pop(context, 'rename'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const T('Delete'),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'terminal':
        widget.onOpenInTerminal!(e.path);
      case 'download':
        await _download(e);
      case 'select':
        _toggle(e);
      case 'copy':
        await Clipboard.setData(ClipboardData(text: e.path));
        _toast('Path copied');
      case 'rename':
        final name = await _ask('Rename', initial: e.name);
        if (name == null || name.isEmpty || name == e.name) return;
        await _run(
          () => widget.api.move(e.path, joinPath(parentPath(e.path), name)),
          'Renamed to $name',
        );
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Delete ${e.name}?'),
            content: Text(
              e.isDir
                  ? 'The folder and everything in it will be deleted from the server.'
                  : 'The file will be deleted from the server.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const T('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const T('Delete'),
              ),
            ],
          ),
        );
        if (ok == true) {
          await _run(() => widget.api.delete(e.path), 'Deleted ${e.name}');
        }
    }
  }

  List<TerminalEntry> get _shown => visibleEntries(
    sortEntries(
      _listing?.entries ?? const [],
      _sortBy,
      descending: _descending,
    ),
    showHidden: _showHidden,
  );

  List<TerminalEntry> get _pickedEntries => [
    for (final e in _listing?.entries ?? const <TerminalEntry>[])
      if (_picked.contains(e.path)) e,
  ];

  void _toggle(TerminalEntry e) => setState(
    () =>
        _picked.contains(e.path) ? _picked.remove(e.path) : _picked.add(e.path),
  );

  /// Saves a file from the server to the phone, where the person picks.
  Future<void> _download(TerminalEntry e) async {
    try {
      final bytes = await widget.api.read(e.path);
      final saved = await FilePicker.saveFile(
        fileName: e.name,
        bytes: Uint8List.fromList(bytes),
      );
      if (saved != null && mounted) _toast('Saved ${e.name}');
    } catch (err) {
      if (mounted) _toast("Couldn't download ${e.name}: $err");
    }
  }

  Future<void> _deletePicked() async {
    final list = _pickedEntries;
    if (list.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Delete ${list.length} item${list.length == 1 ? '' : 's'}?',
        ),
        content: const T(
          'They will be deleted from the server, folders with everything in them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const T('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const T('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(_picked.clear);
    await _run(() async {
      for (final e in list) {
        await widget.api.delete(e.path);
      }
    }, 'Deleted ${list.length}');
  }

  Future<void> _movePicked() async {
    final list = _pickedEntries;
    if (list.isEmpty || _dir == null) return;
    final to = await _ask('Move to folder', initial: _dir!);
    if (to == null || to.isEmpty || to == _dir) return;
    setState(_picked.clear);
    await _run(() async {
      for (final e in list) {
        await widget.api.move(e.path, joinPath(to, e.name));
      }
    }, 'Moved ${list.length} to $to');
  }

  Future<void> _downloadPicked() async {
    for (final e in _pickedEntries.where((e) => !e.isDir)) {
      await _download(e);
    }
  }

  Future<void> _compare() async {
    final files = _pickedEntries.where((e) => !e.isDir).toList();
    if (files.length != 2) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            CompareScreen(api: widget.api, first: files[0], second: files[1]),
      ),
    );
  }

  Widget _selectionBar() {
    final files = _pickedEntries.where((e) => !e.isDir).length;
    return Row(
      children: [
        IconButton(
          tooltip: tr('Done'),
          icon: const Icon(Icons.close),
          onPressed: () => setState(_picked.clear),
        ),
        Expanded(child: Text('${_picked.length} selected')),
        IconButton(
          tooltip: tr('Select all'),
          icon: const Icon(Icons.select_all),
          onPressed: () =>
              setState(() => _picked.addAll(_shown.map((e) => e.path))),
        ),
        if (files == 2 && _picked.length == 2)
          IconButton(
            tooltip: tr('Compare'),
            icon: const Icon(Icons.difference_outlined),
            onPressed: _compare,
          ),
        if (files > 0)
          IconButton(
            tooltip: tr('Download'),
            icon: const Icon(Icons.download_outlined),
            onPressed: _downloadPicked,
          ),
        IconButton(
          tooltip: tr('Move'),
          icon: const Icon(Icons.drive_file_move_outlined),
          onPressed: _movePicked,
        ),
        IconButton(
          tooltip: tr('Delete'),
          icon: const Icon(Icons.delete_outline),
          onPressed: _deletePicked,
        ),
      ],
    );
  }

  /// What's serving on the server's ports, each openable in the app
  /// through Open WebUI (the web's port preview).
  Future<void> _ports() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: FutureBuilder(
          future: widget.api.ports(),
          builder: (context, snap) {
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snap.error}'),
              );
            }
            final list = snap.data;
            if (list == null) {
              return const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (list.isEmpty) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: T(
                  'Nothing is listening on a port. Start a server in the '
                  'terminal (for example python -m http.server 8000).',
                ),
              );
            }
            return ListView(
              shrinkWrap: true,
              children: [
                for (final p in list)
                  ListTile(
                    leading: const Icon(Icons.public),
                    title: Text('Port ${p.port}'),
                    subtitle: p.process.isEmpty ? null : Text(p.process),
                    trailing: IconButton(
                      tooltip: tr('Copy address'),
                      icon: const Icon(Icons.link),
                      onPressed: () => Clipboard.setData(
                        ClipboardData(
                          text: widget.api.client
                              .uri(widget.api.proxyPath(p.port))
                              .toString(),
                        ),
                      ),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      Navigator.push(
                        this.context,
                        MaterialPageRoute<void>(
                          builder: (_) => ServerPage(
                            title: 'Port ${p.port}',
                            browse: true,
                            // Your own terminal: at its own address.
                            path: widget.api.server.direct
                                ? ''
                                : widget.api.proxyPath(p.port),
                            url: widget.api.server.direct
                                ? widget.api.client
                                      .uri(widget.api.proxyPath(p.port))
                                      .toString()
                                : null,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _viewMenu() => PopupMenuButton<String>(
    tooltip: tr('Sort and show'),
    icon: const Icon(Icons.sort),
    onSelected: (v) => setState(() {
      switch (v) {
        case 'hidden':
          _showHidden = !_showHidden;
        case 'desc':
          _descending = !_descending;
        case 'select':
          final first = _shown.firstOrNull;
          if (first != null) _picked.add(first.path);
        case 'ports':
          _ports();
        case 'grid':
          _grid = !_grid;
        default:
          _sortBy = FileSort.values.byName(v);
      }
    }),
    itemBuilder: (_) => [
      for (final (by, label) in const [
        (FileSort.name, 'Name'),
        (FileSort.size, 'Size'),
        (FileSort.modified, 'Date modified'),
      ])
        CheckedPopupMenuItem(
          value: by.name,
          checked: _sortBy == by,
          child: Text('Sort by $label'),
        ),
      CheckedPopupMenuItem(
        value: 'desc',
        checked: _descending,
        child: const T('Reverse order'),
      ),
      const PopupMenuDivider(),
      CheckedPopupMenuItem(
        value: 'grid',
        checked: _grid,
        child: const T('Grid view'),
      ),
      CheckedPopupMenuItem(
        value: 'hidden',
        checked: _showHidden,
        child: const T('Show hidden files'),
      ),
      const PopupMenuItem(value: 'select', child: T('Select…')),
      const PopupMenuItem(value: 'ports', child: T('Running web pages')),
    ],
  );

  Widget _gridTile(TerminalEntry e) {
    final muted = context.nexus.muted;
    final picked = _picked.contains(e.path);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _tap(e),
      onLongPress: () => _picked.isNotEmpty ? _toggle(e) : _entryMenu(e),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: picked || e.path == _marked
              ? NexusColors.accent.withValues(alpha: 0.12)
              : null,
        ),
        padding: const EdgeInsets.all(6),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _picked.isNotEmpty
                  ? (picked ? Icons.check_circle : Icons.radio_button_unchecked)
                  : e.isDir
                  ? Icons.folder
                  : _iconFor(e.name),
              size: 40,
              color: e.isDir ? NexusColors.accent : muted,
            ),
            const SizedBox(height: 6),
            Text(
              e.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  void _tap(TerminalEntry e) => _picked.isNotEmpty
      ? _toggle(e)
      : e.isDir
      ? _go(e.path)
      : _openFile(e.path, e.name);

  Future<void> _openFile(String path, String name) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => FileViewer(
          api: widget.api,
          path: path,
          name: name,
          onAsk: widget.onAskFile,
        ),
      ),
    );
    if (mounted) await _refresh();
  }

  List<(String, String)> _crumbs(String dir) {
    final home = _home;
    final out = <(String, String)>[];
    var rest = dir;
    var prefix = '';
    if (home != null && (dir == home || dir.startsWith('$home/'))) {
      out.add(('Home', home));
      rest = dir.substring(home.length);
      prefix = home;
    } else {
      out.add(('/', '/'));
    }
    for (final part in rest.split('/').where((p) => p.isNotEmpty)) {
      prefix = prefix == '/' ? '/$part' : '$prefix/$part';
      out.add((part, prefix));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final listing = _listing;
    final dir = _dir;
    final muted = context.nexus.muted;
    return Scaffold(
      floatingActionButton: dir == null
          ? null
          : FloatingActionButton(
              tooltip: tr('Add'),
              onPressed: () async {
                final choice = await showModalBottomSheet<String>(
                  context: context,
                  showDragHandle: true,
                  builder: (context) => SafeArea(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        ListTile(
                          leading: const Icon(Icons.upload_file),
                          title: const T('Upload from phone'),
                          onTap: () => Navigator.pop(context, 'upload'),
                        ),
                        ListTile(
                          leading: const Icon(Icons.drive_folder_upload),
                          title: const T('Upload Folder'),
                          onTap: () => Navigator.pop(context, 'dir'),
                        ),
                        ListTile(
                          leading: const Icon(Icons.create_new_folder_outlined),
                          title: const T('New folder'),
                          onTap: () => Navigator.pop(context, 'folder'),
                        ),
                        ListTile(
                          leading: const Icon(Icons.note_add_outlined),
                          title: const T('New file'),
                          onTap: () => Navigator.pop(context, 'file'),
                        ),
                      ],
                    ),
                  ),
                );
                switch (choice) {
                  case 'upload':
                    await _upload();
                  case 'dir':
                    await _uploadFolder();
                  case 'folder':
                    await _newFolder();
                  case 'file':
                    await _newFile();
                }
              },
              child: const Icon(Icons.add),
            ),
      body: Column(
        children: [
          if (_busy) const LinearProgressIndicator(minHeight: 2),
          if (dir != null && _picked.isNotEmpty)
            SizedBox(height: 48, child: _selectionBar())
          else if (dir != null)
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  IconButton(
                    tooltip: tr('Back'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _back.isEmpty ? null : _goBack,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  IconButton(
                    tooltip: tr('Forward'),
                    visualDensity: VisualDensity.compact,
                    onPressed: _forward.isEmpty ? null : _goForward,
                    icon: const Icon(Icons.chevron_right),
                  ),
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      reverse: true,
                      children: [
                        for (final (label, path) in _crumbs(dir).reversed)
                          Row(
                            children: [
                              TextButton(
                                onPressed: path == dir ? null : () => _go(path),
                                child: Text(label),
                              ),
                              if (path != dir)
                                Icon(
                                  Icons.chevron_right,
                                  size: 16,
                                  color: muted,
                                ),
                            ],
                          ),
                      ].reversed.toList(),
                    ),
                  ),
                  _viewMenu(),
                ],
              ),
            ),
          Expanded(
            child: _error != null && listing == null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('$_error', textAlign: TextAlign.center),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: _start,
                            child: const T('Try again'),
                          ),
                        ],
                      ),
                    ),
                  )
                : listing == null
                ? const SizedBox.shrink()
                : RefreshIndicator(
                    onRefresh: _refresh,
                    child: ListView(
                      padding: const EdgeInsets.only(bottom: 88),
                      children: [
                        if (dir != '/')
                          ListTile(
                            leading: const Icon(Icons.arrow_upward),
                            title: const T('..'),
                            onTap: () => _go(parentPath(dir!)),
                          ),
                        if (_shown.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(32),
                            child: Center(
                              child: T(
                                'This folder is empty',
                                style: TextStyle(color: muted),
                              ),
                            ),
                          ),
                        if (_grid)
                          GridView.extent(
                            maxCrossAxisExtent: 112,
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(8),
                            children: [for (final e in _shown) _gridTile(e)],
                          )
                        else
                          for (final e in _shown)
                            ListTile(
                              selected:
                                  e.path == _marked || _picked.contains(e.path),
                              leading: _picked.isNotEmpty
                                  ? Icon(
                                      _picked.contains(e.path)
                                          ? Icons.check_circle
                                          : Icons.radio_button_unchecked,
                                    )
                                  : Icon(
                                      e.isDir ? Icons.folder : _iconFor(e.name),
                                      color: e.isDir
                                          ? NexusColors.accent
                                          : muted,
                                    ),
                              title: Text(e.name),
                              subtitle: Text(
                                [
                                  if (!e.isDir && e.size != null)
                                    _size(e.size!),
                                  if (e.modified != null) _when(e.modified!),
                                ].join(' · '),
                                style: TextStyle(color: muted, fontSize: 12),
                              ),
                              onTap: () => _tap(e),
                              onLongPress: () => _picked.isNotEmpty
                                  ? _toggle(e)
                                  : _entryMenu(e),
                              trailing: _picked.isNotEmpty
                                  ? null
                                  : IconButton(
                                      icon: const Icon(Icons.more_vert),
                                      onPressed: () => _entryMenu(e),
                                    ),
                            ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

const _imageTypes = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'};

String _ext(String name) {
  final i = name.lastIndexOf('.');
  return i < 0 ? '' : name.substring(i + 1).toLowerCase();
}

IconData _iconFor(String name) {
  final ext = _ext(name);
  if (_imageTypes.contains(ext)) return Icons.image_outlined;
  if (const {'pdf'}.contains(ext)) return Icons.picture_as_pdf_outlined;
  if (const {'zip', 'gz', 'tar', 'xz', '7z'}.contains(ext)) {
    return Icons.folder_zip_outlined;
  }
  if (const {'mp3', 'wav', 'ogg', 'flac', 'm4a'}.contains(ext)) {
    return Icons.audio_file_outlined;
  }
  if (const {'mp4', 'mkv', 'mov', 'webm'}.contains(ext)) {
    return Icons.video_file_outlined;
  }
  return Icons.description_outlined;
}

String _size(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

String _when(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  if (d.inDays < 7) return '${d.inDays} d ago';
  return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
}

/// Shows a file: pictures as pictures, text as editable text.
/// Sends a file and a message about it to the chat this terminal is part of.
typedef AskAboutFile = Future<void> Function(
  String message,
  List<int> bytes,
  String name,
);

/// The message the web's "Ask or edit" box sends: the picked lines quoted,
/// with where they are, then what was asked.
String fileAskMessage(
  String path,
  String text,
  TextSelection selection,
  String instruction,
) {
  if (!selection.isValid || selection.isCollapsed) return instruction;
  final start = selection.start.clamp(0, text.length);
  final end = selection.end.clamp(0, text.length);
  final picked = text.substring(start, end);
  final first = '\n'.allMatches(text.substring(0, start)).length + 1;
  final last = first + '\n'.allMatches(picked.trimRight()).length;
  final where = first == last ? '$path:$first' : '$path:$first-$last';
  final quote = [
    where,
    picked,
  ].join('\n').split('\n').map((l) => '> $l').join('\n');
  return '$quote\n\n$instruction';
}

class FileViewer extends StatefulWidget {
  const FileViewer({
    super.key,
    required this.api,
    required this.path,
    required this.name,
    this.onAsk,
  });
  final TerminalApi api;
  final String path;
  final String name;

  /// Set inside a chat: an "Ask or edit" box sends the file there.
  final AskAboutFile? onAsk;

  @override
  State<FileViewer> createState() => _FileViewerState();
}

class _FileViewerState extends State<FileViewer> {
  List<int>? _bytes;
  String? _text;
  Object? _error;
  final _edit = TextEditingController();
  final _ask = TextEditingController();
  bool _asking = false;

  Future<void> _send() async {
    final instruction = _ask.text.trim();
    final bytes = _bytes;
    if (instruction.isEmpty || bytes == null || _asking) return;
    setState(() => _asking = true);
    try {
      if (_dirty) await _save();
      final latest = _text == null ? bytes : utf8.encode(_edit.text);
      await widget.onAsk!(
        fileAskMessage(widget.path, _edit.text, _edit.selection, instruction),
        latest,
        widget.name,
      );
      _ask.clear();
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: T('Sent to the chat')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Not sent: $e')));
      }
    }
    if (mounted) setState(() => _asking = false);
  }

  bool _dirty = false;
  bool _saving = false;

  bool get _image => _imageTypes.contains(_ext(widget.name));
  bool get _notebook => _ext(widget.name) == 'ipynb';
  bool get _pdf => _ext(widget.name) == 'pdf';
  bool get _sqlite =>
      const {'db', 'sqlite', 'sqlite3', 'db3'}.contains(_ext(widget.name));

  /// Notebooks show as cells; this switches to their raw text to edit.
  bool _raw = false;
  final _zoom = TransformationController();

  void _zoomBy(double factor) {
    final scale = (_zoom.value.getMaxScaleOnAxis() * factor).clamp(1.0, 8.0);
    _zoom.value = Matrix4.diagonal3Values(scale, scale, 1);
  }

  Future<void> _download() async {
    final bytes = _bytes;
    if (bytes == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await FilePicker.saveFile(
        fileName: widget.name,
        bytes: Uint8List.fromList(bytes),
      );
      if (saved != null) {
        messenger.showSnackBar(SnackBar(content: Text('Saved ${widget.name}')));
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

  Future<void> _load() async {
    try {
      final bytes = await widget.api.read(widget.path);
      String? text;
      if (!_image && !_sqlite) {
        try {
          text = utf8.decode(bytes);
        } on FormatException {
          text = null;
        }
      }
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _text = text;
        if (text != null) _edit.text = text;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.api.write(widget.path, _edit.text);
      if (!mounted) return;
      setState(() => _dirty = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: T('Saved')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _zoom.dispose();
    _edit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (popped, _) async {
        if (popped) return;
        final leave = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const T('Discard your changes?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const T('Keep editing'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const T('Discard'),
              ),
            ],
          ),
        );
        if (leave == true && context.mounted) {
          setState(() => _dirty = false);
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.name),
          actions: [
            IconButton(
              tooltip: tr('Copy path'),
              icon: const Icon(Icons.link),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: widget.path));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Copied ${widget.path}')),
                );
              },
            ),
            if (_image) ...[
              IconButton(
                tooltip: tr('Zoom out'),
                icon: const Icon(Icons.zoom_out),
                onPressed: () => _zoomBy(1 / 1.5),
              ),
              IconButton(
                tooltip: tr('Zoom in'),
                icon: const Icon(Icons.zoom_in),
                onPressed: () => _zoomBy(1.5),
              ),
            ],
            if (_notebook && _text != null)
              IconButton(
                tooltip: _raw ? 'Show cells' : 'Edit as text',
                icon: Icon(_raw ? Icons.view_agenda_outlined : Icons.edit_note),
                onPressed: () => setState(() => _raw = !_raw),
              ),
            if (_bytes != null)
              IconButton(
                tooltip: tr('Download to phone'),
                icon: const Icon(Icons.download_outlined),
                onPressed: _download,
              ),
            if (_text != null)
              IconButton(
                tooltip: tr('Copy all'),
                icon: const Icon(Icons.copy),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: _edit.text)),
              ),
            if (_dirty)
              IconButton(
                tooltip: tr('Save'),
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                onPressed: _saving ? null : _save,
              ),
          ],
        ),
        body: _error != null
            ? Center(child: Text('$_error'))
            : bytes == null
            ? const Center(child: CircularProgressIndicator())
            : _sqlite
            ? SqliteView(bytes: bytes, name: widget.name)
            : _image
            ? InteractiveViewer(
                transformationController: _zoom,
                maxScale: 8,
                child: Center(child: Image.memory(Uint8List.fromList(bytes))),
              )
            : _pdf
            ? Center(
                child: FilledButton.icon(
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: Text('Open PDF (${_size(bytes.length)})'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => PdfViewScreen(
                        name: widget.name,
                        bytes: Uint8List.fromList(bytes),
                      ),
                    ),
                  ),
                ),
              )
            : _text == null && isOfficeFile(widget.name)
            ? Center(
                child: FilledButton.icon(
                  icon: const Icon(Icons.description_outlined),
                  label: Text('Preview (${_size(bytes.length)})'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => OfficePreviewScreen(
                        name: widget.name,
                        bytes: Uint8List.fromList(bytes),
                      ),
                    ),
                  ),
                ),
              )
            : _text == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    "This file can't be shown here (${_size(bytes.length)}).",
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : _notebook && !_raw
            ? NotebookView(
                source: _edit.text,
                api: widget.api,
                path: widget.path,
              )
            : TextField(
                controller: _edit,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.all(12),
                ),
                onChanged: (_) {
                  if (!_dirty) setState(() => _dirty = true);
                },
              ),
        bottomNavigationBar: widget.onAsk == null || _bytes == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                    12,
                    6,
                    6,
                    6 + MediaQuery.of(context).viewInsets.bottom,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _ask,
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _send(),
                          decoration: InputDecoration(
                            hintText: tr('Ask or edit…'),
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: tr('Send'),
                        onPressed: _asking ? null : _send,
                        icon: _asking
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.arrow_upward),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
