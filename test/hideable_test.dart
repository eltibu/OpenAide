import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/widgets/hideable.dart';

void main() {
  Widget field({bool secret = true}) => MaterialApp(
    home: Scaffold(
      body: Hideable(
        secret: secret,
        builder: (obscure, eye) => TextField(
          obscureText: obscure,
          decoration: InputDecoration(suffixIcon: eye),
        ),
      ),
    ),
  );
  bool hidden(WidgetTester t) =>
      t.widget<EditableText>(find.byType(EditableText)).obscureText;

  testWidgets('the eye shows and hides what was typed', (tester) async {
    await tester.pumpWidget(field());
    expect(hidden(tester), isTrue);
    await tester.tap(find.byTooltip('Show'));
    await tester.pump();
    expect(hidden(tester), isFalse);
    await tester.tap(find.byTooltip('Hide'));
    await tester.pump();
    expect(hidden(tester), isTrue);
  });

  testWidgets('a field that is not secret has no eye', (tester) async {
    await tester.pumpWidget(field(secret: false));
    expect(hidden(tester), isFalse);
    expect(find.byType(IconButton), findsNothing);
  });
}
