// Multi-provider AI helper shared by zulu-ai-reply and generate-match-recap.
// Tries free-tier providers in order until one answers, so these features don't go
// dark the moment one provider's daily quota is used up. Add a key in Supabase
// (`supabase secrets set GROQ_API_KEY=...`) and it's used automatically; any provider
// whose key env var is unset is skipped, no code change needed. Mirrors the "never
// depend on one AI" council pattern from zulu_server.py (the local desktop ZULU),
// minus Ollama -- that's localhost-only, unreachable from an edge function.
//
// Each provider has a list of models, tried in order: free-tier model line-ups change
// (models get retired, renamed, moved to paid), so a 404/400 "no such model" falls
// through to the next model instead of silently killing that provider. Prefer the
// providers' moving aliases ("-latest", openrouter/free) so this keeps working without
// edits. Override any provider's list with <NAME>_MODEL (comma-separated).

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
  models: string[];
  keyEnv: string;
}

// Free-tier notes (Oct 2026, verify at each provider's console if something stops answering):
//  groq       -- no card; ~1,000 req/day on the larger models, 30/min
//  cerebras   -- 1M tokens/day on the free key
//  openrouter -- `openrouter/free` routes to whichever free model is up (50 req/day
//                without credit, 1,000/day after a one-off $10 top-up)
//  mistral    -- free "Experiment" plan, no card, ~1 req/s
//  together / deepseek -- paid only, kept for anyone who adds a key
const OPENAI_COMPAT_PROVIDERS: OpenAICompatProvider[] = [
  { name: 'groq', base: 'https://api.groq.com/openai/v1/chat/completions', models: ['openai/gpt-oss-120b', 'llama-3.3-70b-versatile', 'openai/gpt-oss-20b'], keyEnv: 'GROQ_API_KEY' },
  { name: 'cerebras', base: 'https://api.cerebras.ai/v1/chat/completions', models: ['gpt-oss-120b', 'llama-3.3-70b'], keyEnv: 'CEREBRAS_API_KEY' },
  { name: 'mistral', base: 'https://api.mistral.ai/v1/chat/completions', models: ['mistral-small-latest', 'open-mistral-nemo'], keyEnv: 'MISTRAL_API_KEY' },
  { name: 'openrouter', base: 'https://openrouter.ai/api/v1/chat/completions', models: ['openrouter/free', 'meta-llama/llama-3.3-70b-instruct:free'], keyEnv: 'OPENROUTER_API_KEY' },
  { name: 'together', base: 'https://api.together.xyz/v1/chat/completions', models: ['meta-llama/Llama-3.3-70B-Instruct-Turbo'], keyEnv: 'TOGETHER_API_KEY' },
  { name: 'deepseek', base: 'https://api.deepseek.com/chat/completions', models: ['deepseek-chat'], keyEnv: 'DEEPSEEK_API_KEY' },
];

// Gemini: the moving "-latest" aliases first (they follow Google's current free Flash /
// Flash-Lite), then pinned names as a fallback. Flash-Lite's free quota is far larger
// (~1,000+/day) than Flash's (~20/day on 2.5), so it goes first for short chat replies.
const GEMINI_MODELS = ['gemini-flash-lite-latest', 'gemini-flash-latest', 'gemini-2.5-flash-lite', 'gemini-2.5-flash'];

const TIMEOUT_MS = 20000;

function modelsFor(name: string, defaults: string[]): string[] {
  const env = Deno.env.get(name.toUpperCase() + '_MODEL');
  return env ? env.split(',').map((m) => m.trim()).filter(Boolean) : defaults;
}

// 'next-model' = this model is gone/invalid, try the provider's next one;
// 'next-provider' = quota/auth/outage, skip the rest of this provider.
type Outcome = { text: string } | 'next-model' | 'next-provider';

function classify(status: number): Outcome {
  return status === 404 || status === 400 || status === 422 ? 'next-model' : 'next-provider';
}

async function post(url: string, init: RequestInit): Promise<Response | null> {
  try {
    return await fetch(url, { ...init, signal: AbortSignal.timeout(TIMEOUT_MS) });
  } catch {
    return null;
  }
}

async function callOpenAICompatible(base: string, model: string, key: string, messages: AIMessage[]): Promise<Outcome> {
  const res = await post(base, {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ model, messages, temperature: 0.6, max_tokens: 1024 }),
  });
  if (!res) return 'next-provider';
  if (!res.ok) return classify(res.status);
  try {
    const data = await res.json();
    const text = data?.choices?.[0]?.message?.content;
    return typeof text === 'string' && text.trim() ? { text: text.trim() } : 'next-model';
  } catch {
    return 'next-model';
  }
}

// Gemini's own native generateContent call (not its OpenAI-compat endpoint) -- this
// request shape is the one already proven live in production.
async function callGemini(model: string, key: string, messages: AIMessage[]): Promise<Outcome> {
  const systemMsg = messages.find((m) => m.role === 'system');
  const userText = messages.filter((m) => m.role !== 'system').map((m) => m.content).join('\n\n');
  const res = await post(`https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'x-goog-api-key': key },
    body: JSON.stringify({
      ...(systemMsg ? { systemInstruction: { parts: [{ text: systemMsg.content }] } } : {}),
      contents: [{ parts: [{ text: userText }] }],
    }),
  });
  if (!res) return 'next-provider';
  // Gemini answers 429 per MODEL (Flash and Flash-Lite have separate quotas), so a
  // quota hit on one model should still try the next one, unlike other providers.
  if (res.status === 429) return 'next-model';
  if (!res.ok) return classify(res.status);
  try {
    const data = await res.json();
    const text = data?.candidates?.[0]?.content?.parts?.map((p: { text?: string }) => p.text || '').join('');
    return typeof text === 'string' && text.trim() ? { text: text.trim() } : 'next-model';
  } catch {
    return 'next-model';
  }
}

/**
 * Try each configured free-tier provider (and each of its models) in order until one
 * returns text. Providers with no key set are skipped silently -- one key is enough for
 * a working chain. Returns null only when every configured provider failed or none are
 * configured at all.
 */
export async function askAI(messages: AIMessage[], order?: string[]): Promise<AIResult | null> {
  const tryOrder = order || (Deno.env.get('AI_PROVIDER_ORDER') || 'groq,gemini,cerebras,mistral,openrouter,together,deepseek')
    .split(',').map((s) => s.trim()).filter(Boolean);
  for (const name of tryOrder) {
    if (name === 'gemini') {
      const key = Deno.env.get('GEMINI_API_KEY');
      if (!key) continue;
      for (const model of modelsFor('gemini', GEMINI_MODELS)) {
        const out = await callGemini(model, key, messages);
        if (typeof out === 'object') return { text: out.text, provider: `gemini:${model}` };
        if (out === 'next-provider') break;
      }
      continue;
    }
    const cfg = OPENAI_COMPAT_PROVIDERS.find((p) => p.name === name);
    if (!cfg) continue;
    const key = Deno.env.get(cfg.keyEnv);
    if (!key) continue;
    for (const model of modelsFor(cfg.name, cfg.models)) {
      const out = await callOpenAICompatible(cfg.base, model, key, messages);
      if (typeof out === 'object') return { text: out.text, provider: `${cfg.name}:${model}` };
      if (out === 'next-provider') break;
    }
  }
  return null;
}
