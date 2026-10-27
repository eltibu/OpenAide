import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/settings/data_controls.dart';

void main() {
  test('reads chat exports in each shape', () {
    expect(parseChatExport(''), isEmpty);
    expect(parseChatExport('[{"id":"a","chat":{}}]').single['id'], 'a');
    expect(parseChatExport('{"id":"b","chat":{}}').single['id'], 'b');
    expect(
      parseChatExport('{"id":"c","chat":{}}\n{"id":"d","chat":{}}\n'),
      hasLength(2),
    );
  });

  test('import entries keep what the web keeps', () {
    final e = importEntry({
      'id': 'x',
      'chat': {'title': 'T'},
      'pinned': true,
      'folder_id': 'f',
      'created_at': 5,
    });
    expect(e['chat'], {'title': 'T'});
    expect(e['pinned'], true);
    expect(e['folder_id'], 'f');
    expect(e['created_at'], 5);
    expect(e['meta'], <String, dynamic>{});
    // An old export is the chat itself.
    final old = importEntry({'title': 'Old', 'messages': []});
    expect((old['chat'] as Map)['title'], 'Old');
  });

  test('file sizes', () {
    expect(fileSize(null), '');
    expect(fileSize(500), '500 B');
    expect(fileSize(2048), '2.0 KB');
    expect(fileSize(3 * 1024 * 1024), '3.0 MB');
  });
}
