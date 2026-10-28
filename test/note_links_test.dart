import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/notes/notes_api.dart';

void main() {
  test('links to the server notes open them', () {
    const server = 'https://chat.example.com';
    expect(noteIdIn('https://chat.example.com/notes/abc', server), 'abc');
    expect(noteIdIn('/notes/abc', server), 'abc');
    expect(noteIdIn('https://other.com/notes/abc', server), isNull);
    expect(noteIdIn('https://chat.example.com/notes', server), isNull);
    expect(noteIdIn('https://chat.example.com/c/abc', server), isNull);
    // A server under a path, as on the home network.
    expect(
      noteIdIn(
        'http://192.168.1.20/chat/notes/n1',
        'http://192.168.1.20/chat',
      ),
      'n1',
    );
  });
}
