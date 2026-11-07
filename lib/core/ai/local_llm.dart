/// Models that run on the phone itself (llama.cpp, GGUF files), with no
/// server and no internet: the engine (LocalLlm.kt), the recommended
/// models, Hugging Face search and the "will it fit" check.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'ai_providers.dart';

const _channel = MethodChannel('nexus/local_llm');
const _replies = EventChannel('nexus/local_llm/reply');

/// What the phone has to offer a model.
class DeviceInfo {
  const DeviceInfo({
    required this.totalRam,
    required this.freeStorage,
    required this.supported,
  });

  factory DeviceInfo.fromMap(Map<Object?, Object?> m) => DeviceInfo(
    totalRam: (m['totalRam'] as num?)?.toInt() ?? 0,
    freeStorage: (m['freeStorage'] as num?)?.toInt() ?? 0,
    supported: m['supported'] == true,
  );

  final int totalRam;
  final int freeStorage;

  /// Whether llama.cpp runs here: it's built for 64-bit ARM.
  final bool supported;
}

Future<DeviceInfo> deviceInfo() async => DeviceInfo.fromMap(
  await _channel.invokeMapMethod<Object?, Object?>('deviceInfo') ?? const {},
);

Future<String> modelsDir() async =>
    (await _channel.invokeMethod<String>('modelsDir'))!;

enum Fit {
  good('Runs well on this phone'),
  tight('Tight fit: may be slow, close other apps first'),
  tooBig('Too big for this phone');

  const Fit(this.label);
  final String label;
}

/// How a model of [bytes] fits in [totalRam]. Android gives one app well
/// under the phone's memory, and the model needs its file size plus room
/// for the conversation.
Fit fitFor(int bytes, int totalRam) {
  if (totalRam <= 0) return Fit.tight;
  final need = bytes * 1.15 + 300 * _mb;
  if (need <= totalRam * 0.4) return Fit.good;
  if (need <= totalRam * 0.6) return Fit.tight;
  return Fit.tooBig;
}

/// A rough speed: phones read the whole model for every word, so speed
/// follows size.
String speedFor(int bytes) {
  if (bytes < 1300 * _mb) return 'Fast';
  if (bytes < 2800 * _mb) return 'Medium speed';
  return 'Slow';
}

const _mb = 1024 * 1024;

String formatBytes(int bytes) {
  if (bytes >= 1024 * _mb) {
    return '${(bytes / (1024 * _mb)).toStringAsFixed(1)} GB';
  }
  return '${(bytes / _mb).round()} MB';
}

/// One GGUF file on Hugging Face.
class ModelFile {
  const ModelFile({
    required this.repo,
    required this.file,
    required this.name,
    required this.size,
    this.blurb,
    this.link,
    this.toolScore,
  });

  final String repo;
  final String file;
  final String name;

  /// Bytes; for recommended models, close to the real size.
  final int size;
  final String? blurb;

  /// Where to download it from, when it's not a Hugging Face file.
  final String? link;

  /// Out of 100: how many of OpenAide's tool tasks (phone actions, search,
  /// skills, MCP) it got right in our tests. Recommended models only.
  final int? toolScore;

  String get url =>
      link ??
      'https://huggingface.co/$repo/resolve/main/${Uri.encodeComponent(file).replaceAll('%2F', '/')}?download=true';
}

/// A model from a link someone pasted: a Hugging Face page or file, or
/// any web address of a .gguf file. Null if it isn't one.
ModelFile? modelFromLink(String text) {
  final uri = Uri.tryParse(text.trim());
  if (uri == null || !uri.isScheme('https') && !uri.isScheme('http')) {
    return null;
  }
  final path = uri.pathSegments;
  final name = path.isEmpty ? '' : path.last;
  if (!name.toLowerCase().endsWith('.gguf')) return null;
  if (uri.host == 'huggingface.co' &&
      path.length >= 5 &&
      (path[2] == 'resolve' || path[2] == 'blob')) {
    return ModelFile(
      repo: '${path[0]}/${path[1]}',
      file: path.sublist(4).join('/'),
      name: name.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), ''),
      size: 0,
      link: uri
          .replace(pathSegments: [...path.take(2), 'resolve', ...path.skip(3)])
          .toString(),
    );
  }
  return ModelFile(
    repo: uri.host,
    file: name,
    name: name.replaceAll(RegExp(r'\.gguf$', caseSensitive: false), ''),
    size: 0,
    link: uri.toString(),
  );
}

/// A starting point. People can pick anything else from Hugging Face.
/// Only models that did well in our tool tests (phone actions, web search,
/// skills, MCP; the same prompt and parser the app uses) are here, best
/// first. [recommendedFor] orders them for each phone's memory.
const recommendedModels = [
  ModelFile(
    repo: 'unsloth/Qwen3-4B-Instruct-2507-GGUF',
    file: 'Qwen3-4B-Instruct-2507-Q4_K_M.gguf',
    name: 'Qwen3 4B 2507',
    size: 2497 * _mb,
    blurb:
        'The best with tools and quick to answer. For phones with 8 GB or '
        'more.',
    toolScore: 88,
  ),
  ModelFile(
    repo: 'unsloth/Qwen3-4B-GGUF',
    file: 'Qwen3-4B-Q4_K_M.gguf',
    name: 'Qwen3 4B',
    size: 2497 * _mb,
    blurb: 'Just as good with tools; thinks first, so slower. 8 GB or more.',
    toolScore: 88,
  ),
  ModelFile(
    repo: 'bartowski/Llama-3.2-3B-Instruct-GGUF',
    file: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    name: 'Llama 3.2 3B',
    size: 2019 * _mb,
    blurb: 'Good with tools and fast. Runs well on most phones with 6 GB.',
    toolScore: 76,
  ),
  ModelFile(
    repo: 'bartowski/microsoft_Phi-4-mini-instruct-GGUF',
    file: 'microsoft_Phi-4-mini-instruct-Q4_K_M.gguf',
    name: 'Phi-4 mini',
    size: 2491 * _mb,
    blurb: "Microsoft's small model; good at reasoning and math.",
    toolScore: 76,
  ),
  ModelFile(
    repo: 'unsloth/gemma-3-4b-it-GGUF',
    file: 'gemma-3-4b-it-Q4_K_M.gguf',
    name: 'Gemma 3 4B',
    size: 2489 * _mb,
    blurb: 'Strong writer, many languages. Needs 8 GB or more.',
    toolScore: 71,
  ),
  ModelFile(
    repo: 'unsloth/Qwen3-1.7B-GGUF',
    file: 'Qwen3-1.7B-Q4_K_M.gguf',
    name: 'Qwen3 1.7B',
    size: 1107 * _mb,
    blurb: 'The pick for phones with 4 GB. Thinks before it answers.',
    toolScore: 65,
  ),
  ModelFile(
    repo: 'unsloth/Qwen3-0.6B-GGUF',
    file: 'Qwen3-0.6B-Q4_K_M.gguf',
    name: 'Qwen3 0.6B',
    size: 397 * _mb,
    blurb: 'Tiny and quick, for any phone. Simple questions and actions.',
    toolScore: 65,
  ),
];

/// The recommended models in the order that suits a phone with
/// [totalRam]: the ones that run well first, best with tools first, and
/// the ones too big for it last.
List<ModelFile> recommendedFor(int totalRam) {
  int rank(ModelFile m) => totalRam <= 0 ? 0 : fitFor(m.size, totalRam).index;
  // The list is already best first; only how well it fits moves a model.
  final order = {for (final (i, m) in recommendedModels.indexed) m: i};
  return [...recommendedModels]..sort(
    (a, b) => rank(a) != rank(b)
        ? rank(a).compareTo(rank(b))
        : order[a]!.compareTo(order[b]!),
  );
}

// Hugging Face: search every GGUF model there.

const _hf = 'https://huggingface.co';

class HfRepo {
  const HfRepo({
    required this.id,
    required this.downloads,
    required this.likes,
  });
  final String id;
  final int downloads;
  final int likes;
}

/// GGUF models on Hugging Face matching [query], most downloaded first.
Future<List<HfRepo>> searchHuggingFace(
  String query, {
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(
          Uri.parse('$_hf/api/models').replace(
            queryParameters: {
              'search': query.trim(),
              'filter': 'gguf',
              'sort': 'downloads',
              'direction': '-1',
              'limit': '40',
            },
          ),
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      throw AiException('Hugging Face answered ${res.statusCode}.');
    }
    return [
      for (final m in (jsonDecode(res.body) as List).whereType<Map>())
        HfRepo(
          id: '${m['id'] ?? m['modelId']}',
          downloads: (m['downloads'] as num?)?.toInt() ?? 0,
          likes: (m['likes'] as num?)?.toInt() ?? 0,
        ),
    ];
  } on TimeoutException {
    throw AiException("Hugging Face didn't answer in time.");
  } on SocketException {
    throw AiException("Couldn't reach Hugging Face. Check the internet.");
  } finally {
    if (client == null) c.close();
  }
}

/// The GGUF files in [repo] that can be downloaded as one file, smallest
/// first, and whether the repo needs a Hugging Face sign-in.
Future<({List<ModelFile> files, bool gated})> huggingFaceFiles(
  String repo, {
  http.Client? client,
}) async {
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(Uri.parse('$_hf/api/models/$repo?blobs=true'))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode >= 400) {
      throw AiException('Hugging Face answered ${res.statusCode}.');
    }
    final json = jsonDecode(res.body) as Map;
    return (
      files: ggufFiles(repo, json['siblings'] as List? ?? const []),
      gated: json['gated'] != null && json['gated'] != false,
    );
  } on TimeoutException {
    throw AiException("Hugging Face didn't answer in time.");
  } on SocketException {
    throw AiException("Couldn't reach Hugging Face. Check the internet.");
  } finally {
    if (client == null) c.close();
  }
}

/// Model files among a repo's [siblings]: not the vision add-ons (mmproj),
/// and not models split over several files.
@visibleForTesting
List<ModelFile> ggufFiles(String repo, List siblings) {
  final split = RegExp(r'-\d{5}-of-\d{5}\.gguf$');
  return [
    for (final s in siblings.whereType<Map>())
      if ('${s['rfilename']}'.toLowerCase().endsWith('.gguf') &&
          !'${s['rfilename']}'.toLowerCase().contains('mmproj') &&
          !split.hasMatch('${s['rfilename']}'))
        ModelFile(
          repo: repo,
          file: '${s['rfilename']}',
          name: '${s['rfilename']}'
              .split('/')
              .last
              .replaceAll(RegExp(r'\.gguf$', caseSensitive: false), ''),
          size:
              (s['size'] as num?)?.toInt() ??
              ((s['lfs'] as Map?)?['size'] as num?)?.toInt() ??
              0,
        ),
  ]..sort((a, b) => a.size.compareTo(b.size));
}

// Replies.

/// The last reply's speed, for the models screen.
final lastLocalStats = ValueNotifier<Map<String, dynamic>?>(null);

/// Streams the reply of the model in [path] to [messages]. Photos are left
/// out: these models read text only.
Stream<AiChunk> streamLocalReply({
  required String path,
  required List<AiMessage> messages,
  String? system,
  Map<String, dynamic> params = const {},
  int contextSize = 4096,
  bool think = true,
}) async* {
  if (!await File(path).exists()) {
    throw AiException(
      "This model isn't on the phone anymore. Download it again in "
      'Settings > Models on this phone.',
    );
  }
  final maxTokens = ((params['max_tokens'] as num?)?.toInt() ?? 2048).clamp(
    64,
    contextSize ~/ 2,
  );
  final chat = fitHistory(
    [
      if (system != null && system.trim().isNotEmpty)
        AiMessage('system', system),
      for (final m in messages)
        if (m.text.isNotEmpty) AiMessage(m.role, m.text),
    ],
    // About 3 characters a token, leaving room for the reply.
    maxChars: (contextSize - maxTokens) * 3,
  );
  final split = ThinkSplitter();
  try {
    await for (final event in _replies.receiveBroadcastStream({
      'path': path,
      'context': contextSize,
      'roles': [for (final m in chat) m.role],
      'contents': [for (final m in chat) m.text],
      'temperature': (params['temperature'] as num?)?.toDouble() ?? 0.7,
      'topP': (params['top_p'] as num?)?.toDouble() ?? 0.95,
      'maxTokens': maxTokens,
      'think': think,
    })) {
      final e = (event as Map).cast<String, Object?>();
      if (e['text'] is String) {
        final chunk = split.add(e['text'] as String);
        if (chunk != null) yield chunk;
      } else if (e['done'] is String) {
        final tail = split.close();
        if (tail != null) yield tail;
        try {
          lastLocalStats.value = (jsonDecode(e['done'] as String) as Map)
              .cast<String, dynamic>();
        } catch (_) {}
      }
    }
  } on PlatformException catch (e) {
    throw AiException(e.message ?? 'The model stopped.');
  } on MissingPluginException {
    throw AiException("Models on the phone don't work on this device.");
  }
}

/// The reply of the downloaded model [file] (its id in the picker), with
/// the settings from the models screen.
Stream<AiChunk> streamLocalModel({
  required String file,
  required List<AiMessage> messages,
  String? system,
  Map<String, dynamic> params = const {},
}) async* {
  final dir = await modelsDir();
  final settings = await LocalSettings.read();
  yield* streamLocalReply(
    path: '$dir/$file',
    messages: messages,
    system: system,
    params: params,
    contextSize: settings.contextSize,
    think: settings.think,
  );
}

/// How models on the phone run, from the models screen.
class LocalSettings {
  const LocalSettings({this.contextSize = 4096, this.think = true});

  /// Tokens of conversation the model keeps in mind; more uses more memory.
  final int contextSize;

  /// Lets models that can think (Qwen3) think before answering.
  final bool think;

  static Future<File> _file() async =>
      File('${await modelsDir()}/settings.json');

  static Future<LocalSettings> read() async {
    try {
      final json = jsonDecode(await (await _file()).readAsString()) as Map;
      return LocalSettings(
        contextSize: (json['context'] as num?)?.toInt() ?? 4096,
        think: json['think'] != false,
      );
    } catch (_) {
      return const LocalSettings();
    }
  }

  Future<void> save() async => (await _file()).writeAsString(
    jsonEncode({'context': contextSize, 'think': think}),
  );
}

/// Stops the reply being written.
Future<void> stopLocalReply() => _channel.invokeMethod('stop');

/// Frees the model's memory.
Future<void> unloadLocalModel() => _channel.invokeMethod('unload');

/// The newest messages that fit in [maxChars], always keeping the system
/// prompt and the last message.
@visibleForTesting
List<AiMessage> fitHistory(List<AiMessage> chat, {required int maxChars}) {
  final system = chat.where((m) => m.role == 'system').toList();
  final rest = chat.where((m) => m.role != 'system').toList();
  var used = system.fold<int>(0, (n, m) => n + m.text.length);
  final kept = <AiMessage>[];
  // While tools run, the person's question comes before the calls and
  // their results; it's always kept, or the model forgets what was asked.
  final asked = rest.lastIndexWhere(
    (m) => m.role == 'user' && !m.text.trimLeft().startsWith('<tool_response>'),
  );
  for (final (i, m) in rest.indexed.toList().reversed) {
    if (kept.isNotEmpty && i < asked && used + m.text.length > maxChars) break;
    kept.insert(0, m);
    used += m.text.length;
  }
  // Chat templates expect the conversation to start with a person.
  while (kept.length > 1 && kept.first.role != 'user') {
    kept.removeAt(0);
  }
  return [...system, ...kept];
}

/// Splits `<think>...</think>` (Qwen, DeepSeek and others) out of the text
/// as it streams, so the thinking shows in its own step.
class ThinkSplitter {
  static const _open = '<think>';
  static const _close = '</think>';

  String _held = '';
  bool _thinking = false;
  bool _started = false;

  AiChunk? add(String piece) {
    var s = _held + piece;
    _held = '';
    final text = StringBuffer();
    final thought = StringBuffer();
    while (s.isNotEmpty) {
      if (!_started) {
        final t = s.trimLeft();
        if (t.isEmpty) return null;
        if (t.startsWith(_open)) {
          _thinking = true;
          s = t.substring(_open.length);
        } else if (_open.startsWith(t)) {
          _held = s;
          break;
        }
        _started = true;
        continue;
      }
      final tag = _thinking ? _close : _open;
      final at = s.indexOf(tag);
      if (at >= 0) {
        (_thinking ? thought : text).write(s.substring(0, at));
        s = s.substring(at + tag.length);
        _thinking = !_thinking;
        if (!_thinking) s = s.trimLeft();
        continue;
      }
      // Hold back what may be the start of a tag.
      var keep = 0;
      for (var n = tag.length - 1; n > 0; n--) {
        if (s.endsWith(tag.substring(0, n))) {
          keep = n;
          break;
        }
      }
      (_thinking ? thought : text).write(s.substring(0, s.length - keep));
      _held = s.substring(s.length - keep);
      break;
    }
    if (text.isEmpty && thought.isEmpty) return null;
    return AiChunk(text: '$text', thinking: '$thought');
  }

  /// Whatever was held back at the end.
  AiChunk? close() {
    if (_held.isEmpty) return null;
    final held = _held;
    _held = '';
    return _thinking ? AiChunk(thinking: held) : AiChunk(text: held);
  }
}

// Downloads, through Android's download manager.

Future<int> startDownload(ModelFile m, String fileName) async =>
    (await _channel.invokeMethod<int>('download', {
      'url': m.url,
      'file': fileName,
      'title': m.name,
    }))!;

class DownloadState {
  const DownloadState(this.id, this.state, this.done, this.total, this.reason);
  final int id;

  /// running, waiting, paused, done, failed or gone.
  final String state;
  final int done;
  final int total;
  final String? reason;
}

Future<List<DownloadState>> downloadStates(List<int> ids) async {
  final list =
      await _channel.invokeListMethod<Map>('downloads', {'ids': ids}) ??
      const [];
  return [
    for (final m in list)
      DownloadState(
        (m['id'] as num).toInt(),
        '${m['state']}',
        (m['done'] as num?)?.toInt() ?? 0,
        (m['total'] as num?)?.toInt() ?? 0,
        m['reason'] as String?,
      ),
  ];
}

Future<void> cancelDownload(int id) =>
    _channel.invokeMethod('cancelDownload', {'id': id});
