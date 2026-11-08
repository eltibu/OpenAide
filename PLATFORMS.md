# OpenAide beyond Android

OpenAide is one Flutter app. Since November 2026 the repo also has Windows,
Linux, macOS and iOS/iPadOS targets. Android stays the main platform; this
page says what works where. Only the Linux build has been run so far;
the others are built by CI but not yet tried on real devices.

| | Android | iPhone / iPad | Mac | Windows | Linux |
|---|---|---|---|---|---|
| Chat, Open WebUI sync, workspace, notes, channels, admin | yes | yes | yes | yes | yes |
| AI providers without a server (OpenRouter, Claude, OpenAI, Copilot) | yes | yes | yes | yes | yes |
| Dictation, voice notes, Listen, classic voice call | yes | yes | yes | yes | yes |
| Read aloud (server voice) | yes | yes | yes | yes | yes |
| Live (Realtime) voice call | yes | classic call instead | classic call instead | classic call instead | classic call instead |
| In-app pages (artifacts, Mermaid, PDFs, server pages) | yes | yes | yes | opens in your browser | opens in your browser |
| Browser (SSO) sign-in | yes | yes | yes | not yet: email/password or API key | not yet: email/password or API key |
| Models on the device (llama.cpp) | yes | not yet | not yet | not yet | not yet |
| Default assistant, overlay panel, quick tile, phone actions | yes | no (iOS has no equivalent) | no | no | no |
| Updates | in the app | App Store / TestFlight | release page | release page | release page |

What decides each row is in `lib/core/platform_caps.dart`.

## Building

Builds for these platforms run on GitHub's own servers, never on the Android
build PC: Actions → "Windows, Linux, Mac, iPhone and iPad" → Run workflow.
Give it a release tag (for example `v0.1.272`) to attach the Windows, Linux
and Mac downloads to that release, where the app's update check finds them.

On your own computer: `flutter build windows`, `flutter build linux`
(needs `libgtk-3-dev libsecret-1-dev libgstreamer1.0-dev
libgstreamer-plugins-base1.0-dev libpulse-dev`), or on a Mac
`flutter build macos` / `flutter build ios`.

Linux keeps sign-ins in the desktop keyring (GNOME Keyring or KWallet's
Secret Service), so one must be running.

## Apple

The Mac and iPhone/iPad builds are unsigned. To hand them to people:

1. An Apple Developer account ($99 a year) in the name OpenAide ships under.
2. Bundle id `com.eltibu.openaide` registered there, and an App Store
   Connect app record for iPhone/iPad (and Mac, or notarize the Mac app to
   share it outside the store).
3. Signing certificates and an App Store Connect API key as repo secrets,
   so the workflow can sign and upload to TestFlight.
