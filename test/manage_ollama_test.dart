import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/admin/manage_ollama.dart';

void main() {
  test('pull progress in percent', () {
    expect(pullPercent({'status': 'pulling manifest'}), isNull);
    expect(pullPercent({'total': 0, 'completed': 0}), isNull);
    expect(pullPercent({'total': 200, 'completed': 50}), 25);
    expect(pullPercent({'total': 100, 'completed': 150}), 100);
  });
}
