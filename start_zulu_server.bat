@echo off
REM Double-click this to run zulu_server.py with auto-restart-on-crash.
REM Closing this window stops the server -- to survive PC restarts too, put a
REM shortcut to this file in your Windows Startup folder (Win+R, type
REM shell:startup, drop a shortcut there).
REM Remember: for the public site/jd-stock/portfolio chat widgets to reach this
REM server, you also still need `cloudflared tunnel --url http://localhost:5005`
REM running, and the resulting URL pasted wherever each site expects it.
cd /d "%~dp0"
python run_zulu_server_forever.py
pause
