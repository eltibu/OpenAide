import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/widgets/nexus_logo.dart';
import 'updater.dart';

/// Settings page: GitHub token, current build, check and install.
class UpdateScreen extends ConsumerStatefulWidget {
  const UpdateScreen({super.key});

  @override
  ConsumerState<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends ConsumerState<UpdateScreen> {
  final _token = TextEditingController();
  String _version = '';
  bool _hasToken = false;

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
      appBar: AppBar(title: const Text('App updates')),
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
                    Text('Nexus Assistant', style: theme.textTheme.titleLarge),
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
          Text('GitHub token', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            builtInToken.isNotEmpty
                ? 'Built into the app, nothing to set up. You can paste a '
                      'different token here to override it.'
                : _hasToken
                ? 'A token is saved. Paste a new one to replace it.'
                : 'Needed because the repo is private. Create a fine-grained '
                      'token on GitHub with read-only "Contents" access to '
                      '$updateRepo only, and paste it here.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _token,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'github_pat_…',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _saveToken(),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _saveToken,
              child: const Text('Save token'),
            ),
          ),
          const Divider(height: 32),
          switch (state) {
            UpdateIdle() => const SizedBox.shrink(),
            UpdateChecking() => const LinearProgressIndicator(),
            UpToDate() => const Text('You have the latest build.'),
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
                  label: const Text('Install'),
                ),
              ],
            ),
            UpdateDownloading(:final progress) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Downloading…'),
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
            child: const Text('Check for updates'),
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
            child: const Text('Install'),
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
            child: const Text('Try again'),
          ),
        ],
      ),
      _ => const SizedBox.shrink(),
    };
  }
}
