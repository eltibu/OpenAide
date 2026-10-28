"""Fake AI provider for the end-to-end tests.

One small server that stands in for everything the Open WebUI test server
talks to, so tests get the same answers every time:

* OpenAI-style chat at /v1 (models "fake" and "fake2").
  - "fake" answers "You said: <message>", "fake2" answers "Fake2 says: ...".
  - "think" in the message: the reply starts with reasoning.
  - "slow": a long reply, one "word" at a time.
  - "echo settings": the system prompt and temperature it was sent.
  - With tools: "ask me" calls ask_user (options Red and Blue), "time" calls
    get_current_timestamp, "weather" calls get_weather. A tool result is
    answered "Tool said: <result>".
* Speech to text (/v1/audio/transcriptions): "hello from a voice note".
* Text to speech (/v1/audio/speech): a short silent MP3-ish blob.
* Ollama at /api (version, tags, pull with progress, delete).

Run: python fake_ai.py [port]   (default 11500)
"""

import asyncio
import json
import sys
import time
import uuid

from aiohttp import web

MODELS = ["fake", "fake2"]
ollama_models = {"tiny:1b": 1_000_000}


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            p.get("text", "") for p in content if isinstance(p, dict)
        )
    return ""


def _sample(schema, name=""):
    """A plausible value for a JSON schema, for the model's tool calls."""
    t = schema.get("type")
    if "enum" in schema:
        return schema["enum"][0]
    if t == "string":
        return {"city": "Paris", "location": "Paris"}.get(name, "x")
    if t in ("integer", "number"):
        return 1
    if t == "boolean":
        return True
    if t == "array":
        return [_sample(schema.get("items", {}))]
    if t == "object":
        props = schema.get("properties", {})
        return {k: _sample(v, k) for k, v in props.items()}
    return "x"


def _tool_call(body):
    """The tool the fake model calls for this request, or None."""
    tools = body.get("tools") or []
    msgs = body.get("messages") or []
    if not tools or not msgs or msgs[-1].get("role") != "user":
        return None
    if _email(_text(msgs[-1].get("content"))) is not None:
        return None
    said = _text(msgs[-1].get("content")).lower()
    by_name = {t["function"]["name"]: t["function"] for t in tools
               if t.get("type") == "function"}

    def find(part):
        if part in by_name:
            return part
        return next((n for n in by_name if part in n), None)

    name = None
    if "ask me" in said:
        name = find("ask_user")
    elif "weather" in said:
        name = find("weather")
    elif "what time" in said or "the time" in said:
        name = find("get_current_timestamp") or find("time")
    if not name:
        return None
    params = by_name[name].get("parameters") or {}
    args = _sample(params) if params.get("properties") else {}
    if "ask_user" in name:
        args = _ask_args(params)
    return name, args


def _ask_args(params):
    """ask_user's arguments: one question with Red and Blue to pick from."""
    return {"questions": [{
        "id": "colour",
        "header": "Colour",
        "question": "Which colour?",
        "options": [
            {"label": "Red", "description": "Warm"},
            {"label": "Blue", "description": "Cool"},
        ],
    }]}


def _reply(body):
    model = body.get("model", "fake")
    msgs = body.get("messages") or []
    last = msgs[-1] if msgs else {}
    if last.get("role") == "tool":
        return None, f"Tool said: {_text(last.get('content'))}"
    said = next(
        (_text(m.get("content")) for m in reversed(msgs)
         if m.get("role") == "user"),
        "",
    )
    low = said.lower()
    if "echo settings" in low:
        system = " | ".join(
            _text(m.get("content")) for m in msgs if m.get("role") == "system"
        )
        return None, (
            f"System was: {system or 'None'} "
            f"temperature={body.get('temperature', 'None')}"
        )
    if (mail := _email(said)) is not None:
        return None, mail
    if "slow" in low:
        return None, "SLOW"
    reasoning = "Let me think about that." if "think" in low else None
    prefix = "Fake2 says" if model.endswith("fake2") else "You said"
    return reasoning, f"{prefix}: {said}"


EMAILS = [
    {"id": "m1", "thread": "t1", "from": "Ana Ruiz <ana@example.com>",
     "to": "Me <me@example.com>", "subject": "Field trip forms",
     "date": "2026-10-28T09:00:00Z",
     "snippet": "Could you send the field trip forms?", "unread": True,
     "note": "Ana needs the forms back by Friday."},
    {"id": "m2", "thread": "t2", "from": "Bank <no-reply@bank.example>",
     "to": "Me <me@example.com>", "subject": "Your statement",
     "date": "2026-10-27T09:00:00Z", "snippet": "Your statement is ready.",
     "unread": False, "note": "Nothing to do."},
]


def _email(said):
    """Fixed answers to the app's "email through Nexus" requests."""
    if "most recent emails in my Gmail" in said:
        return json.dumps(EMAILS)
    if said.startswith("Open the email with Gmail message id"):
        return ("=== From: Ana Ruiz <ana@example.com> | To: Me "
                "<me@example.com> | Date: 2026-10-28T09:00:00Z\n"
                "Hi, could you send the field trip forms by Friday?\n"
                "=== SUMMARY\nAna wants the field trip forms.\n"
                "=== REPLY\nHi Ana, I'll send them today.")
    if said.startswith(("Send this reply now", "Send a new email now",
                        "Forward ")):
        return json.dumps({"sent": True, "error": ""})
    if "Answer with a JSON object: {\"done\"" in said:
        return json.dumps({"done": True, "error": ""})
    return None


def _chunk(model, delta, finish=None):
    return {
        "id": "chatcmpl-fake",
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }


async def models(_):
    return web.json_response({
        "object": "list",
        "data": [{"id": m, "object": "model", "owned_by": "fake"}
                 for m in MODELS],
    })


async def chat(request):
    body = await request.json()
    model = body.get("model", "fake")
    call = _tool_call(body)
    reasoning, text = (None, None) if call else _reply(body)
    usage = {"prompt_tokens": 5, "completion_tokens": 5, "total_tokens": 10}

    if not body.get("stream"):
        msg = {"role": "assistant", "content": text or ""}
        if call:
            msg["tool_calls"] = [{
                "id": "call_" + uuid.uuid4().hex[:8], "type": "function",
                "function": {"name": call[0], "arguments": json.dumps(call[1])},
            }]
            msg["content"] = None
        if text == "SLOW":
            msg["content"] = " ".join(["word"] * 300)
        return web.json_response({
            "id": "chatcmpl-fake", "object": "chat.completion",
            "created": int(time.time()), "model": model,
            "choices": [{"index": 0, "message": msg,
                         "finish_reason": "tool_calls" if call else "stop"}],
            "usage": usage,
        })

    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
    await resp.prepare(request)

    async def send(obj):
        await resp.write(f"data: {json.dumps(obj)}\n\n".encode())

    try:
        await send(_chunk(model, {"role": "assistant", "content": ""}))
        if call:
            await send(_chunk(model, {"tool_calls": [{
                "index": 0, "id": "call_" + uuid.uuid4().hex[:8],
                "type": "function",
                "function": {"name": call[0],
                             "arguments": json.dumps(call[1])},
            }]}))
            await send(_chunk(model, {}, "tool_calls"))
        else:
            if reasoning:
                for word in reasoning.split(" "):
                    await send(_chunk(model, {"reasoning_content": word + " "}))
                    await asyncio.sleep(0.05)
            if text == "SLOW":
                for _ in range(300):
                    await send(_chunk(model, {"content": "word "}))
                    await asyncio.sleep(0.05)
            else:
                for word in text.split(" "):
                    await send(_chunk(model, {"content": word + " "}))
                    await asyncio.sleep(0.01)
            await send(_chunk(model, {}, "stop"))
        last = _chunk(model, {}, None)
        last["choices"] = []
        last["usage"] = usage
        await send(last)
        await resp.write(b"data: [DONE]\n\n")
    except (ConnectionResetError, asyncio.CancelledError):
        pass
    return resp


async def transcribe(request):
    await request.read()
    return web.json_response({"text": "hello from a voice note"})


async def speech(request):
    await request.read()
    # A valid, silent MPEG frame repeated: players accept it.
    frame = bytes.fromhex("fffb9064") + bytes(413)
    return web.Response(body=frame * 20, content_type="audio/mpeg")


async def images(request):
    await request.read()
    png = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQD"
           "wAEhQGAhKmMIQAAAABJRU5ErkJggg==")
    return web.json_response({"created": int(time.time()),
                              "data": [{"b64_json": png}]})


async def embeddings(request):
    body = await request.json()
    inputs = body.get("input")
    inputs = inputs if isinstance(inputs, list) else [inputs]
    return web.json_response({
        "object": "list",
        "data": [{"object": "embedding", "index": i,
                  "embedding": [0.1] * 8} for i in range(len(inputs))],
        "model": body.get("model", "fake-embed"),
    })


# Ollama stand-in.
async def o_version(_):
    return web.json_response({"version": "0.9.0"})


async def o_tags(_):
    return web.json_response({"models": [
        {"name": n, "model": n, "size": s, "digest": "sha256:" + "0" * 64,
         "modified_at": "2026-10-28T00:00:00Z",
         "details": {"family": "fake", "parameter_size": "1B",
                     "quantization_level": "Q4_0"}}
        for n, s in ollama_models.items()
    ]})


async def o_ps(_):
    return web.json_response({"models": []})


async def o_pull(request):
    body = await request.json()
    name = body.get("name") or body.get("model")
    resp = web.StreamResponse(
        headers={"Content-Type": "application/x-ndjson"})
    await resp.prepare(request)

    async def send(obj):
        await resp.write((json.dumps(obj) + "\n").encode())

    try:
        await send({"status": "pulling manifest"})
        await asyncio.sleep(0.5)
        for done in (50, 100):
            await send({"status": "pulling layer", "digest": "sha256:abc",
                        "total": 100, "completed": done})
            await asyncio.sleep(0.5)
        ollama_models[name] = 1_000_000
        await send({"status": "success"})
    except (ConnectionResetError, asyncio.CancelledError):
        pass
    return resp


async def o_delete(request):
    body = await request.json()
    name = body.get("name") or body.get("model")
    if ollama_models.pop(name, None) is None:
        return web.json_response({"error": "not found"}, status=404)
    return web.json_response({})


async def o_show(request):
    body = await request.json()
    return web.json_response({"modelfile": f"FROM {body.get('name')}",
                              "parameters": "", "template": "",
                              "details": {"family": "fake"}})


async def health(_):
    return web.Response(text="Ollama is running")


def app():
    a = web.Application(client_max_size=64 * 1024 * 1024)
    a.add_routes([
        web.get("/v1/models", models),
        web.get("/models", models),
        web.post("/v1/chat/completions", chat),
        web.post("/chat/completions", chat),
        web.post("/v1/audio/transcriptions", transcribe),
        web.post("/v1/audio/speech", speech),
        web.post("/v1/images/generations", images),
        web.post("/v1/embeddings", embeddings),
        web.get("/", health),
        web.get("/api/version", o_version),
        web.get("/api/tags", o_tags),
        web.get("/api/ps", o_ps),
        web.post("/api/pull", o_pull),
        web.delete("/api/delete", o_delete),
        web.post("/api/show", o_show),
    ])
    return a


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 11500
    web.run_app(app(), host="127.0.0.1", port=port, print=None)
