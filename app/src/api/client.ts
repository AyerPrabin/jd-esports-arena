import { supabase } from '@/lib/supabase';
import { env } from '@/config/env';

// One error type so every view handles failures the same way.
export class ApiError extends Error {
  constructor(message: string, readonly cause?: unknown) {
    super(message);
    this.name = 'ApiError';
  }
}

// Call a Postgres RPC (SECURITY DEFINER functions). Throws ApiError on failure.
export async function rpc<T>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args ?? {});
  if (error) throw new ApiError(error.message, error);
  return data as T;
}

// A plain table select builder — callers chain .eq().order() etc, then await run().
export function from(table: string) {
  return supabase.from(table);
}
export async function run<T>(query: PromiseLike<{ data: T | null; error: { message: string } | null }>): Promise<T> {
  const { data, error } = await query;
  if (error) throw new ApiError(error.message, error);
  return (data ?? ([] as unknown)) as T;
}

// Call a public Edge Function (e.g. zulu-ai-reply). Admin-secret functions are
// never called from the client — those run server-to-server only.
export async function edge<T>(name: string, body: unknown): Promise<T> {
  const { data: { session } } = await supabase.auth.getSession();
  const res = await fetch(`${env.supabaseUrl}/functions/v1/${name}`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: env.supabaseAnonKey,
      ...(session ? { Authorization: `Bearer ${session.access_token}` } : {}),
    },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new ApiError(text || `Edge function ${name} failed (${res.status})`);
  try {
    return JSON.parse(text) as T;
  } catch {
    return text as unknown as T;
  }
}
