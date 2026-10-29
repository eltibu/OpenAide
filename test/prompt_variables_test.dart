import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/settings/user_location.dart';
import 'package:nexus_assistant/features/workspace/prompts_api.dart';

void main() {
  test('chat variables as the web sends them', () {
    final v = promptVariables(
      userName: 'Joel',
      userEmail: 'j@x.io',
      now: DateTime(2026, 10, 28, 9, 5, 3),
    );
    expect(v['{{USER_NAME}}'], 'Joel');
    expect(v['{{USER_EMAIL}}'], 'j@x.io');
    expect(v['{{CURRENT_DATE}}'], '2026-10-28');
    expect(v['{{CURRENT_TIME}}'], '09:05:03');
    expect(v['{{CURRENT_DATETIME}}'], '2026-10-28 09:05:03');
    expect(v['{{CURRENT_WEEKDAY}}'], 'Wednesday');
    expect(v['{{USER_LANGUAGE}}'], 'en-US');
    expect(v['{{USER_LOCATION}}'], 'Unknown');
    expect(
      promptVariables(
        location: '1.000, 2.000 (lat, long)',
      )['{{USER_LOCATION}}'],
      '1.000, 2.000 (lat, long)',
    );
  });

  test('position written as the web writes it', () {
    expect(formatPosition(40.41678, -3.70379), '40.417, -3.704 (lat, long)');
    expect(userLocationOn({'userLocation': true}), isTrue);
    expect(userLocationOn(null), isFalse);
  });
}
