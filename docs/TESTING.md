# Testing

Three layers, all automatic:

1. **Unit and screen tests** (`test/*.dart`). `flutter test`. Every Build runs them.
2. **Server tests** (`test/integration/`). The app's code against a real Open WebUI 0.12.5: chats, streaming, tools and approvals, voice notes, email through OpenAide, notes, channels, calendar, automations, terminal and files, workspace, admin settings and more. They skip themselves when no server is set.
3. **Screen crawl** (`integration_test/crawl_test.dart`). Runs the real app, signed in and with no server, opens every page it can reach from the side menu and the account menu, and taps every button that is safe to tap. It reports exceptions, layout overflows and error messages that appear after a tap. It leaves alone buttons that delete, sign out, send, or need the phone's hardware, and it does not flip switches (admin switches change the server).

## The test server

`tool/e2e/start_server.sh [workdir]` starts, on this machine only:

- Open WebUI 0.12.5 (the home server's version) with a fresh database, first account `e2e@example.com` as admin, with a channel, a tool and a skill to find (`setup_server.py`). `serve.py` turns off the sign-in rate limit, since every test signs in.
- A fake AI provider (`fake_ai.py`) with models `fake` and `fake2`, so answers are the same every time: "You said: …", reasoning for "think", a long slow reply for "slow", tool calls for "ask me", "what time" and "weather", fixed emails for the email requests, speech to text, text to speech, images, embeddings, and an Ollama stand-in.
- Open Terminal, connected as the server's terminal.

It prints the environment the tests need:

```sh
eval "$(tool/e2e/start_server.sh)"
export OLLAMA_URL=http://127.0.0.1:11500 FAKE_OPENAI_URL=http://127.0.0.1:11500/v1
flutter test test/integration --concurrency=1
tool/e2e/crawl.sh                      # needs libgtk-3-dev and xvfb
python3 tool/e2e/summary.py <json report> build/e2e
```

Needs `uv` (installs Python 3.12 and Open WebUI into the workdir on first run).

The encrypted chat tests (`test/mls_test.dart`, `test/integration/encrypted_chat_test.dart`) need the encryption library built for this computer; they are skipped without it:

```sh
export OPENAIDE_ENCRYPTION_LIB="$(tool/build_encryption.sh host)"
```

## On GitHub

`.github/workflows/e2e.yml` (Feature tests) runs all of this on the PC runner when the shared branches move, nightly, by hand, and on pull requests that change the tests. It never holds back a Build. The run summary lists pass and fail per area in plain words; the crawl report is attached to the run.

Not covered: Realtime voice calls (the fake provider doesn't speak the Realtime protocol; the test skips itself) and anything that needs the phone itself (microphone, camera, the file picker, Android's assistant and share sheet, on-device models). The crawl lists those as "needs the phone" instead of failures.
