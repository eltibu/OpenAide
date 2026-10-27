import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_widget/markdown_widget.dart';
import 'package:nexus_assistant/features/chat/markdown_extras.dart';
import 'package:nexus_assistant/features/terminal/file_links.dart';
import 'package:nexus_assistant/features/terminal/file_open.dart';

void main() {
  testWidgets('tapping a file in a reply opens it; commands stay text', (
    tester,
  ) async {
    final opened = <String>[];
    void onFile(FileRef f) => opened.add('$f');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownBlock(
            data:
                'Saved to `/home/eltibu/Pictures/cat.png`. Run `ls -la` or '
                'open [the notes](/home/eltibu/notes.md).\n\n'
                '```\ncat /etc/hosts\n```',
            config: withFileLinks(
              withReplyCode(MarkdownConfig.defaultConfig, false),
              onFile,
            ),
            generator: withFileTaps(replyMarkdownGenerator(), onFile),
          ),
        ),
      ),
    );
    final spans = <TextSpan>[];
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      rich.text.visitChildren((s) {
        if (s is TextSpan && s.recognizer is TapGestureRecognizer) {
          spans.add(s);
        }
        return true;
      });
    }
    for (final s in spans) {
      (s.recognizer! as TapGestureRecognizer).onTap!();
    }
    expect(opened, contains('/home/eltibu/Pictures/cat.png'));
    expect(opened, contains('/home/eltibu/notes.md'));
    expect(opened.where((o) => o.contains('ls')), isEmpty);
    expect(opened.where((o) => o.contains('hosts')), isEmpty);
    expect(
      find.textContaining('cat /etc/hosts', findRichText: true),
      findsOneWidget,
    );
  });
}
