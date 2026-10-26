import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/update/updater.dart';

void main() {
  test('reads the build number from a release tag', () {
    expect(buildFromTag('build-42'), 42);
    expect(buildFromTag('v1.0'), isNull);
    expect(buildFromTag(null), isNull);
  });
}
