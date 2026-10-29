/// Ollama model downloads that keep going while you move around the app:
/// started from Admin > Models > Manage or from the chat's model picker,
/// shown with their progress in both, and cancelled from either.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../chat/chat_controller.dart' show modelsProvider;

/// Pull progress as Ollama reports it, in percent; null when it doesn't say.
double? pullPercent(Map<String, dynamic> p) {
  final total = (p['total'] as num?)?.toDouble();
  final done = (p['completed'] as num?)?.toDouble();
  if (total == null || total <= 0 || done == null) return null;
  return (done / total * 100).clamp(0, 100).toDouble();
}

/// How a pull ended.
enum PullEnd { ready, failed, cancelled }

/// Running pulls: model tag → (status, percent).
class OllamaPulls extends Notifier<Map<String, (String, double?)>> {
  final _subs = <String, StreamSubscription>{};
  final _dones = <String, Completer<(PullEnd, String?)>>{};

  @override
  Map<String, (String, double?)> build() {
    ref.onDispose(() {
      for (final s in _subs.values) {
        s.cancel();
      }
    });
    return const {};
  }

  void _set(String tag, (String, double?)? v) => state = {
    for (final e in state.entries)
      if (e.key != tag) e.key: e.value,
    tag: ?v,
  };

  /// Pulls [tag] onto the Ollama server at [server] (its place in the
  /// admin's list). Ends with how it went, and the error when it failed.
  /// The model list is refreshed afterwards.
  Future<(PullEnd, String?)> pull(String tag, {int server = 0}) async {
    tag = tag.trim();
    if (tag.isEmpty) return (PullEnd.failed, 'No model name');
    final running = _dones[tag];
    if (running != null) return running.future;
    _set(tag, ('Starting', null));
    final done = _dones[tag] = Completer();
    String? error;
    var status = '';
    _subs[tag] = ref
        .read(clientProvider)
        .streamJson('POST', '/ollama/api/pull/$server', {'name': tag})
        .listen(
          (p) {
            if (p['error'] != null) {
              error = '${p['error']}';
              return;
            }
            status = '${p['status'] ?? ''}';
            _set(tag, (status, pullPercent(p)));
          },
          onError: (Object e) {
            if (!done.isCompleted) done.complete((PullEnd.failed, '$e'));
          },
          onDone: () {
            if (!done.isCompleted) {
              done.complete(
                status == 'success'
                    ? (PullEnd.ready, null)
                    : (PullEnd.failed, error ?? 'It stopped before finishing'),
              );
            }
          },
          cancelOnError: true,
        );
    final end = await done.future;
    _subs.remove(tag)?.cancel();
    _dones.remove(tag);
    _set(tag, null);
    ref.invalidate(modelsProvider);
    return end;
  }

  /// Stops the pull of [tag]; its [pull] ends as cancelled.
  void cancel(String tag) {
    _subs.remove(tag)?.cancel();
    final done = _dones[tag];
    if (done != null && !done.isCompleted) {
      done.complete((PullEnd.cancelled, null));
    }
  }
}

final ollamaPullsProvider =
    NotifierProvider<OllamaPulls, Map<String, (String, double?)>>(
      OllamaPulls.new,
    );
