import { rpc } from './client';

// Register a squad for a tournament. Server checks slot cap, mobile-only, unique
// squad name per tournament, bans, and early access.
export function register(params: {
  slug: string;
  squad: string;
  logo?: string | null;
  status: 'confirmed' | 'pending';
  device: 'mobile' | 'emulator';
}) {
  return rpc('register_for_tournament', {
    p_tournament_slug: params.slug,
    p_squad_name: params.squad,
    p_squad_logo: params.logo ?? null,
    p_status: params.status,
    p_payment_screenshot: null,
    p_device_type: params.device,
  });
}

// Confirm attendance — only valid in the 48h→24h window before start (server-enforced).
export function confirmAttendance(slug: string) {
  return rpc('confirm_attendance', { p_slug: slug });
}
