import { defineStore } from 'pinia';
import { ref } from 'vue';
import { supabase } from '@/lib/supabase';
import { rpc } from '@/api/client';

// Auth/session state, app-wide. One auth subscription lives here.
export const useSessionStore = defineStore('session', () => {
  const email = ref<string | null>(null);
  const userId = ref<string | null>(null);
  const isModerator = ref(false);
  const ready = ref(false);

  async function refreshRoles() {
    if (!userId.value) {
      isModerator.value = false;
      return;
    }
    try {
      isModerator.value = Boolean(await rpc<boolean>('is_moderator'));
    } catch {
      isModerator.value = false;
    }
  }

  async function init() {
    const { data: { session } } = await supabase.auth.getSession();
    email.value = session?.user.email ?? null;
    userId.value = session?.user.id ?? null;
    await refreshRoles();
    ready.value = true;
    supabase.auth.onAuthStateChange((_event, s) => {
      email.value = s?.user.email ?? null;
      userId.value = s?.user.id ?? null;
      void refreshRoles();
    });
  }

  async function signOut() {
    await supabase.auth.signOut();
  }

  return { email, userId, isModerator, ready, init, signOut };
});
