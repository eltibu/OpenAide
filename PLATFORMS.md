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
| Updates | in the app | AltStore / SideStore source | release page | release page | release page |

What decides each row is in `lib/core/platform_caps.dart`.

## Building

Linux builds on the Android build PC (the self-hosted runner); Windows,
Mac and iPhone/iPad build on GitHub's servers. Every run starts on the PC
(it picks the version number), so the PC must be on: Actions → "Windows,
Linux, Mac, iPhone and iPad" → Run workflow.
A push whose commit message contains `[build other platforms]` runs it
too, without attaching anything. Give it a release tag (for example `v0.1.272`) to attach the Windows, Linux
and Mac downloads to that release, where the app's update check finds them.

On your own computer: `flutter build windows`, `flutter build linux`
(needs `libgtk-3-dev libsecret-1-dev libgstreamer1.0-dev
libgstreamer-plugins-base1.0-dev`), or on a Mac
`flutter build macos` / `flutter build ios`.

Linux keeps sign-ins in the desktop keyring (GNOME Keyring or KWallet's
Secret Service), so one must be running.

## Apple without a paid account

Building needs a Mac, so the Apple builds run on GitHub's Mac servers (free
for public repos like this one). Neither download needs Apple's $99 account.

**Mac** (`OpenAide-macos-….zip` on the release): ad-hoc signed, so macOS
warns the first time.

1. Unzip and drag OpenAide to Applications.
2. Open it once; macOS says it can't check it. Click Done.
3. System Settings → Privacy & Security → "OpenAide was blocked" →
   Open Anyway, then confirm with your password.

(Or in Terminal: `xattr -dr com.apple.quarantine /Applications/OpenAide.app`.)
Sign-ins are kept in the login keychain.

**iPhone and iPad** (`OpenAide-ios-….ipa`): installed with
[SideStore](https://sidestore.io) or [AltStore](https://altstore.io), both
free, using your own free Apple ID.

1. Install SideStore (or AltStore with AltServer on a computer) by
   following its own guide.
2. In SideStore/AltStore → Sources → add
   `https://github.com/eltibu/OpenAide/releases/latest/download/altstore.json`
3. Install OpenAide from that source. New releases show up there as
   updates, and in OpenAide's Settings → App updates.

Limits of a free Apple ID: the app must be refreshed every 7 days
(SideStore does it on the phone, AltStore needs the computer nearby), and
at most 3 sideloaded apps at once. Push notifications are not available.

### What still needs Apple's account ($99 a year)

- App Store and TestFlight (anyone installs with one tap, no refresh).
- Notarizing the Mac app, so it opens without the Privacy & Security step.
- Push notifications on iPhone and iPad.

When that's set up: register bundle id `com.eltibu.openaide`, create the
App Store Connect app record, and add the signing certificates and an App
Store Connect API key as repo secrets so the workflow can sign and upload.
