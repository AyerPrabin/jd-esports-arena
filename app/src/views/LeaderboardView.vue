<script setup lang="ts">
// First migrated view: read-only Best-of-3 standings. Composes store + api + ui
// components, with no direct Supabase call — the template for every other view.
import { computed, onMounted } from 'vue';
import { useTournamentsStore } from '@/stores/tournaments';
import { standingsFromBo3 } from '@/api/tournaments';
import BaseCard from '@/components/ui/BaseCard.vue';

const store = useTournamentsStore();
onMounted(() => store.load());

const title = computed(() => store.doc.bo3?.title || store.doc.bo3?.tournament || 'Standings');
const rows = computed(() => standingsFromBo3(store.doc.bo3));
</script>

<template>
  <BaseCard :title="`🏆 ${title}`">
    <p v-if="store.loading" class="hint">Loading standings…</p>
    <p v-else-if="store.error" class="hint err">{{ store.error }}</p>
    <p v-else-if="!rows.length" class="hint">No results published yet.</p>
    <table v-else>
      <thead>
        <tr><th>#</th><th>Squad</th><th class="num">Points</th></tr>
      </thead>
      <tbody>
        <tr v-for="r in rows" :key="r.team">
          <td>{{ r.rank }}</td>
          <td>{{ r.team }}</td>
          <td class="num">{{ r.totalPts }}</td>
        </tr>
      </tbody>
    </table>
  </BaseCard>
</template>

<style scoped>
table { width: 100%; border-collapse: collapse; }
th, td { padding: 8px 10px; text-align: left; border-bottom: 1px solid var(--line); }
.num { text-align: right; }
.hint { color: var(--silver); }
.hint.err { color: var(--red); }
</style>
