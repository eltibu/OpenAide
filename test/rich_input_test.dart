import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/rich_input.dart';

void main() {
  testWidgets('formatting shows while the text stays the same', (tester) async {
    final c = RichInputController();
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Builder(
            builder: (context) {
              ctx = context;
              return TextField(controller: c, maxLines: null);
            },
          ),
        ),
      ),
    );
    const samples = [
      '# Plan\nSome **bold** and *italic* and `code`',
      '> quoted ~~old~~ [docs](https://x.io) under_score snake_case_name',
      '** not bold ** 2*3*4 a*b',
      '',
    ];
    for (final t in samples) {
      c.text = t;
      final span = c.buildTextSpan(
        context: ctx,
        style: const TextStyle(fontSize: 16),
        withComposing: false,
      );
      expect(span.toPlainText(), t);
    }
    c.text = 'Some **bold**';
    final spans = <TextSpan>[];
    c
        .buildTextSpan(
          context: ctx,
          style: const TextStyle(),
          withComposing: false,
        )
        .visitChildren((s) {
          if (s is TextSpan && s.text != null) spans.add(s);
          return true;
        });
    expect(
      spans.firstWhere((s) => s.text == 'bold').style?.fontWeight,
      FontWeight.w700,
    );
    c.rich = false;
    final plain = c.buildTextSpan(
      context: ctx,
      style: const TextStyle(),
      withComposing: false,
    );
    expect(plain.children, isNull);
  });
}
