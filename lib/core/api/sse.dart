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

/// One Server-Sent Event with its name, for streams that use names.
class SseEvent {
  const SseEvent(this.event, this.data);
  final String event;
  final String data;
}

/// Turns a byte stream of Server-Sent Events into whole events (several
/// `data:` lines joined), with their `event:` names.
Stream<SseEvent> parseSseEvents(Stream<List<int>> bytes) async* {
  final lines = bytes.transform(utf8.decoder).transform(const LineSplitter());
  var event = 'message';
  final data = <String>[];
  await for (final line in lines) {
    if (line.isEmpty) {
      if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
      event = 'message';
      data.clear();
    } else if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      final d = line.substring(5);
      data.add(d.startsWith(' ') ? d.substring(1) : d);
    }
  }
  if (data.isNotEmpty) yield SseEvent(event, data.join('\n'));
}
