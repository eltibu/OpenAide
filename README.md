# OpenAide (formerly Nexus Assistant)

An Android assistant app for [Open WebUI](https://github.com/open-webui/open-webui). It keeps everything on your Open WebUI server, so the phone and the web UI always show the same chats, and new models or tools you add on the server appear in the app automatically.

Status: early development (step 1 of the [roadmap](docs/ARCHITECTURE.md#roadmap)).

## What works now

- Connect to any Open WebUI server with email/password or an API key
- Pick any model your server exposes
- Streaming chat, with stop
- Chats are created and saved on the server and listed from it
- Replies run on the server like in the web UI, so tools, memory and titles work

## Build

Requires Flutter (stable) and the Android SDK.

```sh
flutter pub get
flutter test
flutter run            # on a connected device or emulator
flutter build apk      # build/app/outputs/flutter-apk/app-release.apk
```

Every push also builds an APK in GitHub Actions (Actions tab → Build → artifact `nexus-assistant-apk`).

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the app is put together.
