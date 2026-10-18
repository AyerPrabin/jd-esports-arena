<script setup lang="ts">
// App shell: top nav + a global error banner + the routed view. Views that hit a
// fatal error can set the banner via the (future) error store; for now it listens
// for unhandled promise rejections so no failure is fully silent.
import { onMounted, ref } from 'vue';
import { useSessionStore } from '@/stores/session';

const session = useSessionStore();
const banner = ref<string | null>(null);

onMounted(() => {
  void session.init();
  window.addEventListener('unhandledrejection', (e) => {
    banner.value = e.reason?.message ?? 'Something went wrong.';
  });
});
</script>

<template>
  <div class="shell">
    <header class="nav">
      <strong>JD Esports Arena</strong>
      <nav>
        <RouterLink to="/leaderboard">Leaderboard</RouterLink>
      </nav>
      <span class="who">{{ session.email || '' }}</span>
    </header>

    <div v-if="banner" class="banner" @click="banner = null">⚠️ {{ banner }} (tap to dismiss)</div>

    <main><RouterView /></main>
  </div>
</template>

<style scoped>
.shell { max-width: 960px; margin: 0 auto; padding: 16px; }
.nav { display: flex; align-items: center; gap: 16px; padding: 10px 0 18px; }
.nav nav { display: flex; gap: 12px; flex: 1; }
.nav .who { color: var(--silver); font-size: 0.85rem; }
.banner {
  background: rgba(255, 97, 97, 0.12);
  border: 1px solid var(--red);
  color: #ffd6d6; border-radius: 10px;
  padding: 10px 14px; margin-bottom: 14px; cursor: pointer;
}
</style>
