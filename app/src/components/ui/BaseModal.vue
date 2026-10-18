<script setup lang="ts">
defineProps<{ open: boolean; title?: string }>();
const emit = defineEmits<{ close: [] }>();
</script>

<template>
  <div v-if="open" class="overlay" @click.self="emit('close')">
    <div class="modal" role="dialog" aria-modal="true">
      <button class="x" aria-label="Close" @click="emit('close')">×</button>
      <h3 v-if="title">{{ title }}</h3>
      <slot />
    </div>
  </div>
</template>

<style scoped>
.overlay {
  position: fixed; inset: 0; z-index: 90;
  background: rgba(0, 0, 0, 0.6);
  display: grid; place-items: center; padding: 16px;
}
.modal {
  position: relative;
  width: min(460px, 100%);
  background: var(--panel);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 22px;
}
.x {
  position: absolute; top: 12px; right: 14px;
  width: 34px; height: 34px; border-radius: 50%;
  background: rgba(255, 255, 255, 0.04); border: 1px solid var(--line);
  color: var(--cream); font-size: 1.1rem; cursor: pointer;
}
</style>
