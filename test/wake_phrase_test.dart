import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/theme.dart';
import 'package:nexus_assistant/features/phone/wake_phrase.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the listening model', () {
    late HttpServer server;
    late Directory dir;
    var asked = 0;
    List<int> body = const [];

    setUp(() async {
      HttpOverrides.global = null;
      asked = 0;
      dir = Directory.systemTemp.createTempSync('wake');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        asked++;
        req.response
          ..contentLength = body.length
          ..add(body)
          ..close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    Uri url() => Uri.parse('http://127.0.0.1:${server.port}/model.zip');

    test('downloads once, unpacks and reports progress', () async {
      final zip = Archive()
        ..add(ArchiveFile.bytes('$wakeModelName/am/final.mdl', [1, 2, 3]))
        ..add(ArchiveFile.bytes('$wakeModelName/conf/model.conf', [4]));
      body = ZipEncoder().encode(zip);
      final seen = <double>[];
      final path = await downloadWakeModel(
        dir,
        from: url(),
        progress: seen.add,
      );
      expect(path, '${dir.path}/$wakeModelName');
      expect(File('$path/am/final.mdl').readAsBytesSync(), [1, 2, 3]);
      expect(seen.last, 1.0);
      expect(File('${dir.path}/$wakeModelName.zip').existsSync(), isFalse);

      // Kept on the phone: not downloaded again.
      await downloadWakeModel(dir, from: url());
      expect(asked, 1);
    });

    test('a download without the model is refused', () async {
      body = ZipEncoder().encode(
        Archive()..add(ArchiveFile.bytes('other/readme.txt', [1])),
      );
      await expectLater(
        downloadWakeModel(dir, from: url()),
        throwsA(isA<FileSystemException>()),
      );
      expect(File('${dir.path}/$wakeModelName.zip').existsSync(), isFalse);
    });
  });

  testWidgets('the setting turns off and asks to open over other apps', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    var on = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('nexus/launch'), (
          call,
        ) async {
          calls.add(call);
          if (call.method == 'wakeState') {
            return {'on': on, 'model': '/m', 'canOpen': false};
          }
          if (call.method == 'wake') on = (call.arguments as Map)['on'];
          return null;
        });
    await tester.pumpWidget(
      MaterialApp(
        theme: nexusTheme(Brightness.light),
        home: const Scaffold(body: WakePhraseTile()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Allow OpenAide to open over other apps'), findsOneWidget);
    await tester.tap(find.text('Allow OpenAide to open over other apps'));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(calls.map((c) => c.method), contains('openOverOtherApps'));
    expect(on, isFalse);
    expect(find.text('Allow OpenAide to open over other apps'), findsNothing);
  });
}
