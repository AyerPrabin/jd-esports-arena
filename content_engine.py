"""
Generates a review-ready batch of social promo assets (images + captions) for
one tournament in tournaments.json. Nothing here posts anywhere automatically
-- it only writes files under content/<slug>/ for a human to look at and post.

Usage:
    python content_engine.py "JD Free Fire Open #2"
    python content_engine.py            # defaults to the next "upcoming" one
"""
import json
import re
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).parent
CONTENT_DIR = ROOT / "content"

# Existing clean (text-free) art used as crop source for feed/story images.
ART_SOURCE = ROOT / "event-card.jpg"

# Pre-made banner per tournament number, already has text/branding baked in.
BANNER_BY_INDEX = {
    1: ROOT / "jd-free-fire-open-1.png",
    2: ROOT / "jd-free-fire-open-2.png",
    3: ROOT / "jd-free-fire-open-3.png",
}

CROPS = {
    "square_1080x1080.jpg": (1, 1),
    "portrait_1080x1350.jpg": (4, 5),
    "story_1080x1920.jpg": (9, 16),
}


def slugify(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def load_tournament(name_arg):
    data = json.loads((ROOT / "tournaments.json").read_text(encoding="utf-8"))
    tournaments = data["tournaments"]
    if name_arg:
        for t in tournaments:
            if t["name"].lower() == name_arg.lower():
                return t
        raise SystemExit(f"No tournament named {name_arg!r} in tournaments.json")
    for t in tournaments:
        if t.get("status") == "upcoming":
            return t
    raise SystemExit("No upcoming tournament found in tournaments.json")


def center_crop(im, target_w_ratio, target_h_ratio, out_px=1080):
    target_ratio = target_w_ratio / target_h_ratio
    w, h = im.size
    src_ratio = w / h
    if src_ratio > target_ratio:
        new_w = int(h * target_ratio)
        left = (w - new_w) // 2
        box = (left, 0, left + new_w, h)
    else:
        new_h = int(w / target_ratio)
        top = (h - new_h) // 2
        box = (0, top, w, top + new_h)
    cropped = im.crop(box)
    out_h = int(out_px * target_h_ratio / target_w_ratio)
    return cropped.resize((out_px, out_h), Image.LANCZOS)


def make_images(tournament, out_dir):
    if not ART_SOURCE.exists():
        print(f"  [skip] {ART_SOURCE.name} not found, skipping crops")
        return
    im = Image.open(ART_SOURCE).convert("RGB")
    for filename, (rw, rh) in CROPS.items():
        out = center_crop(im, rw, rh)
        out.save(out_dir / filename, quality=92)
        print(f"  wrote {filename} ({out.size[0]}x{out.size[1]})")

    match = re.search(r"#(\d+)", tournament["name"])
    idx = int(match.group(1)) if match else None
    banner = BANNER_BY_INDEX.get(idx)
    if banner and banner.exists():
        dest = out_dir / f"banner{banner.suffix}"
        dest.write_bytes(banner.read_bytes())
        print(f"  copied pre-made banner -> {dest.name} (has text baked in, verify prize/date match tournaments.json before posting)")


def build_captions(t):
    name = t["name"]
    date = t.get("date", "")
    time_ = t.get("time", "")
    prize = t.get("prize", "")
    entry = t.get("entry", "")
    slots = t.get("slots", "")
    fmt = t.get("format", "")
    hashtags_en = "#FreeFire #FreeFireNepal #FreeFireIndia #JDEsportsArena #AyerFire #EsportsNepal #FreeFireTournament #FFBattleRoyale"

    return f"""# {name} — content pack
Generated from tournaments.json. Review before posting; nothing here has been published.

Facts used: {date} {time_} | Prize {prize} | Entry {entry} | Slots {slots} | {fmt}

---

## 1. Teaser (T-7, post to IG/FB feed + Discord #announcements)

**English:**
{name} is coming. Squad up. {prize} prize pool, {entry} entry. {date}, {time_}. Slots are limited to {slots} squads — registration link in bio.

**Nepali/Hindi-mixed (common in NP/IN FF community captions):**
{name} aa dai xa! Squad ready gara, {prize} ko prize pool, entry {entry}. {date} {time_} ma huney. {slots} squad matra — bio ma link cha, register garna bir na garnu 🔥

{hashtags_en}

---

## 2. Registration open (T-6, pin in Discord, IG story + feed)

**English:**
Registration is LIVE for {name}. {entry} entry, {prize} up for grabs. First {slots} squads get in — don't sleep on this one.
Register: [link]

**Nepali/Hindi-mixed:**
Registration khulyo {name} ko lagi! Entry {entry}, prize {prize}. Pahila {slots} squad le matra pauxan — turunta register gara!
Register: [link]

{hashtags_en}

---

## 3. Reminder — T-3 days

**English:**
3 days left. {name} kicks off {date}, {time_}. If your squad isn't registered yet, this is the reminder.
Register: [link]

**Nepali/Hindi-mixed:**
3 din matra baaki! {name} {date} {time_} bata suru huncha. Squad register vaisakeko xaina bhane, ahile gara!

{hashtags_en}

---

## 4. Reminder — T-1 day / day-of

**English:**
Tomorrow. {name}. {prize} on the line. Room codes go out to registered squads — check your DMs/notifications before {time_}.

**Nepali/Hindi-mixed:**
Bholi ho match! {name}. Room code registered squad haru lai pathauxam match suru huney bela ma — notification check gardai basnu.

{hashtags_en}

---

## 5. Live now

**English:**
LIVE NOW: {name}. Follow the bracket/leaderboard on site. Good luck to every squad dropping in today.

**Nepali/Hindi-mixed:**
ABHI LIVE: {name}. Leaderboard site ma herna sakinxa. Sabai squad lai all the best!

{hashtags_en} #FreeFireLive

---

## 6. Results / highlights (post-match, pair with gameplay/ clip)

**English:**
{name} — results are in. Congrats to the winning squad. Highlights + full standings on site. Next tournament coming soon — follow so you don't miss registration.

**Nepali/Hindi-mixed:**
{name} sakiyo! Winning squad lai congratulations. Highlights aru results site ma herna paunuhuncha. Arko tournament chittai auxa — follow gardai basnu.

{hashtags_en} #Winner #Highlights

---

## Notes for whoever posts these
- Swap [link] for the actual registration URL before posting.
- Story/portrait/square crops in this folder are plain art (no text) — either post as-is with the caption carrying the info, or add a text overlay in Canva/IG's own text tool. Do not rely on this script's crops to have text on them.
- `banner.png` (if present) is the pre-made banner with all details baked into the image itself — use it as-is for Facebook/Discord/link posts, but only after confirming the prize/date on it matches tournaments.json (the Open #2 banner currently shows Rs 400; tournaments.json says Rs 500 — needs a re-export before use).
"""


def main():
    name_arg = sys.argv[1] if len(sys.argv) > 1 else None
    t = load_tournament(name_arg)
    slug = slugify(t["name"])
    out_dir = CONTENT_DIR / slug
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Generating content pack for: {t['name']}")
    make_images(t, out_dir)

    captions_path = out_dir / "captions.md"
    captions_path.write_text(build_captions(t), encoding="utf-8")
    print(f"  wrote {captions_path.relative_to(ROOT)}")
    print(f"\nDone. Review everything in {out_dir.relative_to(ROOT)}/ before posting anything.")


if __name__ == "__main__":
    main()
