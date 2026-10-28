/// A read-only look at a Word, PowerPoint or Excel file, as the web's
/// previews: its text, headings, lists and tables, with zoom. Slides show
/// one card each, with their speaker notes.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../../core/theme.dart';
import 'office.dart';
import 'slides.dart';

/// The Office files this preview opens.
bool isOfficeFile(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0) return false;
  return const {
    'docx',
    'docm',
    'pptx',
    'pptm',
    'xlsx',
    'xlsm',
  }.contains(name.substring(dot + 1).toLowerCase());
}

class OfficePreviewScreen extends StatefulWidget {
  const OfficePreviewScreen({
    super.key,
    required this.name,
    required this.bytes,
  });
  final String name;
  final Uint8List bytes;

  @override
  State<OfficePreviewScreen> createState() => _OfficePreviewScreenState();
}

class _OfficePreviewScreenState extends State<OfficePreviewScreen> {
  double _zoom = 1;
  List<Slide>? _slides;
  String _markdown = '';
  Object? _error;

  bool get _isSlides =>
      RegExp(r"\.ppt[xm]$", caseSensitive: false).hasMatch(widget.name);

  @override
  void initState() {
    super.initState();
    try {
      if (_isSlides) {
        _slides = slidesFromPptx(widget.bytes);
        _markdown = '';
      } else {
        _slides = null;
        _markdown = importFile(widget.name, widget.bytes).$2;
      }
    } catch (e) {
      _slides = null;
      _markdown = '';
      _error = e;
    }
  }

  void _set(double z) => setState(() => _zoom = z.clamp(0.5, 3).toDouble());

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final config = dark
        ? MarkdownConfig.darkConfig
        : MarkdownConfig.defaultConfig;
    final muted = context.nexus.muted;
    Widget md(String text) => MarkdownBlock(data: text, config: config);
    final slides = _slides;
    return Scaffold(
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
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  "This file can't be shown.\n$_error",
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(_zoom)),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (slides == null)
                    md(_markdown.trim().isEmpty ? '_Empty_' : _markdown)
                  else
                    for (final (i, s) in slides.indexed)
                      Card(
                        margin: const EdgeInsets.only(bottom: 16),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Slide ${i + 1}',
                                style: TextStyle(color: muted, fontSize: 12),
                              ),
                              md(s.toMarkdown()),
                            ],
                          ),
                        ),
                      ),
                ],
              ),
            ),
    );
  }
}
