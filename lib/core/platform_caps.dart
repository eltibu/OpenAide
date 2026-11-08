import 'package:flutter/foundation.dart';

/// What the device the app runs on can do. OpenAide started on Android and
/// many features talk to its own Android code (voice, the assistant panel,
/// on-device models, installing updates). Everywhere else those features
/// hide or fall back to something that works on that platform.
abstract final class PlatformCaps {
  // defaultTargetPlatform, not dart:io's Platform: widget tests run as
  // Android whatever computer runs them, and can pretend to be another.
  static bool get android => _is(TargetPlatform.android);
  static bool get ios => _is(TargetPlatform.iOS);
  static bool get macos => _is(TargetPlatform.macOS);
  static bool get windows => _is(TargetPlatform.windows);
  static bool get linux => _is(TargetPlatform.linux);

  static bool _is(TargetPlatform p) => !kIsWeb && defaultTargetPlatform == p;

  /// Windows, Linux or Mac.
  static bool get desktop => macos || windows || linux;

  /// Apple's phone and tablet (iPadOS reports as iOS).
  static bool get apple => ios || macos;

  /// A real in-app browser (web pages, artifacts, Mermaid, PDFs, browser
  /// sign-in). Windows and Linux have none built into Flutter's web view
  /// yet: those screens show an "Open in your browser" card instead.
  static bool get webView => android || ios || macos;

  /// The app's own microphone and speaker code (voice calls, dictation,
  /// voice notes, Listen mode). Android only for now.
  static bool get nativeVoice => android;

  /// Models that run on the device itself (llama.cpp). Android only for now.
  static bool get localModels => android;

  /// Downloading and installing a new version from inside the app. Other
  /// platforms open the download page; app stores update the app themselves.
  static bool get selfInstallUpdates => android;

  /// Being the device's assistant (long-press, overlay panel, quick tile),
  /// and reading contacts, calendar and other phone actions.
  static bool get phoneAssistant => android;

  /// Short name for the platform, shown in Settings > About.
  static String get name => switch (defaultTargetPlatform) {
    _ when kIsWeb => 'Web',
    TargetPlatform.android => 'Android',
    TargetPlatform.iOS => 'iPhone and iPad',
    TargetPlatform.macOS => 'Mac',
    TargetPlatform.windows => 'Windows',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.fuchsia => 'Fuchsia',
  };
}
