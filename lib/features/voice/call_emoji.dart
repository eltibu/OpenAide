/// Settings > Interface > Display Emoji in Call, as on the web: while the
/// answer is read aloud, an emoji the model picks for each piece shows in
/// place of the circle.
library;

import '../../core/api/openwebui_client.dart';

const showEmojiInCallKey = 'showEmojiInCall';

bool emojiInCallOn(Map? ui) => ui?[showEmojiInCallKey] == true;

bool _pictograph(int r) =>
    r >= 0x1F000 && r <= 0x1FAFF ||
    r >= 0x2600 && r <= 0x27BF ||
    r >= 0x2300 && r <= 0x23FF ||
    r >= 0x2B00 && r <= 0x2BFF ||
    r == 0x00A9 ||
    r == 0x00AE ||
    r == 0x203C ||
    r == 0x2049 ||
    r == 0x2122;

/// The first emoji in the model's answer, as the web reads it.
String? firstEmoji(String? text) {
  if (text == null) return null;
  for (final r in text.runes) {
    if (_pictograph(r)) return String.fromCharCode(r);
  }
  return null;
}

/// Asks the server's emoji task for one emoji for [text]; null if none.
Future<String?> emojiFor(
  OpenWebUiClient client, {
  required String model,
  required String text,
  String? chatId,
}) async {
  try {
    final res = await client.send(
      'POST',
      '/api/v1/tasks/emoji/completions',
      body: {'model': model, 'prompt': text, 'chat_id': ?chatId},
    );
    final choices = (res as Map?)?['choices'] as List?;
    final content =
        ((choices?.firstOrNull as Map?)?['message'] as Map?)?['content'];
    return firstEmoji(content is String ? content : null);
  } catch (_) {
    return null;
  }
}
