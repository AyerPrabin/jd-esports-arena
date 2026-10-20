"""Runs the ZULU Discord bot with no window, restarting it whenever it exits (crash, network drop).

Started at Windows login by the Task Scheduler task "ZULU Discord bot" (see README/notes); also fine to
double-click. Output goes to zulu_discord.log next to this file (rotated at ~2 MB). Stop it from Task
Manager (pythonw.exe) or `schtasks /End /TN "ZULU Discord bot"`.
"""
import os
import subprocess
import sys
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
BOT = os.path.join(HERE, "zulu_discord.py")
LOG = os.path.join(HERE, "zulu_discord.log")
PY = os.path.join(os.path.dirname(sys.executable), "python.exe")  # console python for the child, no window (CREATE_NO_WINDOW)


def log_file():
    if os.path.exists(LOG) and os.path.getsize(LOG) > 2_000_000:
        os.replace(LOG, LOG + ".1")
    return open(LOG, "a", encoding="utf-8", buffering=1)


def main():
    backoff = 5
    while True:
        with log_file() as f:
            f.write(f"\n[{datetime.now():%Y-%m-%d %H:%M:%S}] starting zulu_discord.py\n")
            started = time.time()
            env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1")
            code = subprocess.call([PY if os.path.exists(PY) else sys.executable, BOT], cwd=HERE, stdout=f,
                                   stderr=subprocess.STDOUT, env=env, creationflags=0x08000000)
            f.write(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] bot exited with code {code}\n")
        backoff = 5 if time.time() - started > 120 else min(backoff * 2, 300)   # crash loop -> back off
        time.sleep(backoff)


if __name__ == "__main__":
    main()
