import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/i18n/app_strings.dart';
import 'package:nexus_assistant/features/admin/ui_translations.dart';

void main() {
  test('rows go to the server shape and back', () {
    final rows = translationRows({
      'de-DE': {'New chat': 'Neues Gespräch'},
      'en-US': {'New chat': 'Fresh chat'},
    });
    expect(rows.single.original, 'New chat');
    expect(rows.single.byLanguage, {
      'de-DE': 'Neues Gespräch',
      'en-US': 'Fresh chat',
    });
    rows.add(UiTranslation('')); // an empty new row is left out
    expect(translationsFrom(rows), {
      'de-DE': {'New chat': 'Neues Gespräch'},
      'en-US': {'New chat': 'Fresh chat'},
    });
  });

  test('refuses worded rows without text, and the same text twice', () {
    expect(
      () => translationsFrom([
        UiTranslation('', {'de-DE': 'x'}),
      ]),
      throwsFormatException,
    );
    expect(
      () => translationsFrom([UiTranslation('a'), UiTranslation('a')]),
      throwsFormatException,
    );
  });

  test('the server\'s wording wins in the app', () {
    final s = AppStrings.instance;
    expect(tr('New chat'), 'New chat');
    s.setAdminWords({
      'en-US': {'New chat': 'Fresh chat'},
    });
    expect(tr('New chat'), 'Fresh chat');
    s.setAdminWords({});
    expect(tr('New chat'), 'New chat');
  });
}
