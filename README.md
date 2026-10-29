# OpenAide

An open-source AI assistant for Android. Use it with your own [Open WebUI](https://github.com/open-webui/open-webui) server for full feature parity with the web UI, or on its own with an AI provider (OpenRouter, Claude, OpenAI) or a model that runs entirely on your phone. It can replace the default Android assistant.

Status: early (0.1.x). Things change quickly and some screens are still rough.

<!-- Screenshots: add phone screenshots to docs/screenshots/ and list them here.
<p>
  <img src="docs/screenshots/chat.png" width="200">
  <img src="docs/screenshots/voice.png" width="200">
  <img src="docs/screenshots/studio.png" width="200">
  <img src="docs/screenshots/settings.png" width="200">
</p>
-->

## Features

- **Open WebUI, fully synced.** Chats, models, tools, knowledge, memory, notes, channels and settings all live on your server, so the phone and the web UI always match. New models or tools you add on the server show up in the app without an app update.
- **Works without a server too.** Sign in to OpenRouter, or add a Claude or OpenAI API key, and chat straight from the phone. Built-in tools, skills and MCP servers work with these models.
- **Models on the phone.** Download a small model (llama.cpp, from Hugging Face) and chat offline.
- **Voice.** Hands-free voice calls, dictation and spoken replies.
- **Default assistant.** Set OpenAide as the Android assistant: long-press the power button or swipe from the corner to ask.
- **Studio.** Write and edit documents, spreadsheets and slides with AI help, and open or save Word, Excel and PowerPoint files.
- **Notes and recordings.** Quick notes, meeting minutes from a recording, and dictation.
- **Email.** Read, sort and answer mail through your Open WebUI server or straight over IMAP/SMTP.
- **More from Open WebUI:** terminal, files, artifacts, calendar, automations, channels, workspace, playground and the admin panel.

## Install

OpenAide is not on Google Play yet. Install the APK from GitHub:

1. On your phone, open the [latest release](../../releases/latest) and download `OpenAide-<version>.apk`.
2. Open the downloaded file. If Android asks, allow your browser or file manager to **install unknown apps**.
3. If Play Protect warns about an app from an unknown developer, tap **More details → Install anyway**. The full source is in this repo, and every release is built by the [Build workflow](.github/workflows/build.yml).
4. Open OpenAide and choose how to connect: your Open WebUI server, an AI provider, or a model on the phone.

Requires Android 9 or newer.

### Updates

OpenAide checks GitHub for new releases on start and offers to install them over the top; your chats and settings stay. In **Settings → App updates** you can pick a channel:

- **Stable**: public releases only (recommended).
- **Dev builds**: every new build, often several a day. Newest features, less tested.

No GitHub account or token is needed.

## Connecting to Open WebUI

Enter your server's address (for example `https://chat.example.com` or `http://192.168.1.20:3000`) and sign in with your email and password, an API key, or your server's single sign-on page. Everything the app does runs through the server, so its tools, pipelines, filters and knowledge apply exactly as on the web.

## Build from source

Requires Flutter (stable) and the Android SDK.

```sh
flutter pub get
flutter test
flutter run            # on a connected device or emulator
flutter build apk      # build/app/outputs/flutter-apk/app-release.apk
```

A build you make yourself is signed with your own key, so it can't install over a release from this repo (and the other way round). Uninstall one before installing the other.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the app is put together.

## Contributing

Issues and pull requests are welcome. Please describe what you changed and how you tested it. Pull requests from forks don't run the build workflow automatically.

## Privacy and security

See [PRIVACY.md](PRIVACY.md) for what the app stores and sends, and [SECURITY.md](SECURITY.md) to report a vulnerability.

## Support

OpenAide is free, with no ads and no tracking. If it helps you, you can [buy me a coffee](https://buymeacoffee.com/eltibu).

## License

[MIT](LICENSE). Third-party licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
