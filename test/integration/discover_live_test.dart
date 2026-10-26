// Run with OWUI_URL set (see server_sync_test.dart).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/core/api/openwebui_client.dart';

void main() {
  final url = Platform.environment['OWUI_URL'];
  test('finds the server from a pasted chat link without a scheme', () async {
    final bare = Uri.parse(url!).authority;
    expect(await OpenWebUiClient.discover('$bare/c/some-chat-id'), url);
  }, skip: url == null ? 'Set OWUI_URL' : null);
}
