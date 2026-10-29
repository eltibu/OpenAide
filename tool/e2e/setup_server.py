"""Creates the test admin on a fresh Open WebUI and prints the tests' env.

python setup_server.py http://127.0.0.1:8080
"""

import json
import sys
import urllib.request

URL = sys.argv[1].rstrip("/")
EMAIL = "e2e@example.com"
PASSWORD = "e2e-Password-1"


def call(method, path, body=None, token=None):
    req = urllib.request.Request(
        URL + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})},
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b"null")


try:
    token = call("POST", "/api/v1/auths/signup",
                 {"name": "E2E Admin", "email": EMAIL,
                  "password": PASSWORD})["token"]
except Exception:
    token = call("POST", "/api/v1/auths/signin",
                 {"email": EMAIL, "password": PASSWORD})["token"]

# What some tests expect to find: a channel, a tool and a skill.
CLOCK = '''"""
title: Clock
description: Tells the time
"""
from datetime import datetime


class Tools:
    def get_time(self) -> str:
        """Get the current time."""
        return datetime.now().isoformat()
'''


def seed(method, path, body):
    try:
        call(method, path, body, token)
    except Exception as e:  # Already there from an earlier run.
        print(f"# seed {path}: {e}", file=sys.stderr)


seed("POST", "/api/v1/channels/create", {"name": "general"})
seed("POST", "/api/v1/tools/create", {
    "id": "clock", "name": "Clock", "content": CLOCK,
    "meta": {"description": "Tells the time"}})
seed("POST", "/api/v1/skills/create", {
    "id": "summarize", "name": "Summarize",
    "description": "Summarize text", "content": "Summarize in 3 bullets.",
    "meta": {}, "is_active": True})

# Signups after the first wait for approval by default; tests that add a
# second person approve it themselves.
print(f"export OWUI_URL={URL}")
print(f"export OWUI_EMAIL={EMAIL}")
print(f"export OWUI_PASSWORD={PASSWORD}")
