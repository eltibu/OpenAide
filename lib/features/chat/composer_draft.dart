import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Text handed to the chat box from elsewhere on the screen.
class ComposerDraft extends Notifier<String?> {
  @override
  String? build() => null;

  void put(String text) => state = text;

  void clear() => state = null;
}

final composerDraftProvider = NotifierProvider<ComposerDraft, String?>(
  ComposerDraft.new,
);

/// Pastes longer than this become a file when Settings > Interface asks.
const pastedTextLimit = 1000;

/// What was put into [before] to make [after] (one paste or typing run).
String insertedText(String before, String after) {
  var start = 0;
  while (start < before.length &&
      start < after.length &&
      before[start] == after[start]) {
    start++;
  }
  var end = 0;
  while (end < before.length - start &&
      end < after.length - start &&
      before[before.length - 1 - end] == after[after.length - 1 - end]) {
    end++;
  }
  return after.substring(start, after.length - end);
}
