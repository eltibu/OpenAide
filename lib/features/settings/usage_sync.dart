/// Sync Usage Stats with Open WebUI Community, as the web's sync window.
/// On the web the community site opens your server in a popup and the two
/// pass messages; here the community site opens in the app, and the app
/// stands in for that popup: it answers the site's requests with your
/// stats (counts and timestamps only, never what was said) once you agree,
/// or saves them as a JSON file instead.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/api/openwebui_client.dart';
import '../../core/auth/session.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../server/community_share.dart' show communityUrl;

/// Every page of /chats/stats/export from [page] on, as the server sends
/// them; [onPage] sees each with the running count and the total. Stops
/// early when [stopped] says so.
Future<List<Map>> exportUsageStats(
  OpenWebUiClient client, {
  Map<String, String> query = const {},
  void Function(Map page, int done, int total)? onPage,
  bool Function()? stopped,
}) async {
  final items = <Map>[];
  for (var page = 1; page < 10000; page++) {
    if (stopped?.call() ?? false) break;
    final res =
        await client.send(
          'GET',
          '/api/v1/chats/stats/export',
          query: {...query, 'page': '$page'},
        ) as Map? ??
        const {};
    final got = [...((res['items'] as List?) ?? const []).whereType<Map>()];
    items.addAll(got);
    final total = (res['total'] as num?)?.toInt() ?? items.length;
    onPage?.call(res, items.length, total);
    if (got.isEmpty || items.length >= total) break;
  }
  return items;
}

/// Stands in for the web's popup in the community page: the page's
/// window.open of a "?sync=true" link gets a window whose postMessage
/// reaches the app, and the app's answers arrive as messages from it.
String usageSyncShim(String serverOrigin) =>
    '''
(function () {
  if (window.__openaideSync) return;
  var popup = {
    closed: false,
    focus: function () {},
    close: function () { this.closed = true; },
    postMessage: function (m) {
      OpenAideSync.postMessage(JSON.stringify({ kind: 'message', data: m }));
    }
  };
  window.__openaideSync = function (data) {
    window.dispatchEvent(new MessageEvent('message', {
      data: data, origin: ${jsonEncode(serverOrigin)}, source: popup
    }));
  };
  var open = window.open;
  window.open = function (url) {
    if (String(url || '').indexOf('sync=true') >= 0) {
      popup.closed = false;
      OpenAideSync.postMessage(JSON.stringify({ kind: 'open' }));
      return popup;
    }
    return open.apply(window, arguments);
  };
})();
''';

class UsageSyncScreen extends ConsumerStatefulWidget {
  const UsageSyncScreen({super.key});

  @override
  ConsumerState<UsageSyncScreen> createState() => _UsageSyncScreenState();
}

class _UsageSyncScreenState extends ConsumerState<UsageSyncScreen> {
  late final WebViewController _web;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    final origin = Uri.parse(ref.read(clientProvider).baseUrl).origin;
    final shim = usageSyncShim(origin);
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel('OpenAideSync', onMessageReceived: _received)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) {
            if (mounted) setState(() => _progress = p);
          },
          onPageStarted: (url) {
            if (_onCommunity(url)) _web.runJavaScript(shim).ignore();
          },
          onPageFinished: (url) {
            if (_onCommunity(url)) _web.runJavaScript(shim).ignore();
          },
        ),
      )
      ..loadRequest(Uri.parse(communityUrl));
  }

  Future<void> _send(Object data) => _web.runJavaScript(
    'window.__openaideSync && window.__openaideSync(${jsonEncode(data)});',
  );

  /// Only the community site gets the stand-in and its answers: a page it
  /// links to must not ask for your stats.
  static bool _onCommunity(String? url) =>
      Uri.tryParse(url ?? '')?.host == Uri.parse(communityUrl).host;

  Future<void> _received(JavaScriptMessage message) async {
    if (!_onCommunity(await _web.currentUrl())) return;
    final Map m;
    try {
      m = jsonDecode(message.message) as Map;
    } catch (_) {
      return;
    }
    if (m['kind'] == 'open') {
      await _send('loaded');
      return;
    }
    final data = m['data'];
    final type = data is Map ? data['type'] : data;
    final client = ref.read(clientProvider);
    if (type == 'export:stats') {
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) =>
            UsageSyncSheet(request: data is Map ? data : const {}, post: _send),
      );
    } else if (type == 'verify:chat' && data is Map) {
      final id = '${(data['data'] as Map?)?['id'] ?? data['id'] ?? ''}';
      if (id.isEmpty) return;
      try {
        final res = await client.send(
          'GET',
          '/api/v1/chats/stats/export/${Uri.encodeComponent(id)}',
        );
        await _send({
          'type': 'verify:chat:response',
          'data': res,
          'chatId': id,
          'requestId': data['requestId'],
        });
      } catch (e) {
        await _send({
          'type': 'verify:chat:error',
          'error': '$e',
          'chatId': id,
          'requestId': data['requestId'],
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: IconButton(
        tooltip: tr('Close'),
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
      title: const T('Sync Usage Stats'),
      actions: [
        IconButton(
          tooltip: tr('Download as JSON'),
          icon: const Icon(Icons.download_outlined),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (_) => const UsageSyncSheet(),
          ),
        ),
      ],
      bottom: _progress < 100
          ? PreferredSize(
              preferredSize: const Size.fromHeight(2),
              child: LinearProgressIndicator(value: _progress / 100),
            )
          : null,
    ),
    body: WebViewWidget(controller: _web),
  );
}

/// What syncing shares and doesn't, Sync (to the community page that
/// asked) and Download as JSON, with progress, Stop Download and Try Again.
class UsageSyncSheet extends ConsumerStatefulWidget {
  const UsageSyncSheet({super.key, this.request = const {}, this.post});

  /// The community page's request (its search and last sync), if any.
  final Map request;

  /// Sends a message to the community page; null when nothing asked, so
  /// only Download is offered.
  final Future<void> Function(Object message)? post;

  @override
  ConsumerState<UsageSyncSheet> createState() => _UsageSyncSheetState();
}

class _UsageSyncSheetState extends ConsumerState<UsageSyncSheet> {
  bool _onlyNew = true;
  bool _syncing = false;
  bool _downloading = false;
  bool _stop = false;
  bool _done = false;
  String? _error;
  int _count = 0;
  int _total = 0;

  Map<String, String> _query({required bool incremental}) => {
    for (final e
        in ((widget.request['searchParams'] as Map?) ?? const {}).entries)
      '${e.key}': '${e.value}',
    if (incremental && widget.request['lastSyncedChatUpdatedAt'] != null)
      'updated_at': '${widget.request['lastSyncedChatUpdatedAt']}',
  };

  Future<void> _post(Map<String, dynamic> message) async =>
      widget.post?.call({...message, 'requestId': widget.request['requestId']});

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _stop = false;
      _error = null;
      _count = _total = 0;
    });
    final client = ref.read(clientProvider);
    try {
      await _post({'type': 'sync:start'});
      final version = await client.send('GET', '/api/version');
      await _post({'type': 'sync:version', 'data': version});
      await exportUsageStats(
        client,
        query: _query(incremental: _onlyNew),
        stopped: () => _stop,
        onPage: (page, done, total) {
          if ((page['items'] as List?)?.isNotEmpty ?? false) {
            _post({'type': 'sync:stats:chats', 'data': page});
          }
          if (!mounted) return;
          setState(() {
            _count = done;
            _total = total;
          });
        },
      );
      if (_stop) {
        await _post({'type': 'sync:error', 'error': 'User cancelled'});
      } else {
        await _post({'type': 'sync:complete'});
      }
      if (mounted) setState(() => _done = !_stop);
    } catch (e) {
      await _post({'type': 'sync:error', 'error': '$e'});
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _syncing = false);
  }

  Future<void> _download() async {
    if (_downloading) {
      setState(() => _stop = true);
      return;
    }
    setState(() {
      _downloading = true;
      _stop = false;
      _error = null;
      _count = _total = 0;
    });
    final client = ref.read(clientProvider);
    try {
      final items = await exportUsageStats(
        client,
        query: _query(incremental: false),
        stopped: () => _stop,
        onPage: (_, done, total) {
          if (!mounted) return;
          setState(() {
            _count = done;
            _total = total;
          });
        },
      );
      if (!_stop) {
        final version =
            ((await client.send('GET', '/api/version')) as Map?)?['version'] ??
            '0.0.0';
        final name =
            'open-webui-stats-$version-${DateTime.now().millisecondsSinceEpoch}.json';
        await FilePicker.saveFile(
          fileName: name,
          bytes: Uint8List.fromList(utf8.encode(jsonEncode(items))),
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _downloading = false);
  }

  @override
  Widget build(BuildContext context) {
    final muted = context.nexus.muted;
    final busy = _syncing || _downloading;
    final text = Theme.of(context).textTheme;
    if (_done) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              T('Sync Complete!', style: text.titleLarge),
              const SizedBox(height: 4),
              const T('Your usage stats have been successfully synced.'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const T('Done'),
              ),
            ],
          ),
        ),
      );
    }
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            T(
              _error != null ? 'Sync Failed' : 'Sync Usage Stats',
              style: text.titleLarge,
            ),
            const SizedBox(height: 8),
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
            ],
            const T(
              'Do you want to sync your usage stats with Open WebUI '
              'Community?',
            ),
            const SizedBox(height: 12),
            T('What is shared:', style: text.titleSmall),
            for (final s in const [
              'Open WebUI version',
              'Model names and usage frequency',
              'Message counts and response timestamps',
              'Content lengths (character counts only)',
              'User ratings (thumbs up/down)',
            ])
              Text('• ${tr(s)}', style: TextStyle(color: muted)),
            const SizedBox(height: 8),
            T('What is NOT shared:', style: text.titleSmall),
            for (final s in const [
              'Your message text or inputs',
              'Model responses or outputs',
              'Uploaded files or images',
            ])
              Text('• ${tr(s)}', style: TextStyle(color: muted)),
            if (widget.post != null)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const T('Only sync new/updated chats'),
                value: _onlyNew,
                onChanged: busy ? null : (v) => setState(() => _onlyNew = v),
              ),
            if (busy) ...[
              const SizedBox(height: 12),
              Text(
                '${tr(_downloading ? 'Downloading stats...' : 'Syncing stats...')}'
                '${_total > 0 ? ' $_count / $_total' : ''}',
                style: TextStyle(color: muted),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: _total > 0 ? (_count / _total).clamp(0.0, 1.0) : null,
              ),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _syncing ? null : _download,
                  child: T(_downloading ? 'Stop Download' : 'Download as JSON'),
                ),
                if (_syncing)
                  TextButton(
                    onPressed: () => setState(() => _stop = true),
                    child: const T('Cancel'),
                  )
                else
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const T('Cancel'),
                  ),
                if (widget.post != null)
                  FilledButton(
                    onPressed: busy ? null : _sync,
                    child: _syncing
                        ? const T('Syncing...')
                        : T(_error != null ? 'Try Again' : 'Sync'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
