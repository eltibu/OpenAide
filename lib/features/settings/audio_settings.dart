/// Settings > Audio, as on the web: the language you speak, sending right
/// after dictation, the voice replies are read in, how fast, and reading
/// every reply aloud.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/phone_voice.dart';
import '../../core/auth/session.dart';
import '../chat/chat_controller.dart';
import '../chat/read_aloud.dart';
import '../chat/speech_prefs.dart';
import 'settings_screen.dart';
import '../../core/i18n/app_strings.dart';

/// The server's text-to-speech voices, id to name.
final ttsVoicesProvider = FutureProvider.autoDispose<List<(String, String)>>((
  ref,
) async {
  final res = await ref
      .watch(clientProvider)
      .send('GET', '/api/v1/audio/voices');
  final list = (res is Map ? res['voices'] : null) as List? ?? const [];
  return [
    for (final v in list)
      if (v is Map && v['id'] != null)
        ('${v['id']}', '${v['name'] ?? v['id']}'),
  ];
});

class AudioSettings extends ConsumerStatefulWidget {
  const AudioSettings({super.key});

  @override
  ConsumerState<AudioSettings> createState() => _AudioSettingsState();
}

class _AudioSettingsState extends ConsumerState<AudioSettings> {
  final _language = TextEditingController();
  double? _rate;
  Timer? _debounce;
  bool _loaded = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _language.dispose();
    super.dispose();
  }

  Future<void> _save(Map<String, dynamic> fields) async {
    try {
      await ref.read(settingsApiProvider).patchUi(fields);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$e')));
      }
    }
    ref.invalidate(uiSettingsProvider);
    ref.invalidate(userSettingsProvider);
  }

  /// `audio` is saved whole, so the other half is kept as it was.
  Future<void> _saveAudio(
    Map<String, dynamic> ui,
    String part,
    Map<String, dynamic> fields,
  ) {
    final audio = {...?(ui['audio'] as Map?)?.cast<String, dynamic>()};
    final now = {...?(audio[part] as Map?)?.cast<String, dynamic>(), ...fields}
      ..removeWhere((_, v) => v == null);
    return _save({
      'audio': {...audio, part: now},
    });
  }

  @override
  Widget build(BuildContext context) {
    final ui = ref.watch(uiSettingsProvider);
    final config = ref.watch(serverConfigProvider).value;
    final serverVoice =
        '${((config?['audio'] as Map?)?['tts'] as Map?)?['voice'] ?? ''}';
    return Scaffold(
      appBar: AppBar(title: const T('Audio')),
      body: ui.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text('Couldn\'t load your settings.\n$e'),
        ),
        data: (ui) {
          final settings = {'ui': ui};
          if (!_loaded) {
            _loaded = true;
            _language.text = speechLanguage(settings) ?? '';
          }
          final tts = ((ui['audio'] as Map?)?['tts'] as Map?) ?? const {};
          final onPhone = phoneSpeechOn(config);
          final voice = '${tts['voice'] ?? ''}';
          final rate = _rate ?? speechRate(settings);
          // Section names in the accent colour, as on every settings page.
          final heading = Theme.of(context).textTheme.titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary);
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: T('Speech to text', style: heading),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: TextField(
                  controller: _language,
                  decoration: InputDecoration(
                    labelText: tr('Language you speak'),
                    hintText: tr('e.g. en, es (empty: detect it)'),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) {
                    _debounce?.cancel();
                    _debounce = Timer(
                      const Duration(milliseconds: 800),
                      () => _saveAudio(ui, 'stt', {
                        'language': v.trim().isEmpty ? null : v.trim(),
                      }),
                    );
                  },
                ),
              ),
              SwitchListTile(
                title: const T('Send right after dictation'),
                subtitle: const T(
                  'Words from the voice note mic are sent, not put in the box',
                ),
                value: ui['speechAutoSend'] == true,
                onChanged: (on) => _save({'speechAutoSend': on}),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: T('Text to speech', style: heading),
              ),
              SwitchListTile(
                title: const T('Read replies aloud'),
                subtitle: const T('Every reply is spoken as it is written'),
                value: ui[readAloudKey] == true,
                onChanged: (on) => _save({readAloudKey: on}),
              ),
              ListTile(
                title: const T('Voice'),
                subtitle: Text(
                  voice.isEmpty
                      ? onPhone
                            ? tr("The phone's voice")
                            : 'The server\'s voice${serverVoice.isEmpty ? '' : ' ($serverVoice)'}'
                      : voice,
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final picked = await showModalBottomSheet<String>(
                    context: context,
                    isScrollControlled: true,
                    showDragHandle: true,
                    builder: (_) => onPhone
                        ? _PhoneVoicePicker(
                            current: voice,
                            nonLocal: tts['nonLocalVoices'] == true,
                          )
                        : _VoicePicker(current: voice),
                  );
                  if (picked == null) return;
                  await _saveAudio(ui, 'tts', {
                    'voice': picked.isEmpty ? null : picked,
                    'defaultVoice': serverVoice,
                  });
                },
              ),
              // The server leaves speaking to the device: the phone's
              // voices, and the web's switch for the online ones.
              if (onPhone)
                SwitchListTile(
                  title: const T('Allow non-local voices'),
                  subtitle: const T(
                    'Also offer voices that need the internet.',
                  ),
                  value: tts['nonLocalVoices'] == true,
                  onChanged: (on) =>
                      _saveAudio(ui, 'tts', {'nonLocalVoices': on}),
                ),
              ListTile(
                title: const T('Speed'),
                subtitle: Slider(
                  value: rate.clamp(0.5, 2.0),
                  min: 0.5,
                  max: 2,
                  divisions: 6,
                  label: '${rate}x',
                  onChanged: (v) => setState(() => _rate = v),
                  onChangeEnd: (v) =>
                      _saveAudio(ui, 'tts', {'playbackRate': v}),
                ),
                trailing: Text('${rate}x'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _VoicePicker extends ConsumerWidget {
  const _VoicePicker({required this.current});
  final String current;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final voices = ref.watch(ttsVoicesProvider);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: voices.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Couldn\'t load the voices.\n$e'),
          ),
          data: (list) => ListView(
            shrinkWrap: true,
            children: [
              _pick(context, '', 'The server\'s voice', null),
              for (final (id, name) in list)
                _pick(context, id, name, name == id ? null : id),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pick(BuildContext context, String id, String name, String? sub) =>
      ListTile(
        leading: Icon(
          id == current ? Icons.radio_button_checked : Icons.radio_button_off,
        ),
        title: Text(name),
        subtitle: sub == null ? null : Text(sub),
        onTap: () => Navigator.pop(context, id),
      );
}

/// The phone's own voices, grouped by language; the online ones only with
/// Allow non-local voices on.
class _PhoneVoicePicker extends StatelessWidget {
  const _PhoneVoicePicker({required this.current, required this.nonLocal});
  final String current;
  final bool nonLocal;

  @override
  Widget build(BuildContext context) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.7,
      ),
      child: FutureBuilder(
        future: phoneVoices(),
        builder: (context, snap) {
          if (snap.hasError) {
            return Padding(
              padding: const EdgeInsets.all(24),
              child: Text("Couldn't load the voices.\n${snap.error}"),
            );
          }
          final all = snap.data;
          if (all == null) {
            return const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          Widget pick(String id, String name, String? sub) => ListTile(
            leading: Icon(
              id == current
                  ? Icons.radio_button_checked
                  : Icons.radio_button_off,
            ),
            title: Text(name),
            subtitle: sub == null ? null : Text(sub),
            onTap: () => Navigator.pop(context, id),
          );
          return ListView(
            shrinkWrap: true,
            children: [
              pick('', tr('Default'), tr("The phone's voice")),
              for (final v in voicesToOffer(all, nonLocal: nonLocal))
                pick(
                  v.name,
                  v.name,
                  v.network ? '${v.locale} · ${tr('online')}' : v.locale,
                ),
            ],
          );
        },
      ),
    ),
  );
}
