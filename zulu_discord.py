"""
ZULU DISCORD BOT  —  JD Esports Arena community bot (Free Fire)
==============================================================
Legit, free, official Discord bot. It reads the SAME tournaments.json your
website uses (local file or GitHub raw URL), so everything stays in sync.

WHAT IT DOES
------------
- !tournaments / !t   -> current Free Fire schedule (live + upcoming), real registered counts
- !next               -> next match, prize, slots
- !register <squad>   -> Discord-side squad list for organizing (not the official sign-up);
                          only works inside the server itself, not in DMs
- !leaderboard / !lb  -> season standings
- !rules              -> tournament rules
- !ask <question>     -> built-in offline knowledge (Nepal/chemistry/physics/maths) first,
                          falls back to a free AI provider (Groq/Cerebras/Gemini/etc. — whichever
                          key(s) you set) for anything else
- @mention the bot, or reply to one of its messages, and it answers directly (no "!" needed) —
  everywhere else it stays quiet except for light keyword triggers, so it doesn't talk over
  every message in a busy channel
- !link <code>        -> link your Discord to your JD Arena account (code comes from the
                          website's account panel) so Room IDs can be DM'd here
- !giverole <squad> | <role>  -> (needs Manage Roles) MANUALLY award a Discord role like
                          "Winner S1" to every member of that squad who has linked their Discord
                          account and registered confirmed/approved under that squad name;
                          creates the role if it doesn't exist yet
- AUTOMATIC season-winner role: every poll (see ZULU_ANNOUNCE_CHANNEL_ID below), whichever team
  sits #1 on tournaments.json's top-level "leaderboard" gets a role auto-created/assigned to
  every one of its linked members — no command needed. Role is named "Winner <season>" if
  tournaments.json has a top-level "season" string (e.g. "season": "S1" -> "Winner S1"),
  else "Season Champion". Only fires again when the #1 team's NAME changes, and never revokes
  the role from a past #1 if someone else takes the top spot later — it's a permanent trophy,
  not a live-synced badge. Needs SUPABASE_SERVICE_ROLE_KEY + ZULU_ANNOUNCE_CHANNEL_ID set (the
  channel's guild is what the role gets created/assigned in).
- !help               -> command list
- light auto-reply to "room id", "when is the tournament", etc. (no spam)
- welcomes new members
- optional: auto-posts to a channel when a tournament goes live, fills up, or results are
  published (set ZULU_ANNOUNCE_CHANNEL_ID) — this is also what turns on the automatic
  season-winner role above

VOICE / MUSIC / TTS (slash commands)
-------------------------------------
- /join               -> joins the voice channel you're currently sitting in
- /leave              -> leaves voice, clears the music + TTS queue
- /play <song or URL> -> queues audio pulled from YouTube (via yt-dlp) and plays it
- /skip /pause /resume/ /stop  -> playback controls; /stop also clears the queue
- /queue              -> shows what's up next
- /ttschannel here|off -> (needs Manage Server) designate a text channel that ZULU reads
  aloud in voice chat, word for word, whenever it's connected to a voice channel. Auto-leaves
  a voice channel once every human has left it.
Needs FFmpeg on PATH (winget install Gyan.FFmpeg, or ffmpeg.org) plus the extra pip packages
below. If yt-dlp/PyNaCl/gTTS aren't installed, the bot still runs fine — those commands just
reply that the feature isn't available instead of crashing.

SETUP
-----
1. pip install discord.py requests PyNaCl yt-dlp gTTS
2. Create a bot at https://discord.com/developers/applications -> Bot -> add token.
   Enable "MESSAGE CONTENT INTENT" and "SERVER MEMBERS INTENT" under Bot settings.
3. Invite it to your server (OAuth2 -> URL Generator -> scopes: bot, applications.commands;
   perms: Send Messages, Read Message History, Connect, Speak, Manage Roles for !giverole).
   After inviting, drag the bot's own role ABOVE any role you want it to hand out (Server
   Settings -> Roles) — Discord won't let a bot assign or create a role above its own position.
4. Set env vars and run:
       export DISCORD_TOKEN="your-bot-token"
       # optional: live data straight from your repo
       export ZULU_TOURNAMENTS_URL="https://raw.githubusercontent.com/AyerPrabin/<repo>/main/tournaments.json"
       # optional: general-purpose !ask / mention-chat fallback (else set these in zulu_secrets.py) —
       # set any one of GOOGLE_API_KEY, GROQ_API_KEY, CEREBRAS_API_KEY, OPENROUTER_API_KEY,
       # TOGETHER_API_KEY, OPENAI_API_KEY, DEEPSEEK_API_KEY; more than one gives automatic fallback
       export GOOGLE_API_KEY="your-gemini-key"
       # required for !giverole only — Supabase dashboard -> Settings -> API -> service_role key.
       # SECRET: server-side only, never paste this into any website file (unlike the public anon
       # key above, it bypasses Row Level Security entirely — treat it like DISCORD_TOKEN).
       export SUPABASE_SERVICE_ROLE_KEY="your-service-role-key"
       # optional: proactive announcements to one channel (right-click channel -> Copy Channel ID,
       # needs Developer Mode on in Discord settings)
       export ZULU_ANNOUNCE_CHANNEL_ID="123456789012345678"
       # optional: default TTS auto-read channel (overridable per-server with /ttschannel)
       export ZULU_TTS_CHANNEL_ID="123456789012345678"
       # optional: put your test server's ID here while developing — slash commands sync to
       # that one guild instantly instead of taking up to an hour to propagate globally
       export ZULU_DEV_GUILD_ID="123456789012345678"
       python zulu_discord.py
"""

import os
import sys
import json
import random
import asyncio
import time
import uuid
from collections import deque
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone

# See zulu_server.py's identical block for why: a print() with an emoji/Devanagari char
# crashes outright on a Windows console using a legacy codepage. This is a separate long-
# running process from zulu_server.py, so it needs its own fix, not just that one.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        try:
            _stream.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass

import discord
from discord import app_commands
from discord.ext import commands, tasks

try:
    import requests
except Exception:
    requests = None

# voice/music/TTS are all optional — the bot still runs fine without them, those commands
# just say so instead of crashing. See the module docstring for what to pip install.
try:
    import yt_dlp
except Exception:
    yt_dlp = None

try:
    from gtts import gTTS
except Exception:
    gTTS = None

# share ZULU's built-in knowledge so the bot can answer questions too
try:
    from zulu_knowledge import knowledge_answer
except Exception:
    def knowledge_answer(q, founder="Prabin", min_score=2):
        return None

HERE = os.path.dirname(os.path.abspath(__file__))

# secrets loaded from zulu_secrets.py if present; never committed (see .gitignore)
try:
    import zulu_secrets as _SECRETS
except Exception:
    _SECRETS = None


def _secret(name, default=""):
    v = os.environ.get(name, "")
    if not v and _SECRETS is not None:
        v = getattr(_SECRETS, name, "") or ""
    return v or default


LOCAL_JSON = os.path.join(HERE, "tournaments.json")
REG_PATH = os.path.join(HERE, "registrations.json")
TOURNAMENTS_URL = os.environ.get("ZULU_TOURNAMENTS_URL", "")
MC_SERVER = os.environ.get("ZULU_MC_SERVER", "Ogsssss.aternos.me:43345")
TOKEN = _secret("DISCORD_TOKEN")
GOLD = 0xC9A84C

# Same public Supabase project the website reads from (Settings -> API). The anon/publishable
# key is safe to ship here — it's the same one already sitting in jd-arena.html's page source,
# protected by Row Level Security, not a secret. Used read-only, via the same public
# get_public_roster() RPC the site itself calls, so the bot shows the REAL registered count
# instead of tournaments.json's "registered" field, which nothing keeps in sync anymore now
# that in-app sign-ups write straight to Supabase.
SUPABASE_URL = os.environ.get("ZULU_SUPABASE_URL", "https://cnoxvqvpmgowdiyrrusv.supabase.co")
SUPABASE_ANON_KEY = os.environ.get("ZULU_SUPABASE_ANON_KEY", "sb_publishable_5n7uzH5crKrLe8A75K6OVQ_C_di-jil")

# SECRET — server-side only, never put this in any client-facing file (unlike the anon key
# above, it bypasses Row Level Security entirely). Same key the publish-results Edge Function
# uses to join registrations -> players for their discord_user_id; !giverole below reuses that
# exact pattern so it can find a squad's linked Discord accounts without a new public RPC that
# would otherwise leak player-to-Discord mappings to anyone holding the (public) anon key.
# Get it from Supabase dashboard -> Settings -> API -> service_role key.
SUPABASE_SERVICE_ROLE_KEY = _secret("SUPABASE_SERVICE_ROLE_KEY")

# Free-tier keys for a general-purpose AI fallback — completely separate from the private
# zulu_server.py/zulu_personality.py "Tactical AI" system (owner-only, never meant to be public).
# This bot gets its own small system prompt and never touches that code or data. Multiple
# providers are tried in order so one rate-limited free tier doesn't take the AI fully offline —
# set any ONE of the keys below to enable the AI; more than one adds automatic fallback.
GOOGLE_API_KEY = _secret("GOOGLE_API_KEY")
GOOGLE_MODEL = _secret("GOOGLE_MODEL", "gemini-2.5-flash")
BOT_SYSTEM_PROMPT = (
    "You are ZULU, the community bot for JD Esports Arena, a Free Fire tournament community. "
    "Answer questions helpfully and concisely, in a friendly, Discord-appropriate way. "
    "Keep replies short (a few sentences) unless the question needs more."
)
AI_PROVIDERS = {
    "groq":       {"base": "https://api.groq.com/openai/v1/chat/completions",   "model": "llama-3.3-70b-versatile",                "key_env": "GROQ_API_KEY"},
    "cerebras":   {"base": "https://api.cerebras.ai/v1/chat/completions",       "model": "llama-3.3-70b",                          "key_env": "CEREBRAS_API_KEY"},
    "google":     {"base": "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", "model": GOOGLE_MODEL,     "key_env": "GOOGLE_API_KEY"},
    "openrouter": {"base": "https://openrouter.ai/api/v1/chat/completions",     "model": "meta-llama/llama-3.3-70b-instruct:free", "key_env": "OPENROUTER_API_KEY"},
    "together":   {"base": "https://api.together.xyz/v1/chat/completions",     "model": "meta-llama/Llama-3.3-70B-Instruct-Turbo", "key_env": "TOGETHER_API_KEY"},
    "openai":     {"base": "https://api.openai.com/v1/chat/completions",       "model": "gpt-4o-mini",                            "key_env": "OPENAI_API_KEY"},
    "deepseek":   {"base": "https://api.deepseek.com/chat/completions",        "model": "deepseek-chat",                          "key_env": "DEEPSEEK_API_KEY"},
}


def _ai_members():
    """(name, base, model, key) for every provider that actually has a key set, in preference order."""
    out = []
    for name, cfg in AI_PROVIDERS.items():
        key = _secret(cfg["key_env"])
        if key:
            out.append((name, cfg["base"], cfg["model"], key))
    return out


def _ai_call(base, model, key, messages):
    if not requests:
        return None
    try:
        r = requests.post(
            base,
            headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
            json={"model": model, "messages": messages, "max_tokens": 500, "temperature": 0.6},
            timeout=25,
        )
        if not r.ok:
            return None
        return (r.json()["choices"][0]["message"].get("content") or "").strip() or None
    except Exception:
        return None


def ai_answer(q):
    """Multi-provider fallback for questions the offline knowledge base doesn't cover. Synchronous
    (network I/O) — callers on the bot's event loop MUST run this via asyncio.to_thread, never
    awaited directly, or it blocks every other command for as long as the request takes. Queries
    every configured free provider in parallel and fuses the drafts into one answer via the lead
    provider, so a single model's mistake or blind spot doesn't define the answer — same approach
    as the website's AI council. Falls back to whichever single draft came back if fusion has
    nothing to fuse (one key configured, or only one provider actually answered)."""
    messages = [{"role": "system", "content": BOT_SYSTEM_PROMPT}, {"role": "user", "content": q}]
    members = _ai_members()
    if not members:
        return None
    if len(members) == 1:
        name, base, model, key = members[0]
        return _ai_call(base, model, key, messages)
    drafts = []
    with ThreadPoolExecutor(max_workers=len(members)) as ex:
        futs = {ex.submit(_ai_call, base, model, key, messages): name for name, base, model, key in members}
        for f in as_completed(futs):
            text = f.result()
            if text:
                drafts.append(text)
    if not drafts:
        return None
    if len(drafts) == 1:
        return drafts[0]
    lead_name, lead_base, lead_model, lead_key = members[0]
    panel_text = "\n\n".join(f"### Draft {i + 1}:\n{d}" for i, d in enumerate(drafts))
    synth_messages = [
        {"role": "system", "content":
         "You are ZULU, the community bot for JD Esports Arena. Several models drafted answers to "
         "the question below. Fuse them into ONE final answer: keep the strongest, most accurate "
         "points, cut errors, contradictions and repetition, and prefer whatever's most correct "
         "when they disagree. Keep it short and Discord-appropriate. Never mention the drafts or "
         "other models."},
        {"role": "user", "content": q + "\n\n--- draft answers to fuse ---\n" + panel_text},
    ]
    fused = _ai_call(lead_base, lead_model, lead_key, synth_messages)
    return fused or drafts[0]


# zulu_server.py runs alongside this bot on the same PC -- its /public endpoint has the
# SAME isolation the note above wants (no private dossier, no tools, no memory) but with
# real grounding (knowledge_search RAG, live tournament context) and rate limiting this
# bot's own ai_answer() never had. Prefer it; fall back to the bot's own direct
# multi-provider path if zulu_server.py isn't running, so the bot never goes fully silent
# just because that other process happens to be down.
ZULU_SERVER_URL = _secret("ZULU_SERVER_URL", "http://localhost:5005")

# @mention/reply-to-bot isn't a registered command, so it can't use @commands.cooldown --
# same 15s-per-user protection as !ask, done by hand.
_MENTION_COOLDOWN_SEC = 15
_mention_last_call = {}


def _mention_cooldown_ok(user_id):
    now = time.time()
    last = _mention_last_call.get(user_id, 0)
    if now - last < _MENTION_COOLDOWN_SEC:
        return False
    _mention_last_call[user_id] = now
    return True


def _looks_like_deflection(reply):
    """zulu_server.py's /public is deliberately scoped to ONLY JD Arena topics for the
    public esports site -- it deflects anything else (business plans, general trivia) with
    a canned or LLM-worded refusal that always frames itself around being "private" and
    steering back to "JD Arena" (see PUBLIC_SYSTEM_PROMPT/_PUBLIC_SECRET_REPLY in
    zulu_server.py). This bot's own !ask/mention has always answered general trivia too
    (Nepal/chemistry/physics/maths, per its own !help text) -- without this check, routing
    through /public would silently break that for every general-knowledge question, since a
    non-empty deflection looks like a valid reply otherwise."""
    low = reply.lower()
    return "private" in low and ("jd arena" in low or "jd esports" in low)


def ai_answer_grounded(q):
    """Synchronous (network I/O) -- same to_thread requirement as ai_answer(). A deflection
    from /public (see _looks_like_deflection) is NOT treated as a real answer -- it falls
    through to the bot's own unrestricted ai_answer(q), same as a network failure would."""
    if requests and ZULU_SERVER_URL:
        try:
            # 8s, not /public's own generous budget -- this blocks a Discord reply with the
            # channel stuck showing "typing...", so a slow/stale zulu_server.py shouldn't
            # make every general question wait needlessly long before falling back.
            r = requests.post(ZULU_SERVER_URL.rstrip("/") + "/public", json={"message": q}, timeout=8)
            if r.ok:
                reply = (r.json() or {}).get("reply")
                if reply and not _looks_like_deflection(reply):
                    return reply
        except Exception:
            pass
    return ai_answer(q)


def load_data():
    """Live from GitHub if configured, else the local file."""
    if TOURNAMENTS_URL and requests:
        try:
            r = requests.get(TOURNAMENTS_URL, timeout=10)
            if r.ok:
                return r.json()
        except Exception:
            pass
    try:
        with open(LOCAL_JSON, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"tournaments": [], "leaderboard": []}


def load_live_counts():
    """{tournament_name: real confirmed+approved registration count}, straight from Supabase.

    Returns {} (never raises) if requests/Supabase aren't reachable — callers fall back to
    tournaments.json's stale "registered" field in that case, same as before this existed.
    """
    if not requests or not SUPABASE_URL or not SUPABASE_ANON_KEY:
        return {}
    try:
        r = requests.post(
            f"{SUPABASE_URL}/rest/v1/rpc/get_public_roster",
            headers={"apikey": SUPABASE_ANON_KEY, "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                      "Content-Type": "application/json"},
            json={}, timeout=10,
        )
        if not r.ok:
            return {}
        counts = {}
        for row in r.json() or []:
            slug = row.get("tournament_slug")
            if slug:
                counts[slug] = counts.get(slug, 0) + 1
        return counts
    except Exception:
        return {}


def _ilike_escape(value):
    """Escape a user-supplied string for safe use inside a PostgREST ilike.<pattern> filter.
    Unescaped, '*' is PostgREST's own stand-in for SQL's '%' ("any sequence") and '_' is SQL
    ILIKE's native "any single char" — a squad name of exactly '*' would otherwise match
    every row instead of just that one squad (see !giverole below)."""
    return value.replace("\\", "\\\\").replace("*", "\\*").replace("_", "\\_")


def lookup_squad_discord_ids(squad_name, tournament_slug=None):
    """Every linked Discord account (players who ran !link) among confirmed/approved
    registrations under this squad name — service-role only, so it bypasses RLS the same
    way publish-results' Edge Function does. Synchronous (network I/O) — run via
    asyncio.to_thread. Returns None on a request/API failure (caller should say "try again"),
    or a (possibly empty) list of discord_user_id strings on success."""
    if not requests or not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        return None
    params = {
        "select": "players(discord_user_id)",
        "squad_name": "ilike." + _ilike_escape(squad_name),
        "status": "in.(confirmed,approved)",
    }
    if tournament_slug:
        params["tournament_slug"] = "eq." + tournament_slug
    try:
        r = requests.get(
            f"{SUPABASE_URL}/rest/v1/registrations",
            headers={"apikey": SUPABASE_SERVICE_ROLE_KEY, "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}"},
            params=params, timeout=15,
        )
        if not r.ok:
            return None
        ids = set()
        for row in r.json() or []:
            p = row.get("players")
            did = (p or {}).get("discord_user_id")
            if did:
                ids.add(did)
        return list(ids)
    except Exception:
        return None


def lookup_player_by_discord_id(discord_user_id):
    """{player_tag, username} for the player linked to this Discord account, or None if
    unlinked/not found. Service-role only — players' RLS policy is "read own row", so the
    anon key can't see this. Synchronous (network I/O) — run via asyncio.to_thread."""
    if not requests or not SUPABASE_URL or not SUPABASE_SERVICE_ROLE_KEY:
        return None
    try:
        r = requests.get(
            f"{SUPABASE_URL}/rest/v1/players",
            headers={"apikey": SUPABASE_SERVICE_ROLE_KEY, "Authorization": f"Bearer {SUPABASE_SERVICE_ROLE_KEY}"},
            params={"select": "player_tag,username", "discord_user_id": "eq." + str(discord_user_id)},
            timeout=15,
        )
        if not r.ok:
            return None
        rows = r.json() or []
        return rows[0] if rows else None
    except Exception:
        return None


def fetch_career_stats(player_tag):
    """Career totals for a player_tag via the public get_player_career_stats() RPC — same
    read anyone gets on the site's own player-profile view, nothing extra exposed here.
    Synchronous (network I/O) — run via asyncio.to_thread. None on failure or no history."""
    if not requests or not SUPABASE_URL or not SUPABASE_ANON_KEY:
        return None
    try:
        r = requests.post(
            f"{SUPABASE_URL}/rest/v1/rpc/get_player_career_stats",
            headers={"apikey": SUPABASE_ANON_KEY, "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                      "Content-Type": "application/json"},
            json={"p_player_tag": player_tag}, timeout=15,
        )
        if not r.ok:
            return None
        rows = r.json() or []
        return rows[0] if rows else None
    except Exception:
        return None


def real_registered(t, live_counts):
    """Best available registered count for a tournament: live Supabase count if we got one
    back, else tournaments.json's own (possibly stale) 'registered' field."""
    name = t.get("name", "")
    return live_counts[name] if name in live_counts else int(t.get("registered") or 0)


def load_regs():
    """{tournament_name: [{squad, user, user_id, at}, ...]}"""
    try:
        with open(REG_PATH, encoding="utf-8") as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_regs(regs):
    with open(REG_PATH, "w", encoding="utf-8") as f:
        json.dump(regs, f, indent=2)


def open_events(d):
    """Tournaments still taking registrations, in schedule order."""
    return [t for t in d.get("tournaments", []) if (t.get("status") or "").lower() in ("upcoming", "live")]


# ── proactive announcements ──────────────────────────────────────────────────
# Set ZULU_ANNOUNCE_CHANNEL_ID (right-click a channel -> Copy Channel ID, needs Developer
# Mode on) to have the bot post on its own when something changes, instead of only replying
# when asked. Leave unset and this whole feature is inert — no behavior change.
ANNOUNCE_CHANNEL_ID = int(os.environ.get("ZULU_ANNOUNCE_CHANNEL_ID", "0") or 0)
ANNOUNCE_STATE_PATH = os.path.join(HERE, "announce_state.json")
ANNOUNCE_POLL_MINUTES = 5


def load_announce_state():
    try:
        with open(ANNOUNCE_STATE_PATH, encoding="utf-8") as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_announce_state(state):
    with open(ANNOUNCE_STATE_PATH, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2)


intents = discord.Intents.default()
intents.message_content = True
intents.members = True
bot = commands.Bot(command_prefix="!", intents=intents, help_command=None)

DEV_GUILD_ID = int(os.environ.get("ZULU_DEV_GUILD_ID", "0") or 0)


# ── voice / music / TTS ──────────────────────────────────────────────────────
# One playback queue per guild, sequential: whatever's queued for TTS always plays before the
# next music track (so someone's spoken message doesn't wait behind a 4-minute song), but never
# interrupts audio already playing. Everything routes through _advance(), which is the only
# place that calls VoiceClient.play() — keeps two things from stepping on each other's playback.
YDL_OPTS = {
    "format": "bestaudio/best",
    "noplaylist": True,
    "quiet": True,
    "no_warnings": True,
    "default_search": "ytsearch1",
    "source_address": "0.0.0.0",
}
FFMPEG_BEFORE_OPTIONS = "-reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5"
FFMPEG_OPTIONS = "-vn"
TTS_DIR = os.path.join(HERE, "tts_cache")
TTS_SETTINGS_PATH = os.path.join(HERE, "tts_settings.json")
DEFAULT_TTS_CHANNEL_ID = int(os.environ.get("ZULU_TTS_CHANNEL_ID", "0") or 0)


class GuildAudioState:
    def __init__(self):
        self.voice_client = None
        self.queue = deque()       # music tracks: {"title", "url", "webpage_url"}
        self.tts_queue = deque()   # plain text strings waiting to be spoken
        self.busy = False          # something is currently playing or about to be
        self.current = None        # track dict currently playing, or None (never set for TTS)
        self.volume = 1.0          # 0.0-2.0, applied via PCMVolumeTransformer


_audio_states = {}


def _state(guild_id):
    st = _audio_states.get(guild_id)
    if st is None:
        st = GuildAudioState()
        _audio_states[guild_id] = st
    return st


def load_tts_settings():
    try:
        with open(TTS_SETTINGS_PATH, encoding="utf-8") as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


def save_tts_settings(d):
    with open(TTS_SETTINGS_PATH, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2)


def tts_channel_for(guild_id):
    """0 means TTS auto-read is off for this guild."""
    override = load_tts_settings().get(str(guild_id))
    return int(override) if override else DEFAULT_TTS_CHANNEL_ID


def _extract_track(query):
    """Blocking (network) — run via asyncio.to_thread. query can be a search phrase or a URL."""
    with yt_dlp.YoutubeDL(YDL_OPTS) as ydl:
        data = ydl.extract_info(query, download=False)
        if data and "entries" in data:
            entries = [e for e in data["entries"] if e]
            if not entries:
                return None
            data = entries[0]
        if not data or not data.get("url"):
            return None
        return {
            "title": data.get("title") or "Unknown title",
            "url": data.get("url"),
            "webpage_url": data.get("webpage_url") or "",
        }


def _synth_tts(text, guild_id):
    """Blocking (network) — run via asyncio.to_thread. Returns a temp mp3 path, or None."""
    if not gTTS:
        return None
    text = text.strip()[:300]
    if not text:
        return None
    try:
        os.makedirs(TTS_DIR, exist_ok=True)
        path = os.path.join(TTS_DIR, f"{guild_id}_{uuid.uuid4().hex}.mp3")
        gTTS(text=text, lang="en").save(path)
        return path
    except Exception:
        return None


async def _advance(guild_id):
    """Pulls the next thing to play for this guild and plays it. Called once to kick off
    playback, then re-invoked from the 'after' callback every time something finishes —
    that's the only place playback continues from, so the queue never stalls or double-plays."""
    st = _state(guild_id)
    vc = st.voice_client
    if not vc or not vc.is_connected():
        st.busy = False
        st.current = None
        return
    if not st.tts_queue and not st.queue:
        st.busy = False
        st.current = None
        return
    # Set busy BEFORE the first await below (gTTS synthesis is a network round-trip) — a
    # message arriving mid-synth would otherwise see busy still False and spawn a second
    # concurrent _advance(), racing both into vc.play().
    st.busy = True

    cleanup_path = None
    if st.tts_queue:
        st.current = None
        text = st.tts_queue.popleft()
        cleanup_path = await asyncio.to_thread(_synth_tts, text, guild_id)
        if not cleanup_path:
            await _advance(guild_id)
            return
        source = discord.FFmpegPCMAudio(cleanup_path)
    else:
        track = st.queue.popleft()
        st.current = track
        source = discord.FFmpegPCMAudio(
            track["url"], before_options=FFMPEG_BEFORE_OPTIONS, options=FFMPEG_OPTIONS)
    source = discord.PCMVolumeTransformer(source, volume=st.volume)

    def _after(err):
        if cleanup_path:
            try:
                os.remove(cleanup_path)
            except Exception:
                pass
        if err:
            print("playback error:", repr(err))
        asyncio.run_coroutine_threadsafe(_advance(guild_id), bot.loop)

    vc.play(source, after=_after)


def season_role_name(d):
    """Role name for the season leaderboard's #1 team. tournaments.json can carry an optional
    top-level "season" string (e.g. "S1") to get "Winner S1"; without one it falls back to a
    generic name so this still works out of the box."""
    season = (d.get("season") or "").strip()
    return f"Winner {season}" if season else "Season Champion"


async def _grant_role_to_squad(guild, squad_name, role_name, reason):
    """Best-effort: look up every linked Discord account (!link) registered under squad_name,
    find-or-create role_name, and assign it. Never raises — returns (given, found, retry).
    retry=True means this hit a TRANSIENT failure (Supabase unreachable, or Discord rejected
    creating the role) and the caller should NOT treat the leader as resolved — try again next
    poll. retry=False means this resolved cleanly, even when that resolution is "nobody's
    linked their Discord yet" (given=found=0) — that's a legitimate terminal state, not a
    failure, so it shouldn't be retried forever."""
    if not SUPABASE_SERVICE_ROLE_KEY:
        return (0, 0, True)
    ids = await asyncio.to_thread(lookup_squad_discord_ids, squad_name)
    if ids is None:
        return (0, 0, True)   # Supabase request failed — transient
    if not ids:
        return (0, 0, False)  # nobody linked under this squad — terminal, not a failure
    role = discord.utils.find(lambda r: r.name.lower() == role_name.lower(), guild.roles)
    if not role:
        try:
            role = await guild.create_role(name=role_name, colour=discord.Colour(GOLD), reason=reason)
        except Exception:
            return (0, len(ids), True)  # couldn't create the role — transient
    given = 0
    for did in ids:
        member = await _resolve_member(guild, did)
        if not member:
            continue
        try:
            await member.add_roles(role, reason=reason)
            given += 1
        except Exception:
            pass
    return (given, len(ids), False)


def schedule_embed():
    d = load_data()
    ts = d.get("tournaments", [])
    live_counts = load_live_counts()
    e = discord.Embed(title="🎮 JD Esports Arena — Free Fire", color=GOLD)
    live = [t for t in ts if (t.get("status") or "").lower() == "live"]
    up = [t for t in ts if (t.get("status") or "").lower() == "upcoming"]
    for t in live:
        e.add_field(name=f"🔴 LIVE — {t.get('name','')}",
                    value=f"{t.get('prize','')} • {t.get('format','')}", inline=False)
    for t in up:
        e.add_field(name=f"🗓️ {t.get('name','')}",
                    value=f"{t.get('date','TBA')} {t.get('time','')} • Prize {t.get('prize','')} • "
                          f"{real_registered(t, live_counts)}/{t.get('slots',0)} squads", inline=False)
    if not live and not up:
        e.description = "No tournaments scheduled right now — check back soon. 🪂"
    e.set_footer(text="!register <squad> to join • !leaderboard for standings")
    return e


@tasks.loop(minutes=ANNOUNCE_POLL_MINUTES)
async def check_announcements():
    if not ANNOUNCE_CHANNEL_ID:
        return
    channel = bot.get_channel(ANNOUNCE_CHANNEL_ID)
    if not channel:
        return  # bad ID, or bot not in that server/channel — nothing to post to
    d = load_data()
    live_counts = load_live_counts()
    state = load_announce_state()
    seen = state.setdefault("tournaments", {})
    bo3_announced = set(state.setdefault("bo3_announced", []))

    for t in d.get("tournaments", []):
        name = t.get("name", "")
        if not name:
            continue
        prev = seen.get(name, {})
        status = (t.get("status") or "").lower()
        count = real_registered(t, live_counts)
        slots = int(t.get("slots") or 0)
        full = bool(slots and count >= slots)

        if status == "live" and prev.get("status") != "live":
            try:
                await channel.send(f"🔴 **{name}** is LIVE now! {t.get('prize','')} — {t.get('format','')}")
            except Exception:
                pass
        if full and not prev.get("full"):
            try:
                await channel.send(f"🎉 **{name}** is full — {count}/{slots} squads locked in!")
            except Exception:
                pass

        seen[name] = {"status": status, "full": full}

    bo3 = d.get("bo3") or {}
    bo3_name = bo3.get("tournament")
    if bo3.get("published") and bo3_name and bo3_name not in bo3_announced:
        try:
            await channel.send(f"🏆 Results are up for **{bo3_name}**! Check `!leaderboard` or the site for the full breakdown.")
            bo3_announced.add(bo3_name)
        except Exception:
            pass

    state["bo3_announced"] = list(bo3_announced)

    # ── season leaderboard #1 -> auto-award a Discord role to that squad's linked members.
    # Only fires again when the #1 NAME actually changes, so an unchanged leader doesn't
    # re-trigger every poll. Never revokes from a past leader if someone else takes #1 later —
    # once awarded, a winner keeps the role (see the design note in the module docstring).
    lb = d.get("leaderboard") or []
    if lb:
        ranked = sorted(lb, key=lambda r: (-(r.get("points") or 0), -(r.get("wins") or 0)))
        leader = (ranked[0].get("team") or "").strip()
        if leader and state.get("season_leader") != leader:
            if not SUPABASE_SERVICE_ROLE_KEY:
                pass  # leave season_leader unset so this retries once the key is configured
            else:
                role_name = season_role_name(d)
                given, found, retry = await _grant_role_to_squad(
                    channel.guild, leader, role_name, f"Season leaderboard #1: {leader}")
                if given:
                    try:
                        await channel.send(f"🏆 **{leader}** takes #1 on the season leaderboard — "
                                            f"awarded the **{role_name}** role!")
                    except Exception:
                        pass
                if not retry:
                    state["season_leader"] = leader
                # else: leave season_leader as-is so a transient Supabase/Discord failure
                # gets retried on the next poll instead of silently giving up forever.

    save_announce_state(state)


@check_announcements.before_loop
async def before_check_announcements():
    await bot.wait_until_ready()


@bot.event
async def on_ready():
    print(f"ZULU Discord online as {bot.user} — serving JD Esports Arena")
    if ANNOUNCE_CHANNEL_ID and not check_announcements.is_running():
        check_announcements.start()
    try:
        if DEV_GUILD_ID:
            guild_obj = discord.Object(id=DEV_GUILD_ID)
            bot.tree.copy_global_to(guild=guild_obj)
            await bot.tree.sync(guild=guild_obj)
        else:
            await bot.tree.sync()
    except Exception as e:
        print("slash command sync failed:", repr(e))


@bot.event
async def on_command_error(ctx, error):
    if isinstance(error, commands.MissingPermissions):
        need = ", ".join(p.replace("_", " ").title() for p in error.missing_permissions)
        await ctx.send(f"You need **{need}** permission to do that.")
        return
    if isinstance(error, commands.CommandOnCooldown):
        await ctx.send(f"Slow down a bit — try again in {error.retry_after:.0f}s.")
        return
    if isinstance(error, (commands.CommandNotFound, commands.CheckFailure)):
        return
    print("command error:", repr(error))


@bot.tree.error
async def on_app_command_error(interaction: discord.Interaction, error: app_commands.AppCommandError):
    if isinstance(error, app_commands.MissingPermissions):
        msg = "You need **Manage Server** permission to do that."
    else:
        print("app command error:", repr(error))
        msg = "Something went wrong running that command — try again in a moment."
    try:
        if interaction.response.is_done():
            await interaction.followup.send(msg, ephemeral=True)
        else:
            await interaction.response.send_message(msg, ephemeral=True)
    except Exception:
        pass


@bot.event
async def on_voice_state_update(member, before, after):
    """Auto-leave a voice channel once every human has left it, so ZULU doesn't sit alone
    playing to an empty room. Ignores the bot's own join/leave events."""
    if member.bot:
        return
    guild = member.guild
    vc = guild.voice_client
    if not vc or not vc.is_connected():
        return
    if any(not m.bot for m in vc.channel.members):
        return
    st = _state(guild.id)
    st.queue.clear()
    st.tts_queue.clear()
    try:
        await vc.disconnect(force=True)
    except Exception:
        pass


@bot.tree.command(name="join", description="Join the voice channel you're currently in")
async def join_cmd(interaction: discord.Interaction):
    if not interaction.guild:
        await interaction.response.send_message("This only works inside a server.", ephemeral=True)
        return
    member = interaction.guild.get_member(interaction.user.id)
    voice_state = member.voice if member else None
    if not voice_state or not voice_state.channel:
        await interaction.response.send_message(
            "Join a voice channel first, then run `/join`.", ephemeral=True)
        return
    channel = voice_state.channel
    vc = interaction.guild.voice_client
    try:
        if vc and vc.is_connected():
            await vc.move_to(channel)
        else:
            vc = await channel.connect()
    except Exception as e:
        await interaction.response.send_message(f"Couldn't join **{channel.name}**: {e}", ephemeral=True)
        return
    _state(interaction.guild.id).voice_client = vc
    await interaction.response.send_message(f"🔊 Joined **{channel.name}**.")


@bot.tree.command(name="leave", description="Leave the voice channel and clear the queue")
async def leave_cmd(interaction: discord.Interaction):
    vc = interaction.guild.voice_client if interaction.guild else None
    if not vc or not vc.is_connected():
        await interaction.response.send_message("I'm not in a voice channel.", ephemeral=True)
        return
    st = _state(interaction.guild.id)
    st.queue.clear()
    st.tts_queue.clear()
    await vc.disconnect(force=True)
    await interaction.response.send_message("👋 Left the voice channel.")


@bot.tree.command(name="play", description="Play a song in voice chat (search words or a YouTube URL)")
@app_commands.describe(query="Song name to search, or a YouTube link")
async def play_cmd(interaction: discord.Interaction, query: str):
    if not interaction.guild:
        await interaction.response.send_message("This only works inside a server.", ephemeral=True)
        return
    if not yt_dlp:
        await interaction.response.send_message(
            "Music needs `yt-dlp` installed on the bot's host (`pip install yt-dlp`).", ephemeral=True)
        return
    vc = interaction.guild.voice_client
    voice_state = None
    if not vc or not vc.is_connected():
        member = interaction.guild.get_member(interaction.user.id)
        voice_state = member.voice if member else None
        if not voice_state or not voice_state.channel:
            await interaction.response.send_message(
                "Join a voice channel first, then `/play`.", ephemeral=True)
            return

    # Defer BEFORE any slow work — a cold voice connect (below) or the yt-dlp network
    # extraction (further down) can easily exceed Discord's 3-second interaction-ack window,
    # which would otherwise expire the interaction and drop this reply silently.
    await interaction.response.defer()

    if not vc or not vc.is_connected():
        try:
            vc = await voice_state.channel.connect()
        except Exception as e:
            await interaction.followup.send(f"Couldn't join **{voice_state.channel.name}**: {e}")
            return

    try:
        track = await asyncio.to_thread(_extract_track, query)
    except Exception as e:
        await interaction.followup.send(f"Couldn't fetch that: {e}")
        return
    if not track:
        await interaction.followup.send("No results for that.")
        return

    st = _state(interaction.guild.id)
    st.voice_client = vc
    st.queue.append(track)
    if st.busy or vc.is_playing() or vc.is_paused():
        await interaction.followup.send(f"➕ Queued **{track['title']}** (position {len(st.queue)}).")
    else:
        await interaction.followup.send(f"▶️ Now playing **{track['title']}**.")
        await _advance(interaction.guild.id)


@bot.tree.command(name="skip", description="Skip the current song")
async def skip_cmd(interaction: discord.Interaction):
    vc = interaction.guild.voice_client if interaction.guild else None
    if not vc or not (vc.is_playing() or vc.is_paused()):
        await interaction.response.send_message("Nothing is playing.", ephemeral=True)
        return
    vc.stop()  # fires the 'after' callback, which advances the queue on its own
    await interaction.response.send_message("⏭️ Skipped.")


@bot.tree.command(name="pause", description="Pause the current song")
async def pause_cmd(interaction: discord.Interaction):
    vc = interaction.guild.voice_client if interaction.guild else None
    if not vc or not vc.is_playing():
        await interaction.response.send_message("Nothing is playing.", ephemeral=True)
        return
    vc.pause()
    await interaction.response.send_message("⏸️ Paused.")


@bot.tree.command(name="resume", description="Resume the paused song")
async def resume_cmd(interaction: discord.Interaction):
    vc = interaction.guild.voice_client if interaction.guild else None
    if not vc or not vc.is_paused():
        await interaction.response.send_message("Nothing is paused.", ephemeral=True)
        return
    vc.resume()
    await interaction.response.send_message("▶️ Resumed.")


@bot.tree.command(name="stop", description="Stop playback and clear the queue")
async def stop_cmd(interaction: discord.Interaction):
    if not interaction.guild:
        await interaction.response.send_message("This only works inside a server.", ephemeral=True)
        return
    st = _state(interaction.guild.id)
    st.queue.clear()
    st.tts_queue.clear()
    vc = interaction.guild.voice_client
    if vc and (vc.is_playing() or vc.is_paused()):
        vc.stop()
    await interaction.response.send_message("⏹️ Stopped and cleared the queue.")


@bot.tree.command(name="queue", description="Show what's playing and queued up next")
async def queue_cmd(interaction: discord.Interaction):
    if not interaction.guild:
        await interaction.response.send_message("This only works inside a server.", ephemeral=True)
        return
    st = _state(interaction.guild.id)
    if not st.current and not st.queue:
        await interaction.response.send_message("Queue is empty — `/play <song>` to start one.", ephemeral=True)
        return
    parts = []
    if st.current:
        parts.append(f"▶️ **Now playing:** {st.current['title']}")
    if st.queue:
        listing = "\n".join(f"{i + 1}. {t['title']}" for i, t in enumerate(list(st.queue)[:10]))
        parts.append(f"**Up next:**\n{listing}")
    await interaction.response.send_message("\n\n".join(parts))


@bot.tree.command(name="nowplaying", description="Show the currently playing track")
async def nowplaying_cmd(interaction: discord.Interaction):
    if not interaction.guild:
        await interaction.response.send_message("This only works inside a server.", ephemeral=True)
        return
    st = _state(interaction.guild.id)
    if not st.current:
        await interaction.response.send_message("Nothing's playing right now.", ephemeral=True)
        return
    link = f" (<{st.current['webpage_url']}>)" if st.current.get("webpage_url") else ""
    await interaction.response.send_message(f"▶️ **Now playing:** {st.current['title']}{link}")


@bot.tree.command(name="volume", description="Set music volume (0-200%)")
@app_commands.describe(percent="0 to 200 — 100 is normal volume")
async def volume_cmd(interaction: discord.Interaction, percent: app_commands.Range[int, 0, 200]):
    if not interaction.guild:
        await interaction.response.send_message("This only works inside a server.", ephemeral=True)
        return
    st = _state(interaction.guild.id)
    st.volume = percent / 100
    vc = interaction.guild.voice_client
    if vc and vc.source and isinstance(vc.source, discord.PCMVolumeTransformer):
        vc.source.volume = st.volume
    await interaction.response.send_message(f"🔊 Volume set to **{percent}%**.")


@bot.tree.command(name="shuffle", description="Shuffle the upcoming queue")
async def shuffle_cmd(interaction: discord.Interaction):
    if not interaction.guild:
        await interaction.response.send_message("This only works inside a server.", ephemeral=True)
        return
    st = _state(interaction.guild.id)
    if len(st.queue) < 2:
        await interaction.response.send_message("Not enough queued up to shuffle.", ephemeral=True)
        return
    items = list(st.queue)
    random.shuffle(items)
    st.queue = deque(items)
    await interaction.response.send_message(f"🔀 Shuffled **{len(items)}** track(s).")


@bot.tree.command(name="ttschannel",
                   description="Set (or turn off) the channel ZULU reads aloud in voice chat")
@app_commands.describe(mode="'here' to use this channel, or 'off' to disable")
@app_commands.choices(mode=[
    app_commands.Choice(name="here — use this channel", value="here"),
    app_commands.Choice(name="off — disable auto-read", value="off"),
])
@app_commands.checks.has_permissions(manage_guild=True)
async def ttschannel_cmd(interaction: discord.Interaction, mode: app_commands.Choice[str]):
    if not interaction.guild:
        await interaction.response.send_message("This only works inside a server.", ephemeral=True)
        return
    settings = load_tts_settings()
    if mode.value == "off":
        settings.pop(str(interaction.guild.id), None)
        save_tts_settings(settings)
        await interaction.response.send_message("🔇 TTS auto-read disabled.")
        return
    settings[str(interaction.guild.id)] = interaction.channel_id
    save_tts_settings(settings)
    await interaction.response.send_message(
        f"🗣️ I'll read messages from {interaction.channel.mention} aloud, word for word, "
        f"whenever I'm connected to a voice channel here. `/join` first if I'm not already in one.")


@bot.command(name="tournaments", aliases=["t", "tour", "schedule"])
async def tournaments_cmd(ctx):
    await ctx.send(embed=schedule_embed())


@bot.command(name="next")
async def next_cmd(ctx):
    d = load_data()
    up = [t for t in d.get("tournaments", []) if (t.get("status") or "").lower() in ("upcoming", "live")]
    if not up:
        await ctx.send("No tournaments scheduled yet, squad. Stay ready. 🪂")
        return
    t = up[0]
    count = real_registered(t, load_live_counts())
    await ctx.send(
        f"**Next up: {t.get('name','')}**\n"
        f"📅 {t.get('date','TBA')} {t.get('time','')}\n"
        f"🏆 Prize {t.get('prize','—')}\n"
        f"🎟️ Entry {t.get('entry','—')}\n"
        f"👥 {count}/{t.get('slots',0)} squads — `!register <squad>` to grab a slot."
    )


@bot.command(name="leaderboard", aliases=["lb", "standings"])
async def lb_cmd(ctx):
    d = load_data()
    lb = d.get("leaderboard", [])
    if not lb:
        await ctx.send("No standings yet — the first tournament sets the board. 🏆")
        return
    e = discord.Embed(title="🏆 JD Arena — Season Leaderboard", color=GOLD)
    e.description = "\n".join(
        f"**{i+1}.** {r.get('team','?')} — {r.get('points',0)} pts ({r.get('wins',0)}W)"
        for i, r in enumerate(lb[:10]))
    await ctx.send(embed=e)


@bot.command(name="register", aliases=["reg", "join"])
async def reg_cmd(ctx, *, arg: str = None):
    if not ctx.guild:
        await ctx.send("Registration only works inside the JD Esports Arena server, not in DMs — "
                        "join the server and run `!register` there.")
        return
    d = load_data()
    events = open_events(d)
    if not events:
        await ctx.send("No open tournaments right now — check back soon. 🪂")
        return
    idx, squad = 0, arg
    if arg:
        parts = arg.split(None, 1)
        if parts[0].isdigit() and len(parts) > 1 and 1 <= int(parts[0]) <= len(events):
            idx, squad = int(parts[0]) - 1, parts[1]
    ev = events[idx]
    name = ev.get("name", "the tournament")
    if not squad or not squad.strip():
        live_counts = load_live_counts()
        listing = "\n".join(f"`{i+1}` {e.get('name','')} ({real_registered(e, live_counts)}/{e.get('slots','?')})"
                             for i, e in enumerate(events))
        await ctx.send(f"**Open events:**\n{listing}\n"
                        f"Register: `!register <squad name>` (goes to #1) or `!register <event#> <squad name>`.")
        return
    squad = squad.strip()[:40]
    slots = int(ev.get("slots") or 0)
    regs = load_regs()
    pending = regs.get(name, [])
    discord_taken = [r["squad"] for r in pending]
    if any(x.lower() == squad.lower() for x in discord_taken if x):
        await ctx.send(f"⚠️ **{squad}** is already registered for **{name}**.")
        return
    # Real capacity lives on the website now (Supabase), not tournaments.json — check that
    # first so Discord can't wave squads in past a tournament that's actually already full.
    live_count = load_live_counts().get(name)
    effective_count = live_count if live_count is not None else len(discord_taken)
    if slots and effective_count >= slots:
        await ctx.send(f"🚫 **{name}** is full ({effective_count}/{slots} squads on the official site). "
                        f"Try another with `!register <event#> <squad>` — see `!register` for the list.")
        return
    pending.append({"squad": squad, "user": str(ctx.author), "user_id": ctx.author.id,
                     "at": datetime.now(timezone.utc).isoformat()})
    regs[name] = pending
    save_regs(regs)
    await ctx.send(f"✅ **{squad}** noted for **{name}**, {ctx.author.mention}! "
                    f"This is a Discord-side list for organizing — it doesn't replace the official "
                    f"sign-up on the website, so make sure you (or someone in your squad) also registers "
                    f"there to actually lock the slot and get the Room ID. `!roster` to see who's in here, "
                    f"`!unregister {squad}` to drop out. 🪂")


@bot.command(name="unregister", aliases=["leave", "drop"])
async def unregister_cmd(ctx, *, squad: str = None):
    if not ctx.guild:
        await ctx.send("This only works inside the JD Esports Arena server, not in DMs.")
        return
    if not squad or not squad.strip():
        await ctx.send("Usage: `!unregister <squad name>`")
        return
    regs = load_regs()
    squad_l = squad.strip().lower()
    removed = None
    for ev_name, lst in regs.items():
        for r in list(lst):
            if r.get("squad", "").strip().lower() == squad_l and r.get("user_id") == ctx.author.id:
                lst.remove(r)
                removed = ev_name
    if removed:
        save_regs(regs)
        await ctx.send(f"👋 Removed **{squad}** from **{removed}**.")
    else:
        await ctx.send("Couldn't find a registration under that squad name tied to your account.")


@bot.command(name="roster", aliases=["squads", "who"])
async def roster_cmd(ctx, *, arg: str = None):
    d = load_data()
    events = open_events(d)
    if not events:
        await ctx.send("No open tournaments right now.")
        return
    idx = 0
    if arg and arg.strip().isdigit() and 1 <= int(arg.strip()) <= len(events):
        idx = int(arg.strip()) - 1
    ev = events[idx]
    name = ev.get("name", "")
    slots = int(ev.get("slots") or 0)
    regs = load_regs()
    discord_squads = [r["squad"] for r in regs.get(name, [])]
    e = discord.Embed(title=f"👥 {name} — Squads", color=GOLD)
    e.description = ("\n".join(f"{i+1}. {t}" for i, t in enumerate(discord_squads))
                      if discord_squads else "No squads registered here yet — `!register <squad>` to be first.")
    live_count = load_live_counts().get(name)
    footer = f"{len(discord_squads)} squad(s) registered here via !register"
    if live_count is not None:
        footer += f" · {live_count}{'/'+str(slots) if slots else ''} really registered on the website (the official count)"
    e.set_footer(text=footer)
    await ctx.send(embed=e)


async def _resolve_member(guild, discord_user_id):
    m = guild.get_member(int(discord_user_id))
    if m:
        return m
    try:
        return await guild.fetch_member(int(discord_user_id))
    except Exception:
        return None


@bot.command(name="clear", aliases=["purge"])
@commands.has_permissions(manage_messages=True)
async def clear_cmd(ctx, amount: int = None):
    """Bulk-delete the last <amount> messages in this channel (not counting the command
    itself). Needs Manage Messages for both the caller (checked above) and the bot."""
    if not ctx.guild:
        await ctx.send("This only works inside a server.")
        return
    if not amount or amount < 1:
        await ctx.send("Usage: `!clear <amount>` — e.g. `!clear 20` (max 100).")
        return
    amount = min(amount, 100)
    try:
        deleted = await ctx.channel.purge(limit=amount + 1)  # +1 removes the command message too
    except discord.Forbidden:
        await ctx.send("I need **Manage Messages** permission here to do that.")
        return
    except discord.HTTPException as e:
        await ctx.send(f"Couldn't clear messages: {e}")
        return
    msg = await ctx.send(f"🧹 Cleared **{len(deleted) - 1}** message(s).")
    await asyncio.sleep(4)
    try:
        await msg.delete()
    except Exception:
        pass


@bot.command(name="giverole", aliases=["awardrole"])
@commands.has_permissions(manage_roles=True)
async def giverole_cmd(ctx, *, arg: str = None):
    """Award a role (e.g. 'Winner S1') to every member of a squad who has linked their
    Discord (!link) and registered (confirmed/approved) under that squad name. Only
    reaches linked accounts — someone who never ran !link can't be matched to a squad."""
    if not ctx.guild:
        await ctx.send("This only works inside the server.")
        return
    parts = [p.strip() for p in (arg or "").split("|")]
    if len(parts) < 2 or not parts[0] or not parts[1]:
        await ctx.send("Usage: `!giverole <squad name> | <role name> [| <tournament name>]`\n"
                        "e.g. `!giverole Alpha Squad | Winner S1`\n"
                        "Add a tournament name/slug as a third part if the squad name might "
                        "repeat across seasons.")
        return
    squad_name, role_name = parts[0], parts[1]
    tournament_slug = parts[2] if len(parts) > 2 and parts[2] else None
    if not SUPABASE_SERVICE_ROLE_KEY:
        await ctx.send("`SUPABASE_SERVICE_ROLE_KEY` isn't set on the bot, so I can't look up linked "
                        "Discord accounts (Supabase dashboard → Settings → API → service_role key).")
        return

    async with ctx.typing():
        discord_ids = await asyncio.to_thread(lookup_squad_discord_ids, squad_name, tournament_slug)
    if discord_ids is None:
        await ctx.send("Couldn't reach the database right now — try again in a moment.")
        return
    if not discord_ids:
        await ctx.send(f"No linked Discord accounts found for squad **{squad_name}**"
                        f"{' in ' + tournament_slug if tournament_slug else ''} — they may not have "
                        f"registered in-app under that squad name, or haven't run `!link` yet.")
        return

    role = discord.utils.find(lambda r: r.name.lower() == role_name.lower(), ctx.guild.roles)
    if not role:
        try:
            role = await ctx.guild.create_role(name=role_name, colour=discord.Colour(GOLD),
                                                reason=f"Auto-created by !giverole ({ctx.author})")
        except discord.Forbidden:
            await ctx.send("I don't have permission to create roles — give me **Manage Roles**, "
                            "or create the role manually first.")
            return

    given, missing = [], 0
    for did in discord_ids:
        member = await _resolve_member(ctx.guild, did)
        if not member:
            missing += 1
            continue
        try:
            await member.add_roles(role, reason=f"{squad_name} — awarded by {ctx.author}")
            given.append(member.mention)
        except discord.Forbidden:
            missing += 1

    if given:
        msg = f"🏆 **{role.name}** given to: {', '.join(given)}"
        if missing:
            msg += f"\n({missing} linked account(s) weren't in this server, or I lack permission — check my role is above **{role.name}**.)"
    else:
        msg = (f"Found {len(discord_ids)} linked account(s) for **{squad_name}** but couldn't role any of "
               f"them — they may have left the server, or my role needs to be moved above **{role.name}** "
               f"in Server Settings → Roles.")
    await ctx.send(msg)


@bot.command(name="rules")
async def rules_cmd(ctx):
    await ctx.send(
        "**JD Arena rules — Free Fire BR (Squad):**\n"
        "• Squad mode, no emulators unless stated\n"
        "• Be in the lobby 10 minutes early\n"
        "• Room ID / password sent before each match\n"
        "• Points = placement + kills\n"
        "• No teaming, no hacks — instant ban\n"
        "Full details posted on match day.")


@bot.command(name="help", aliases=["commands"])
async def help_cmd(ctx):
    await ctx.send(
        "**ZULU — JD Esports Arena bot**\n"
        "`!tournaments` — Free Fire schedule\n"
        "`!next` — next match + open slots\n"
        "`!register <squad>` — join event #1 (or `!register <event#> <squad>`)\n"
        "`!roster [event#]` — see who's registered\n"
        "`!unregister <squad>` — drop your own registration\n"
        "`!leaderboard` — season standings\n"
        "`!rules` — tournament rules\n"
        "`!mcstatus` — is the Minecraft server up + who's on\n"
        "`!ask <question>` — ask ZULU anything — built-in on Nepal/chemistry/physics/maths, "
        "general questions too\n"
        "`!link <code>` — link your Discord to your JD Arena account (get the code from your "
        "account panel on the site) so Room IDs can be DM'd here, and get the **Guild Member** role\n"
        "`!me` — see your own linked profile + career stats\n"
        "`!giverole <squad> | <role>` — *(needs Manage Roles)* award a role like \"Winner S1\" to "
        "everyone in that squad who's linked their Discord\n"
        "\n**Voice & music (slash commands):**\n"
        "`/join` — join your current voice channel • `/leave` — leave it\n"
        "`/play <song or YouTube URL>` — queue and play audio\n"
        "`/skip` `/pause` `/resume` `/stop` — playback controls\n"
        "`/queue` `/nowplaying` — see what's playing/queued\n"
        "`/volume <0-200>` — adjust playback volume • `/shuffle` — shuffle the queue\n"
        "`/ttschannel` — *(needs Manage Server)* pick a text channel ZULU reads aloud in voice chat\n"
        "\n**Moderation:**\n"
        "`!clear <amount>` — *(needs Manage Messages)* bulk-delete recent messages")


@bot.command(name="ask")
@commands.cooldown(1, 15, commands.BucketType.user)   # AI calls cost real (free-tier) quota --
                                                        # unthrottled before, one spammer could burn it
async def ask_cmd(ctx, *, q: str = None):
    if not q:
        await ctx.send("Ask me something — e.g. `!ask what is the capital of Nepal`")
        return
    a = knowledge_answer(q)
    if not a and (ZULU_SERVER_URL or _ai_members()):
        async with ctx.typing():
            a = await asyncio.to_thread(ai_answer_grounded, q)
    await ctx.send(a[:1900] if a else
                   "Couldn't get an answer for that one right now — try rephrasing, or ask something Nepal/chemistry/physics/maths-related.")


GUILD_MEMBER_ROLE_NAME = "Guild Member"


async def _grant_guild_member_role(ctx):
    """Best-effort: find-or-create the "Guild Member" role and give it to whoever just linked
    their account. Only meaningful inside a server — !link also works in DMs (no role to give
    there), so this is a no-op when ctx.guild is None. Never raises; a missing Manage Roles
    permission or a role positioned below the bot's own just means no role changes, silently."""
    if not ctx.guild:
        return
    role = discord.utils.find(lambda r: r.name.lower() == GUILD_MEMBER_ROLE_NAME.lower(), ctx.guild.roles)
    if not role:
        try:
            role = await ctx.guild.create_role(name=GUILD_MEMBER_ROLE_NAME, colour=discord.Colour(GOLD),
                                                reason="Auto-created for linked JD Arena accounts")
        except Exception:
            return
    try:
        member = ctx.guild.get_member(ctx.author.id) or await ctx.guild.fetch_member(ctx.author.id)
        if role not in member.roles:
            await member.add_roles(role, reason="Linked JD Arena account via !link")
    except Exception:
        pass


@bot.command(name="link")
async def link_cmd(ctx, code: str = None):
    if not code:
        await ctx.send("Usage: `!link <code>` — get the code from your account panel on the JD Arena website.")
        return
    if not requests:
        await ctx.send("I need the `requests` library for this — `pip install requests`.")
        return
    try:
        r = await asyncio.to_thread(
            requests.post,
            f"{SUPABASE_URL}/rest/v1/rpc/link_discord_account",
            headers={"apikey": SUPABASE_ANON_KEY, "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
                      "Content-Type": "application/json"},
            json={"p_code": code.strip(), "p_discord_user_id": str(ctx.author.id),
                  "p_discord_username": str(ctx.author)},
            timeout=15,
        )
    except Exception:
        await ctx.send("Couldn't reach the site's database right now — try again in a moment.")
        return
    if r.ok:
        await _grant_guild_member_role(ctx)
        await ctx.send(f"✅ Linked, {ctx.author.mention} — Room IDs will be DM'd here from now on. "
                        f"Run `!me` any time to see your linked profile and stats.")
        return
    try:
        detail = r.json().get("message") or r.text
    except Exception:
        detail = r.text
    await ctx.send(f"❌ Couldn't link: {detail[:300] if detail else 'that code is invalid or has expired.'}")


@bot.command(name="me", aliases=["profile", "mystats"])
async def me_cmd(ctx):
    """Shows the caller their own linked JD Arena profile + career stats. Only ever looks up
    the caller's own account (ctx.author.id) — never takes another user as an argument, so
    this can't be used to pull someone else's data."""
    if not SUPABASE_SERVICE_ROLE_KEY:
        await ctx.send("Account lookups aren't configured on this bot yet — ask the admin to set "
                        "`SUPABASE_SERVICE_ROLE_KEY`.")
        return
    async with ctx.typing():
        player = await asyncio.to_thread(lookup_player_by_discord_id, ctx.author.id)
    if not player:
        await ctx.send(f"{ctx.author.mention} you haven't linked your JD Arena account yet — run "
                        f"`!link <code>` (get the code from your account panel on the site).")
        return
    async with ctx.typing():
        stats = await asyncio.to_thread(fetch_career_stats, player["player_tag"])
    e = discord.Embed(title=f"🪪 {player['username']}'s JD Arena profile", color=GOLD)
    e.add_field(name="Player tag", value=player["player_tag"], inline=True)
    if stats and stats.get("tournaments_played"):
        e.add_field(name="Tournaments played", value=str(stats.get("tournaments_played", 0)), inline=True)
        e.add_field(name="Total kills", value=str(stats.get("total_kills", 0)), inline=True)
        e.add_field(name="Total points", value=str(stats.get("total_points", 0)), inline=True)
        e.add_field(name="Booyahs (#1s)", value=str(stats.get("booyahs", 0)), inline=True)
        e.add_field(name="Avg placement", value=str(stats.get("avg_placement", "—")), inline=True)
        prize = stats.get("total_prize") or 0
        if prize:
            e.add_field(name="Total prize won", value=f"NPR {prize}", inline=True)
    else:
        e.description = "No tournament history yet — get out there and play!"
    await ctx.send(embed=e)


@bot.command(name="mcstatus", aliases=["mc", "server"])
async def mc_cmd(ctx):
    if not requests:
        await ctx.send("I need the `requests` library for this — `pip install requests`.")
        return
    try:
        r = requests.get("https://api.mcsrvstat.us/3/" + MC_SERVER, timeout=10)
        d = r.json()
    except Exception:
        await ctx.send("Couldn't reach the status service right now — try again in a moment.")
        return
    if d.get("online"):
        pl = d.get("players", {}) or {}
        online, mx = pl.get("online", 0), pl.get("max", 0)
        names = ", ".join(p.get("name", "?") for p in (pl.get("list") or [])[:20])
        e = discord.Embed(title="🟢 " + MC_SERVER + " is ONLINE", color=0x5AAB8A)
        e.add_field(name="Players",
                    value=(str(online) + "/" + str(mx) + ("\n" + names if names else "")),
                    inline=False)
        ver = d.get("version")
        if ver:
            e.add_field(name="Version", value=str(ver), inline=True)
        await ctx.send(embed=e)
    else:
        await ctx.send("🔴 **" + MC_SERVER + "** is offline right now.\n"
                       "Aternos free servers sleep when empty — start it from the Aternos panel (aternos.org). "
                       "A keep-alive bot isn't allowed by Aternos; ask me for the real 24/7 options.")


async def _is_reply_to_bot(msg):
    if not msg.reference:
        return False
    resolved = msg.reference.resolved
    if resolved is None:
        try:
            resolved = await msg.channel.fetch_message(msg.reference.message_id)
        except Exception:
            return False
    return getattr(resolved, "author", None) == bot.user


async def _maybe_speak(msg):
    """If ZULU is in a voice channel in this guild and this message was posted in the
    channel designated by /ttschannel, queue it to be read aloud. Best-effort — a TTS
    failure here should never break the rest of on_message."""
    try:
        vc = msg.guild.voice_client
        if not vc or not vc.is_connected():
            return
        if msg.channel.id != tts_channel_for(msg.guild.id):
            return
        text = msg.content.strip()
        if not text:
            return
        st = _state(msg.guild.id)
        st.tts_queue.append(f"{msg.author.display_name} says {text}")
        if not st.busy:
            await _advance(msg.guild.id)
    except Exception:
        pass


@bot.event
async def on_message(msg):
    if msg.author.bot:
        return
    await bot.process_commands(msg)          # commands run first
    if msg.content.startswith("!"):
        return
    if msg.guild:
        await _maybe_speak(msg)
    # @mention the bot, or reply directly to one of its messages, and it answers for real
    # (no "!" needed) instead of the old "I go by commands, not chat" brush-off. Everywhere
    # else it stays quiet except for the light keyword triggers below, so it doesn't talk
    # over every message in a busy channel.
    if bot.user in msg.mentions or await _is_reply_to_bot(msg):
        q = msg.content
        for m in msg.mentions:
            q = q.replace(f"<@{m.id}>", "").replace(f"<@!{m.id}>", "")
        q = q.strip()
        if not q:
            await msg.channel.send(f"Hey {msg.author.mention} — ask me something, or try `!help` for commands.")
            return
        if not _mention_cooldown_ok(msg.author.id):
            await msg.channel.send(f"Slow down a bit, {msg.author.mention} — try again in a few seconds.")
            return
        try:
            a = knowledge_answer(q)
            if not a and (ZULU_SERVER_URL or _ai_members()):
                async with msg.channel.typing():
                    a = await asyncio.to_thread(ai_answer_grounded, q)
            await msg.channel.send((a[:1900] if a else
                f"Couldn't get an answer for that right now, {msg.author.mention} — try `!help` for commands.").rstrip())
        except Exception:
            pass
        return
    low = msg.content.lower()
    triggers = ["room id", "room code", "when tournament", "next tournament",
                "when is the match", "kab hai", "kun bela"]
    if any(w in low for w in triggers):
        try:
            await msg.channel.send(f"{msg.author.mention} type `!next` for the schedule and Room ID timing. 🎮")
        except Exception:
            pass


@bot.event
async def on_member_join(member):
    try:
        ch = member.guild.system_channel
        if ch:
            await ch.send(f"Welcome to **JD Esports Arena**, {member.mention}! 🪂 "
                          f"Type `!tournaments` to see what's on and `!register <squad>` to compete. GLHF.")
    except Exception:
        pass


if __name__ == "__main__":
    if not TOKEN:
        print("Set DISCORD_TOKEN (see the setup notes at the top of this file).")
        raise SystemExit(1)
    bot.run(TOKEN)
