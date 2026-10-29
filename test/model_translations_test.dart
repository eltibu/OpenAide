import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/workspace/model_translations.dart';

void main() {
  test('empty translations are dropped, as the web saves them', () {
    expect(
      prunedTranslations({
        'es-ES': {'name': 'Nexo', 'description': ' '},
        'fr-FR': {'name': '', 'description': ''},
        'de-DE': 'bad',
      }),
      {
        'es-ES': {'name': 'Nexo'},
      },
    );
    expect(prunedTranslations({}), isNull);
    expect(prunedTranslations(null), isNull);
  });

  test('the web languages are offered', () {
    final codes = [for (final (c, _) in editingLanguages) c];
    expect(codes, containsAll(['en-US', 'es-ES', 'fr-FR']));
  });
}
