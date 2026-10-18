<script setup lang="ts">
defineProps<{ title?: string }>();
</script>

<template>
  <section class="card">
    <h2 v-if="title">{{ title }}</h2>
    <slot />
  </section>
</template>

<style scoped>
.card {
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 18px 20px;
}
.card h2 { margin: 0 0 12px; font-size: 1.15rem; }
</style>
