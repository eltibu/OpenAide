/// Hands-free: say "Hey OpenAide" and the assistant opens, as a long-press
/// of power or home would. The phone listens with a small offline speech
/// model (WakeService.kt), downloaded once; nothing leaves the phone until
/// the phrase is heard. Settings > Phone and assistant.
library;

import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../../core/i18n/app_strings.dart';
import '../../core/theme.dart';
import '../voice/call_audio.dart';
import 'phone_launch.dart';

/// Vosk's small English model (Apache 2.0, about 40 MB).
const wakeModelName = 'vosk-model-small-en-us-0.15';
final wakeModelUrl = Uri.parse(
  'https://alphacephei.com/vosk/models/$wakeModelName.zip',
);

/// The SHA-256 of that zip: a download that differs (a changed or tampered
/// file) is refused, since the phone runs what's in it. Checked by the
/// build ("Check the wake-phrase model").
const wakeModelSha256 = '';

/// The model's folder in [into], downloading and unpacking it the first
/// time. [progress] gets 0 to 1 while it downloads.
Future<String> downloadWakeModel(
  Directory into, {
  Uri? from,
  String sha256Hex = wakeModelSha256,
  http.Client? client,
  void Function(double)? progress,
}) async {
  final dir = Directory('${into.path}/$wakeModelName');
  if (File('${dir.path}/am/final.mdl').existsSync()) return dir.path;
  final web = client ?? http.Client();
  final zip = File('${into.path}/$wakeModelName.zip');
  try {
    into.createSync(recursive: true);
    final res = await web.send(http.Request('GET', from ?? wakeModelUrl));
    if (res.statusCode != 200) {
      throw HttpException('The download answered ${res.statusCode}');
    }
    final total = res.contentLength ?? 0;
    var got = 0;
    final out = zip.openWrite();
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    await for (final chunk in res.stream) {
      out.add(chunk);
      hash.add(chunk);
      got += chunk.length;
      if (total > 0) progress?.call(got / total);
    }
    await out.close();
    hash.close();
    if (sha256Hex.isNotEmpty && '${digest.value}' != sha256Hex) {
      throw const FileSystemException(
        "The speech model download wasn't the expected file",
      );
    }
    // The zip holds the model's own folder.
    await extractFileToDisk(zip.path, into.path);
    if (!File('${dir.path}/am/final.mdl').existsSync()) {
      throw const FileSystemException('The download had no speech model');
    }
    return dir.path;
  } finally {
    if (zip.existsSync()) zip.deleteSync();
    if (client == null) web.close();
  }
}

/// What the phone has: whether it listens, its model, and whether Android
/// lets OpenAide open over other apps when it hears you.
typedef WakeState = ({bool on, String? model, bool canOpen});

Future<WakeState?> wakeState() async {
  try {
    final m = await phoneChannel.invokeMapMethod<String, dynamic>('wakeState');
    if (m == null) return null;
    return (
      on: m['on'] == true,
      model: m['model'] as String?,
      canOpen: m['canOpen'] == true,
    );
  } on MissingPluginException {
    return null;
  }
}

Future<void> setWake(bool on, {String? model}) async {
  try {
    await phoneChannel.invokeMethod('wake', {'on': on, 'model': model});
  } on MissingPluginException {
    // Not on a phone.
  }
}

Future<void> openOverOtherApps() async {
  try {
    await phoneChannel.invokeMethod('openOverOtherApps');
  } on MissingPluginException {
    // Not on a phone.
  }
}

/// The switch in Settings > Phone and assistant.
class WakePhraseTile extends StatefulWidget {
  const WakePhraseTile({super.key});

  @override
  State<WakePhraseTile> createState() => _WakePhraseTileState();
}

class _WakePhraseTileState extends State<WakePhraseTile>
    with WidgetsBindingObserver {
  WakeState? _state;
  double? _download;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Back from Android's "Display over other apps".
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final s = await wakeState();
    if (mounted) setState(() => _state = s);
  }

  Future<void> _turn(bool on) async {
    setState(() => _error = null);
    if (!on) {
      await setWake(false);
      return _check();
    }
    // The microphone first: Android asks once.
    final audio = AndroidCallAudio();
    final mic = await audio.start();
    await audio.stop();
    if (mic != 'started') {
      setState(
        () => _error = mic == 'denied'
            ? tr('OpenAide needs the microphone to hear you.')
            : mic,
      );
      return;
    }
    var model = _state?.model;
    if (model == null || !Directory(model).existsSync()) {
      setState(() => _download = 0);
      try {
        final support = await getApplicationSupportDirectory();
        model = await downloadWakeModel(
          Directory('${support.path}/wake'),
          progress: (p) {
            if (mounted) setState(() => _download = p);
          },
        );
      } catch (e) {
        if (mounted) {
          setState(() {
            _download = null;
            _error = '${tr("Couldn't download the listening model")}: $e';
          });
        }
        return;
      }
      if (!mounted) return;
      setState(() => _download = null);
    }
    await setWake(true, model: model);
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    if (state == null) return const SizedBox.shrink();
    final muted = context.nexus.muted;
    final download = _download;
    return Column(
      children: [
        SwitchListTile(
          secondary: const Icon(Icons.record_voice_over_outlined),
          title: const T('Hands-free: "Hey OpenAide"'),
          subtitle: Text(
            download != null
                ? '${tr('Downloading the listening model')} '
                      '${(download * 100).round()}%'
                : tr(
                    'Say "Hey OpenAide" while the phone is unlocked and the '
                    'assistant opens. Listening happens on the phone with a '
                    'small offline model (about 40 MB, English); nothing is '
                    'sent until it hears you. Uses some battery.',
                  ),
            style: TextStyle(color: muted),
          ),
          value: state.on,
          onChanged: download != null ? null : _turn,
        ),
        if (download != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(value: download),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (state.on && !state.canOpen)
          ListTile(
            leading: const Icon(Icons.layers_outlined),
            title: const T('Allow OpenAide to open over other apps'),
            subtitle: T(
              'Android needs this to open the assistant when it hears you '
              'while you\'re in another app. Turn on OpenAide in the list '
              'that opens.',
              style: TextStyle(color: muted),
            ),
            trailing: const Icon(Icons.open_in_new),
            onTap: openOverOtherApps,
          ),
      ],
    );
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
