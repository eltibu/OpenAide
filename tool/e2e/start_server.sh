#!/usr/bin/env bash
# Starts a throwaway Open WebUI with the fake AI provider for the
# end-to-end tests, and prints the env the tests need.
#
#   tool/e2e/start_server.sh [workdir]
#
# Needs uv (https://docs.astral.sh/uv). First run installs Open WebUI
# (same version as the home server) into <workdir>/venv.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-${E2E_WORKDIR:-$HOME/.cache/openaide-e2e}}"
OWUI_VERSION="${OWUI_VERSION:-0.12.4}"
OPEN_TERMINAL_VERSION="${OPEN_TERMINAL_VERSION:-0.14.6}"
PORT="${OWUI_PORT:-8080}"
TERM_PORT="${TERM_PORT:-8100}"
FAKE_PORT="${FAKE_PORT:-11500}"
mkdir -p "$WORK"
if [ ! -x "$WORK/venv/bin/open-webui" ]; then
  uv venv -q -p 3.12 "$WORK/venv"
  VIRTUAL_ENV="$WORK/venv" uv pip install -q "open-webui==$OWUI_VERSION" \
    "open-terminal==$OPEN_TERMINAL_VERSION"
fi
# Stop a server left from an earlier run.
for p in owui fake_ai terminal; do
  [ -f "$WORK/$p.pid" ] && kill "$(cat "$WORK/$p.pid")" 2>/dev/null || true
done
sleep 1
# A fresh database each run: the first account becomes the admin.
rm -rf "$WORK/data" && mkdir -p "$WORK/data"

"$WORK/venv/bin/python" "$HERE/fake_ai.py" "$FAKE_PORT" \
  > "$WORK/fake_ai.log" 2>&1 &
echo $! > "$WORK/fake_ai.pid"

# A terminal server (Open Terminal) for the Terminal and Files pages.
mkdir -p "$WORK/data/terminal-home"
"$WORK/venv/bin/open-terminal" run --host 127.0.0.1 --port "$TERM_PORT" \
  --api-key e2e-terminal --cwd "$WORK/data/terminal-home" \
  > "$WORK/terminal.log" 2>&1 &
echo $! > "$WORK/terminal.pid"

export DATA_DIR="$WORK/data"
export TERMINAL_SERVER_CONNECTIONS="[{\"id\": \"local\", \"name\": \"Test terminal\", \"url\": \"http://127.0.0.1:$TERM_PORT\", \"key\": \"e2e-terminal\", \"auth_type\": \"bearer\", \"enabled\": true}]"
export WEBUI_SECRET_KEY=e2e-secret
export ENABLE_OPENAI_API=true
export OPENAI_API_BASE_URL="http://127.0.0.1:$FAKE_PORT/v1"
export OPENAI_API_KEY=fake
export ENABLE_OLLAMA_API=false
export AUDIO_STT_ENGINE=openai
export AUDIO_STT_OPENAI_API_BASE_URL="http://127.0.0.1:$FAKE_PORT/v1"
export AUDIO_STT_OPENAI_API_KEY=fake
export AUDIO_TTS_ENGINE=openai
export AUDIO_TTS_OPENAI_API_BASE_URL="http://127.0.0.1:$FAKE_PORT/v1"
export AUDIO_TTS_OPENAI_API_KEY=fake
export RAG_EMBEDDING_ENGINE=openai
export RAG_OPENAI_API_BASE_URL="http://127.0.0.1:$FAKE_PORT/v1"
export RAG_OPENAI_API_KEY=fake
export RAG_EMBEDDING_MODEL=fake-embed
export BYPASS_EMBEDDING_AND_RETRIEVAL=false
export ENABLE_IMAGE_GENERATION=true
export IMAGE_GENERATION_ENGINE=openai
export IMAGES_OPENAI_API_BASE_URL="http://127.0.0.1:$FAKE_PORT/v1"
export IMAGES_OPENAI_API_KEY=fake
export ENABLE_NOTES=true
export ENABLE_CHANNELS=true
export ENABLE_SIGNUP=true
export ENABLE_TOOL_PERMISSIONS=true
export OFFLINE_MODE=true
export HF_HUB_OFFLINE=1
export ANONYMIZED_TELEMETRY=false
export SCARF_NO_ANALYTICS=true
export DO_NOT_TRACK=true
"$WORK/venv/bin/python" "$HERE/serve.py" "$PORT" \
  > "$WORK/owui.log" 2>&1 &
echo $! > "$WORK/owui.pid"

for _ in $(seq 1 180); do
  curl -sf "http://127.0.0.1:$PORT/health" > /dev/null && break
  sleep 1
done
curl -sf "http://127.0.0.1:$PORT/health" > /dev/null || {
  tail -50 "$WORK/owui.log"; exit 1; }

"$WORK/venv/bin/python" "$HERE/setup_server.py" "http://127.0.0.1:$PORT"
