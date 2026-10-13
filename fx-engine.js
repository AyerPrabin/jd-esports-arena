/* JD Arena squad-effects engine (canvas). Adds a live particle layer behind every squad-effect
   card (.sqfx: tournament rosters, the effects-shop preview, challenge cards) so the effects
   players buy actually feel alive: embers, snow, lightning, tracer fire, blade slashes,
   shooting stars, holographic diamonds.
   Built for cheap phones on mobile data, so it's one small file and NOT a big particle library:
   - one shared requestAnimationFrame loop for every card; cards off screen aren't drawn
     (IntersectionObserver) and the loop sleeps when no card is visible
   - glows are pre-rendered sprites drawn with drawImage + 'lighter' blending (never canvas
     shadowBlur, which is what kills frame rate on low-end Androids)
   - devicePixelRatio capped at 1.5; weak devices (≤4 GB RAM or ≤4 cores) run at 30 fps with
     fewer particles
   - colours come from the card's own --fx1 / --fx2, so particles match the effect bought
   - cards get re-rendered (roster modal, live grid, shop preview), so a debounced
     MutationObserver mounts new cards and drops detached ones
   While a card runs here its old CSS particles (.sqp / .fxp) are hidden; if this file fails
   to load they still show. Bought effects keep animating with reduced motion on (owner
   decision, see effects-pro.css). */
(function () {
  if (window.jdFx || !window.requestAnimationFrame) return;
  var low = (navigator.deviceMemory && navigator.deviceMemory <= 4) || (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 4);
  var STEP = low ? 1000 / 30 : 0;           // min ms between frames (0 = every display frame)
  var DPR = Math.min(1.5, window.devicePixelRatio || 1);
  var CAP = low ? 26 : 48;                   // max particles per card
  var KEYS = ['glow', 'steel', 'gold', 'fire', 'ice', 'neon', 'rainbow', 'galaxy', 'thunder', 'bullets', 'blade', 'legend'];

  var st = document.createElement('style');
  st.textContent = '.fxc{position:absolute;inset:0;width:100%;height:100%;z-index:0;pointer-events:none;border-radius:inherit}' +
    '.fx-live .sqp,.fx-live .fxp{display:none!important}';
  document.head.appendChild(st);

  var R = function (a, b) { return a + Math.random() * (b - a); };
  var TAU = Math.PI * 2;

  // ── sprites: a soft round glow per colour, rendered once ──
  var sprites = {};
  function glow(color) {
    if (sprites[color]) return sprites[color];
    var s = 32, c = document.createElement('canvas'); c.width = c.height = s;
    var g = c.getContext('2d'), gr = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 2);
    gr.addColorStop(0, color); gr.addColorStop(0.25, color); gr.addColorStop(1, 'rgba(0,0,0,0)');
    g.fillStyle = gr; g.globalAlpha = 1; g.fillRect(0, 0, s, s);
    // white-hot core
    var gc = g.createRadialGradient(s / 2, s / 2, 0, s / 2, s / 2, s / 6);
    gc.addColorStop(0, 'rgba(255,255,255,.9)'); gc.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = gc; g.fillRect(0, 0, s, s);
    return (sprites[color] = c);
  }
  function dot(ctx, color, x, y, size, a) {
    if (a <= 0) return;
    ctx.globalAlpha = Math.min(1, a);
    ctx.drawImage(glow(color), x - size, y - size, size * 2, size * 2);
  }
  function star4(ctx, color, x, y, r, a) {
    ctx.globalAlpha = Math.min(1, a); ctx.strokeStyle = color; ctx.lineWidth = 1.2;
    ctx.beginPath(); ctx.moveTo(x - r, y); ctx.lineTo(x + r, y); ctx.moveTo(x, y - r); ctx.lineTo(x, y + r); ctx.stroke();
    dot(ctx, color, x, y, r * 0.7, a);
  }

  // ── effects: spawn rate (per second), spawn(), step() → alive?, draw(), optional frame() for set pieces ──
  var FX = {
    // soft warm motes drifting up
    glow: { rate: 7,
      spawn: function (I) { return { x: R(0, I.w), y: I.h + 6, vx: R(-6, 6), vy: -R(10, 22), l: 0, m: R(2.4, 4), s: R(5, 10) }; },
      step: function (I, p, dt) { p.x += p.vx * dt; p.y += p.vy * dt; return (p.l += dt) < p.m; },
      draw: function (I, ctx, p) { dot(ctx, I.c1, p.x, p.y, p.s, Math.sin(Math.PI * p.l / p.m) * 0.5); } },

    // grinder sparks: short bursts off the edge, falling with gravity
    steel: { rate: 0,
      frame: function (I, ctx, dt) {
        if ((I.t1 = (I.t1 || 0) - dt) <= 0) {
          I.t1 = R(0.9, 2);
          var x = R(I.w * 0.15, I.w * 0.85), y = Math.random() < 0.5 ? 0 : I.h;
          for (var k = 0; k < 12 && I.p.length < CAP; k++) I.p.push({ x: x, y: y, vx: R(-110, 110), vy: (y ? -1 : 1) * R(40, 150), l: 0, m: R(0.35, 0.8), g: 320 });
        }
      },
      step: function (I, p, dt) { p.vy += p.g * dt; p.x += p.vx * dt; p.y += p.vy * dt; return (p.l += dt) < p.m; },
      draw: function (I, ctx, p) {
        var a = 1 - p.l / p.m; ctx.globalAlpha = a; ctx.strokeStyle = '#F4F7FB'; ctx.lineWidth = 1.2;
        ctx.beginPath(); ctx.moveTo(p.x, p.y); ctx.lineTo(p.x - p.vx * 0.035, p.y - p.vy * 0.035); ctx.stroke();
        dot(ctx, I.c1, p.x, p.y, 3, a * 0.8);
      } },

    // champion: gold glints popping across the card + rising gold dust
    gold: { rate: 9,
      spawn: function (I) {
        return Math.random() < 0.35
          ? { k: 1, x: R(0, I.w), y: R(0, I.h), l: 0, m: R(0.7, 1.2), s: R(4, 8) }
          : { k: 0, x: R(0, I.w), y: I.h + 4, vy: -R(14, 30), l: 0, m: R(1.8, 3), s: R(2, 4) };
      },
      step: function (I, p, dt) { if (!p.k) p.y += p.vy * dt; return (p.l += dt) < p.m; },
      draw: function (I, ctx, p) {
        var a = Math.sin(Math.PI * p.l / p.m);
        if (p.k) star4(ctx, '#FFF4C2', p.x, p.y, p.s * a + 1, a); else dot(ctx, I.c1, p.x, p.y, p.s, a * 0.7);
      } },

    // embers rising out of a heat glow, white-hot to orange to red
    fire: { rate: 26,
      spawn: function (I) { return { x: R(0, I.w), y: I.h + 4, vx: R(-8, 8), vy: -R(35, 80), ph: R(0, TAU), l: 0, m: R(0.8, 1.7), s: R(3, 6.5) }; },
      step: function (I, p, dt) { p.vx += Math.sin(I.t * 7 + p.ph) * 60 * dt; p.x += p.vx * dt; p.y += p.vy * dt; return (p.l += dt) < p.m; },
      draw: function (I, ctx, p) {
        var f = p.l / p.m, c = f < 0.25 ? '#FFF1A8' : f < 0.55 ? '#FFB347' : f < 0.8 ? '#FF6B3D' : '#C1351B';
        dot(ctx, c, p.x, p.y, p.s * (1 - f * 0.5), (1 - f) * 0.95);
      },
      frame: function (I, ctx) {
        var g = ctx.createLinearGradient(0, I.h, 0, I.h * 0.45), a = 0.18 + Math.sin(I.t * 9) * 0.04 + Math.sin(I.t * 23) * 0.03;
        g.addColorStop(0, 'rgba(255,110,40,' + a + ')'); g.addColorStop(1, 'rgba(255,110,40,0)');
        ctx.globalAlpha = 1; ctx.fillStyle = g; ctx.fillRect(0, I.h * 0.45, I.w, I.h * 0.55);
      } },

    // snowflakes swaying down, with frost sparkles
    ice: { rate: 8,
      spawn: function (I) { return Math.random() < 0.2 ? { k: 1, x: R(0, I.w), y: R(0, I.h), l: 0, m: R(0.6, 1), s: R(3, 5) } : { k: 0, x: R(0, I.w), y: -6, vy: R(14, 30), ph: R(0, TAU), r: R(0, TAU), vr: R(-1.5, 1.5), s: R(2.2, 4.5), l: 0, m: 99 }; },
      step: function (I, p, dt) { if (p.k) return (p.l += dt) < p.m; p.y += p.vy * dt; p.x += Math.sin(I.t * 1.6 + p.ph) * 12 * dt; p.r += p.vr * dt; return p.y < I.h + 8; },
      draw: function (I, ctx, p) {
        if (p.k) return star4(ctx, '#EAFFFF', p.x, p.y, p.s, Math.sin(Math.PI * p.l / p.m));
        ctx.globalAlpha = 0.85; ctx.strokeStyle = '#EAFFFF'; ctx.lineWidth = 1;
        ctx.beginPath();
        for (var k = 0; k < 3; k++) { var a = p.r + k * Math.PI / 3, dx = Math.cos(a) * p.s, dy = Math.sin(a) * p.s; ctx.moveTo(p.x - dx, p.y - dy); ctx.lineTo(p.x + dx, p.y + dy); }
        ctx.stroke(); dot(ctx, I.c1, p.x, p.y, p.s * 1.2, 0.35);
      } },

    // two light runners chasing round the card edge, leaving neon trails
    neon: { rate: 3,
      spawn: function (I) { return { x: R(0, I.w), y: R(0, I.h), l: 0, m: R(0.8, 1.4), s: R(2, 4) }; },
      step: function (I, p, dt) { return (p.l += dt) < p.m; },
      draw: function (I, ctx, p) { dot(ctx, I.c2, p.x, p.y, p.s, Math.sin(Math.PI * p.l / p.m) * 0.6); },
      frame: function (I, ctx, dt) {
        var per = 2 * (I.w + I.h); I.run = ((I.run || 0) + dt * per * 0.28) % per;
        for (var r = 0; r < 2; r++) for (var k = 0; k < 14; k++) {
          var d = (I.run + r * per / 2 - k * 6 + per) % per, pt = edge(I, d);
          dot(ctx, r ? I.c2 : I.c1, pt[0], pt[1], 6 - k * 0.3, (1 - k / 14) * 0.9);
        }
      } },

    // prism shards tumbling down in every colour
    rainbow: { rate: 10,
      spawn: function (I) { return { x: R(0, I.w), y: -6, vy: R(22, 45), vx: R(-10, 10), r: R(0, TAU), vr: R(-4, 4), h: R(0, 360), s: R(3, 6) }; },
      step: function (I, p, dt) { p.x += p.vx * dt; p.y += p.vy * dt; p.r += p.vr * dt; p.h = (p.h + 90 * dt) % 360; return p.y < I.h + 8; },
      draw: function (I, ctx, p) {
        ctx.save(); ctx.translate(p.x, p.y); ctx.rotate(p.r); ctx.globalAlpha = 0.85; ctx.fillStyle = 'hsl(' + (p.h | 0) + ',95%,65%)';
        ctx.fillRect(-p.s / 2, -p.s * 0.3, p.s, p.s * 0.6); ctx.restore();
      } },

    // drifting star field + shooting stars
    galaxy: { rate: 0,
      frame: function (I, ctx, dt) {
        if (!I.stars) { I.stars = []; for (var k = 0; k < (low ? 18 : 30); k++) I.stars.push({ x: R(0, I.w), y: R(0, I.h), s: R(0.8, 2.4), v: R(3, 12), ph: R(0, TAU) }); }
        for (var i = 0; i < I.stars.length; i++) {
          var s = I.stars[i]; s.x -= s.v * dt; if (s.x < -4) { s.x = I.w + 4; s.y = R(0, I.h); }
          dot(ctx, i % 3 ? '#D9CCFF' : '#C4F3FF', s.x, s.y, s.s * 2, 0.45 + 0.4 * Math.sin(I.t * 2 + s.ph));
        }
        if ((I.t1 = (I.t1 || R(1, 2)) - dt) <= 0) { I.t1 = R(2.2, 4.5); I.shot = { x: R(I.w * 0.3, I.w * 1.1), y: R(-10, I.h * 0.3), l: 0 }; }
        var sh = I.shot;
        if (sh && (sh.l += dt) < 0.7) {
          var hx = sh.x - sh.l * 420, hy = sh.y + sh.l * 160, g = ctx.createLinearGradient(hx, hy, hx + 70, hy - 27);
          g.addColorStop(0, 'rgba(255,255,255,.95)'); g.addColorStop(1, 'rgba(255,255,255,0)');
          ctx.globalAlpha = 1 - sh.l / 0.7; ctx.strokeStyle = g; ctx.lineWidth = 1.6;
          ctx.beginPath(); ctx.moveTo(hx, hy); ctx.lineTo(hx + 70, hy - 27); ctx.stroke(); dot(ctx, '#FFFFFF', hx, hy, 4, 1 - sh.l / 0.7);
        }
      } },

    // branching lightning strikes with a flash, plus crackling sparks
    thunder: { rate: 5,
      spawn: function (I) { return { x: R(0, I.w), y: R(0, I.h), l: 0, m: R(0.15, 0.35), s: R(2, 4) }; },
      step: function (I, p, dt) { return (p.l += dt) < p.m; },
      draw: function (I, ctx, p) { dot(ctx, I.c1, p.x + R(-2, 2), p.y + R(-2, 2), p.s, 1 - p.l / p.m); },
      frame: function (I, ctx, dt) {
        if ((I.t1 = (I.t1 === undefined ? 0.4 : I.t1) - dt) <= 0) { I.t1 = R(1.3, 3); I.bolt = { pts: bolt(R(I.w * 0.1, I.w * 0.9), -4, R(I.w * 0.1, I.w * 0.9), I.h + 4, low ? 4 : 5), br: [], l: 0 }; var b = I.bolt.pts, j = (b.length / 3) | 0; I.bolt.br.push(bolt(b[j][0], b[j][1], b[j][0] + R(-60, 60), I.h * R(0.6, 1), 3)); }
        var B = I.bolt; if (!B || (B.l += dt) > 0.42) return;
        var a = (1 - B.l / 0.42) * (Math.random() < 0.25 ? 0.4 : 1);
        if (B.l < 0.1) { ctx.globalAlpha = 0.16 * (1 - B.l / 0.1); ctx.fillStyle = '#CFF4FF'; ctx.fillRect(0, 0, I.w, I.h); }
        [B.pts].concat(B.br).forEach(function (pts, n) {
          ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1]); for (var i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
          ctx.globalAlpha = a * 0.3; ctx.strokeStyle = I.c1; ctx.lineWidth = n ? 3 : 6; ctx.stroke();
          ctx.globalAlpha = a; ctx.strokeStyle = '#FFFFFF'; ctx.lineWidth = n ? 1 : 1.8; ctx.stroke();
        });
      } },

    // tracer rounds zipping across + brass shell casings ejecting and falling
    bullets: { rate: 2.4,
      spawn: function (I) { return { k: 1, x: R(I.w * 0.55, I.w * 0.95), y: R(0, I.h * 0.4), vx: R(-50, 50), vy: -R(70, 130), r: 0, vr: R(-14, 14), g: 420 }; },
      step: function (I, p, dt) { p.vy += p.g * dt; p.x += p.vx * dt; p.y += p.vy * dt; p.r += p.vr * dt; return p.y < I.h + 10; },
      draw: function (I, ctx, p) {
        ctx.save(); ctx.translate(p.x, p.y); ctx.rotate(p.r); ctx.globalAlpha = 0.95;
        ctx.fillStyle = '#C9902F'; ctx.fillRect(-1.8, -4, 3.6, 8); ctx.fillStyle = '#FFE19A'; ctx.fillRect(-1.8, -4, 1.2, 8); ctx.restore();
      },
      frame: function (I, ctx, dt) {
        I.tr = I.tr || [];
        if ((I.t1 = (I.t1 || 0) - dt) <= 0) { I.t1 = R(0.18, 0.55); I.tr.push({ y: R(I.h * 0.15, I.h * 0.85), x: -40, v: R(700, 1000) }); I.flash = 0.06; }
        for (var i = I.tr.length - 1; i >= 0; i--) {
          var t = I.tr[i]; t.x += t.v * dt;
          if (!t.hit && t.x >= I.w - 4) { t.hit = true; burst(I, I.w - 3, t.y, 6, true); } // impact sparks on the edge
          if (t.x > I.w + 80) { I.tr.splice(i, 1); continue; }
          var g = ctx.createLinearGradient(t.x - 70, t.y, t.x, t.y); g.addColorStop(0, 'rgba(255,170,60,0)'); g.addColorStop(1, 'rgba(255,236,170,1)');
          ctx.globalAlpha = 1; ctx.strokeStyle = g; ctx.lineWidth = 2; ctx.beginPath(); ctx.moveTo(t.x - 70, t.y); ctx.lineTo(t.x, t.y); ctx.stroke();
          dot(ctx, I.c1, t.x, t.y, 5, 0.9);
        }
        if (I.flash > 0) { I.flash -= dt; dot(ctx, '#FFD27A', 6, I.h / 2, 26, I.flash * 10); }
      } },

    // fast blade slashes across the card that throw sparks
    blade: { rate: 0,
      frame: function (I, ctx, dt) {
        if ((I.t1 = (I.t1 === undefined ? 0.5 : I.t1) - dt) <= 0) {
          I.t1 = R(1.4, 2.6);
          var ltr = Math.random() < 0.5, x0 = ltr ? -10 : I.w + 10, x1 = ltr ? I.w + 10 : -10, y0 = R(-10, I.h * 0.4), y1 = R(I.h * 0.6, I.h + 10);
          I.slash = { x0: x0, y0: y0, x1: x1, y1: y1, cx: (x0 + x1) / 2 + R(-30, 30), cy: (y0 + y1) / 2 + (ltr ? -1 : 1) * R(20, 50), l: 0 };
          for (var k = 0; k < 14 && I.p.length < CAP; k++) { var u = R(0.2, 0.8), pt = quad(I.slash, u); I.p.push({ x: pt[0], y: pt[1], vx: R(-120, 120), vy: R(-140, 40), l: 0, m: R(0.3, 0.7), g: 300, d: 0.12 + u * 0.15 }); }
        }
        var S = I.slash; if (!S || (S.l += dt) > 0.55) return;
        var reveal = Math.min(1, S.l / 0.12), fade = S.l < 0.12 ? 1 : 1 - (S.l - 0.12) / 0.43;
        ctx.beginPath(); ctx.moveTo(S.x0, S.y0);
        for (var i = 1; i <= 16; i++) { var q = quad(S, reveal * i / 16); ctx.lineTo(q[0], q[1]); }
        ctx.globalAlpha = fade * 0.35; ctx.strokeStyle = I.c1; ctx.lineWidth = 9; ctx.stroke();
        ctx.globalAlpha = fade; ctx.strokeStyle = '#FFFFFF'; ctx.lineWidth = 2; ctx.stroke();
      },
      step: function (I, p, dt) { if ((p.d -= dt) > 0) return true; p.vy += p.g * dt; p.x += p.vx * dt; p.y += p.vy * dt; return (p.l += dt) < p.m; },
      draw: function (I, ctx, p) { if (p.d > 0) return; var a = 1 - p.l / p.m; ctx.globalAlpha = a; ctx.strokeStyle = Math.random() < 0.5 ? '#FFFFFF' : I.c1; ctx.lineWidth = 1.2; ctx.beginPath(); ctx.moveTo(p.x, p.y); ctx.lineTo(p.x - p.vx * 0.03, p.y - p.vy * 0.03); ctx.stroke(); } },

    // holographic diamonds rising, colour shifting, with sparkle bursts
    legend: { rate: 8,
      spawn: function (I) { return { x: R(0, I.w), y: I.h + 6, vy: -R(18, 40), vx: R(-6, 6), r: R(0, TAU), vr: R(-2, 2), h: R(0, 360), s: R(3, 6.5), l: 0, m: R(1.6, 2.8) }; },
      step: function (I, p, dt) { p.x += p.vx * dt; p.y += p.vy * dt; p.r += p.vr * dt; p.h = (p.h + 120 * dt) % 360; return (p.l += dt) < p.m; },
      draw: function (I, ctx, p) {
        var a = Math.sin(Math.PI * p.l / p.m);
        ctx.save(); ctx.translate(p.x, p.y); ctx.rotate(Math.PI / 4 + p.r * 0.2);
        ctx.globalAlpha = a * 0.25; ctx.fillStyle = 'hsl(' + (p.h | 0) + ',100%,75%)'; ctx.fillRect(-p.s * 1.6, -p.s * 1.6, p.s * 3.2, p.s * 3.2);
        ctx.globalAlpha = a * 0.95; ctx.fillRect(-p.s / 2, -p.s / 2, p.s, p.s); ctx.restore();
      },
      frame: function (I, ctx, dt) {
        if ((I.t1 = (I.t1 === undefined ? 1 : I.t1) - dt) <= 0) { I.t1 = R(1.3, 2.4); I.burst = { x: R(I.w * 0.15, I.w * 0.85), y: R(I.h * 0.2, I.h * 0.8), l: 0 }; }
        var B = I.burst; if (!B || (B.l += dt) > 0.6) return;
        for (var k = 0; k < 8; k++) { var a = k * TAU / 8, d = 4 + B.l * 70; star4(ctx, '#FFF6D6', B.x + Math.cos(a) * d, B.y + Math.sin(a) * d, 3, 1 - B.l / 0.6); }
      } }
  };

  // point d px along the card's edge (clockwise from top-left), inset 2px
  function edge(I, d) {
    var w = I.w - 4, h = I.h - 4;
    if (d < w) return [2 + d, 2]; d -= w;
    if (d < h) return [I.w - 2, 2 + d]; d -= h;
    if (d < w) return [I.w - 2 - d, I.h - 2]; d -= w;
    return [2, I.h - 2 - Math.min(d, h)];
  }
  function quad(S, u) { var v = 1 - u; return [v * v * S.x0 + 2 * v * u * S.cx + u * u * S.x1, v * v * S.y0 + 2 * v * u * S.cy + u * u * S.y1]; }
  // jagged lightning by midpoint displacement
  function bolt(x0, y0, x1, y1, depth) {
    var pts = [[x0, y0], [x1, y1]], off = Math.abs(x1 - x0) * 0.3 + 26;
    for (var d = 0; d < depth; d++) {
      var nx = [pts[0]];
      for (var i = 1; i < pts.length; i++) { var a = pts[i - 1], b = pts[i]; nx.push([(a[0] + b[0]) / 2 + R(-off, off), (a[1] + b[1]) / 2 + R(-off * 0.3, off * 0.3)], b); }
      pts = nx; off *= 0.55;
    }
    return pts;
  }

  // ── scenery behind the particles: one set piece per effect, cheap (a few big sprites or one gradient) ──
  var AURA = {
    // Galaxy: slow nebula clouds in the effect's two colours
    galaxy: function (I, ctx) {
      if (!I.neb) { I.neb = []; for (var k = 0; k < 3; k++) I.neb.push({ x: R(0, I.w), y: R(0, I.h), r: R(I.h * 0.7, I.h * 1.3), v: R(-6, 6), c: k % 2 ? I.c2 : I.c1 }); }
      for (var i = 0; i < I.neb.length; i++) { var n = I.neb[i]; n.x += n.v * 0.016; if (n.x < -n.r) n.x = I.w + n.r; if (n.x > I.w + n.r) n.x = -n.r; dot(ctx, n.c, n.x, n.y, n.r, 0.13 + 0.05 * Math.sin(I.t * 0.7 + i)); }
    },
    // Legend: light rays turning slowly out from the squad logo
    legend: function (I, ctx) {
      var cx = Math.min(70, I.w * 0.2), cy = I.h / 2, L = I.w * 1.1;
      ctx.save(); ctx.translate(cx, cy); ctx.rotate(I.t * 0.25);
      for (var k = 0; k < 6; k++) {
        ctx.rotate(TAU / 6); ctx.globalAlpha = 0.07 + 0.03 * Math.sin(I.t * 1.5 + k);
        ctx.fillStyle = 'hsl(' + (((I.t * 40) + k * 60) % 360 | 0) + ',100%,80%)';
        ctx.beginPath(); ctx.moveTo(0, 0); ctx.lineTo(L, -L * 0.07); ctx.lineTo(L, L * 0.07); ctx.closePath(); ctx.fill();
      }
      ctx.restore();
    },
    // Champion: a bright gold sweep across the card every few seconds
    gold: function (I, ctx, dt) {
      I.sw = (I.sw === undefined ? R(0, 3) : I.sw) + dt; var u = (I.sw % 3.2) / 0.9; if (u > 1) return;
      var x = -I.w * 0.3 + u * I.w * 1.6, g = ctx.createLinearGradient(x - 50, 0, x + 50, 0);
      g.addColorStop(0, 'rgba(255,220,120,0)'); g.addColorStop(0.5, 'rgba(255,236,170,.35)'); g.addColorStop(1, 'rgba(255,220,120,0)');
      ctx.globalAlpha = 1; ctx.fillStyle = g; ctx.fillRect(0, 0, I.w, I.h);
    },
    // Frozen: cold mist hanging along the top
    ice: function (I, ctx) {
      var g = ctx.createLinearGradient(0, 0, 0, I.h * 0.6), a = 0.14 + 0.04 * Math.sin(I.t * 1.3);
      g.addColorStop(0, 'rgba(180,235,255,' + a + ')'); g.addColorStop(1, 'rgba(180,235,255,0)');
      ctx.globalAlpha = 1; ctx.fillStyle = g; ctx.fillRect(0, 0, I.w, I.h * 0.6);
    },
    // Thunder: small sparks crawling along the card edge between strikes
    thunder: function (I, ctx, dt) {
      if ((I.ea = (I.ea || 0) - dt) <= 0) { I.ea = R(0.12, 0.4); var per = 2 * (I.w + I.h), d = R(0, per), a = edge(I, d), b = edge(I, (d + R(18, 40)) % per); I.arc = { pts: bolt(a[0], a[1], b[0], b[1], 3), l: 0 }; }
      var A = I.arc; if (!A || (A.l += dt) > 0.16) return;
      ctx.beginPath(); ctx.moveTo(A.pts[0][0], A.pts[0][1]); for (var i = 1; i < A.pts.length; i++) ctx.lineTo(A.pts[i][0], A.pts[i][1]);
      ctx.globalAlpha = 0.9 * (1 - A.l / 0.16); ctx.strokeStyle = '#E8FBFF'; ctx.lineWidth = 1.2; ctx.stroke();
    },
    // Fire: every so often the flames flare up
    fire: function (I, ctx, dt) {
      if ((I.fl = (I.fl === undefined ? R(1, 3) : I.fl) - dt) <= 0) { I.fl = R(2.5, 5); burst(I, R(I.w * 0.2, I.w * 0.8), I.h, 14, true); }
    }
  };

  // ── bursts: tap a card (or let it scroll into view) and it explodes in its own style ──
  var BURST = {
    fire: { g: -60, c: ['#FFF1A8', '#FFB347', '#FF6B3D'] }, ice: { g: 30, c: ['#EAFFFF', '#5FD3FF', '#FFFFFF'] },
    thunder: { g: 0, c: ['#FFFFFF', '#9EEAFF', '#4FD8FF'], spark: true }, bullets: { g: 260, c: ['#FFE19A', '#FFB347', '#FF7A1A'], spark: true },
    blade: { g: 200, c: ['#FFFFFF', '#FF5A6A', '#C9D2DE'], spark: true }, steel: { g: 300, c: ['#FFFFFF', '#CFD8E3'], spark: true },
    legend: { g: -20, hue: true }, rainbow: { g: 80, hue: true }, galaxy: { g: 0, c: ['#FFFFFF', '#D9CCFF', '#C4F3FF'] }
  };
  function burst(I, x, y, n, quiet) {
    var B = BURST[I.key] || { g: 40, c: [I.c1, I.c2, '#FFFFFF'] };
    I.b = I.b || []; I.rings = I.rings || [];
    for (var k = 0; k < n && I.b.length < (low ? 30 : 60); k++) {
      var a = quiet ? R(-Math.PI * 0.9, -Math.PI * 0.1) : R(0, TAU), v = R(quiet ? 40 : 70, quiet ? 120 : 260);
      I.b.push({ x: x, y: y, vx: Math.cos(a) * v, vy: Math.sin(a) * v, l: 0, m: R(0.45, 0.95), s: R(2.5, 5), g: B.g,
        c: B.hue ? 'hsl(' + (R(0, 360) | 0) + ',100%,72%)' : (B.c ? B.c[k % B.c.length] : I.c1), spark: B.spark });
    }
    if (!quiet) I.rings.push({ x: x, y: y, l: 0 });
    wake();
  }
  function drawBursts(I, ctx, dt) {
    var b = I.b, rg = I.rings;
    if (rg) for (var i = rg.length - 1; i >= 0; i--) {
      var r = rg[i]; if ((r.l += dt) > 0.5) { rg.splice(i, 1); continue; }
      ctx.globalAlpha = 0.7 * (1 - r.l / 0.5); ctx.strokeStyle = I.c2; ctx.lineWidth = 2;
      ctx.beginPath(); ctx.arc(r.x, r.y, 6 + r.l * 160, 0, TAU); ctx.stroke();
    }
    if (b) for (var j = b.length - 1; j >= 0; j--) {
      var p = b[j]; if ((p.l += dt) > p.m) { b.splice(j, 1); continue; }
      p.vx *= 0.97; p.vy = p.vy * 0.97 + p.g * dt; p.x += p.vx * dt; p.y += p.vy * dt;
      var a2 = 1 - p.l / p.m;
      if (p.spark) { ctx.globalAlpha = a2; ctx.strokeStyle = p.c; ctx.lineWidth = 1.4; ctx.beginPath(); ctx.moveTo(p.x, p.y); ctx.lineTo(p.x - p.vx * 0.03, p.y - p.vy * 0.03); ctx.stroke(); }
      else if (p.c.charAt(0) === 'h') { ctx.globalAlpha = a2; ctx.fillStyle = p.c; ctx.fillRect(p.x - p.s / 2, p.y - p.s / 2, p.s, p.s); }
      else dot(ctx, p.c, p.x, p.y, p.s * 1.6, a2);
    }
  }

  // ── instances ──
  var live = [], byEl = new WeakMap(), io = null, running = false, last = 0;
  function keyOf(el) {
    for (var i = 0; i < el.classList.length; i++) {
      var c = el.classList[i], m = /^sqfx-([a-z]+)$/.exec(c);
      if (m && KEYS.indexOf(m[1]) >= 0) return m[1];
    }
    return null;
  }
  function colors(I) {
    var cs = getComputedStyle(I.el);
    I.c1 = (cs.getPropertyValue('--fx1') || '').trim() || '#FFC83D';
    I.c2 = (cs.getPropertyValue('--fx2') || '').trim() || '#FFF1B8';
  }
  function size(I) {
    var r = I.el.getBoundingClientRect(), w = Math.max(1, Math.round(r.width)), h = Math.max(1, Math.round(r.height));
    if (w === I.w && h === I.h) return;
    I.w = w; I.h = h; I.cv.width = Math.round(w * DPR); I.cv.height = Math.round(h * DPR);
    I.ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
  }
  function mount(el) {
    var key = keyOf(el); if (!key) return;
    var I = byEl.get(el);
    if (I && I.key === key && I.cv.parentNode === el) return;
    if (I) unmount(I);
    var cv = document.createElement('canvas'); cv.className = 'fxc'; cv.setAttribute('aria-hidden', 'true');
    el.insertBefore(cv, el.firstChild); el.classList.add('fx-live');
    I = { el: el, key: key, fx: FX[key], cv: cv, ctx: cv.getContext('2d'), w: 0, h: 0, p: [], t: R(0, 10), acc: 0, vis: false, entered: false };
    colors(I); size(I);
    // tap / click: the card bursts where you touched it (doesn't block the card's own buttons)
    I.tap = function (e) { var r = el.getBoundingClientRect(); burst(I, e.clientX - r.left, e.clientY - r.top, low ? 18 : 30); };
    el.addEventListener('pointerdown', I.tap, { passive: true });
    byEl.set(el, I); live.push(I);
    io.observe(el);
  }
  function unmount(I) {
    io.unobserve(I.el); I.el.removeEventListener('pointerdown', I.tap); if (I.cv.parentNode) I.cv.parentNode.removeChild(I.cv);
    I.el.classList.remove('fx-live'); byEl.delete(I.el);
    var i = live.indexOf(I); if (i >= 0) live.splice(i, 1);
  }
  function scan() {
    for (var i = live.length - 1; i >= 0; i--) { var I = live[i]; if (!I.el.isConnected || keyOf(I.el) !== I.key) unmount(I); }
    var els = document.querySelectorAll('.sqfx');
    for (var j = 0; j < els.length; j++) mount(els[j]);
    wake();
  }

  function frame(now) {
    running = false;
    var any = false;
    for (var i = 0; i < live.length; i++) if (live[i].vis) { any = true; break; }
    if (!any || document.hidden) return;   // sleep; woken by the observers
    running = true; requestAnimationFrame(frame);
    if (STEP && now - last < STEP - 1) return;
    var dt = Math.min(0.05, (now - (last || now)) / 1000); last = now;
    for (var k = 0; k < live.length; k++) {
      var I = live[k]; if (!I.vis) continue;
      if (!I.el.isConnected) continue;
      size(I);
      var ctx = I.ctx, fx = I.fx; I.t += dt;
      ctx.globalCompositeOperation = 'source-over'; ctx.globalAlpha = 1; ctx.clearRect(0, 0, I.w, I.h);
      ctx.globalCompositeOperation = 'lighter';
      if (AURA[I.key]) AURA[I.key](I, ctx, dt);
      if (fx.rate) { I.acc += fx.rate * dt; while (I.acc >= 1) { I.acc -= 1; if (I.p.length < CAP) I.p.push(fx.spawn(I)); } }
      if (fx.frame) fx.frame(I, ctx, dt);
      for (var n = I.p.length - 1; n >= 0; n--) { var p = I.p[n]; if (!fx.step(I, p, dt)) { I.p.splice(n, 1); continue; } fx.draw(I, ctx, p); }
      drawBursts(I, ctx, dt);
    }
  }
  function wake() { if (!running && !document.hidden) { running = true; last = 0; requestAnimationFrame(frame); } }

  function start() {
    io = new IntersectionObserver(function (es) {
      es.forEach(function (e) {
        var I = byEl.get(e.target); if (!I) return;
        I.vis = e.isIntersecting;
        if (I.vis) {
          colors(I); size(I);
          // first time on screen: a burst from the squad logo, staggered so a list ripples
          if (!I.entered) { I.entered = true; var d = Math.min(900, live.indexOf(I) * 90); setTimeout(function () { if (I.vis) burst(I, Math.min(70, I.w * 0.2), I.h / 2, low ? 14 : 24); }, d); }
        }
      });
      wake();
    }, { rootMargin: '60px' });
    var t = null;
    new MutationObserver(function () { clearTimeout(t); t = setTimeout(scan, 120); }).observe(document.body, { childList: true, subtree: true });
    document.addEventListener('visibilitychange', wake);
    scan();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
  window.jdFx = { scan: scan, count: function () { return live.length; } };
})();
