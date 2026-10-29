"""results-archive.json: every published match-by-match board, rebuilt from tournaments.json's git history.

The site keeps only the latest board in tournaments.json (bo3), so older events' M1/M2/M3 points live in
git history. Rebuilt automatically by .github/workflows/results-archive.yml on every tournaments.json change;
by hand: python tools/make_results_archive.py
"""
import json
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
log = subprocess.run(["git", "log", "--format=%H", "--", "tournaments.json"], cwd=REPO,
                     capture_output=True, text=True, encoding="utf-8").stdout.split()
events: dict[str, dict] = {}
for h in log:                                  # newest first: the first board seen per event is its last one
    raw = subprocess.run(["git", "show", f"{h}:tournaments.json"], cwd=REPO, capture_output=True).stdout
    try:
        d = json.loads(raw.decode("utf-8"))
    except Exception:
        continue
    b = d.get("bo3") or {}
    name, teams = b.get("tournament"), b.get("teams") or []
    if not name or name in events or not b.get("published") or not teams:
        continue
    if not any((r.get("pts") or r.get("kills")) for x in teams for r in (x.get("r") or [])):
        continue
    ev = next((x for x in d.get("tournaments", []) if x.get("name") == name), {})
    events[name] = {
        "name": name, "date": ev.get("date", ""), "start": ev.get("start", ""),
        "maps": [ev.get("map", ""), ev.get("map2", ""), ev.get("map3", "")],
        "prize": ev.get("prize", ""), "winner": ev.get("winner", ""),
        "kill_pts": b.get("kill_pts") or 0,
        "teams": [{"team": x.get("team", ""), "r": [{"kills": int(r.get("kills") or 0), "pts": int(r.get("pts") or 0)}
                                                     for r in (x.get("r") or [])]} for x in teams if x.get("team")],
    }
out = sorted(events.values(), key=lambda e: e["start"] or "", reverse=True)
(REPO / "results-archive.json").write_text(json.dumps({"events": out}, ensure_ascii=False, indent=1) + "\n",
                                           encoding="utf-8", newline="\n")
print(len(out), "events:", ", ".join(e["name"] for e in out))
