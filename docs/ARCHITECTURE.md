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
    api/chat_socket.dart        Open WebUI's live socket (reply progress)
    api/sse.dart                Server-Sent Events parsing
    auth/session.dart           server URL + token in secure storage, Riverpod providers
    models/chat.dart            Open WebUI chat tree (history.messages / currentId)
    models/model_info.dart      model metadata, raw JSON kept for future fields
  features/
    auth/login_screen.dart      server URL, email/password or API key
    chat/chat_controller.dart   send, live reply, stop, retry (the server saves everything)
    chat/chat_screen.dart       chat UI, model picker, chat list drawer
```

State management is Riverpod 3.

## How a message is sent

The app sends a reply the same way the web UI does (Open WebUI 0.12+), so the server does all the work and keeps all the data:

1. The app opens Open WebUI's live socket (`/ws/socket.io`, Socket.IO) once per sign-in.
2. `POST /api/chat/completions` carries the new user message, an id for the empty reply, the chat id (none for a new chat) and the socket's session id. The server saves both messages in the chat (creating the chat if needed) and answers at once with the chat id and task id.
3. The server runs the reply as a background task with the model's tools, memory, knowledge and filters, and saves the answer, its tool results and the title in the chat.
4. Progress arrives over the socket as `events` (`response:completion` text deltas, `status`, `chat:title`, `chat:completion` with `done`). If the socket is down, the app checks the saved chat every few seconds instead.
5. Photos and files are uploaded first (`POST /api/v1/files/`; photos with `process=false`, documents read by the server, and the app waits for that as the web UI does). They go on the user message's `files` in the web UI's shape; documents are also sent as the request's `files` for retrieval. The server turns photos into image parts for the model itself.
6. When the reply is done, the app reloads the chat from the server, which stays the source of truth. Stop calls `POST /api/tasks/stop/{task_id}`; Retry asks again for the same user message, which adds a new reply next to the failed one, like Regenerate.

## Open WebUI endpoints used so far

| Purpose | Endpoint |
| --- | --- |
| Server config / version | `GET /api/config` |
| Sign in | `POST /api/v1/auths/signin` |
| Current user (validates token or API key) | `GET /api/v1/auths/` |
| Models | `GET /api/models` |
| Chat list (not pinned, not in a folder) | `GET /api/v1/chats/?page=N` |
| Pinned chats / search | `GET /api/v1/chats/pinned`, `GET /api/v1/chats/search?text=` |
| Rename, pin, archive, move a chat | `POST /api/v1/chats/{id}` (title only), `/{id}/pin`, `/{id}/archive`, `/{id}/folder` |
| Folders | `GET`, `POST /api/v1/folders/`, `POST /{id}/update`, `DELETE /{id}?delete_contents=false`, chats via `GET /api/v1/chats/folder/{id}/list` |
| Read / create / update / delete chat | `GET`, `POST /api/v1/chats/new`, `POST`, `DELETE /api/v1/chats/{id}` |
| Start a reply (server-run task) | `POST /api/chat/completions` |
| Live reply progress | Socket.IO `/ws/socket.io`, `events` |
| Stop a reply | `POST /api/tasks/stop/{task_id}` |
| Upload a photo or file | `POST /api/v1/files/?process=…`, then `GET /api/v1/files/{id}/process/status` |
| Show an uploaded photo | `GET /api/v1/files/{id}/content` |

## Roadmap

1. **Foundation** (this): connection, auth, models, chat sync, streaming chat.
2. **Full chat parity**: files and images, knowledge/RAG, tool and function toggles, web search, image generation, folders, pinned/archived chats, regenerate/edit branches, rich rendering (code, math, artifacts), in-app fallback to the web UI for anything not built natively yet.
3. **Voice and assistant**: voice mode on the server's STT/TTS, then a Kotlin `VoiceInteractionService` so the app can be set as the default Android assistant, with an overlay.
4. **Polish and release**: phone actions, share-to-app, widgets, signed builds, F-Droid and Play Store.
