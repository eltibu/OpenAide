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
