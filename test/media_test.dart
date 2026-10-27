import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/painting.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';
import 'package:nexus_assistant/core/models/chat.dart';
import 'package:nexus_assistant/features/chat/attachments.dart';

void main() {
  final client = OpenWebUiClient(baseUrl: 'http://192.168.1.209/chat')
    ..token = 't';

  test('a generated picture loads from its file, signed in', () {
    final a = Attachment.fromJson({
      'type': 'image',
      'url': '/api/v1/files/abc-123/content',
    });
    expect(a.isImage, isTrue);
    expect(a.fileId, 'abc-123');
    expect(
      attachmentUri(a, client).toString(),
      'http://192.168.1.209/chat/api/v1/files/abc-123/content',
    );
    final image = attachmentImage(a, client) as NetworkImage;
    expect(image.headers?['Authorization'], 'Bearer t');
  });

  test('videos are told apart by type or name', () {
    expect(
      Attachment.fromJson({
        'type': 'file',
        'name': 'clip',
        'content_type': 'video/mp4',
      }).isVideo,
      isTrue,
    );
    expect(
      Attachment.fromJson({'type': 'file', 'name': 'Trip.MOV'}).isVideo,
      isTrue,
    );
    expect(
      Attachment.fromJson({'type': 'file', 'name': 'notes.txt'}).isVideo,
      isFalse,
    );
  });

  test('markdown pictures resolve server paths and data URLs', () {
    final server = markdownImage('/static/x.png', client) as NetworkImage;
    expect(server.url, 'http://192.168.1.209/chat/static/x.png');
    expect(server.headers?['Authorization'], 'Bearer t');
    final other =
        markdownImage('https://example.com/a.png', client) as NetworkImage;
    expect(other.headers, isNull);
    expect(
      markdownImage(
        'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
        client,
      ),
      isA<MemoryImage>(),
    );
  });
}
