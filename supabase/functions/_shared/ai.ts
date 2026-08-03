// Multi-provider AI helper shared by zulu-ai-reply and generate-match-recap.
// Tries free-tier providers in order until one answers, so these features don't go
// dark the moment Gemini's small daily quota (~20 req/day free tier) is used up.
// Add a key in Supabase Dashboard -> Edge Functions -> Secrets and it's used
// automatically; any provider whose key env var is unset is skipped, no code change
// needed. Mirrors the "never depend on one AI" council pattern from zulu_server.py
// (the local desktop ZULU), minus Ollama -- that's localhost-only, unreachable from
// an edge function.

export interface AIMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface AIResult {
  text: string;
  provider: string;
}

interface OpenAICompatProvider {
  name: string;
  base: string;
  model: string;
  keyEnv: string;
}

// Order here is also the default try-order (see askAI): fastest/highest-quota free
// tiers first. Model strings match the ones already validated in zulu_secrets.py /
// zulu_server.py's PROVIDERS table.
const OPENAI_COMPAT_PROVIDERS: OpenAICompatProvider[] = [
  { name: 'groq', base: 'https://api.groq.com/openai/v1/chat/completions', model: 'llama-3.3-70b-versatile', keyEnv: 'GROQ_API_KEY' },
  { name: 'cerebras', base: 'https://api.cerebras.ai/v1/chat/completions', model: 'llama-3.3-70b', keyEnv: 'CEREBRAS_API_KEY' },
  { name: 'openrouter', base: 'https://openrouter.ai/api/v1/chat/completions', model: 'meta-llama/llama-3.3-70b-instruct:free', keyEnv: 'OPENROUTER_API_KEY' },
  { name: 'together', base: 'https://api.together.xyz/v1/chat/completions', model: 'meta-llama/Llama-3.3-70B-Instruct-Turbo', keyEnv: 'TOGETHER_API_KEY' },
  { name: 'deepseek', base: 'https://api.deepseek.com/chat/completions', model: 'deepseek-chat', keyEnv: 'DEEPSEEK_API_KEY' },
];

async function callOpenAICompatible(base: string, model: string, key: string, messages: AIMessage[]): Promise<string | null> {
  try {
    const res = await fetch(base, {
      method: 'POST',
      headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, messages, temperature: 0.6, max_tokens: 1024 }),
    });
    if (!res.ok) return null;
    const data = await res.json();
    const text = data?.choices?.[0]?.message?.content;
    return typeof text === 'string' && text.trim() ? text.trim() : null;
  } catch {
    return null;
  }
}

// Kept as Gemini's own native generateContent call (not the OpenAI-compat endpoint) --
// this is the exact request shape already proven live in production; no reason to swap
// it for a "uniform" path that risks regressing the one thing that currently works.
async function callGemini(messages: AIMessage[]): Promise<string | null> {
  const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY');
  if (!GEMINI_API_KEY) return null;
  const GEMINI_MODEL = Deno.env.get('GEMINI_MODEL') || 'gemini-2.5-flash';
  const systemMsg = messages.find((m) => m.role === 'system');
  const userText = messages
    .filter((m) => m.role !== 'system')
    .map((m) => m.content)
    .join('\n\n');
  try {
    const res = await fetch(
      `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          ...(systemMsg ? { systemInstruction: { parts: [{ text: systemMsg.content }] } } : {}),
          contents: [{ parts: [{ text: userText }] }],
        }),
      },
    );
    if (!res.ok) return null;
    const data = await res.json();
    const text = data?.candidates?.[0]?.content?.parts?.[0]?.text;
    return typeof text === 'string' && text.trim() ? text.trim() : null;
  } catch {
    return null;
  }
}

/**
 * Try each configured free-tier provider in order until one returns text. Providers
 * with no key set (env var empty/unset) are skipped silently -- pasting one key (e.g.
 * just GROQ_API_KEY) is enough to get a working fallback chain. Returns null only when
 * every configured provider failed or none are configured at all.
 */
export async function askAI(messages: AIMessage[], order?: string[]): Promise<AIResult | null> {
  const tryOrder = order || ['groq', 'gemini', 'cerebras', 'openrouter', 'together', 'deepseek'];
  for (const name of tryOrder) {
    if (name === 'gemini') {
      const text = await callGemini(messages);
      if (text) return { text, provider: 'gemini' };
      continue;
    }
    const cfg = OPENAI_COMPAT_PROVIDERS.find((p) => p.name === name);
    if (!cfg) continue;
    const key = Deno.env.get(cfg.keyEnv);
    if (!key) continue;
    const model = Deno.env.get(cfg.name.toUpperCase() + '_MODEL') || cfg.model;
    const text = await callOpenAICompatible(cfg.base, model, key, messages);
    if (text) return { text, provider: cfg.name };
  }
  return null;
}

