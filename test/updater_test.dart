import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/update/updater.dart';

void main() {
  test('reads the build number from a release tag', () {
    expect(buildFromTag('v0.1.43'), 43);
    expect(buildFromTag('build-42'), 42);
    expect(buildFromTag('v1.0'), isNull);
    expect(versionName(43), '0.1.43');
    expect(buildFromTag(null), isNull);
  });
}
