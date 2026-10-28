/// Settings > Models on this phone: download models that run on the phone
/// itself, offline. A few are recommended; any GGUF model on Hugging Face,
/// or any link to one, works too.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/ai/local_llm.dart';
import '../../core/theme.dart';
import 'local_models.dart';

final _deviceProvider = FutureProvider.autoDispose<DeviceInfo>(
  (ref) => deviceInfo(),
);

class LocalModelsScreen extends ConsumerStatefulWidget {
  const LocalModelsScreen({super.key});

  @override
  ConsumerState<LocalModelsScreen> createState() => _LocalModelsScreenState();
}

class _LocalModelsScreenState extends ConsumerState<LocalModelsScreen> {
  final _search = TextEditingController();
  List<HfRepo>? _results;
  bool _searching = false;
  String? _searchError;
  LocalSettings _settings = const LocalSettings();

  @override
  void initState() {
    super.initState();
    LocalSettings.read().then((s) {
      if (mounted) setState(() => _settings = s);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _setSettings(LocalSettings s) async {
    setState(() => _settings = s);
    await s.save();
    // The model reloads with the new memory size on its next reply.
    await unloadLocalModel().catchError((_) {});
  }

  Future<void> _runSearch() async {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final found = await searchHuggingFace(q);
      if (mounted) setState(() => _results = found);
    } catch (e) {
      if (mounted) setState(() => _searchError = '$e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Downloads [m], after a warning when it's too big or the phone is full.
  Future<void> _download(ModelFile m, DeviceInfo? device) async {
    final fit = device == null || m.size == 0
        ? null
        : fitFor(m.size, device.totalRam);
    final noRoom = device != null && m.size > 0 && m.size > device.freeStorage;
    if (fit == Fit.tooBig || noRoom) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(noRoom ? 'Not enough storage' : 'Too big for this phone'),
          content: Text(
            noRoom
                ? '${m.name} needs ${formatBytes(m.size)}, and the phone has '
                      '${formatBytes(device.freeStorage)} free.'
                : '${m.name} needs more memory than this phone can give one '
                      'app (${formatBytes(device!.totalRam)} in all). It will '
                      'probably close itself or run very slowly.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Download anyway'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await ref.read(localModelsProvider.notifier).download(m);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Downloading ${m.name}. It keeps going if you leave the app.',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text("Couldn't start: $e")));
      }
    }
  }

  Future<void> _addLink(DeviceInfo? device) async {
    final input = TextEditingController();
    final link = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add from a link'),
        content: TextField(
          controller: input,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: 'https://huggingface.co/…/model.gguf',
            helperText: 'A link to a .gguf file',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, input.text),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    // Not disposed: the dialog's text field still builds while it closes.
    if (link == null || link.trim().isEmpty) return;
    final m = modelFromLink(link);
    if (m == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "That isn't a link to a .gguf file. On Hugging Face, open the "
              "file and copy its download link.",
            ),
          ),
        );
      }
      return;
    }
    await _download(m, device);
  }

  Future<void> _openRepo(HfRepo repo, DeviceInfo? device) async {
    final picked = await showModalBottomSheet<ModelFile>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _RepoFiles(repo: repo, device: device),
    );
    if (picked != null) await _download(picked, device);
  }

  Future<void> _remove(LocalModel m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(m.ready ? 'Delete ${m.name}?' : 'Stop downloading?'),
        content: Text(
          m.ready
              ? 'Frees ${formatBytes(m.size)}. You can download it again later.'
              : '${m.name} will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(m.ready ? 'Delete' : 'Stop'),
          ),
        ],
      ),
    );
    if (ok == true) await ref.read(localModelsProvider.notifier).remove(m);
  }

  @override
  Widget build(BuildContext context) {
    final device = ref.watch(_deviceProvider).value;
    final models = ref.watch(localModelsProvider);
    final mine = models.value ?? const <LocalModel>[];
    final muted = TextStyle(color: context.nexus.muted);
    return Scaffold(
      appBar: AppBar(title: const Text('Models on this phone')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            'These models run on the phone itself: no server, no account '
            'and no internet once downloaded. They are smaller and slower '
            'than online models, and use battery while they answer. Pick '
            'them in the model picker under "On this phone".',
            style: muted,
          ),
          if (device != null) ...[
            const SizedBox(height: 12),
            if (!device.supported)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    "This phone can't run models on the device: it needs a "
                    '64-bit ARM processor.',
                  ),
                ),
              )
            else
              Text(
                'This phone: ${formatBytes(device.totalRam)} memory, '
                '${formatBytes(device.freeStorage)} free storage.',
                style: muted,
              ),
          ],
          if (mine.isNotEmpty) ...[
            _heading(context, 'Your models'),
            for (final m in mine)
              _MyModel(
                model: m,
                onRemove: () => _remove(m),
                onRetry: () => ref.read(localModelsProvider.notifier).retry(m),
              ),
            ValueListenableBuilder(
              valueListenable: lastLocalStats,
              builder: (context, stats, _) {
                final tps = (stats?['tokens_per_second'] as num?)?.toDouble();
                if (tps == null || tps <= 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Last reply: ${tps.toStringAsFixed(1)} tokens a second.',
                    style: muted,
                  ),
                );
              },
            ),
          ],
          _heading(context, 'How they run'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Let models think first'),
            subtitle: const Text(
              'Models that can (Qwen3) reason before answering: better '
              'answers, but slower.',
            ),
            value: _settings.think,
            onChanged: (v) => _setSettings(
              LocalSettings(contextSize: _settings.contextSize, think: v),
            ),
          ),
          const SizedBox(height: 4),
          const Text('Conversation memory'),
          const SizedBox(height: 8),
          SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 2048, label: Text('Short')),
              ButtonSegment(value: 4096, label: Text('Normal')),
              ButtonSegment(value: 8192, label: Text('Long')),
            ],
            selected: {_settings.contextSize},
            onSelectionChanged: (v) => _setSettings(
              LocalSettings(contextSize: v.first, think: _settings.think),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'How much of the chat the model keeps in mind. Longer uses more '
            'memory and starts slower.',
            style: muted,
          ),
          _heading(context, 'Recommended'),
          for (final m in recommendedModels)
            _Downloadable(
              model: m,
              device: device,
              have: mine.any((x) => x.repo == m.repo && x.name == m.name),
              onDownload: () => _download(m, device),
            ),
          _heading(context, 'Find any model on Hugging Face'),
          TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _runSearch(),
            decoration: InputDecoration(
              hintText: 'Search, e.g. qwen, llama, mistral, phi',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: _runSearch,
                    ),
              border: const OutlineInputBorder(),
            ),
          ),
          if (_searchError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _searchError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_results != null && _results!.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('No GGUF models found.', style: muted),
            ),
          for (final r in _results ?? const <HfRepo>[])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(r.id),
              subtitle: Text(
                '${_count(r.downloads)} downloads · ${_count(r.likes)} likes',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openRepo(r, device),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _addLink(device),
            icon: const Icon(Icons.link),
            label: const Text('Add from a link'),
          ),
        ],
      ),
    );
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

String _count(int n) => n >= 1000000
    ? '${(n / 1000000).toStringAsFixed(1)}M'
    : n >= 1000
    ? '${(n / 1000).toStringAsFixed(1)}k'
    : '$n';

/// A fit chip: green, amber or red.
class _FitLabel extends StatelessWidget {
  const _FitLabel({required this.size, required this.device});
  final int size;
  final DeviceInfo? device;

  @override
  Widget build(BuildContext context) {
    if (device == null || size == 0) return const SizedBox.shrink();
    final fit = fitFor(size, device!.totalRam);
    final scheme = Theme.of(context).colorScheme;
    final color = switch (fit) {
      Fit.good => Colors.green.shade700,
      Fit.tight => Colors.orange.shade800,
      Fit.tooBig => scheme.error,
    };
    final icon = switch (fit) {
      Fit.good => Icons.check_circle_outline,
      Fit.tight => Icons.warning_amber_outlined,
      Fit.tooBig => Icons.block,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            fit == Fit.tooBig ? fit.label : '${fit.label} · ${speedFor(size)}',
            style: TextStyle(color: color, fontSize: 12.5),
          ),
        ),
      ],
    );
  }
}

class _Downloadable extends StatelessWidget {
  const _Downloadable({
    required this.model,
    required this.device,
    required this.have,
    required this.onDownload,
  });

  final ModelFile model;
  final DeviceInfo? device;
  final bool have;
  final VoidCallback onDownload;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 8),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${model.name}  ·  ${model.size == 0 ? 'size unknown' : formatBytes(model.size)}',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                if (model.blurb != null) ...[
                  const SizedBox(height: 2),
                  Text(model.blurb!),
                ],
                const SizedBox(height: 4),
                _FitLabel(size: model.size, device: device),
              ],
            ),
          ),
          have
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.check),
                )
              : IconButton(
                  tooltip: 'Download',
                  icon: const Icon(Icons.download),
                  onPressed: device?.supported == false ? null : onDownload,
                ),
        ],
      ),
    ),
  );
}

class _MyModel extends StatelessWidget {
  const _MyModel({
    required this.model,
    required this.onRemove,
    required this.onRetry,
  });

  final LocalModel model;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final m = model;
    final muted = TextStyle(color: context.nexus.muted);
    final progress = m.size > 0 ? m.done / m.size : null;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(m.name, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  switch (m.state) {
                    'downloading' => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LinearProgressIndicator(value: progress),
                        const SizedBox(height: 4),
                        Text(
                          m.size > 0
                              ? '${formatBytes(m.done)} of ${formatBytes(m.size)}'
                                    '${m.reason == null ? '' : ' · ${m.reason}'}'
                              : m.reason ?? 'Starting…',
                          style: muted,
                        ),
                      ],
                    ),
                    'failed' => Text(
                      m.reason ?? 'Download failed',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    _ => Text(
                      'Ready · ${formatBytes(m.size)}'
                      '${m.repo == null ? '' : ' · ${m.repo}'}',
                      style: muted,
                    ),
                  },
                ],
              ),
            ),
            if (m.state == 'failed' && m.url != null)
              IconButton(
                tooltip: 'Try again',
                icon: const Icon(Icons.refresh),
                onPressed: onRetry,
              ),
            IconButton(
              tooltip: m.ready ? 'Delete' : 'Stop',
              icon: Icon(m.ready ? Icons.delete_outline : Icons.close),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// A Hugging Face repo's files, each with its size and fit.
class _RepoFiles extends StatefulWidget {
  const _RepoFiles({required this.repo, required this.device});
  final HfRepo repo;
  final DeviceInfo? device;

  @override
  State<_RepoFiles> createState() => _RepoFilesState();
}

class _RepoFilesState extends State<_RepoFiles> {
  late final Future<({List<ModelFile> files, bool gated})> _files =
      huggingFaceFiles(widget.repo.id);

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              widget.repo.id,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Each file is the same model at a different size. Q4_K_M is '
              'usually the best balance; bigger files are a little smarter '
              'and slower.',
              style: TextStyle(color: context.nexus.muted),
            ),
          ),
          Expanded(
            child: FutureBuilder(
              future: _files,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(child: Text('${snap.error}'));
                }
                final data = snap.data;
                if (data == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (data.files.isEmpty) {
                  return const Center(
                    child: Text('No single-file GGUF models here.'),
                  );
                }
                return ListView(
                  children: [
                    if (data.gated)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: Text(
                          'This model needs a Hugging Face sign-in to '
                          'download, so it will probably fail. Look for a '
                          'copy by another uploader (bartowski or unsloth).',
                        ),
                      ),
                    for (final f in data.files)
                      ListTile(
                        title: Text(f.file),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(formatBytes(f.size)),
                            _FitLabel(size: f.size, device: widget.device),
                          ],
                        ),
                        trailing: const Icon(Icons.download),
                        onTap: () => Navigator.pop(context, f),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
