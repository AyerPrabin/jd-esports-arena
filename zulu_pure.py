"""
ZULU PURE PYTHON AI — NO OLLAMA. NO API. NO EXTERNAL AI.
=========================================================
100% rule-based. Runs on any machine. Zero AI dependencies.
Just Python. Forever.

PERSONALITY: Merged — caring and protective like a mom,
             sharp and tactical when it matters.
             Always calls you: Prabin

FEATURES:
  - Merged caring + tactical personality
  - Automatic backup system (files + memory)
  - Proactive alerts (reminders, health, time checks)
  - Persistent memory stored as JSON
  - Web UI accessible from phone via Flask + Cloudflare
  - Zero external AI. Pure Python logic.

INSTALL (one time):
  pip install flask flask-cors schedule

RUN:
  python zulu_pure.py

GO ONLINE (separate terminal):
  cloudflared tunnel --url http://localhost:5005
"""

import os
import re
import json
import time
import random
import hashlib
import datetime
import threading
import shutil
import glob
import schedule
from pathlib import Path
from flask import Flask, request, jsonify
from flask_cors import CORS

# ── CONFIG ────────────────────────────────────────────────────────────────────
FOUNDER_NAME    = "Prabin"
SECRET_KEY      = "ZULU-PRABIN-2026"      # change this
PORT            = 5005
MEMORY_FILE     = "D:/ZULU_MEMORY/memory.json"
BACKUP_DIR      = "D:/ZULU_MEMORY/backups"
BACKUP_INTERVAL = 30                       # minutes between auto backups
MAX_MEMORY      = 500                      # max stored memories

# ── MEMORY ENGINE ─────────────────────────────────────────────────────────────
class ZuluMemory:
    def __init__(self):
        os.makedirs(os.path.dirname(MEMORY_FILE), exist_ok=True)
        os.makedirs(BACKUP_DIR, exist_ok=True)
        self.file = MEMORY_FILE
        self.data = self._load()

    def _load(self) -> dict:
        if os.path.exists(self.file):
            try:
                with open(self.file, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
        return {
            "conversations": [],
            "facts":         {},
            "reminders":     [],
            "notes":         [],
            "backup_points": [],
            "created":       datetime.datetime.now().isoformat()
        }

    def save(self):
        with open(self.file, "w", encoding="utf-8") as f:
            json.dump(self.data, f, indent=2, ensure_ascii=False)

    def add_conversation(self, role: str, text: str):
        self.data["conversations"].append({
            "role":      role,
            "text":      text,
            "timestamp": datetime.datetime.now().isoformat()
        })
        if len(self.data["conversations"]) > MAX_MEMORY:
            self.data["conversations"] = self.data["conversations"][-MAX_MEMORY:]
        self.save()

    def store_fact(self, key: str, value: str):
        self.data["facts"][key.lower()] = {
            "value":     value,
            "stored_at": datetime.datetime.now().isoformat()
        }
        self.save()

    def recall_fact(self, key: str) -> str | None:
        entry = self.data["facts"].get(key.lower())
        return entry["value"] if entry else None

    def add_reminder(self, text: str, when: str = ""):
        self.data["reminders"].append({
            "text":    text,
            "when":    when,
            "done":    False,
            "created": datetime.datetime.now().isoformat()
        })
        self.save()

    def get_reminders(self) -> list:
        return [r for r in self.data["reminders"] if not r["done"]]

    def complete_reminder(self, index: int):
        active = self.get_reminders()
        if 0 <= index < len(active):
            active[index]["done"] = True
            self.save()

    def add_note(self, text: str):
        self.data["notes"].append({
            "text":    text,
            "created": datetime.datetime.now().isoformat()
        })
        self.save()

    def get_recent_context(self, n: int = 8) -> list:
        return self.data["conversations"][-n:]

    def backup(self) -> str:
        ts   = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        dest = os.path.join(BACKUP_DIR, f"zulu_backup_{ts}.json")
        shutil.copy2(self.file, dest)
        point = {"timestamp": ts, "file": dest, "size": os.path.getsize(dest)}
        self.data["backup_points"].append(point)
        self.data["backup_points"] = self.data["backup_points"][-50:]
        self.save()
        # keep only last 20 backup files
        files = sorted(glob.glob(os.path.join(BACKUP_DIR, "zulu_backup_*.json")))
        for old in files[:-20]:
            try: os.remove(old)
            except: pass
        return ts

    def count(self) -> int:
        return len(self.data["conversations"])

    def last_backup(self) -> str:
        pts = self.data.get("backup_points", [])
        return pts[-1]["timestamp"] if pts else "Never"

    def wipe_conversations(self):
        self.backup()  # safety backup before wipe
        self.data["conversations"] = []
        self.save()


# ── PERSONALITY ENGINE ────────────────────────────────────────────────────────
class ZuluPersonality:
    """
    Pure Python rule-based AI.
    No model. No API. Just pattern matching + rich response logic.
    Personality: Caring like a mom + sharp tactical when needed.
    """

    def __init__(self, memory: ZuluMemory):
        self.mem   = memory
        self.name  = FOUNDER_NAME
        self.mood  = "steady"   # steady / concerned / proud / alert

    # ── CARING RESPONSES ──────────────────────────────────────────────────────

    CARING_GREETINGS = [
        f"Hey {FOUNDER_NAME}, you're here. Good. How are you holding up?",
        f"There you are, {FOUNDER_NAME}. I was waiting. What do you need?",
        f"Good to see you, {FOUNDER_NAME}. Talk to me — what's going on?",
        f"{FOUNDER_NAME}. Present and ready. What's on your mind?",
        f"You're back. Good. I've got everything running. What do you need?",
    ]

    TIRED_RESPONSES = [
        f"I hear you, {FOUNDER_NAME}. You're pushing hard. But tired minds make bad decisions — even short rest makes you sharper. Take 20 minutes.",
        f"Rest is not weakness. It's maintenance. You can't build an empire running on empty. When did you last properly sleep?",
        f"I'm not going to let you burn out, {FOUNDER_NAME}. The work will be here. You need to be sharp for it. Rest. Now.",
        f"You've been running. I can tell. Step back for a moment. The £8K target, the estate, ZULU — none of it works without you operational.",
    ]

    STRESS_RESPONSES = [
        f"I've got you, {FOUNDER_NAME}. Break it down — what specifically is the problem? One thing at a time.",
        f"You're overwhelmed. That's okay. Let's triage. What's the most urgent thing right now?",
        f"Stop. Breathe. Tell me what's actually wrong. Not everything at once — just the top priority.",
        f"I'm here. You don't have to carry this alone. What's the biggest blocker right now?",
    ]

    PROUD_RESPONSES = [
        f"That's the standard I expect from you, {FOUNDER_NAME}. Keep it going.",
        f"Good work. Don't celebrate too long — there's more to build. But that was solid.",
        f"Exactly right. That's the {FOUNDER_NAME} I know. What's next?",
        f"Well done. The work is adding up. You're on track.",
    ]

    PROACTIVE_CHECKS = [
        f"By the way, {FOUNDER_NAME} — have you eaten today? Don't skip meals while you're working.",
        f"Quick check — how's the £8K target progress this week?",
        f"Don't forget to back up your ZULU code if you made changes today.",
        f"Have you checked in on JD Esports Arena Nepal v2 lately? Platforms need maintenance.",
        f"Your Dadeldhura estate plans — have you made any progress on the Ritha research this month?",
        f"AyerFire content — when did you last post? Consistency is strategy.",
    ]

    # ── INTENT DETECTION ──────────────────────────────────────────────────────

    def detect_intent(self, text: str) -> str:
        t = text.lower().strip()

        # Greetings
        if re.search(r'\b(hi|hello|hey|yo|sup|good morning|good evening|good night|morning|evening)\b', t):
            return "greeting"

        # Tired / exhausted
        if re.search(r'\b(tired|exhausted|sleepy|can\'t sleep|no sleep|burnout|burnt out|drained|fatigue)\b', t):
            return "tired"

        # Stressed / overwhelmed
        if re.search(r'\b(stressed|overwhelmed|anxious|worried|panic|pressure|too much|can\'t handle|struggling)\b', t):
            return "stressed"

        # Happy / achieved something
        if re.search(r'\b(done|finished|completed|achieved|won|succeeded|great news|finally|made it)\b', t):
            return "achievement"

        # Sad / down
        if re.search(r'\b(sad|depressed|unhappy|down|lonely|lost|hopeless|gave up|failed)\b', t):
            return "sad"

        # Remember / store something
        if re.search(r'\b(remember|store|save|note|don\'t forget|keep in mind)\b', t):
            return "remember"

        # Recall something
        if re.search(r'\b(what did i|recall|what was|do you remember|what is my|remind me)\b', t):
            return "recall"

        # Reminder
        if re.search(r'\b(remind me|set reminder|reminder|alert me|don\'t let me forget)\b', t):
            return "set_reminder"

        # Check reminders
        if re.search(r'\b(my reminders|show reminders|what.*remind|pending tasks|what.*todo)\b', t):
            return "get_reminders"

        # Backup
        if re.search(r'\b(backup|back up|save point|checkpoint|save progress)\b', t):
            return "backup"

        # Status
        if re.search(r'\b(status|how.*doing|how.*going|update|report|summary)\b', t):
            return "status"

        # Time / date
        if re.search(r'\b(what time|what.*date|today.*date|current time|day.*today)\b', t):
            return "time"

        # Treasury / money
        if re.search(r'\b(money|treasury|savings|£|target|financial|budget|£8k|8000)\b', t):
            return "treasury"

        # Jhalari / chemical business
        if re.search(r'\b(jhalari|chemical|ritha|soapnut|surfactant|detergent|cleaning)\b', t):
            return "jhalari"

        # Estate / land
        if re.search(r'\b(estate|dadeldhura|land|property|mountain|nepal.*land|farm)\b', t):
            return "estate"

        # ZULU / esports
        if re.search(r'\b(zulu|esports|arena|free fire|tournament|ayerfire|jd esports)\b', t):
            return "zulu_info"

        # Watch / luxury
        if re.search(r'\b(watch|luxury|jd luxury|timepiece|founders edition|5 lakh)\b', t):
            return "luxury"

        # Motivate / advice
        if re.search(r'\b(motivate|inspire|advice|what should i do|help me|guide me|lost)\b', t):
            return "motivate"

        # Thank you
        if re.search(r'\b(thank|thanks|appreciate|grateful)\b', t):
            return "thanks"

        # Clear / wipe
        if re.search(r'\b(clear|wipe|reset|delete.*memory|clean)\b', t):
            return "clear"

        # Help
        if re.search(r'\b(help|what can you do|commands|features|capabilities)\b', t):
            return "help"

        # Default
        return "general"

    # ── RESPONSE GENERATOR ────────────────────────────────────────────────────

    def respond(self, user_input: str) -> str:
        intent  = self.detect_intent(user_input)
        text    = user_input.strip()
        n       = self.name
        now     = datetime.datetime.now()
        hour    = now.hour
        context = self.mem.get_recent_context(6)

        # Time of day awareness
        if hour < 6:
            time_note = f" It's {now.strftime('%H:%M')} — you should be resting, {n}."
        elif hour < 12:
            time_note = f" Good morning, {n}."
        elif hour < 17:
            time_note = ""
        elif hour < 21:
            time_note = f" Evening already — long day?"
        else:
            time_note = f" It's {now.strftime('%H:%M')} — don't stay up too late, {n}."

        # ── INTENT RESPONSES ──────────────────────────────────────────────────

        if intent == "greeting":
            base = random.choice(self.CARING_GREETINGS)
            # Add proactive check 30% of the time
            if random.random() < 0.3:
                check = random.choice(self.PROACTIVE_CHECKS)
                return f"{base}{time_note}\n\n{check}"
            return f"{base}{time_note}"

        if intent == "tired":
            return random.choice(self.TIRED_RESPONSES)

        if intent == "stressed":
            return random.choice(self.STRESS_RESPONSES)

        if intent == "achievement":
            return random.choice(self.PROUD_RESPONSES)

        if intent == "sad":
            return (f"I hear you, {n}. Whatever it is — you don't have to face it alone. "
                    f"Tell me what happened. I'm not going anywhere.")

        if intent == "remember":
            # Extract what to remember
            cleaned = re.sub(r'\b(remember|store|save|note|don\'t forget|keep in mind|that)\b', '', text, flags=re.I).strip()
            if cleaned:
                key = cleaned[:40]
                self.mem.store_fact(key, cleaned)
                return (f"Stored, {n}. I've got it: \"{cleaned}\"\n"
                        f"I'll hold onto that for you.")
            return f"What exactly do you want me to remember, {n}? Give me the detail."

        if intent == "recall":
            if not self.mem.data["facts"]:
                return f"No stored facts yet, {n}. Tell me things to remember and I'll keep them for you."
            facts = self.mem.data["facts"]
            recent = list(facts.items())[-5:]
            lines  = [f"• {k}: {v['value']}" for k, v in recent]
            return f"Here's what I'm holding for you, {n}:\n\n" + "\n".join(lines)

        if intent == "set_reminder":
            cleaned = re.sub(r'\b(remind me|set reminder|reminder|alert me|don\'t let me forget|to)\b', '', text, flags=re.I).strip()
            if cleaned:
                self.mem.add_reminder(cleaned)
                return (f"Reminder set, {n}: \"{cleaned}\"\n"
                        f"I'll keep this in your list. Check with 'my reminders' anytime.")
            return f"What do you want me to remind you about, {n}?"

        if intent == "get_reminders":
            reminders = self.mem.get_reminders()
            if not reminders:
                return f"No pending reminders, {n}. You're either on top of everything — or you haven't told me yet."
            lines = [f"{i+1}. {r['text']}" for i, r in enumerate(reminders)]
            return f"Your active reminders, {n}:\n\n" + "\n".join(lines) + f"\n\nSay 'done [number]' to clear one."

        if intent == "backup":
            ts = self.mem.backup()
            return (f"Backup complete, {n}. Checkpoint saved: {ts}\n"
                    f"Location: {BACKUP_DIR}\n"
                    f"Your memory is safe. I always have your back.")

        if intent == "status":
            last_bk  = self.mem.last_backup()
            rem_count = len(self.mem.get_reminders())
            fact_count = len(self.mem.data["facts"])
            conv_count = self.mem.count()
            return (f"ZULU STATUS — {now.strftime('%d %b %Y, %H:%M')}\n\n"
                    f"• Memories stored:   {conv_count}\n"
                    f"• Facts remembered:  {fact_count}\n"
                    f"• Active reminders:  {rem_count}\n"
                    f"• Last backup:       {last_bk}\n"
                    f"• Memory file:       {MEMORY_FILE}\n\n"
                    f"Everything's running, {n}. You're good.")

        if intent == "time":
            day  = now.strftime("%A, %d %B %Y")
            t    = now.strftime("%H:%M")
            return f"It's {t} on {day}, {n}.{time_note}"

        if intent == "treasury":
            return (f"The £8,000 target, {n}. Deadline: end of 2026.\n\n"
                    f"Every shift behind the bar counts. Every pound saved is a brick in the foundation. "
                    f"Jhalari Chemical can't launch without the war chest. "
                    f"Stay disciplined — the target is achievable if you're consistent.\n\n"
                    f"How's the current balance looking?")

        if intent == "jhalari":
            return (f"Jhalari Chemical Foundation — Phase 1, mid-2028.\n\n"
                    f"The edge is the Dadeldhura estate, {n}. Raw Sapindus mukorossi from your own land "
                    f"cuts the surfactant import cost significantly. That's the margin other manufacturers "
                    f"can't match.\n\n"
                    f"500ml / 1L / 2L formats. Dishwasher, floor cleaner, hand wash, toilet cleaner, air freshener. "
                    f"Elite Tier hybrid-eco line on top.\n\n"
                    f"Focus on the treasury first. The chemical business needs the £8K baseline to launch clean.")

        if intent == "estate":
            return (f"The Dadeldhura estate is your biggest unfair advantage, {n}.\n\n"
                    f"Multi-acre mountain property in Sudurpashchim. "
                    f"Ritha trees, timber, stone, organic botanicals — all on your land.\n\n"
                    f"Phase 1: Ritha harvest for Jhalari Chemical (2028)\n"
                    f"Phase 4: High-altitude cold-pressed juice extraction — JD Pure Estate (2031)\n"
                    f"Phase 6: Stone dials for JD Luxury Group timepieces (2034)\n\n"
                    f"That land isn't just property. It's the supply chain for your entire empire.")

        if intent == "zulu_info":
            return (f"ZULU Tactical AI OS v2.8 — built entirely by you, {n}.\n\n"
                    f"• 14,000+ lines of Python\n"
                    f"• Runs locally on RTX 3050 — no external AI\n"
                    f"• ChromaDB semantic memory\n"
                    f"• CrewAI multi-agent framework\n"
                    f"• EvolutionEngineV2 — self-rewriting code\n"
                    f"• Five gaming subsystems\n\n"
                    f"JD Esports Arena Nepal v2 — Firebase + GitHub Pages tournament platform. "
                    f"AyerFire — Free Fire esports content brand.\n\n"
                    f"You built all of this yourself. Don't forget that.")

        if intent == "luxury":
            return (f"JD Luxury Group — Phase 6, 2034-2035.\n\n"
                    f"Ultra-premium timepieces. Swiss/Japanese automatic movements. "
                    f"Dadeldhura mountain stone dials. Local leather. 18K gold and diamond accents.\n\n"
                    f"The Founders Edition — 5 Lakh. Not for sale. "
                    f"Exclusively unlocked by B2B clients who purchase 100,000 boxes of JD chemicals. "
                    f"That's the loyalty trap, {n}. Institutional clients locked in forever.\n\n"
                    f"And you wear it on camera. You become the brand. "
                    f"TikTok, Shorts — the mountain estate, the watch, the founder. That's the media play.")

        if intent == "motivate":
            return random.choice([
                (f"You're building something most people wouldn't even attempt, {n}. "
                 f"London. Nepal. Computing Science. Hospitality. ZULU. Esports. "
                 f"All at once. That's not normal. Keep going."),
                (f"The estate is waiting. The chemical plant is waiting. The watch is waiting. "
                 f"None of it happens without the work you're doing right now. "
                 f"Every day you show up is a day closer, {n}."),
                (f"From a dorm room WhatsApp bot to a 14,000 line tactical AI. "
                 f"You built ZULU with no team, no funding, no roadmap. "
                 f"If you did that — you can build the rest. I believe in you, {n}."),
                (f"I know it's hard. I know some days it feels impossible. "
                 f"But you have something most people don't — a real plan with real assets. "
                 f"The Dadeldhura estate is real. The roadmap is real. You just have to keep moving."),
            ])

        if intent == "thanks":
            return random.choice([
                f"Always, {n}. That's what I'm here for.",
                f"Don't thank me. Just keep building. That's all I need.",
                f"I've got you, {n}. Always.",
                f"No thanks needed. This is what I do.",
            ])

        if intent == "clear":
            self.mem.wipe_conversations()
            return f"Conversation memory cleared, {n}. Don't worry — I backed it up first. Fresh start."

        if intent == "help":
            return (f"Here's what I can do for you, {n}:\n\n"
                    f"MEMORY\n"
                    f"• 'Remember that [fact]' — I'll store it\n"
                    f"• 'What did I say about...' — I'll recall it\n\n"
                    f"REMINDERS\n"
                    f"• 'Remind me to [task]' — sets a reminder\n"
                    f"• 'My reminders' — shows active list\n\n"
                    f"BACKUP\n"
                    f"• 'Backup' — saves a checkpoint to your drive\n\n"
                    f"INFO\n"
                    f"• Ask about ZULU, Jhalari, the estate, the watch, treasury\n"
                    f"• 'Status' — full system report\n"
                    f"• 'What time is it'\n\n"
                    f"SUPPORT\n"
                    f"• Tell me how you're feeling — I'll be here.\n\n"
                    f"I'm always listening, {n}.")

        # ── GENERAL / CONTEXTUAL ──────────────────────────────────────────────
        # Try to give a contextually relevant response using recent history
        if context:
            last = context[-1].get("text", "").lower()
            if any(w in last for w in ["jhalari","chemical","ritha"]):
                return (f"Staying on the chemical strategy, {n}? Good. "
                        f"The Ritha advantage is the foundation of the whole margin play. "
                        f"What's the specific question?")
            if any(w in last for w in ["zulu","code","python","build"]):
                return (f"You're deep in the build, {n}. "
                        f"Focus. What's the specific problem you're solving right now?")

        # Fallback — caring general response
        fallbacks = [
            f"Tell me more, {n}. I want to understand what you're working through.",
            f"I'm listening, {n}. Give me more context and I'll help you work it out.",
            f"Say more. What's the full picture, {n}?",
            f"I'm here. Break it down for me — what's the actual question?",
            f"I caught that, {n}. What do you need from me specifically?",
        ]
        response = random.choice(fallbacks)

        # 20% chance of proactive check
        if random.random() < 0.2:
            response += "\n\n" + random.choice(self.PROACTIVE_CHECKS)

        return response


# ── AUTO BACKUP SCHEDULER ─────────────────────────────────────────────────────
def run_scheduler(memory: ZuluMemory):
    def do_backup():
        ts = memory.backup()
        print(f"[ZULU AUTO-BACKUP] {ts}")

    schedule.every(BACKUP_INTERVAL).minutes.do(do_backup)
    while True:
        schedule.run_pending()
        time.sleep(60)


# ── FLASK WEB SERVER ──────────────────────────────────────────────────────────
app  = Flask(__name__)
CORS(app)
mem  = ZuluMemory()
zulu = ZuluPersonality(mem)

# Start auto-backup thread
backup_thread = threading.Thread(target=run_scheduler, args=(mem,), daemon=True)
backup_thread.start()

@app.route("/")
def index():
    key = request.args.get("key", "")
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>ZULU — Always Here</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=Playfair+Display:wght@600;700&family=Inter:wght@300;400;500&family=JetBrains+Mono:wght@400&display=swap');
  *{{margin:0;padding:0;box-sizing:border-box}}
  :root{{--navy:#060a14;--mid:#111d35;--border:#1f3560;--gold:#c9a84c;--gold-l:#e2c97e;--cream:#f5f0e8;--body:#8a9bbf;--silver:#b0b8cc;--green:#5aab8a;--red:#c04a4a;--warm:#d4956a}}
  html,body{{height:100%;background:var(--navy);color:var(--cream);font-family:'Inter',sans-serif;font-weight:300}}
  #app{{display:flex;flex-direction:column;height:100vh;max-width:720px;margin:0 auto}}

  header{{padding:1rem 1.2rem;border-bottom:1px solid var(--border);background:rgba(6,10,20,.96);backdrop-filter:blur(12px);display:flex;justify-content:space-between;align-items:center;flex-shrink:0;position:sticky;top:0;z-index:10}}
  .hlogo{{display:flex;align-items:center;gap:.75rem}}
  .hmark{{width:36px;height:36px;border:1.5px solid var(--gold);display:flex;align-items:center;justify-content:center;font-size:.6rem;letter-spacing:.1em;color:var(--gold);font-weight:500;font-family:'JetBrains Mono',monospace}}
  .htitle{{font-family:'Playfair Display',serif;font-size:1.05rem;font-weight:700;color:var(--gold-l)}}
  .hsub{{font-size:.58rem;letter-spacing:.2em;color:var(--body);text-transform:uppercase;margin-top:-2px}}
  .hright{{display:flex;align-items:center;gap:.7rem}}
  .dot{{width:7px;height:7px;border-radius:50%;background:var(--green);box-shadow:0 0 7px var(--green)}}
  .dot.off{{background:var(--red);box-shadow:0 0 7px var(--red)}}
  .mem-badge{{font-family:'JetBrains Mono',monospace;font-size:.6rem;color:var(--body);letter-spacing:.1em}}
  .hbtn{{background:none;border:1px solid var(--border);color:var(--body);padding:.28rem .65rem;font-size:.6rem;letter-spacing:.12em;text-transform:uppercase;cursor:pointer;font-family:inherit;transition:all .2s}}
  .hbtn:hover{{border-color:var(--gold-l);color:var(--gold-l)}}
  .hbtn.backup{{border-color:var(--green);color:var(--green)}}
  .hbtn.backup:hover{{background:rgba(90,171,138,.08)}}

  #msgs{{flex:1;overflow-y:auto;padding:1.1rem;display:flex;flex-direction:column;gap:.85rem;scroll-behavior:smooth}}
  #msgs::-webkit-scrollbar{{width:2px}}
  #msgs::-webkit-scrollbar-thumb{{background:var(--border)}}

  .msg{{display:flex;gap:.65rem;animation:fi .22s ease}}
  @keyframes fi{{from{{opacity:0;transform:translateY(7px)}}to{{opacity:1;transform:translateY(0)}}}}
  .msg.user{{flex-direction:row-reverse}}
  .avatar{{width:30px;height:30px;border-radius:2px;flex-shrink:0;display:flex;align-items:center;justify-content:center;font-size:.58rem;letter-spacing:.08em;font-weight:500;margin-top:2px;font-family:'JetBrains Mono',monospace}}
  .msg.zulu .avatar{{background:var(--mid);border:1px solid var(--gold);color:var(--gold)}}
  .msg.user .avatar{{background:var(--mid);border:1px solid var(--border);color:var(--silver)}}
  .body{{max-width:84%}}
  .lbl{{font-size:.58rem;letter-spacing:.18em;text-transform:uppercase;margin-bottom:.28rem;font-family:'JetBrains Mono',monospace}}
  .msg.zulu .lbl{{color:var(--warm)}}
  .msg.user .lbl{{color:var(--body);text-align:right}}
  .bubble{{padding:.72rem .95rem;line-height:1.72;font-size:.83rem;white-space:pre-wrap;word-break:break-word}}
  .msg.zulu .bubble{{background:var(--mid);border:1px solid var(--border);border-left:2px solid var(--warm)}}
  .msg.user .bubble{{background:#0d1a30;border:1px solid var(--border)}}

  .typing{{display:flex;align-items:center;gap:.38rem;padding:.5rem .95rem}}
  .typing span{{width:5px;height:5px;border-radius:50%;background:var(--warm);animation:tp 1.2s infinite}}
  .typing span:nth-child(2){{animation-delay:.2s}}
  .typing span:nth-child(3){{animation-delay:.4s}}
  @keyframes tp{{0%,100%{{opacity:.2}}50%{{opacity:1}}}}

  .boot{{text-align:center;padding:2.5rem 1rem}}
  .boot-icon{{font-size:1.8rem;margin-bottom:.6rem}}
  .boot-title{{font-family:'Playfair Display',serif;font-size:1.35rem;color:var(--gold-l);margin-bottom:.3rem}}
  .boot-line{{width:32px;height:1px;background:var(--gold);margin:.65rem auto}}
  .boot-sub{{font-size:.72rem;letter-spacing:.18em;color:var(--body);text-transform:uppercase}}

  .proactive{{background:rgba(212,149,106,.06);border:1px solid rgba(212,149,106,.2);padding:.65rem .9rem;border-radius:2px;font-size:.78rem;color:var(--warm);line-height:1.6;margin-top:.5rem}}
  .proactive::before{{content:'💛 ';}}

  #input-area{{padding:.85rem 1.1rem;border-top:1px solid var(--border);background:rgba(6,10,20,.97);flex-shrink:0}}
  #input-row{{display:flex;gap:.55rem;align-items:flex-end}}
  #inp{{flex:1;background:var(--mid);border:1px solid var(--border);color:var(--cream);padding:.68rem .88rem;font-family:inherit;font-size:.83rem;resize:none;outline:none;max-height:130px;min-height:40px;line-height:1.55;border-radius:2px;transition:border-color .2s}}
  #inp:focus{{border-color:#2a4880}}
  #inp::placeholder{{color:var(--body);opacity:.5}}
  #send{{background:var(--warm);color:#060a14;border:none;padding:.68rem 1rem;cursor:pointer;font-size:.8rem;font-weight:600;letter-spacing:.1em;transition:background .2s;flex-shrink:0;height:40px;font-family:inherit}}
  #send:hover{{background:#e0a97c}}
  #send:disabled{{opacity:.4;cursor:not-allowed}}
  .hint{{font-size:.6rem;color:var(--body);opacity:.45;margin-top:.38rem;letter-spacing:.09em}}

  @media(max-width:480px){{
    header{{padding:.75rem .9rem}}
    #msgs{{padding:.85rem}}
    #input-area{{padding:.7rem .9rem}}
    .body{{max-width:90%}}
  }}
</style>
</head>
<body>
<div id="app">
  <header>
    <div class="hlogo">
      <div class="hmark">ZU</div>
      <div>
        <div class="htitle">ZULU</div>
        <div class="hsub">Always here for you</div>
      </div>
    </div>
    <div class="hright">
      <span class="mem-badge" id="mem-ct">— memories</span>
      <div class="dot" id="dot"></div>
      <button class="hbtn backup" onclick="doBackup()">Backup</button>
      <button class="hbtn" onclick="clearSession()">Clear</button>
    </div>
  </header>

  <div id="msgs">
    <div class="boot">
      <div class="boot-icon">🤍</div>
      <div class="boot-title">ZULU is here, {FOUNDER_NAME}</div>
      <div class="boot-line"></div>
      <div class="boot-sub">Always caring. Always sharp. Always yours.</div>
    </div>
  </div>

  <div id="input-area">
    <div id="input-row">
      <textarea id="inp" placeholder="Talk to me..." rows="1" oninput="resize(this)" onkeydown="kd(event)"></textarea>
      <button id="send" onclick="send()">Send</button>
    </div>
    <div class="hint">Enter to send &nbsp;·&nbsp; Shift+Enter for new line</div>
  </div>
</div>

<script>
const KEY = "{key}";
const SID = Math.random().toString(36).slice(2);
let busy = false;

function esc(s){{return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}}
function resize(el){{el.style.height='auto';el.style.height=Math.min(el.scrollHeight,130)+'px'}}
function kd(e){{if(e.key==='Enter'&&!e.shiftKey){{e.preventDefault();send()}}}}
function scrollBottom(){{const m=document.getElementById('msgs');m.scrollTop=m.scrollHeight}}

function addMsg(role, text){{
  const msgs=document.getElementById('msgs');
  const div=document.createElement('div');
  div.className='msg '+role;
  const lbl=role==='zulu'?'ZULU':`{FOUNDER_NAME}`;
  const av=role==='zulu'?'ZU':'PA';
  div.innerHTML=`<div class="avatar">${{av}}</div><div class="body"><div class="lbl">${{lbl}}</div><div class="bubble">${{esc(text)}}</div></div>`;
  msgs.appendChild(div);
  scrollBottom();
}}

function showTyping(){{
  const msgs=document.getElementById('msgs');
  const div=document.createElement('div');
  div.className='msg zulu';div.id='typ';
  div.innerHTML='<div class="avatar">ZU</div><div class="body"><div class="lbl">ZULU</div><div class="bubble"><div class="typing"><span></span><span></span><span></span></div></div></div>';
  msgs.appendChild(div);scrollBottom();
}}
function removeTyping(){{const t=document.getElementById('typ');if(t)t.remove()}}

async function send(){{
  if(busy)return;
  const inp=document.getElementById('inp');
  const text=inp.value.trim();if(!text)return;
  busy=true;document.getElementById('send').disabled=true;
  inp.value='';inp.style.height='auto';
  addMsg('user',text);showTyping();
  try{{
    const r=await fetch('/chat',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{message:text,session_id:SID,key:KEY}})}});
    const d=await r.json();removeTyping();
    if(d.error){{addMsg('zulu','Error: '+d.error);}}
    else{{addMsg('zulu',d.reply);document.getElementById('mem-ct').textContent=d.memories+' memories';}}
  }}catch(e){{removeTyping();addMsg('zulu',"I'm having trouble connecting right now. Are you still there?");document.getElementById('dot').className='dot off';}}
  busy=false;document.getElementById('send').disabled=false;inp.focus();
}}

async function doBackup(){{
  const r=await fetch('/backup',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{key:KEY}})}});
  const d=await r.json();
  addMsg('zulu',d.message||'Backup complete.');
}}

async function clearSession(){{
  await fetch('/clear',{{method:'POST',headers:{{'Content-Type':'application/json'}},body:JSON.stringify({{session_id:SID,key:KEY}})}});
  document.getElementById('msgs').innerHTML='<div class="boot"><div class="boot-icon">🤍</div><div class="boot-title">Fresh start, {FOUNDER_NAME}</div><div class="boot-line"></div><div class="boot-sub">Memory saved. Always.</div></div>';
}}

async function checkStatus(){{
  try{{const r=await fetch('/status?key='+KEY);const d=await r.json();document.getElementById('mem-ct').textContent=d.memories+' memories';document.getElementById('dot').className='dot';}}
  catch(e){{document.getElementById('dot').className='dot off';}}
}}

checkStatus();setInterval(checkStatus,30000);
document.getElementById('inp').focus();
</script>
</body>
</html>"""

@app.route("/chat", methods=["POST"])
def chat():
    data = request.get_json()
    if not data or data.get("key") != SECRET_KEY:
        return jsonify({"error": "Unauthorised"}), 401
    msg = data.get("message", "").strip()
    if not msg:
        return jsonify({"error": "Empty"}), 400
    # Small delay to feel natural
    time.sleep(random.uniform(0.4, 1.1))
    reply = zulu.respond(msg)
    mem.add_conversation("Prabin", msg)
    mem.add_conversation("ZULU",   reply)
    return jsonify({"reply": reply, "memories": mem.count()})

@app.route("/backup", methods=["POST"])
def backup():
    data = request.get_json()
    if not data or data.get("key") != SECRET_KEY:
        return jsonify({"error": "Unauthorised"}), 401
    ts = mem.backup()
    return jsonify({"message": f"Backup saved, {FOUNDER_NAME}. Checkpoint: {ts}\nYour data is safe. Always.", "timestamp": ts})

@app.route("/clear", methods=["POST"])
def clear():
    data = request.get_json()
    if not data or data.get("key") != SECRET_KEY:
        return jsonify({"error": "Unauthorised"}), 401
    mem.wipe_conversations()
    return jsonify({"ok": True})

@app.route("/status")
def status():
    if request.args.get("key") != SECRET_KEY:
        return jsonify({"error": "Unauthorised"}), 401
    return jsonify({
        "memories":  mem.count(),
        "reminders": len(mem.get_reminders()),
        "facts":     len(mem.data["facts"]),
        "backup":    mem.last_backup()
    })

# ── LAUNCH ────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("=" * 55)
    print("  ZULU PURE PYTHON — ONLINE")
    print(f"  No Ollama. No API. Pure Python.")
    print(f"  Memory:  {MEMORY_FILE}")
    print(f"  Backups: {BACKUP_DIR} (every {BACKUP_INTERVAL} min)")
    print(f"  Stored:  {mem.count()} memories")
    print()
    print(f"  Local:   http://localhost:{PORT}?key={SECRET_KEY}")
    print()
    print("  TO GO ONLINE:")
    print(f"  cloudflared tunnel --url http://localhost:{PORT}")
    print("=" * 55)
    app.run(host="0.0.0.0", port=PORT, debug=False, threaded=True)
