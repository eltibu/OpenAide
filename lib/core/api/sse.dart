import 'dart:async';
import 'dart:convert';

/// Turns a byte stream of Server-Sent Events into the JSON payloads of each
/// `data:` line. Stops at the OpenAI-style `[DONE]` sentinel.
Stream<Map<String, dynamic>> parseSse(Stream<List<int>> bytes) async* {
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data.isEmpty) continue;
    if (data == '[DONE]') return;
    try {
      final decoded = jsonDecode(data);
      if (decoded is Map<String, dynamic>) yield decoded;
    } on FormatException {
      // Ignore keep-alives or partial frames the server may interleave.
    }
  }
}

/// Extracts the text delta from an OpenAI-compatible streaming chunk.
String? deltaContent(Map<String, dynamic> chunk) {
  final choices = chunk['choices'];
  if (choices is! List || choices.isEmpty) return null;
  final delta = (choices.first as Map)['delta'];
  if (delta is! Map) return null;
  final content = delta['content'];
  return content is String ? content : null;
}
