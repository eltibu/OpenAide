/// Settings > Interface > Rich text input, as the web's rich message box:
/// formatting shows as you type (bold, italic, code, strikethrough,
/// headings, quotes and links), while the text stays the Markdown sent.
library;

import 'package:flutter/material.dart';

/// A text controller that styles its own Markdown; [rich] off shows plain
/// text.
class RichInputController extends TextEditingController {
  RichInputController({super.text});

  bool rich = true;

  static final _inline = RegExp(
    r'(\*\*|__)(?=\S)(.+?)(?<=\S)\1'
    r'|~~(?=\S)(.+?)(?<=\S)~~'
    r'|`([^`\n]+)`'
    r'|(?<![\*\w])[\*_](?=\S)([^\*_\n]+?)(?<=\S)[\*_](?![\*\w])'
    r'|\[([^\]\n]+)\]\(([^)\s]+)\)',
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // Mid-word input from the keyboard keeps its underline.
    if (!rich || (withComposing && value.isComposingRangeValid)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final base = style ?? const TextStyle();
    final scheme = Theme.of(context).colorScheme;
    final faint = base.copyWith(
      color: (base.color ?? scheme.onSurface).withValues(alpha: 0.4),
    );
    return TextSpan(
      style: base,
      children: [
        for (final (i, line) in text.split('\n').indexed) ...[
          if (i > 0) const TextSpan(text: '\n'),
          ..._line(line, base, faint, scheme),
        ],
      ],
    );
  }

  List<InlineSpan> _line(
    String line,
    TextStyle base,
    TextStyle faint,
    ColorScheme scheme,
  ) {
    final heading = RegExp(r'^(#{1,6} )').firstMatch(line);
    if (heading != null) {
      final level = heading.group(1)!.length - 1;
      final style = base.copyWith(
        fontWeight: FontWeight.w700,
        fontSize: (base.fontSize ?? 16) * (level <= 2 ? 1.15 : 1.05),
      );
      return [
        TextSpan(text: heading.group(1), style: faint),
        ..._inlines(line.substring(heading.end), style, faint, scheme),
      ];
    }
    if (line.startsWith('> ')) {
      final quote = base.copyWith(fontStyle: FontStyle.italic);
      return [
        TextSpan(text: '> ', style: faint),
        ..._inlines(line.substring(2), quote, faint, scheme),
      ];
    }
    return _inlines(line, base, faint, scheme);
  }

  List<InlineSpan> _inlines(
    String s,
    TextStyle base,
    TextStyle faint,
    ColorScheme scheme,
  ) {
    final out = <InlineSpan>[];
    var at = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start > at) out.add(TextSpan(text: s.substring(at, m.start)));
      final whole = m.group(0)!;
      if (m.group(2) != null) {
        final mark = m.group(1)!;
        out.addAll([
          TextSpan(text: mark, style: faint),
          TextSpan(
            text: m.group(2),
            style: base.copyWith(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: mark, style: faint),
        ]);
      } else if (m.group(3) != null) {
        out.addAll([
          TextSpan(text: '~~', style: faint),
          TextSpan(
            text: m.group(3),
            style: base.copyWith(decoration: TextDecoration.lineThrough),
          ),
          TextSpan(text: '~~', style: faint),
        ]);
      } else if (m.group(4) != null) {
        out.add(
          TextSpan(
            text: whole,
            style: base.copyWith(
              fontFamily: 'monospace',
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        );
      } else if (m.group(5) != null) {
        out.addAll([
          TextSpan(text: whole[0], style: faint),
          TextSpan(
            text: m.group(5),
            style: base.copyWith(fontStyle: FontStyle.italic),
          ),
          TextSpan(text: whole[whole.length - 1], style: faint),
        ]);
      } else {
        final label = m.group(6)!;
        out.addAll([
          TextSpan(text: '[', style: faint),
          TextSpan(
            text: label,
            style: base.copyWith(
              color: scheme.primary,
              decoration: TextDecoration.underline,
            ),
          ),
          TextSpan(text: whole.substring(label.length + 1), style: faint),
        ]);
      }
      at = m.end;
    }
    if (at < s.length) out.add(TextSpan(text: s.substring(at)));
    return out;
  }
}
