import { defineStore } from 'pinia';
import { ref } from 'vue';
import { getTournamentsDoc } from '@/api/tournaments';
import type { TournamentsDoc } from '@/api/types';

// Shared tournament data so views don't each fetch their own copy.
export const useTournamentsStore = defineStore('tournaments', () => {
  const doc = ref<TournamentsDoc>({ tournaments: [] });
  const loading = ref(false);
  const error = ref<string | null>(null);
  let timer: number | undefined;

  async function load() {
    loading.value = true;
    error.value = null;
    try {
      doc.value = await getTournamentsDoc();
    } catch (e) {
      error.value = e instanceof Error ? e.message : 'Could not load tournaments.';
    } finally {
      loading.value = false;
    }
  }

  function startAutoRefresh(ms = 30_000) {
    stop();
    timer = window.setInterval(load, ms);
  }
  function stop() {
    if (timer) window.clearInterval(timer);
    timer = undefined;
  }

  return { doc, loading, error, load, startAutoRefresh, stop };
});
