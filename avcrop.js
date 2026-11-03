/* Profile picture crop & zoom. jdCropAvatar(file) opens a sheet: drag to move, slider / pinch / wheel to zoom,
   then resolves to a square JPEG Blob (256 px), or null if the player cancels. No upload happens here. */
(function () {
  var OUT = 256, VIEW = 280;
  var css = '.avc-ov{position:fixed;inset:0;z-index:9999;display:grid;place-items:center;padding:16px;background:rgba(3,5,10,.78);backdrop-filter:blur(6px)}' +
    '.avc{width:min(340px,100%);padding:18px;border-radius:22px;background:#111827;border:1px solid rgba(255,200,80,.35);color:#fff;font:14px/1.4 system-ui,sans-serif;text-align:center}' +
    '.avc h3{margin:0 0 4px;font-size:1.05rem}.avc p{margin:0 0 12px;font-size:.78rem;color:#A6AFC2}' +
    '.avc-st{position:relative;width:' + VIEW + 'px;max-width:100%;aspect-ratio:1;margin:0 auto;border-radius:18px;overflow:hidden;background:#000;touch-action:none;cursor:grab}' +
    '.avc-st canvas{display:block;width:100%;height:100%}.avc-st:active{cursor:grabbing}' +
    '.avc-st::after{content:"";position:absolute;inset:0;border-radius:50%;box-shadow:0 0 0 999px rgba(0,0,0,.55);border:2px solid rgba(255,200,61,.9);pointer-events:none}' +
    '.avc input[type=range]{width:100%;margin:14px 0 4px;accent-color:#FFC83D}' +
    '.avc-b{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:10px}.avc-b button{font:inherit;padding:12px;border-radius:12px;font-weight:800;font-size:.9rem;cursor:pointer;border:1px solid rgba(255,200,80,.42);background:none;color:#FFDD85}' +
    '.avc-b button.ok{border:0;background:linear-gradient(100deg,#FFC83D,#FFAE00);color:#0a0a12}';
  window.jdCropAvatar = function (file) {
    return new Promise(function (done) {
      if (!file || !/^image\//.test(file.type)) { done(null); return; }
      if (!document.getElementById('avc-css')) { var st = document.createElement('style'); st.id = 'avc-css'; st.textContent = css; document.head.appendChild(st); }
      var url = URL.createObjectURL(file), img = new Image();
      img.onerror = function () { URL.revokeObjectURL(url); done(null); };
      img.onload = function () {
        var ov = document.createElement('div'); ov.className = 'avc-ov';
        ov.innerHTML = '<div class="avc" role="dialog" aria-modal="true" aria-label="Adjust your profile picture"><h3>Adjust your picture</h3><p>Drag to move. Zoom to fit your face in the circle.</p>' +
          '<div class="avc-st"><canvas width="' + OUT + '" height="' + OUT + '"></canvas></div>' +
          '<input type="range" min="1" max="4" step="0.01" value="1" aria-label="Zoom">' +
          '<div class="avc-b"><button type="button" data-a="no">Cancel</button><button type="button" class="ok" data-a="ok">Use picture</button></div></div>';
        document.body.appendChild(ov);
        var cv = ov.querySelector('canvas'), cx = cv.getContext('2d'), stage = ov.querySelector('.avc-st'), zoom = ov.querySelector('input');
        var base = OUT / Math.min(img.width, img.height), z = 1, x = 0, y = 0;   // x,y: image offset from centre, in output px
        function clamp() {
          var w = img.width * base * z, h = img.height * base * z, mx = Math.max(0, (w - OUT) / 2), my = Math.max(0, (h - OUT) / 2);
          x = Math.max(-mx, Math.min(mx, x)); y = Math.max(-my, Math.min(my, y));
        }
        function draw() {
          clamp(); var w = img.width * base * z, h = img.height * base * z;
          cx.fillStyle = '#000'; cx.fillRect(0, 0, OUT, OUT);
          cx.imageSmoothingQuality = 'high'; cx.drawImage(img, (OUT - w) / 2 + x, (OUT - h) / 2 + y, w, h);
        }
        function setZoom(v) { z = Math.max(1, Math.min(4, v)); zoom.value = z; draw(); }
        var pts = {}, last = null, pinch = null;
        var scale = function () { return OUT / stage.getBoundingClientRect().width; };
        stage.addEventListener('pointerdown', function (e) { stage.setPointerCapture(e.pointerId); pts[e.pointerId] = [e.clientX, e.clientY]; last = [e.clientX, e.clientY]; });
        stage.addEventListener('pointermove', function (e) {
          if (!pts[e.pointerId]) return; pts[e.pointerId] = [e.clientX, e.clientY];
          var ids = Object.keys(pts);
          if (ids.length >= 2) {
            var a = pts[ids[0]], b = pts[ids[1]], d = Math.hypot(a[0] - b[0], a[1] - b[1]);
            if (pinch) setZoom(pinch.z * d / pinch.d); else pinch = { d: d, z: z };
            return;
          }
          var k = scale(); x += (e.clientX - last[0]) * k; y += (e.clientY - last[1]) * k; last = [e.clientX, e.clientY]; draw();
        });
        var up = function (e) { delete pts[e.pointerId]; pinch = null; var r = Object.values(pts)[0]; last = r || null; };
        stage.addEventListener('pointerup', up); stage.addEventListener('pointercancel', up);
        stage.addEventListener('wheel', function (e) { e.preventDefault(); setZoom(z * (e.deltaY < 0 ? 1.08 : 0.93)); }, { passive: false });
        zoom.addEventListener('input', function () { setZoom(+zoom.value); });
        function close(v) { ov.remove(); URL.revokeObjectURL(url); document.removeEventListener('keydown', key); done(v); }
        function key(e) { if (e.key === 'Escape') close(null); }
        document.addEventListener('keydown', key);
        ov.addEventListener('click', function (e) {
          var a = e.target.dataset && e.target.dataset.a;
          if (e.target === ov || a === 'no') close(null);
          else if (a === 'ok') { draw(); cv.toBlob(function (b) { close(b); }, 'image/jpeg', 0.88); }
        });
        draw();
        ov.querySelector('[data-a="ok"]').focus();
      };
      img.src = url;
    });
  };
})();
