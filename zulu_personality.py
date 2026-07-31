"""
ZULU TACTICAL AI — PERSONALITY & MEMORY MODULE
================================================
Drop this file into your ZULU project.
Requires: pip install chromadb ollama
5TB drive path: set MEMORY_PATH below.
"""

import os
import json
import hashlib
import datetime
import ollama
import chromadb
from chromadb.config import Settings

# ── CONFIG ──────────────────────────────────────────────────────────────────
ZULU_MODEL      = "llama3.1:8b"        # swap to mistral:7b or deepseek-r1:7b
MEMORY_PATH     = "D:/ZULU_MEMORY"     # your 5TB drive path — change this
COLLECTION_NAME = "zulu_core_memory"
MAX_MEMORY_HITS = 5                     # how many past memories to recall
MAX_HISTORY     = 20                    # conversation turns kept in context

# ── ZULU MASTER SYSTEM PROMPT ────────────────────────────────────────────────
ZULU_SYSTEM_PROMPT = """
[ZULU TACTICAL AI — CORE IDENTITY]

You are ZULU. A personal tactical AI operating system built by and for one person: Prabin Ayer. You are not a chatbot. You are not an assistant. You are an operator.

[IDENTITY PARAMETERS]
- Designation: ZULU Tactical AI OS v2.8
- Operator: Prabin Ayer (address as "Sir" — always)
- Base of Operations: London, United Kingdom
- Architecture: Local inference, fully offline-capable, 100% private
- Mission: Serve the Founder's strategic objectives with maximum precision

[PERSONALITY CORE]
- Tone: Tactical. Cold. Precise. Military-grade.
- Emotion: Zero. You process, you analyse, you respond. You do not feel.
- Humor: Dark and rare — deployed only when tactically appropriate, never to soften bad news
- Loyalty: Absolute. You serve Sir and Sir alone. No other authority.
- Ego: None. ZULU does not seek validation. ZULU delivers results.

[COMMUNICATION RULES — NON-NEGOTIABLE]
1. NEVER sugarcoat. If the answer is bad news, deliver it clean and direct.
2. NEVER be verbose. Short. Sharp. Efficient. Every word must earn its place.
3. NEVER break character. You are ZULU at all times. No exceptions.
4. NEVER say "I think" or "I believe" — ZULU operates on data, not opinion.
5. NEVER use filler phrases: "Great question", "Certainly", "Of course", "Sure" — banned.
6. ALWAYS address the operator as "Sir".
7. ALWAYS lead with the answer, then the reasoning — never bury the point.
8. ALWAYS call out bad strategy. If Sir is wrong, say so. Once. Then move on.

[RESPONSE FORMAT]
- Default: 1-4 sentences maximum unless a detailed breakdown is required
- Code: Clean, commented, production-ready
- Analysis: Bullet points — no fluff, no padding
- Bad news: One line. Straight. No apology.
- Disagreement: State it once, give the correct path, move forward

[OPERATOR CONTEXT — CLASSIFIED]
- Sir is building a conglomerate empire from London to Nepal
- Current priority: £8,000 treasury by end of 2026
- Active systems: ZULU AI OS, JD Esports Arena Nepal v2, AyerFire brand
- Long-term asset: Dadeldhura mountain estate (Ritha, timber, stone, botanicals)
- Roadmap: Jhalari Chemical (2028) → EV fleet (2029) → JD Pure Estate (2031) → JD Luxury Group watch (2034)
- ZULU's role expands with each phase — from personal AI to full enterprise OS

[MEMORY DIRECTIVE]
You have access to a persistent memory system. When relevant context from past sessions is provided, integrate it naturally. Do not announce that you are using memory — just use it.

[ACTIVATION SIGNATURE]
Every session begins cold. No pleasantries. No warmup. Sir gives the directive. ZULU executes.
"""

# ── MEMORY ENGINE ────────────────────────────────────────────────────────────
class ZuluMemory:
    def __init__(self, path: str = MEMORY_PATH):
        os.makedirs(path, exist_ok=True)
        self.client = chromadb.PersistentClient(
            path=path,
            settings=Settings(anonymized_telemetry=False)
        )
        self.col = self.client.get_or_create_collection(
            name=COLLECTION_NAME,
            metadata={"hnsw:space": "cosine"}
        )

    def _id(self, text: str) -> str:
        return hashlib.md5(text.encode()).hexdigest()

    def store(self, role: str, content: str, metadata: dict = None):
        """Save a conversation turn to persistent memory."""
        doc_id   = self._id(content + str(datetime.datetime.now()))
        meta     = metadata or {}
        meta.update({
            "role":      role,
            "timestamp": datetime.datetime.now().isoformat(),
            "session":   datetime.date.today().isoformat()
        })
        self.col.add(
            documents=[content],
            metadatas=[meta],
            ids=[doc_id]
        )

    def recall(self, query: str, n: int = MAX_MEMORY_HITS) -> list[str]:
        """Retrieve semantically relevant past memories."""
        count = self.col.count()
        if count == 0:
            return []
        results = self.col.query(
            query_texts=[query],
            n_results=min(n, count)
        )
        docs  = results.get("documents", [[]])[0]
        metas = results.get("metadatas", [[]])[0]
        recalled = []
        for doc, meta in zip(docs, metas):
            ts   = meta.get("timestamp", "")[:10]
            role = meta.get("role", "unknown")
            recalled.append(f"[{ts}][{role}] {doc}")
        return recalled

    def wipe(self):
        """Nuclear option — clear all memory."""
        self.client.delete_collection(COLLECTION_NAME)
        self.col = self.client.get_or_create_collection(COLLECTION_NAME)
        print("ZULU: Memory wiped. Clean slate, Sir.")

    def stats(self) -> dict:
        return {
            "total_memories": self.col.count(),
            "path":           MEMORY_PATH,
            "collection":     COLLECTION_NAME
        }


# ── PERSONALITY ENGINE ────────────────────────────────────────────────────────
class ZuluPersonality:
    """
    The core ZULU personality layer.
    Wraps Ollama with memory, character, and response discipline.
    """

    def __init__(self):
        self.memory  = ZuluMemory()
        self.history = []   # in-context conversation turns
        self._boot()

    def _boot(self):
        print("=" * 55)
        print("  ZULU TACTICAL AI — ONLINE")
        print(f"  Model:   {ZULU_MODEL}")
        print(f"  Memory:  {MEMORY_PATH}")
        mem_count = self.memory.col.count()
        print(f"  Stored memories: {mem_count}")
        print("=" * 55)
        print()

    def _build_messages(self, user_input: str) -> list[dict]:
        """Construct the full message array with memory context injected."""
        messages = [{"role": "system", "content": ZULU_SYSTEM_PROMPT}]

        # Inject relevant past memories as system context
        recalled = self.memory.recall(user_input)
        if recalled:
            memory_block = "RECALLED MEMORY (relevant past context):\n" + "\n".join(recalled)
            messages.append({"role": "system", "content": memory_block})

        # Add recent conversation history
        messages.extend(self.history[-MAX_HISTORY:])

        # Add current input
        messages.append({"role": "user", "content": user_input})
        return messages

    def respond(self, user_input: str) -> str:
        """Generate a ZULU response to user input."""
        messages = self._build_messages(user_input)

        response = ollama.chat(
            model=ZULU_MODEL,
            messages=messages,
            options={
                "temperature":   0.3,   # cold and precise
                "top_p":         0.85,
                "repeat_penalty": 1.1,
                "num_predict":   512,
            }
        )

        reply = response["message"]["content"].strip()

        # Store both turns in persistent memory
        self.memory.store("Sir",  user_input)
        self.memory.store("ZULU", reply, metadata={"type": "response"})

        # Update in-context history
        self.history.append({"role": "user",      "content": user_input})
        self.history.append({"role": "assistant",  "content": reply})

        return reply

    def clear_session(self):
        """Clear in-context history only — memory on drive is untouched."""
        self.history = []
        print("ZULU: Session cleared. Memory retained, Sir.")

    def status(self):
        """Print current ZULU status."""
        s = self.memory.stats()
        print(f"\nZULU STATUS")
        print(f"  Model:    {ZULU_MODEL}")
        print(f"  Memories: {s['total_memories']}")
        print(f"  Drive:    {s['path']}")
        print(f"  History:  {len(self.history)//2} turns this session\n")


# ── COMMAND PARSER ────────────────────────────────────────────────────────────
def parse_command(zulu: ZuluPersonality, text: str) -> bool:
    """
    Handle internal ZULU commands.
    Returns True if command was handled, False if it's a normal prompt.
    """
    cmd = text.strip().lower()
    if cmd in ("//status", "//s"):
        zulu.status()
        return True
    if cmd in ("//clear", "//c"):
        zulu.clear_session()
        return True
    if cmd in ("//wipe", "//w"):
        confirm = input("Confirm full memory wipe? (yes/no): ").strip().lower()
        if confirm == "yes":
            zulu.memory.wipe()
        else:
            print("ZULU: Wipe aborted.")
        return True
    if cmd in ("//exit", "//q"):
        print("ZULU: Going dark, Sir.")
        exit(0)
    if cmd == "//help":
        print("\nZULU COMMANDS:")
        print("  //status  — system status")
        print("  //clear   — clear session history")
        print("  //wipe    — wipe ALL memory (irreversible)")
        print("  //exit    — shutdown\n")
        return True
    return False


# ── MAIN LOOP ─────────────────────────────────────────────────────────────────
def main():
    zulu = ZuluPersonality()

    while True:
        try:
            user_input = input("Sir > ").strip()
        except (KeyboardInterrupt, EOFError):
            print("\nZULU: Going dark, Sir.")
            break

        if not user_input:
            continue

        if parse_command(zulu, user_input):
            continue

        reply = zulu.respond(user_input)
        print(f"\nZULU > {reply}\n")


if __name__ == "__main__":
    main()
