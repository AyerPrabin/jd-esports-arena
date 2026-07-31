"""
RUN ZULU SERVER FOREVER  —  process supervisor for zulu_server.py
====================================================================
Same idea as run_discord_bot_forever.py, for the Flask server instead of the Discord bot.
/public, /jdstock, /portfolio, the admin AI-review pipeline, and now the Discord bot's own
grounded answers all depend on this process being up -- if it crashes it used to just stay
down until someone noticed. This wraps zulu_server.py as a SEPARATE subprocess and relaunches
it every time it exits.

Run this instead of `python zulu_server.py` directly:
    python run_zulu_server_forever.py
Stop it the normal way (Ctrl+C) — that's the only thing that actually ends the loop.

NOTE: this only keeps the process alive while THIS machine is on and this script is
running -- it does not make the server reachable when your PC is off/asleep. For that you
need it hosted somewhere always-on (see the free-tier hosting research from earlier).
"""
import subprocess
import sys
import time
from datetime import datetime

HERE = __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0]
SERVER_SCRIPT = HERE + "/zulu_server.py"

MIN_BACKOFF = 5        # seconds before the first restart attempt
MAX_BACKOFF = 300       # cap backoff at 5 minutes if it keeps crash-looping
HEALTHY_UPTIME = 120    # if the server ran at least this long, treat the next crash as
                        # fresh (reset backoff) rather than part of the same crash loop


def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def main():
    backoff = MIN_BACKOFF
    log(f"Supervisor starting — watching {SERVER_SCRIPT}")
    while True:
        started = time.time()
        log("Launching zulu_server.py ...")
        try:
            proc = subprocess.run([sys.executable, SERVER_SCRIPT])
            code = proc.returncode
        except KeyboardInterrupt:
            log("Stopped by Ctrl+C.")
            return
        except Exception as e:
            log(f"Supervisor itself hit an error launching the server: {e}")
            code = None

        uptime = time.time() - started
        log(f"Server process exited (code={code}) after {uptime:.0f}s.")

        if uptime >= HEALTHY_UPTIME:
            backoff = MIN_BACKOFF   # it ran fine for a while -- this crash isn't a loop, reset
        else:
            backoff = min(backoff * 2, MAX_BACKOFF)   # crashed fast -- back off harder each time

        log(f"Restarting in {backoff}s ...")
        try:
            time.sleep(backoff)
        except KeyboardInterrupt:
            log("Stopped by Ctrl+C.")
            return


if __name__ == "__main__":
    main()
