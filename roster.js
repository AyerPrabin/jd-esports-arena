/* The public squad list without re-downloading pictures (roster_lite.sql, 8 Nov 2026).
   jdRoster(sb) answers like sb.rpc('get_public_roster'): {data:[{tournament_slug, squad_name, squad_logo, ...}], error}.
   Logos come by md5 key and stay on this phone, so each one downloads once instead of on every open
   (the old call sent all of them, 937 KB, every time). Falls back to the old call if the new SQL is missing. */
(function () {
  var LK = 'jd_logos_v1', mem = null;
  function load() {
    if (mem) return mem;
    try { mem = JSON.parse(localStorage.getItem(LK) || '{}') || {}; } catch (e) { mem = {}; }
    return mem;
  }
  function save(keep) {
    var o = {};
    keep.forEach(function (k) { if (mem[k]) o[k] = mem[k]; });   // drop logos no squad uses any more
    mem = o;
    try { localStorage.setItem(LK, JSON.stringify(o)); } catch (e) {}
  }
  window.jdRoster = async function (sb) {
    var r = await sb.rpc('get_public_roster_lite');
    if (r.error) return r.error.code === 'PGRST202' ? sb.rpc('get_public_roster') : r;
    var rows = r.data || [], c = load(), keys = {}, need = [];
    rows.forEach(function (x) { if (x.logo_key) keys[x.logo_key] = 1; });
    Object.keys(keys).forEach(function (k) { if (!c[k]) need.push(k); });
    for (var i = 0; i < need.length; i += 60) {
      var g = await sb.rpc('get_logos', { p_keys: need.slice(i, i + 60) });
      (g.data || []).forEach(function (x) { c[x.k] = x.logo; });
    }
    if (need.length || Object.keys(c).length > Object.keys(keys).length) save(Object.keys(keys));
    return { data: rows.map(function (x) { x.squad_logo = (x.logo_key && c[x.logo_key]) || null; return x; }), error: null };
  };
})();
