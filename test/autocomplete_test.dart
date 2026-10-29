import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/autocomplete.dart';

void main() {
  test('reads the text out of the server reply', () {
    expect(autoCompletionText('{"text": " world"}'), ' world');
    expect(autoCompletionText('Sure: {"text": "and more"} done'), 'and more');
    expect(autoCompletionText('{"other": 1}'), '');
    expect(autoCompletionText('{broken}'), '');
    expect(autoCompletionText('plain words'), 'plain words');
  });
}
