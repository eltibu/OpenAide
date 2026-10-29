import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/streaming_fade.dart';

void main() {
  testWidgets('new text fades in, then settles solid', (tester) async {
    Future<void> show(String text) => tester.pumpWidget(
      MaterialApp(
        home: StreamingFade(text: text, child: Text(text)),
      ),
    );
    AnimationController fade() =>
        (tester.state(find.byType(StreamingFade)) as dynamic).fadeForTest
            as AnimationController;
    await show('Hello');
    expect(fade().value, 1);
    await show('Hello there');
    expect(fade().value, closeTo(0.35, 0.01));
    await tester.pumpAndSettle();
    expect(fade().value, 1);
    expect(find.text('Hello there'), findsOneWidget);
  });
}
