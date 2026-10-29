/// Settings > Phone and assistant > App lock: Nexus asks for the phone's own
/// fingerprint, face or screen lock when it opens, and again after it has
/// been away for a while. Kept on this phone only, so it works offline.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../core/widgets/nexus_logo.dart';
import 'phone_launch.dart';
import '../../core/i18n/app_strings.dart';

const _storage = FlutterSecureStorage();
const _key = 'app_lock_after';

/// How long Nexus may be away before it locks, in seconds, or null when
/// the lock is off.
class AppLock extends AsyncNotifier<int?> {
  @override
  Future<int?> build() async {
    try {
      return int.tryParse(await _storage.read(key: _key) ?? '');
    } catch (_) {
      return null;
    }
  }

  Future<void> set(int? seconds) async {
    if (seconds == null) {
      await _storage.delete(key: _key);
    } else {
      await _storage.write(key: _key, value: '$seconds');
    }
    state = AsyncData(seconds);
  }
}

final appLockProvider = AsyncNotifierProvider<AppLock, int?>(AppLock.new);

/// The choices for when it locks: seconds to label.
const appLockAfter = {
  0: 'Every time you leave',
  60: 'After 1 minute away',
  300: 'After 5 minutes away',
  1800: 'After 30 minutes away',
};

/// Whether the phone has a screen lock to check against.
Future<bool> phoneCanLock() async {
  try {
    return await phoneChannel.invokeMethod<bool>('canLock') ?? false;
  } on MissingPluginException {
    return false;
  }
}

/// Shows the phone's own unlock; true when it was passed.
Future<bool> phoneUnlock() async {
  try {
    return await phoneChannel.invokeMethod<bool>('unlock', {
          'reason':
              'Use your fingerprint, face or screen lock to open OpenAide.',
        }) ??
        false;
  } on MissingPluginException {
    return true;
  }
}

/// Whether coming back after [away] needs an unlock, with the lock set to
/// [after] seconds (null: off).
bool lockDue(int? after, Duration? away) =>
    after != null && away != null && away.inSeconds >= after;

/// Covers the app while it is locked.
class AppLockGate extends ConsumerStatefulWidget {
  const AppLockGate({super.key, required this.child, this.holdChild = false});
  final Widget child;

  /// Builds [child] only once unlocked, so it can't start anything (the
  /// panel over other apps starts listening as it opens) while locked.
  final bool holdChild;

  @override
  ConsumerState<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends ConsumerState<AppLockGate>
    with WidgetsBindingObserver {
  /// Null until the setting is read.
  bool? _locked;
  DateTime? _left;
  bool _unlocking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.read(appLockProvider.future).then((after) {
      if (!mounted) return;
      setState(() => _locked = after != null);
      if (after != null) _unlock();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_unlocking) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _left ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final left = _left;
      _left = null;
      if (_locked == true) return;
      final after = ref.read(appLockProvider).value;
      if (lockDue(
        after,
        left == null ? null : DateTime.now().difference(left),
      )) {
        setState(() => _locked = true);
        _unlock();
      }
    }
  }

  /// [again]: the button, which asks even if an earlier ask never answered.
  Future<void> _unlock({bool again = false}) async {
    if (_unlocking && !again) return;
    _unlocking = true;
    final ok = await phoneUnlock();
    // The unlock screen itself sends the app away and back.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _unlocking = false;
    _left = null;
    if (ok && mounted) setState(() => _locked = false);
  }

  @override
  Widget build(BuildContext context) {
    final locked = _locked;
    return Stack(
      children: [
        if (!widget.holdChild || locked == false) widget.child,
        if (locked != false)
          Positioned.fill(
            child: Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const NexusLogo(size: 96),
                    const SizedBox(height: 24),
                    if (locked == true) ...[
                      const T('OpenAide is locked'),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        icon: const Icon(Icons.fingerprint),
                        label: const T('Unlock'),
                        onPressed: () => _unlock(again: true),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
