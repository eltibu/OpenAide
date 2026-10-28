/// Settings > AI providers: sign in to OpenRouter, or add a Claude or
/// OpenAI key, so their models can answer straight from the phone.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/ai_providers.dart';
import '../../core/ai/copilot.dart';
import '../../core/theme.dart';
import 'ai_keys.dart';
import 'local_models.dart';
import 'local_models_screen.dart';
import '../../core/i18n/app_strings.dart';

class AiProvidersScreen extends StatelessWidget {
  const AiProvidersScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const T('AI providers')),
    body: const AiProviderList(),
  );
}

/// The providers with their sign-in and key fields; also the first screen
/// of using the app without a server.
class AiProviderList extends ConsumerWidget {
  const AiProviderList({super.key, this.intro});

  /// Shown above the providers instead of the usual explanation.
  final Widget? intro;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(aiKeysProvider)) {
      AsyncData(:final value) => ListView(
        padding: const EdgeInsets.all(16),
        children: [
          intro ??
              T(
                'Chat with these from the phone itself, with or without an '
                'Open WebUI server. Keys stay on this phone, and each '
                'provider bills you directly.',
                style: TextStyle(color: context.nexus.muted),
              ),
          const SizedBox(height: 16),
          for (final p in AiProvider.values)
            if (p != AiProvider.local) ...[
              _ProviderCard(provider: p, savedKey: value[p]),
              const SizedBox(height: 12),
            ],
          const _OnThisPhoneCard(),
        ],
      ),
      AsyncError(:final error) => Center(child: Text('$error')),
      _ => const Center(child: CircularProgressIndicator()),
    };
  }
}

/// Models on the phone itself: no key, see LocalModelsScreen.
class _OnThisPhoneCard extends ConsumerWidget {
  const _OnThisPhoneCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = [
      for (final m in ref.watch(localModelsProvider).value ?? const [])
        if (m.ready) m,
    ];
    return Card(
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
        leading: const Icon(Icons.phone_android),
        title: const T('On this phone'),
        subtitle: Text(
          ready.isEmpty
              ? 'Download a model and chat offline: free, private, no '
                    'account. Smaller and slower than online models.'
              : '${ready.length} model${ready.length == 1 ? '' : 's'} '
                    'downloaded. Works offline.',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const LocalModelsScreen())),
      ),
    );
  }
}

class _ProviderCard extends ConsumerStatefulWidget {
  const _ProviderCard({required this.provider, required this.savedKey});
  final AiProvider provider;
  final String? savedKey;

  @override
  ConsumerState<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends ConsumerState<_ProviderCard> {
  final _key = TextEditingController();
  bool _busy = false;
  bool _typing = false;
  String? _error;
  int? _models;
  OpenRouterSignIn? _signIn;

  AiProvider get _p => widget.provider;

  @override
  void initState() {
    super.initState();
    if (widget.savedKey != null) _check(widget.savedKey!, save: false);
  }

  @override
  void dispose() {
    _signIn?.cancel();
    _key.dispose();
    super.dispose();
  }

  String get _blurb => switch (_p) {
    AiProvider.openRouter =>
      'Hundreds of models (Claude, GPT, Gemini, Grok, Llama and more) on one '
          'account. Sign in, or paste a key.',
    AiProvider.anthropic =>
      "Claude straight from Anthropic. Needs an API key from the Claude "
          "Console (pay as you go). A Claude Pro or Max plan can't be used "
          'by other apps.',
    AiProvider.openAi =>
      'GPT models straight from OpenAI. Needs an API key from the OpenAI '
          'platform (pay as you go); a ChatGPT plan is separate.',
    AiProvider.copilot =>
      copilotSignInAvailable
          ? 'Use your own Copilot plan (Claude, GPT, Gemini and more). '
                "Experimental: GitHub doesn't officially support Copilot in "
                'other apps, so it may stop working.'
          : "Use your own Copilot plan. Sign-in isn't set up in this "
                'version yet.',
    AiProvider.local => '',
  };

  String get _hint => switch (_p) {
    AiProvider.openRouter => 'sk-or-…',
    AiProvider.anthropic => 'sk-ant-…',
    AiProvider.openAi => 'sk-…',
    AiProvider.copilot => 'gho_…',
    AiProvider.local => '',
  };

  /// Lists the models [key] unlocks; saves it if that works.
  Future<void> _check(String key, {bool save = true}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final models = await listProviderModels(_p, key.trim());
      if (save) {
        await ref.read(aiKeysProvider.notifier).set(_p, key);
        ref.invalidate(providerModelsProvider);
      }
      if (!mounted) return;
      setState(() {
        _models = models.length;
        _typing = false;
        _key.clear();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInWithOpenRouter() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sign = _signIn = await OpenRouterSignIn.start();
      final key = await sign.key;
      await _check(key);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _signIn = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signInWithGitHub() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final cancel = Completer<void>();
    try {
      final code = await startGitHubDeviceSignIn();
      if (!mounted) return;
      final waiting = waitForGitHubSignIn(code, cancelled: cancel.future);
      var open = true;
      void close() {
        if (open && mounted) Navigator.of(context, rootNavigator: true).pop();
      }

      // The dialog closes itself once GitHub answers.
      unawaited(waiting.then((_) => close(), onError: (_) => close()));
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _DeviceCodeDialog(
          code: code,
          onCancel: () {
            if (!cancel.isCompleted) cancel.complete();
            Navigator.pop(context);
          },
        ),
      );
      open = false;
      await _check(await waiting);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (!cancel.isCompleted) cancel.complete();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    await ref.read(aiKeysProvider.notifier).set(_p, null);
    ref.invalidate(providerModelsProvider);
    if (mounted) setState(() => _models = null);
  }

  @override
  Widget build(BuildContext context) {
    final saved = widget.savedKey != null;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(_p.label, style: theme.textTheme.titleMedium),
                ),
                if (saved)
                  Chip(
                    avatar: const Icon(Icons.check_circle, size: 18),
                    label: Text(
                      _models == null ? 'Connected' : '$_models models',
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(_blurb, style: TextStyle(color: context.nexus.muted)),
            const SizedBox(height: 12),
            if (_signIn != null) ...[
              const T('Approve OpenAide in the browser, then come back here.'),
              const SizedBox(height: 8),
              Row(
                children: [
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _signIn?.cancel(),
                    child: const T('Cancel'),
                  ),
                ],
              ),
            ] else if (_typing ||
                (!saved &&
                    _p != AiProvider.openRouter &&
                    _p != AiProvider.copilot)) ...[
              TextField(
                controller: _key,
                obscureText: true,
                autocorrect: false,
                enabled: !_busy,
                onSubmitted: (v) => v.trim().isEmpty ? null : _check(v),
                decoration: InputDecoration(
                  labelText: tr('API key'),
                  hintText: _hint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _key.text.trim().isEmpty
                              ? null
                              : _check(_key.text),
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const T('Save'),
                  ),
                  TextButton.icon(
                    onPressed: () => launchUrl(
                      Uri.parse(providerKeyPages[_p]!),
                      mode: LaunchMode.externalApplication,
                    ),
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const T('Get a key'),
                  ),
                  if (_typing)
                    TextButton(
                      onPressed: () => setState(() => _typing = false),
                      child: const T('Cancel'),
                    ),
                ],
              ),
            ] else
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (!saved && _p == AiProvider.openRouter)
                    FilledButton.icon(
                      onPressed: _busy ? null : _signInWithOpenRouter,
                      icon: const Icon(Icons.login),
                      label: const T('Sign in with OpenRouter'),
                    ),
                  if (!saved && _p == AiProvider.copilot)
                    FilledButton.icon(
                      onPressed: _busy || !copilotSignInAvailable
                          ? null
                          : _signInWithGitHub,
                      icon: const Icon(Icons.login),
                      label: const T('Sign in with GitHub'),
                    ),
                  if (_p != AiProvider.copilot)
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _typing = true),
                      child: Text(saved ? 'Change key' : 'Paste a key'),
                    ),
                  if (saved)
                    TextButton(
                      onPressed: _busy ? null : _remove,
                      child: const T('Remove'),
                    ),
                ],
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shows the code to type on GitHub, with a button that opens the page.
class _DeviceCodeDialog extends StatelessWidget {
  const _DeviceCodeDialog({required this.code, required this.onCancel});
  final DeviceCode code;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const T('Sign in with GitHub'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const T('Open GitHub and enter this code:'),
        const SizedBox(height: 16),
        SelectableText(
          code.userCode,
          style: Theme.of(context).textTheme.headlineMedium
              ?.copyWith(letterSpacing: 4, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () =>
              Clipboard.setData(ClipboardData(text: code.userCode)),
          icon: const Icon(Icons.copy, size: 18),
          label: const T('Copy code'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: T(
                'Waiting for GitHub…',
                style: TextStyle(color: context.nexus.muted),
              ),
            ),
          ],
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: onCancel, child: const T('Cancel')),
      FilledButton(
        onPressed: () {
          Clipboard.setData(ClipboardData(text: code.userCode));
          launchUrl(
            Uri.parse(code.verificationUri),
            mode: LaunchMode.externalApplication,
          );
        },
        child: const T('Open GitHub'),
      ),
    ],
  );
}
