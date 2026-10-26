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

  test('the newest release is the highest build, not the last published', () {
    Map<String, dynamic> rel(String tag) => {
      'tag_name': tag,
      'assets': [
        {'name': 'nexus-assistant.apk', 'url': 'u-$tag'},
      ],
    };
    final newest = newestRelease([
      rel('v0.1.20'),
      rel('v0.1.21'),
      rel('build-10'),
      {'tag_name': 'v0.1.22', 'assets': []},
      {...rel('v0.1.23'), 'draft': true},
    ]);
    expect(newest?.build, 21);
    expect(newest?.assetApiUrl, 'u-v0.1.21');
    expect(newestRelease([]), isNull);
  });
}
