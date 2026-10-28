import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/settings/interface_settings.dart';
import 'package:nexus_assistant/features/settings/settings_screen.dart';
import 'package:nexus_assistant/features/chat/attachments.dart';
import 'package:nexus_assistant/features/chat/composer_draft.dart';

void main() {
  test('finds what a paste put into the message box', () {
    expect(insertedText('Hi there', 'Hi big there'), 'big ');
    expect(insertedText('', 'abc'), 'abc');
    expect(insertedText('abc', 'abcabc'), 'abc');
  });

  test('photos shrink to the Interface size, at most 2048', () {
    expect(imageLimits(null), (2048, 2048));
    final ui = {
      'imageCompression': true,
      'imageCompressionSize': {'width': '800', 'height': ''},
      'imageCompressionInChannels': false,
    };
    expect(imageLimits(ui), (800, 2048));
    expect(imageLimits(ui, channels: true), (2048, 2048));
    expect(
      imageLimits({
        'imageCompression': true,
        'imageCompressionSize': {'width': 9000, 'height': 600},
      }),
      (2048, 600),
    );
  });

  testWidgets('Interface page shows every switch and the size', (tester) async {
    tester.view.physicalSize = const Size(1080, 9000);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          uiSettingsProvider.overrideWith(
            (ref) async => {
              'imageCompression': true,
              'imageCompressionSize': {'width': '800', 'height': ''},
              'regenerateMenu': false,
            },
          ),
        ],
        child: MaterialApp(
          theme: nexusTheme(Brightness.light),
          home: const InterfaceSettings(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final g in interfaceSwitches.values) {
      for (final (_, _, label, _) in g) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
    }
    expect(find.text('800 wide, any height'), findsOneWidget);
    expect(find.text('Entire document'), findsOneWidget);
  });
}
