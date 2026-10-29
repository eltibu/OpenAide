import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/widgets/nexus_logo.dart';
import 'updater.dart';
import '../../core/i18n/app_strings.dart';
import '../../core/widgets/hideable.dart';

/// Settings page: current build, update channel, optional GitHub token,
/// check and install.
class UpdateScreen extends ConsumerStatefulWidget {
  const UpdateScreen({super.key});

  @override
  ConsumerState<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends ConsumerState<UpdateScreen> {
  final _token = TextEditingController();
  String _version = '';
  bool _hasToken = false;
  UpdateChannel? _channel;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then(
      (i) => setState(() => _version = i.version),
    );
    ref
        .read(updaterProvider.notifier)
        .token()
        .then((t) => setState(() => _hasToken = t != null));
    ref
        .read(updaterProvider.notifier)
        .channel()
        .then((c) => setState(() => _channel = c));
  }

  Future<void> _setChannel(UpdateChannel c) async {
    setState(() => _channel = c);
    final updater = ref.read(updaterProvider.notifier);
    await updater.setChannel(c);
    await updater.check();
  }

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _saveToken() async {
    final updater = ref.read(updaterProvider.notifier);
    await updater.setToken(_token.text);
    _token.clear();
    setState(() => _hasToken = true);
    await updater.check();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updaterProvider);
    final updater = ref.read(updaterProvider.notifier);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const T('App updates')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              const NexusLogo(size: 56),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    T('OpenAide', style: theme.textTheme.titleLarge),
                    Text(
                      'Installed: $_version',
                      style: theme.textTheme.bodyLarge,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          T('Update channel', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_channel != null)
            SegmentedButton<UpdateChannel>(
              segments: const [
                ButtonSegment(
                  value: UpdateChannel.stable,
                  label: T('Stable'),
                  icon: Icon(Icons.verified_outlined),
                ),
                ButtonSegment(
                  value: UpdateChannel.dev,
                  label: T('Dev builds'),
                  icon: Icon(Icons.science_outlined),
                ),
              ],
              selected: {_channel!},
              onSelectionChanged: (s) => _setChannel(s.first),
            ),
          const SizedBox(height: 4),
          Text(
            _channel == UpdateChannel.dev
                ? 'Every new build, often several a day. Newest features, '
                      'less tested.'
                : 'Public releases only.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          T('GitHub token (optional)', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            builtInToken.isNotEmpty
                ? 'Built into the app, nothing to set up. You can paste a '
                      'different token here to override it.'
                : _hasToken
                ? 'A token is saved. Paste a new one to replace it.'
                : 'Not needed: updates come from public GitHub releases. '
                      'Only if $updateRepo is private, paste a fine-grained '
                      'token with read-only "Contents" access to it.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Hideable(
            builder: (obscure, eye) => TextField(
              controller: _token,
              obscureText: obscure,
              autocorrect: false,
              decoration: InputDecoration(
                suffixIcon: eye,
                labelText: tr('github_pat_…'),
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _saveToken(),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _saveToken,
              child: const T('Save token'),
            ),
          ),
          const Divider(height: 32),
          switch (state) {
            UpdateIdle() => const SizedBox.shrink(),
            UpdateChecking() => const LinearProgressIndicator(),
            UpToDate() => const T('You have the latest build.'),
            UpdateFound(:final update) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Version ${versionName(update.build)} is available.',
                  style: theme.textTheme.titleMedium,
                ),
                if (update.notes.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(update.notes, style: theme.textTheme.bodySmall),
                ],
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => updater.install(update),
                  icon: const Icon(Icons.system_update),
                  label: const T('Install'),
                ),
              ],
            ),
            UpdateDownloading(:final progress) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const T('Downloading…'),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: progress),
              ],
            ),
            UpdateFailed(:final message) => Text(
              message,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          },
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: state is UpdateChecking || state is UpdateDownloading
                ? null
                : () => updater.check(),
            child: const T('Check for updates'),
          ),
        ],
      ),
    );
  }
}

/// Checks quietly once on start and offers a found update above the chat.
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () => ref.read(updaterProvider.notifier).check(quiet: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(updaterProvider);
    final updater = ref.read(updaterProvider.notifier);
    return switch (state) {
      UpdateFound(:final update) => MaterialBanner(
        leading: const Icon(Icons.system_update),
        content: Text(
          'Version ${versionName(update.build)} is ready to install.',
        ),
        actions: [
          TextButton(
            onPressed: () => updater.install(update),
            child: const T('Install'),
          ),
        ],
      ),
      UpdateDownloading(:final progress) => MaterialBanner(
        leading: const Icon(Icons.downloading),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              progress == null
                  ? 'Downloading the update…'
                  : 'Downloading the update… ${(progress * 100).round()}%',
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
          ],
        ),
        actions: const [SizedBox.shrink()],
      ),
      // Errors from a tap on Install must be visible here, not only on the
      // App updates page.
      UpdateFailed(:final message) => MaterialBanner(
        leading: Icon(
          Icons.error_outline,
          color: Theme.of(context).colorScheme.error,
        ),
        content: Text('Update failed: $message'),
        actions: [
          TextButton(
            onPressed: () => updater.check(),
            child: const T('Try again'),
          ),
        ],
      ),
      _ => const SizedBox.shrink(),
    };
  }
}
