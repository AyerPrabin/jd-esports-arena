import { createClient } from '@supabase/supabase-js';
import { env } from '@/config/env';

// The single Supabase client for the whole app. Import this, never create another.
export const supabase = createClient(env.supabaseUrl, env.supabaseAnonKey, {
  auth: { persistSession: true, autoRefreshToken: true },
});
