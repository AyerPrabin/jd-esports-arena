"""
RUN DISCORD BOT FOREVER  —  process supervisor for zulu_discord.py
====================================================================
bot.run() only survives network-level hiccups (discord.py handles Gateway reconnects
internally) — an unhandled exception anywhere in the bot's own code, or the process dying
outright, still kills the whole thing and it stays down until someone notices and restarts
it by hand. This wraps zulu_discord.py as a SEPARATE subprocess and relaunches it every
time it exits, so "the bot keeps crashing" becomes "the bot restarts within a few seconds"
instead.

Run this instead of `python zulu_discord.py` directly:
    python run_discord_bot_forever.py
Stop it the normal way (Ctrl+C) — that's the only thing that actually ends the loop.
"""
import subprocess
import sys
import time
from datetime import datetime

HERE = __file__.rsplit("\\", 1)[0].rsplit("/", 1)[0]
BOT_SCRIPT = HERE + "/zulu_discord.py"

MIN_BACKOFF = 5        # seconds before the first restart attempt
MAX_BACKOFF = 300       # cap backoff at 5 minutes if it keeps crash-looping
HEALTHY_UPTIME = 120    # if the bot ran at least this long, treat the next crash as fresh
                        # (reset backoff) rather than part of the same crash loop


def log(msg):
    print(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)


def main():
    backoff = MIN_BACKOFF
    log(f"Supervisor starting — watching {BOT_SCRIPT}")
    while True:
        started = time.time()
        log("Launching zulu_discord.py ...")
        try:
            proc = subprocess.run([sys.executable, BOT_SCRIPT])
            code = proc.returncode
        except KeyboardInterrupt:
            log("Stopped by Ctrl+C.")
            return
        except Exception as e:
            log(f"Supervisor itself hit an error launching the bot: {e}")
            code = None

        uptime = time.time() - started
        log(f"Bot process exited (code={code}) after {uptime:.0f}s.")

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
