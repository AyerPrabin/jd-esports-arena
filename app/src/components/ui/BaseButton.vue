<script setup lang="ts">
// Reusable button. Presentational only — no business logic.
defineProps<{ variant?: 'primary' | 'ghost'; disabled?: boolean }>();
</script>

<template>
  <button class="btn" :class="variant ?? 'primary'" :disabled="disabled">
    <slot />
  </button>
</template>

<style scoped>
.btn {
  font: inherit;
  font-weight: 700;
  border-radius: 999px;
  padding: 10px 18px;
  cursor: pointer;
  border: 1px solid transparent;
  transition: filter 0.15s, background 0.15s;
}
.btn.primary { background: var(--gold); color: #07090f; }
.btn.ghost { background: transparent; color: var(--gold-l); border-color: var(--gold-m); }
.btn:disabled { opacity: 0.55; cursor: not-allowed; }
.btn:not(:disabled):hover { filter: brightness(1.08); }
</style>
