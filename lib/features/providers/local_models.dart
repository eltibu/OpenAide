/// The models downloaded to the phone, and the ones on their way, kept in
/// models.json next to the files.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ai/ai_providers.dart';
import '../../core/ai/local_llm.dart';
import '../../core/models/model_info.dart';

class LocalModel {
  LocalModel({
    required this.file,
    required this.name,
    required this.repo,
    required this.size,
    this.url,
    this.downloadId,
    this.state = 'ready',
    this.done = 0,
    this.reason,
  });

  factory LocalModel.fromJson(Map<String, dynamic> j) => LocalModel(
    file: '${j['file']}',
    name: '${j['name'] ?? j['file']}',
    repo: j['repo'] as String?,
    size: (j['size'] as num?)?.toInt() ?? 0,
    url: j['url'] as String?,
    downloadId: (j['download'] as num?)?.toInt(),
    state: '${j['state'] ?? 'ready'}',
  );

  /// The file's name in the models folder; also its id in the picker.
  final String file;
  final String name;
  final String? repo;
  int size;

  /// Where it came from, to try again.
  final String? url;
  int? downloadId;

  /// ready, downloading or failed.
  String state;
  int done;
  String? reason;

  bool get ready => state == 'ready';

  Map<String, dynamic> toJson() => {
    'file': file,
    'name': name,
    'repo': ?repo,
    'size': size,
    'url': ?url,
    'download': ?downloadId,
    'state': state,
  };
}

class LocalModels extends AsyncNotifier<List<LocalModel>> {
  Timer? _poll;

  @override
  Future<List<LocalModel>> build() async {
    ref.onDispose(() => _poll?.cancel());
    final dir = await modelsDir();
    var list = <LocalModel>[];
    try {
      final json = jsonDecode(await File('$dir/models.json').readAsString());
      list = [
        for (final m in (json as List).whereType<Map>())
          LocalModel.fromJson(m.cast<String, dynamic>()),
      ];
    } catch (_) {}
    // Files that are gone, and GGUF files no list knows about.
    list.removeWhere((m) => m.ready && !File('$dir/${m.file}').existsSync());
    try {
      for (final f in Directory(dir).listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (name.toLowerCase().endsWith('.gguf') &&
            !list.any((m) => m.file == name)) {
          list.add(
            LocalModel(
              file: name,
              name: name.replaceAll(
                RegExp(r'\.gguf$', caseSensitive: false),
                '',
              ),
              repo: null,
              size: f.lengthSync(),
            ),
          );
        }
      }
    } catch (_) {}
    if (list.any((m) => m.state == 'downloading')) _startPolling();
    return list;
  }

  Future<void> _save(List<LocalModel> list) async {
    final dir = await modelsDir();
    await File('$dir/models.json')
        .writeAsString(jsonEncode([for (final m in list) m.toJson()]));
  }

  void _set(List<LocalModel> list) {
    state = AsyncData([...list]);
    unawaited(_save(list));
  }

  /// A file name for [m] that no other model uses.
  String _fileName(ModelFile m, List<LocalModel> list) {
    final base = m.file.split('/').last.replaceAll(RegExp(r'[^\w.\-]'), '_');
    var name = base;
    for (var i = 2; list.any((x) => x.file == name); i++) {
      name = base.replaceFirst(
        RegExp(r'\.gguf$', caseSensitive: false),
        '-$i.gguf',
      );
    }
    return name;
  }

  /// Starts downloading [m]; an error message if it can't.
  Future<void> download(ModelFile m) async {
    final list = [...await future];
    final already = list.where((x) => x.repo == m.repo && x.name == m.name);
    if (already.isNotEmpty && already.first.state != 'failed') return;
    for (final old in already) {
      if (old.downloadId != null) {
        await cancelDownload(old.downloadId!).catchError((_) {});
      }
    }
    list.removeWhere((x) => x.repo == m.repo && x.name == m.name);
    final file = _fileName(m, list);
    final id = await startDownload(m, file);
    list.add(
      LocalModel(
        file: file,
        name: m.name,
        repo: m.repo,
        size: m.size,
        url: m.url,
        downloadId: id,
        state: 'downloading',
      ),
    );
    _set(list);
    _startPolling();
  }

  void _startPolling() {
    _poll ??= Timer.periodic(const Duration(seconds: 1), (_) => _check());
  }

  Future<void> _check() async {
    final list = [...?state.value];
    final running = [
      for (final m in list)
        if (m.state == 'downloading' && m.downloadId != null) m,
    ];
    if (running.isEmpty) {
      _poll?.cancel();
      _poll = null;
      return;
    }
    final states = {
      for (final s in await downloadStates([
        for (final m in running) m.downloadId!,
      ]))
        s.id: s,
    };
    var finished = false;
    for (final m in running) {
      final s = states[m.downloadId];
      if (s == null) continue;
      m.done = s.done;
      if (s.total > 0) m.size = s.total;
      m.reason = s.reason;
      switch (s.state) {
        case 'done':
          m.state = 'ready';
          m.downloadId = null;
          finished = true;
        case 'failed':
          m.state = 'failed';
          finished = true;
        case 'gone':
          // Cancelled from the notification, or the download was cleared.
          final dir = await modelsDir();
          if (File('$dir/${m.file}').existsSync()) {
            m.state = 'ready';
          } else {
            m.state = 'failed';
            m.reason = 'Download was cancelled';
          }
          m.downloadId = null;
          finished = true;
      }
    }
    if (finished) {
      _set(list);
    } else {
      state = AsyncData(list);
    }
  }

  /// Downloads [m] again after a failure.
  Future<void> retry(LocalModel m) async {
    if (m.url == null) return;
    await download(
      ModelFile(
        repo: m.repo ?? '',
        file: m.file,
        name: m.name,
        size: m.size,
        link: m.url,
      ),
    );
  }

  /// Stops a download, or deletes a downloaded model.
  Future<void> remove(LocalModel m) async {
    if (m.downloadId != null) await cancelDownload(m.downloadId!);
    final dir = await modelsDir();
    for (final path in ['$dir/${m.file}', '$dir/${m.file}.part']) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    // The model may be the one in memory.
    await unloadLocalModel().catchError((_) {});
    _set([...?state.value]..removeWhere((x) => x.file == m.file));
  }
}

final localModelsProvider =
    AsyncNotifierProvider<LocalModels, List<LocalModel>>(LocalModels.new);

/// Downloaded models as picker entries, under "On this phone".
/// Only re-read when a model is added or removed, not on every bit of a
/// download's progress (the server's models are listed alongside).
final localPickerModelsProvider = FutureProvider<List<ModelInfo>>((ref) async {
  await ref.watch(
    localModelsProvider.selectAsync(
      (list) => [
        for (final m in list)
          if (m.ready) m.file,
      ].join('\n'),
    ),
  );
  final list = await ref.read(localModelsProvider.future);
  return [
    for (final m in list)
      if (m.ready) localModelInfo(m),
  ];
});

ModelInfo localModelInfo(LocalModel m) => ModelInfo.fromJson({
  'id': providerModelId(AiProvider.local, m.file),
  'name': m.name,
  'owned_by': AiProvider.local.label,
  'nexus_provider': AiProvider.local.id,
  'provider_model': m.file,
  'tags': [
    {'name': AiProvider.local.label},
  ],
  'info': {
    'meta': {
      'description':
          'Runs on this phone, offline. ${formatBytes(m.size)}'
          '${m.repo == null ? '' : ', from ${m.repo}'}.',
      'capabilities': {'vision': false},
    },
  },
});
