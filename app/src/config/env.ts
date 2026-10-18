// The ONLY place env/config is read. Everything else imports from here.
// Fails fast in dev if a required var is missing, so misconfig is obvious.

function required(name: keyof ImportMetaEnv): string {
  const value = import.meta.env[name];
  if (!value) {
    throw new Error(`Missing env var ${name}. Copy app/.env.example to .env.local and fill it in.`);
  }
  return value;
}

export const env = {
  supabaseUrl: required('VITE_SUPABASE_URL'),
  supabaseAnonKey: required('VITE_SUPABASE_ANON_KEY'),
  siteUrl: 'https://jdesport.co.uk',
} as const;
