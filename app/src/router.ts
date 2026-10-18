import { createRouter, createWebHistory } from 'vue-router';

// Views are lazy-loaded so each route is its own chunk. Add routes as pages migrate.
const routes = [
  { path: '/', redirect: '/leaderboard' },
  { path: '/leaderboard', name: 'leaderboard', component: () => import('@/views/LeaderboardView.vue') },
];

export const router = createRouter({
  history: createWebHistory(),
  routes,
  scrollBehavior: () => ({ top: 0 }),
});
