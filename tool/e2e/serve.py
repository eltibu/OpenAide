"""Runs Open WebUI for the tests, with the sign-in rate limit off.

Every test signs in on its own, which trips the server's limit of 15
sign-ins per 3 minutes. python serve.py <port>
"""

import os
import sys


async def _never(*_args, **_kwargs):
    return False


# Guarded: the server's worker processes load this file again on start.
if __name__ == '__main__':
    import uvicorn

    os.environ['FROM_INIT_PY'] = 'true'
    import open_webui.main
    from open_webui.routers import auths
    from open_webui.utils import recurrence

    auths.signin_rate_limiter.is_limited = _never
    # Schedules are worked out in a fresh process, which can take longer
    # than the 2 s allowed on a cold test machine.
    recurrence.RRULE_TIMEOUT_SECONDS = 30
    uvicorn.run(open_webui.main.app, host='127.0.0.1', port=int(sys.argv[1]))
