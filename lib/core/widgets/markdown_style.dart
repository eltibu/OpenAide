/// How Markdown looks everywhere in the app (replies, notes, Studio,
/// channels): quiet headings without rules, roomy lists and light tables,
/// close to the Claude app, in the app's own colors.
library;

import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// The app's Markdown style for [context]'s theme.
MarkdownConfig nexusMarkdown(BuildContext context) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  final scheme = theme.colorScheme;
  final text = scheme.onSurface;
  final rule = scheme.outlineVariant;
  final base = dark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
  TextStyle heading(double size, [FontWeight weight = FontWeight.w600]) =>
      TextStyle(fontSize: size, height: 1.3, fontWeight: weight, color: text);
  return base.copy(
    configs: [
      PConfig(textStyle: TextStyle(fontSize: 16, height: 1.5, color: text)),
      _H1(style: heading(22)),
      _H2(style: heading(19)),
      _H3(style: heading(17)),
      H4Config(style: heading(16)),
      H5Config(style: heading(15)),
      H6Config(style: heading(14)),
      ListConfig(
        marginLeft: 26,
        marginBottom: 6,
        marker: (ordered, depth, index) => ordered
            ? Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${index + 1}.',
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 16, height: 1.5, color: text),
                ),
              )
            : Padding(
                // Centred on the first line of 16/1.5 text.
                padding: const EdgeInsets.only(top: 9, left: 8),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: depth == 1 ? null : text,
                      border: depth == 1 ? Border.all(color: text) : null,
                    ),
                  ),
                ),
              ),
      ),
      TableConfig(
        border: TableBorder(
          horizontalInside: BorderSide(color: rule),
          top: BorderSide(color: rule),
          bottom: BorderSide(color: rule),
        ),
        headPadding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        bodyPadding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        // Wide tables scroll sideways instead of squeezing.
        wrapper: (table) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: table,
        ),
      ),
      BlockquoteConfig(
        sideColor: rule,
        textColor: text.withValues(alpha: 0.75),
        sideWith: 3,
        padding: const EdgeInsets.fromLTRB(14, 2, 0, 2),
      ),
      HrConfig(height: 1, color: rule),
      CodeConfig(
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 14,
          color: text,
          backgroundColor: scheme.surfaceContainerHighest,
        ),
      ),
    ],
  );
}

class _H1 extends H1Config {
  const _H1({required super.style});
  @override
  HeadingDivider? get divider => null;
}

class _H2 extends H2Config {
  const _H2({required super.style});
  @override
  HeadingDivider? get divider => null;
}

class _H3 extends H3Config {
  const _H3({required super.style});
  @override
  HeadingDivider? get divider => null;
}
