@echo off
REM Double-click this to run the Discord bot with auto-restart-on-crash.
REM Closing this window stops the bot -- to survive PC restarts too, put a
REM shortcut to this file in your Windows Startup folder (Win+R, type
REM shell:startup, drop a shortcut there).
cd /d "%~dp0"
python run_discord_bot_forever.py
pause
