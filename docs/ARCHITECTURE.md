# Architecture

Nexus Assistant is an Android client for [Open WebUI](https://github.com/open-webui/open-webui), written in Flutter, with a native Kotlin layer planned for the system assistant integration.

## Principles

1. **The server is the source of truth.** Every chat, message, title and setting is written to Open WebUI through its API. The phone holds only a cache. A chat started on the phone opens in the web UI, and the other way round.
2. **Server-driven, not hardcoded.** Models, tools, functions, knowledge bases and feature flags are read from the server at runtime (`/api/models`, `/api/config`, ...). Whatever you add or change in Open WebUI shows up in the app without an app update.
3. **Never drop data we don't understand.** Chat and message objects keep unknown fields (`extra`) and send them back unchanged on save. Fields from newer Open WebUI versions (sources, files, usage, status history) survive a round trip through the app.
4. **Completions go through Open WebUI**, not straight to a model provider, so pipelines, filters, tools, RAG and per-model system prompts apply exactly as they do on the web.

## Layout

```
lib/
  main.dart                     app shell, theme, signed-in vs login routing
  core/
    api/openwebui_client.dart   REST client (auth, config, models, chats, completions)
    api/sse.dart                Server-Sent Events parsing for streaming replies
    auth/session.dart           server URL + token in secure storage, Riverpod providers
    models/chat.dart            Open WebUI chat tree (history.messages / currentId)
    models/model_info.dart      model metadata, raw JSON kept for future fields
  features/
    auth/login_screen.dart      server URL, email/password or API key
    chat/chat_controller.dart   send, stream, stop, save-to-server, title generation
    chat/chat_screen.dart       chat UI, model picker, chat list drawer
```

State management is Riverpod 3.

## How a message is sent

1. On the first message, the chat is created on the server (`POST /api/v1/chats/new`) before any reply streams, so it exists there even if the app is closed mid-reply.
2. The user and assistant messages are added to the message tree (`parentId` / `childrenIds`, `currentId` = visible tip), the same structure the web UI uses for edits and regenerations.
3. The reply streams from `POST /api/chat/completions` (OpenAI-compatible SSE).
4. When the reply finishes or is stopped, the full chat is saved back (`POST /api/v1/chats/{id}`).
5. After the first reply, a title is generated with the server's title task (`/api/v1/tasks/title/completions`) and saved.

## Open WebUI endpoints used so far

| Purpose | Endpoint |
| --- | --- |
| Server config / version | `GET /api/config` |
| Sign in | `POST /api/v1/auths/signin` |
| Current user (validates token or API key) | `GET /api/v1/auths/` |
| Models | `GET /api/models` |
| Chat list | `GET /api/v1/chats/?page=N` |
| Read / create / update / delete chat | `GET`, `POST /api/v1/chats/new`, `POST`, `DELETE /api/v1/chats/{id}` |
| Streaming completion | `POST /api/chat/completions` |
| Title generation | `POST /api/v1/tasks/title/completions` |

## Roadmap

1. **Foundation** (this): connection, auth, models, chat sync, streaming chat.
2. **Full chat parity**: files and images, knowledge/RAG, tool and function toggles, web search, image generation, folders, pinned/archived chats, regenerate/edit branches, rich rendering (code, math, artifacts), in-app fallback to the web UI for anything not built natively yet.
3. **Voice and assistant**: voice mode on the server's STT/TTS, then a Kotlin `VoiceInteractionService` so the app can be set as the default Android assistant, with an overlay.
4. **Polish and release**: phone actions, share-to-app, widgets, signed builds, F-Droid and Play Store.
