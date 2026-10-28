/// A file's details, as the web's file dialog: its size and type, whether
/// the model reads it whole or only the relevant parts, the text the server
/// read from it, and PDFs shown page by page with zoom.
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/auth/session.dart';
import '../../core/theme.dart';
import '../studio/office_preview.dart';

String fileSize(num? bytes) {
  if (bytes == null) return '';
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

bool isPdf(String name, [String? type]) =>
    (type ?? '').toLowerCase().contains('pdf') ||
    name.toLowerCase().endsWith('.pdf');

/// How much of the content shows before "Show all".
const filePreviewLength = 2000;

class FileDetailsScreen extends ConsumerStatefulWidget {
  const FileDetailsScreen({
    super.key,
    required this.fileId,
    required this.name,
    this.fullContext,
    this.onFullContext,
  });
  final String fileId;
  final String name;

  /// For a file waiting in the message box: whether the model gets all of
  /// it, and how to change that.
  final bool? fullContext;
  final ValueChanged<bool>? onFullContext;

  @override
  ConsumerState<FileDetailsScreen> createState() => _FileDetailsScreenState();
}

class _FileDetailsScreenState extends ConsumerState<FileDetailsScreen> {
  Map<String, dynamic>? _file;
  Object? _error;
  bool _all = false;
  late bool? _full = widget.fullContext;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final res = await ref
          .read(clientProvider)
          .send('GET', '/api/v1/files/${widget.fileId}');
      if (mounted) setState(() => _file = (res as Map).cast());
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<Uint8List> _bytes() async => Uint8List.fromList(
    await ref
        .read(clientProvider)
        .getBytes('/api/v1/files/${widget.fileId}/content'),
  );

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final saved = await FilePicker.saveFile(
        fileName: widget.name,
        bytes: await _bytes(),
      );
      if (saved != null) {
        messenger.showSnackBar(SnackBar(content: Text('Saved ${widget.name}')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final meta = (file?['meta'] as Map?) ?? const {};
    final content = '${(file?['data'] as Map?)?['content'] ?? ''}';
    final type = '${meta['content_type'] ?? ''}';
    final muted = context.nexus.muted;
    final shown = _all || content.length <= filePreviewLength
        ? content
        : '${content.substring(0, filePreviewLength)}…';
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Download',
            icon: const Icon(Icons.download_outlined),
            onPressed: _save,
          ),
        ],
      ),
      body: _error != null
          ? Center(child: Text("Couldn't load the file.\n$_error"))
          : file == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  [
                    if (meta['size'] != null) fileSize(meta['size'] as num),
                    if (type.isNotEmpty) type,
                    if (content.isNotEmpty) '${content.length} characters read',
                  ].join(' · '),
                  style: TextStyle(color: muted),
                ),
                if (_full != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      _full!
                          ? 'Using Entire Document'
                          : 'Using Focused Retrieval',
                    ),
                    subtitle: Text(
                      _full!
                          ? 'The model reads all of it. Uses more of its '
                                'context.'
                          : 'The model gets the parts that match your '
                                'message.',
                    ),
                    value: _full!,
                    onChanged: (on) {
                      setState(() => _full = on);
                      widget.onFullContext?.call(on);
                    },
                  ),
                if (isPdf(widget.name, type))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.picture_as_pdf_outlined),
                      label: const Text('Preview'),
                      onPressed: () async {
                        final bytes = await _bytes();
                        if (!context.mounted) return;
                        await Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                PdfViewScreen(name: widget.name, bytes: bytes),
                          ),
                        );
                      },
                    ),
                  ),
                if (isOfficeFile(widget.name))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.description_outlined),
                      label: const Text('Preview'),
                      onPressed: () async {
                        final bytes = await _bytes();
                        if (!context.mounted) return;
                        await Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => OfficePreviewScreen(
                              name: widget.name,
                              bytes: bytes,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Content',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    if (content.isNotEmpty)
                      IconButton(
                        tooltip: 'Copy content',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () =>
                            Clipboard.setData(ClipboardData(text: content)),
                      ),
                  ],
                ),
                SelectableText(
                  content.isEmpty ? 'No content' : shown,
                  style: TextStyle(color: content.isEmpty ? muted : null),
                ),
                if (!_all && content.length > filePreviewLength)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setState(() => _all = true),
                      child: Text('Show all (${content.length} characters)'),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// The page that draws a PDF with pdf.js, one canvas per page, at a zoom.
String pdfPage() => '''<!doctype html><html><head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=6">
<style>html,body{margin:0;background:#525659}#p canvas{display:block;margin:8px auto;background:#fff;box-shadow:0 1px 4px #0006}
#e{color:#fff;font:14px sans-serif;padding:16px}</style>
<script src="https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.min.js"></script></head>
<body><div id="p"></div><div id="e"></div><script>
var doc=null, zoom=1;
function fail(err){document.getElementById('e').textContent=String(err&&err.message||err);}
function draw(){
  if(!doc) return;
  var box=document.getElementById('p'); box.innerHTML='';
  var w=Math.max(document.documentElement.clientWidth-16,100);
  var chain=Promise.resolve();
  for(let i=1;i<=doc.numPages;i++){
    chain=chain.then(function(){return doc.getPage(i);}).then(function(page){
      var base=page.getViewport({scale:1});
      var css=w/base.width*zoom, ratio=window.devicePixelRatio||1;
      var v=page.getViewport({scale:css*ratio});
      var c=document.createElement('canvas');
      c.width=v.width; c.height=v.height;
      c.style.width=(v.width/ratio)+'px'; c.style.height=(v.height/ratio)+'px';
      box.appendChild(c);
      return page.render({canvasContext:c.getContext('2d'),viewport:v}).promise;
    });
  }
  chain.catch(fail);
}
function setZoom(z){zoom=z; draw();}
function load(b64){
  try{
    pdfjsLib.GlobalWorkerOptions.workerSrc='https://cdn.jsdelivr.net/npm/pdfjs-dist@3.11.174/build/pdf.worker.min.js';
    var raw=atob(b64), bytes=new Uint8Array(raw.length);
    for(var i=0;i<raw.length;i++) bytes[i]=raw.charCodeAt(i);
    pdfjsLib.getDocument({data:bytes}).promise.then(function(d){doc=d; draw();}).catch(fail);
  }catch(err){fail(err);}
}
</script></body></html>''';

/// A PDF page by page, with zoom out, reset and zoom in.
class PdfViewScreen extends StatefulWidget {
  const PdfViewScreen({super.key, required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;

  @override
  State<PdfViewScreen> createState() => _PdfViewScreenState();
}

class _PdfViewScreenState extends State<PdfViewScreen> {
  double _zoom = 1;
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) => _web.runJavaScript(
          'load(${jsonEncode(base64Encode(widget.bytes))})',
        ),
      ),
    )
    ..loadHtmlString(pdfPage());

  void _set(double z) {
    setState(() => _zoom = z.clamp(0.5, 4).toDouble());
    _web.runJavaScript('setZoom($_zoom)');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.name, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: 'Zoom out',
          icon: const Icon(Icons.zoom_out),
          onPressed: () => _set(_zoom / 1.25),
        ),
        Tooltip(
          message: 'Reset zoom',
          child: TextButton(
            onPressed: () => _set(1),
            child: Text('${(_zoom * 100).round()}%'),
          ),
        ),
        IconButton(
          tooltip: 'Zoom in',
          icon: const Icon(Icons.zoom_in),
          onPressed: () => _set(_zoom * 1.25),
        ),
      ],
    ),
    body: WebViewWidget(controller: _web),
  );
}
