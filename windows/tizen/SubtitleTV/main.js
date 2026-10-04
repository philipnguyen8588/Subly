// Subtitle TV: hiện hình HDMI (PS5) bằng tizen.tvwindow và phụ đề dịch từ ScreenTranslator (máy tính, Server-Sent Events).
// Trên TV Samsung (đã thử Q70T, Tizen 5.5), lớp video HDMI luôn nằm TRÊN lớp đồ hoạ của app, nên không vẽ đè lên hình được:
// hình được ép nhẹ chiều cao để chừa một dải đen, phụ đề nằm trong dải đó. Lúc mở menu, hình được tạm ẩn.
//
// Phím theo Samsung Smart Remote (chỉ có vòng điều hướng, OK, Back, ⏯, kênh ∧∨; nút 123 mở bàn phím số ảo):
//   ⏯ = tạm dừng / tiếp tục dịch, OK = dịch toàn màn hình, Back = menu, ◀ ▶ = dải mỏng / dày, ▲ ▼ = cỡ chữ,
//   Kênh ∧ = hiện / ẩn câu gốc, Kênh ∨ = xem lại ảnh đã dịch.
(function () {
  'use strict';

  // ---------- Cài đặt (lưu trên TV) ----------
  var DEFAULTS = {
    servers: [
      { name: 'Mac mini', url: 'http://192.168.8.24:8787' },
      { name: 'PC Windows', url: 'http://192.168.8.22:8787' },
    ],
    server: -1,          // máy đang dùng (-1 = chưa chọn)
    askOnStart: true,    // mở app là hỏi chọn máy
    hdmi: 0,
    band: 110,           // độ dày dải phụ đề (px trên 1080)
    fontScale: 1,
    showSource: false,
    position: 'bottom',  // bottom | top
    hideAfter: 0,        // giây, 0 = không tự ẩn
    voice: true,         // phát giọng đọc máy tính gửi sang (bật "Phát giọng đọc trên TV" trong app máy tính)
    voiceVolume: 100,    // %
  };
  var cfg = load();
  function load() {
    var c = {};
    try { c = JSON.parse(localStorage.getItem('cfg') || '{}'); } catch (e) {}
    var out = {};
    for (var k in DEFAULTS) out[k] = c.hasOwnProperty(k) ? c[k] : JSON.parse(JSON.stringify(DEFAULTS[k]));
    return out;
  }
  function save() { try { localStorage.setItem('cfg', JSON.stringify(cfg)); } catch (e) {} }

  var sub = document.getElementById('sub');
  var menu = document.getElementById('menu');
  var toastEl = document.getElementById('toast');
  var rt = { hdmi: 0, sources: [], sse: 'chưa kết nối', game: '', running: false, analyzing: false, names: true, speakers: [], last: null, menuOpen: false, shotOpen: false };
  var shotEl = document.getElementById('shot');
  var stEl = document.getElementById('st');

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; });
  }
  function host(url) { return url.replace(/^https?:\/\//, ''); }

  var toastTimer = null;
  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.className = cfg.position === 'top' ? 'top' : '';
    toastEl.style.height = Math.min(cfg.band, 40) + 'px';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.className = 'hidden'; }, 3000);
  }

  // ---------- Hình HDMI ----------
  // setSource cần đúng đối tượng SystemInfoVideoSourceInfo lấy từ systeminfo (VIDEOSOURCE), không nhận object tự tạo.
  function withSources(cb) {
    try {
      tizen.systeminfo.getPropertyValue('VIDEOSOURCE', function (vs) { rt.sources = vs.connected || []; cb(); }, function () { cb(); });
    } catch (e) { cb(); }
  }
  function hdmiPorts() { return rt.sources.filter(function (s) { return s.type === 'HDMI'; }).map(function (s) { return s.number; }); }

  function videoRect() {
    var h = 1080 - cfg.band;
    return ['0px', (cfg.position === 'top' ? cfg.band : 0) + 'px', '1920px', h + 'px'];
  }
  function showVideo() {
    if (!rt.hdmi || rt.menuOpen) return;
    try { tizen.tvwindow.show(function () {}, function (e) { toast('Lỗi hiện hình: ' + e.message); }, videoRect(), 'MAIN'); } catch (e) {}
  }
  function hideVideo() { try { tizen.tvwindow.hide(function () {}, function () {}, 'MAIN'); } catch (e) {} }

  function useHdmi(n, quiet) {
    var src = null;
    rt.sources.forEach(function (s) { if (s.type === 'HDMI' && s.number === n) src = s; });
    if (!src) { if (!quiet) toast('HDMI ' + n + ' không có tín hiệu'); return; }
    try {
      tizen.tvwindow.setSource(src, function () {
        rt.hdmi = n; cfg.hdmi = n; save();
        showVideo();
        if (!quiet) toast('Đang xem HDMI ' + n);
        if (rt.menuOpen) renderMenu();
      }, function (e) { toast('Không chọn được HDMI ' + n + ': ' + e.message); }, 'MAIN');
    } catch (e) { toast('Lỗi tvwindow: ' + e.message); }
  }
  function startVideo() {
    withSources(function () {
      var ports = hdmiPorts();
      var pick = ports.indexOf(cfg.hdmi) >= 0 ? cfg.hdmi : ports[0];
      if (pick) useHdmi(pick, true); else toast('Không có cổng HDMI nào có tín hiệu. Bật PS5 lên.');
    });
  }

  // ---------- Phụ đề ----------
  var palette = ['#6aa3ff', '#ffa25c', '#5fd38f', '#ff7cb0', '#a98cff', '#4fd0d8', '#ff7b72', '#e6c35a', '#8c90ff', '#c99a6c', '#a7d35c', '#e08ae6'];
  function colorFor(name) {
    var i = -1, k;
    for (k = 0; k < rt.speakers.length; k++) if (rt.speakers[k].toLowerCase() === name.toLowerCase()) { i = k; break; }
    if (i < 0) { var h = 5381, s = name.toLowerCase(); for (k = 0; k < s.length; k++) h = ((h * 33) + s.charCodeAt(k)) | 0; i = Math.abs(h); }
    return palette[i % palette.length];
  }
  function styled(text) {
    return text.split('\n').map(function (line) {
      var m = rt.names ? /^([^:：]{1,30}[:：])(.*)$/.exec(line) : null;
      if (m && m[1].split(' ').length <= 3) {
        var name = m[1].slice(0, -1).trim();
        return '<span class="name" style="color:' + colorFor(name) + '">' + esc(m[1]) + '</span>' + esc(m[2]);
      }
      return esc(line);
    }).join('<br>');
  }

  function applyBand() {
    sub.style.height = cfg.band + 'px';
    sub.className = cfg.position === 'top' ? 'top' : '';
    updateStatus();
  }

  /// Icon ở góc trái dải: ● xanh = đang dịch, ⏸ vàng = tạm dừng, ⚠ đỏ = mất kết nối máy tính.
  function updateStatus() {
    var size = Math.max(12, Math.min(34, cfg.band * 0.55));
    stEl.style.height = cfg.band + 'px';
    stEl.style.fontSize = size + 'px';
    stEl.className = (cfg.position === 'top' ? 'top ' : '') + (cfg.server < 0 ? 'none' : rt.sse !== 'đã kết nối' ? 'off' : rt.analyzing ? 'busy' : rt.running ? 'run' : 'pause');
    stEl.textContent = cfg.server < 0 ? '' : rt.sse !== 'đã kết nối' ? '⚠' : rt.analyzing ? '⟳' : rt.running ? '●' : '⏸';
  }

  var hideTimer = null;
  /// Vẽ phụ đề trong dải và co chữ cho vừa (tối đa theo độ dày dải × cỡ chữ người chọn).
  function showSubtitle(d) {
    rt.last = d;
    applyBand();
    var withSrc = cfg.showSource && d.source;
    sub.innerHTML = '<div class="tr">' + styled(d.translated || '') + '</div>' + (withSrc ? '<div class="src">' + esc(d.source) + '</div>' : '');
    var tr = sub.querySelector('.tr'), src = sub.querySelector('.src');
    var pad = cfg.band >= 60 ? 14 : 2;
    var size = Math.max(12, Math.min(52, (cfg.band - pad) / (withSrc ? 1.75 : 1.18)) * cfg.fontScale);
    for (var tries = 0; tries < 30; tries++) {
      tr.style.fontSize = size + 'px';
      if (src) src.style.fontSize = Math.max(10, size * 0.55) + 'px';
      if (sub.scrollHeight <= cfg.band + 1 || size <= 12) break;
      size *= 0.92;
    }
    clearTimeout(hideTimer);
    if (cfg.hideAfter > 0) hideTimer = setTimeout(function () { sub.innerHTML = ''; }, cfg.hideAfter * 1000);
  }

  // ---------- Giọng đọc (máy tính tạo âm thanh, TV phát) ----------
  var voiceQueue = [], voiceEl = null;
  function playNext() {
    if (voiceEl || !voiceQueue.length) return;
    var clip = voiceQueue.shift();
    var s = cfg.servers[cfg.server];
    if (!s) { voiceQueue = []; return; }
    var a = new Audio(s.url + '/api/audio/' + clip.id + (clip.mime === 'audio/mpeg' ? '.mp3' : '.wav'));
    a.volume = Math.max(0, Math.min(1, cfg.voiceVolume / 100));
    voiceEl = a;
    var next = function () { if (voiceEl === a) { voiceEl = null; playNext(); } };
    a.onended = next;
    a.onerror = next;
    a.play().catch(next);
  }
  function onAudio(clip) {
    if (!cfg.voice) return;
    // flush = câu mới cắt câu đang đọc (máy tính đang bật "ngắt câu đang đọc").
    if (clip.flush) { voiceQueue = []; if (voiceEl) { try { voiceEl.pause(); } catch (e) {} voiceEl = null; } }
    voiceQueue.push(clip);
    if (voiceQueue.length > 8) voiceQueue.shift();   // tồn quá nhiều (mạng chậm) → bỏ câu cũ nhất
    playNext();
  }
  function stopVoice() { voiceQueue = []; if (voiceEl) { try { voiceEl.pause(); } catch (e) {} voiceEl = null; } }

  // ---------- Kết nối máy tính ----------
  var es = null, retryTimer = null;
  function connect() {
    if (es) { try { es.close(); } catch (e) {} es = null; }
    clearTimeout(retryTimer);
    var s = cfg.servers[cfg.server];
    if (!s) { rt.sse = 'chưa chọn máy'; return; }
    rt.sse = 'đang kết nối…';
    try { es = new EventSource(s.url + '/events?audio=1'); } catch (e) { rt.sse = 'lỗi: ' + e.message; return; }
    var first = true;
    es.onopen = function () {
      rt.sse = 'đã kết nối';
      updateStatus();
      if (first) { toast('Đã kết nối ' + s.name + ' (' + host(s.url) + ')'); first = false; }
      if (rt.menuOpen) renderMenu();
    };
    es.onerror = function () {
      if (rt.sse === 'đã kết nối') toast('Mất kết nối ' + s.name + ', đang thử lại…');
      rt.sse = 'không kết nối được';
      updateStatus();
      if (rt.menuOpen) renderMenu();
    };
    es.addEventListener('state', function (ev) {
      try { var st = JSON.parse(ev.data); rt.names = st.names; rt.speakers = st.speakers || []; rt.game = st.profile; rt.running = st.running; rt.analyzing = st.analyzing; } catch (e) {}
      updateStatus();
      if (rt.menuOpen) renderMenu();
    });
    es.addEventListener('subtitle', function (ev) {
      try { showSubtitle(JSON.parse(ev.data)); } catch (e) {}
    });
    es.addEventListener('audio', function (ev) {
      try { onAudio(JSON.parse(ev.data)); } catch (e) {}
    });
  }

  /// Kiểm tra máy có đang chạy ScreenTranslator không (cho màn hình chọn máy).
  var probe = {};
  function probeServer(i) {
    var s = cfg.servers[i];
    probe[i] = 'wait';
    var x = new XMLHttpRequest();
    var done = false;
    x.open('GET', s.url + '/api/log?limit=1');
    x.timeout = 2500;
    x.onload = function () { done = true; probe[i] = x.status === 200 ? 'on' : 'off'; if (rt.menuOpen) renderMenu(); };
    x.onerror = x.ontimeout = function () { if (!done) { probe[i] = 'off'; if (rt.menuOpen) renderMenu(); } };
    try { x.send(); } catch (e) { probe[i] = 'off'; }
  }

  // ---------- Lệnh tới máy tính (giống nút trên trang web) ----------
  /// POST cần header X-ScreenTranslator (máy chủ từ chối POST không có header này, chống trang lạ bấm hộ).
  function api(method, path, timeoutMs, cb) {
    var s = cfg.servers[cfg.server];
    if (!s) { cb(null, 'Chưa chọn máy tính'); return; }
    var x = new XMLHttpRequest(), done = false;
    x.open(method, s.url + path);
    if (method === 'POST') x.setRequestHeader('X-ScreenTranslator', '1');
    x.timeout = timeoutMs;
    x.onload = function () {
      done = true;
      var j = null;
      try { j = JSON.parse(x.responseText); } catch (e) {}
      cb(j, x.status === 200 ? null : 'HTTP ' + x.status);
    };
    x.onerror = function () { if (!done) { done = true; cb(null, 'Không gọi được ' + s.name); } };
    x.ontimeout = function () { if (!done) { done = true; cb(null, 'Máy tính không trả lời kịp'); } };
    try { x.send(method === 'POST' ? '' : null); } catch (e) { cb(null, e.message); }
  }

  /// Bắt đầu / dừng dịch phụ đề trên máy tính.
  function toggleTranslate() {
    toast(rt.running ? 'Đang tạm dừng dịch…' : 'Đang bật dịch…');
    api('POST', '/api/toggle', 15000, function (j, err) {
      if (err || !j) { toast('Lỗi: ' + err); return; }
      if (!j.ok) { toast(j.error || 'Không bật được dịch'); return; }
      // Trạng thái chính xác tới qua sự kiện "state"; báo ngay theo dự đoán.
      rt.running = !rt.running;
      updateStatus();
      toast(rt.running ? '▶ Đang dịch phụ đề' : '⏸ Đã tạm dừng dịch');
      if (rt.menuOpen) renderMenu();
    });
  }

  /// Dịch toàn màn hình: máy tính chụp hình game, OCR, dịch; xong thì mở ảnh với bản dịch đặt đè lên chữ gốc.
  function analyzeScreen() {
    if (rt.analyzing) { toast('Đang dịch màn hình, đợi chút…'); return; }
    rt.analyzing = true;
    if (rt.menuOpen) { rt.menuOpen = false; menu.className = 'hidden'; }
    openShot(null);
    api('POST', '/api/analyze', 90000, function (j, err) {
      rt.analyzing = false;
      if (err || !j || !j.ok) { closeShot(); toast('Không dịch được màn hình: ' + (err || (j && j.error) || '?')); return; }
      loadShots(j.id);
    });
  }

  // ---------- Xem ảnh "dịch màn hình" ----------
  var shots = [], shotIdx = 0, shotSource = false, shotNoSum = false;

  function loadShots(focusId) {
    api('GET', '/api/analyses', 15000, function (list, err) {
      if (err || !list) { closeShot(); toast('Không tải được ảnh: ' + err); return; }
      shots = list.filter(function (a) { return a.image; });   // mới nhất trước
      if (!shots.length) { closeShot(); toast('Chưa có ảnh dịch màn hình nào'); return; }
      shotIdx = 0;
      for (var i = 0; i < shots.length; i++) if (shots[i].id === focusId) shotIdx = i;
      renderShot();
    });
  }

  /// focusId: null = đang chờ dịch xong; -1 = mở ảnh mới nhất; số = mở đúng ảnh đó.
  function openShot(focusId) {
    rt.shotOpen = true;
    hideVideo();
    shotEl.className = '';
    shotSource = false;
    shotEl.innerHTML = '<div class="wait">' + (focusId === null ? 'Đang chụp và dịch màn hình…' : 'Đang tải ảnh…') + '</div>';
    if (focusId !== null) loadShots(focusId);
  }

  function closeShot() {
    rt.shotOpen = false;
    shotEl.className = 'hidden';
    shotEl.innerHTML = '';
    if (!rt.menuOpen) showVideo();
  }

  function renderShot() {
    var a = shots[shotIdx];
    if (!a) return;
    var s = cfg.servers[cfg.server];
    // Ảnh vừa khít 1920×1080, giữ tỉ lệ.
    var scale = Math.min(1920 / a.width, 1080 / a.height);
    var fw = a.width * scale, fh = a.height * scale, ox = (1920 - fw) / 2, oy = (1080 - fh) / 2;
    var html = '<img src="' + s.url + '/api/shot/' + a.id + '.jpg" style="left:' + ox + 'px;top:' + oy + 'px;width:' + fw + 'px;height:' + fh + 'px">';
    if (!shotSource) {
      (a.items || []).forEach(function (it) {
        var w = it.w * fw, h = it.h * fh;
        // Tiếng Việt thường dài hơn tiếng Anh: hộp rộng thêm một chút, chữ tự co cho vừa (như app máy tính).
        var boxW = Math.min(Math.max(w * 1.15, w + 12), fw - it.x * fw);
        var size = Math.max(10, h / Math.max(1, it.lines) * 0.74);
        html += '<div class="blk" data-size="' + size + '" style="left:' + (ox + it.x * fw - 3) + 'px;top:' + (oy + it.y * fh - 1) +
                'px;width:' + boxW + 'px;height:' + (h + 2) + 'px;font-size:' + size + 'px">' + esc(it.target) + '</div>';
      });
    }
    var when = new Date(a.at * 1000);
    var hh = ('0' + when.getHours()).slice(-2) + ':' + ('0' + when.getMinutes()).slice(-2) + ':' + ('0' + when.getSeconds()).slice(-2);
    html += '<div class="bar"><span>Dịch màn hình · ' + (shotIdx + 1) + '/' + shots.length + ' · ' + hh + ' · ' + (a.items || []).length + ' khối chữ</span>' +
            '<span class="dim">◀▶ ảnh trước/sau · OK: ' + (shotSource ? 'xem bản dịch' : 'xem bản gốc') + ' · ▲▼ tóm tắt · Back: về game</span></div>';
    if (a.summary && !shotNoSum) html += '<div class="sum">' + esc(a.summary) + '</div>';
    shotEl.innerHTML = html;
    // Co chữ từng khối cho vừa hộp (tối thiểu 45 % cỡ ban đầu).
    var blks = shotEl.querySelectorAll('.blk');
    for (var b = 0; b < blks.length; b++) {
      var el = blks[b], size0 = parseFloat(el.getAttribute('data-size')), size = size0;
      while ((el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1) && size > size0 * 0.45) {
        size *= 0.9;
        el.style.fontSize = size + 'px';
      }
    }
  }

  function shotKey(code) {
    switch (code) {
      case 37: if (shotIdx < shots.length - 1) { shotIdx++; renderShot(); } break;   // ◀ ảnh cũ hơn
      case 39: if (shotIdx > 0) { shotIdx--; renderShot(); } break;                   // ▶ ảnh mới hơn
      case 13: shotSource = !shotSource; renderShot(); break;                           // OK: bản gốc / bản dịch
      case 38: case 40: shotNoSum = !shotNoSum; renderShot(); break;                     // ▲▼: ẩn / hiện tóm tắt
      case 10252: case 415: case 19: toggleTranslate(); break;
      case 10009: if (!rt.analyzing || shots.length) closeShot(); break;                 // Back: về game
    }
  }

  // ---------- Menu ----------
  var screen = 'connect';   // connect | settings | ip
  var delMark = -1;        // máy đang chờ xác nhận xoá
  var sel = 0;
  var ipEdit = { oct: [192, 168, 8, 0], idx: 3, typed: '' };

  function openMenu(which) {
    screen = which; sel = 0;
    rt.menuOpen = true;
    hideVideo();
    menu.className = '';
    if (which === 'connect') {
      sel = Math.max(0, cfg.server);
      for (var i = 0; i < cfg.servers.length; i++) probeServer(i);
    }
    renderMenu();
  }
  function closeMenu() {
    rt.menuOpen = false;
    menu.className = 'hidden';
    if (rt.hdmi) showVideo(); else startVideo();
    if (rt.last) showSubtitle(rt.last);
  }

  function onOff(b) { return b ? 'Bật' : 'Tắt'; }
  function settingsItems() {
    var s = cfg.servers[cfg.server];
    var ports = hdmiPorts();
    return [
      { label: rt.running ? '⏸ Tạm dừng dịch' : '▶ Tiếp tục dịch', val: rt.running ? 'đang dịch' : 'đã dừng', action: true,
        sub: 'Khi đang xem: bấm ⏯ trên remote', ok: function () { toggleTranslate(); } },
      { label: 'Dịch toàn màn hình', val: rt.analyzing ? 'đang dịch…' : '', action: true,
        sub: 'Khi đang xem: bấm OK. Chụp hình game, dịch mọi chữ và hiện bản dịch đè lên đúng chỗ', ok: analyzeScreen },
      { label: 'Xem lại ảnh đã dịch', val: '', action: true, sub: 'Khi đang xem: bấm Kênh ∨',
        ok: function () { rt.menuOpen = false; menu.className = 'hidden'; openShot(-1); } },
      { label: 'Máy tính', val: s ? s.name + ' · ' + host(s.url) : 'chưa chọn', sub: rt.sse + (rt.game ? ' · game: ' + rt.game + (rt.running ? ' (đang dịch)' : ' (đã dừng)') : ''),
        ok: function () { openMenu('connect'); } },
      { label: 'Cổng HDMI', val: rt.hdmi ? 'HDMI ' + rt.hdmi : 'chưa có', sub: 'Có tín hiệu: ' + (ports.length ? ports.map(function (p) { return 'HDMI ' + p; }).join(', ') : 'không'),
        lr: function (d) { if (!ports.length) return; var i = ports.indexOf(rt.hdmi); useHdmi(ports[(i + d + ports.length) % ports.length], true); } },
      { label: 'Độ dày dải phụ đề', val: cfg.band + ' px', sub: 'Khi đang xem: ◀ ▶ (20–260 px)',
        lr: function (d) { cfg.band = Math.max(20, Math.min(260, cfg.band + d * (cfg.band > 60 || (cfg.band === 60 && d > 0) ? 10 : 5))); save(); } },
      { label: 'Cỡ chữ', val: '×' + cfg.fontScale.toFixed(1), sub: 'Khi đang xem: ▲ ▼',
        lr: function (d) { cfg.fontScale = Math.round(Math.max(0.5, Math.min(1.6, cfg.fontScale + d * 0.1)) * 10) / 10; save(); } },
      { label: 'Giọng đọc trên TV', val: onOff(cfg.voice), sub: 'Cần bật "Phát giọng đọc trên TV / điện thoại" trong Cài đặt → Voice của app máy tính',
        lr: function () { cfg.voice = !cfg.voice; if (!cfg.voice) stopVoice(); save(); }, ok: function () { cfg.voice = !cfg.voice; if (!cfg.voice) stopVoice(); save(); } },
      { label: 'Âm lượng giọng đọc', val: cfg.voiceVolume + '%', sub: 'So với tiếng game (âm lượng chung vẫn chỉnh bằng nút + − trên remote)',
        lr: function (d) { cfg.voiceVolume = Math.max(10, Math.min(100, cfg.voiceVolume + d * 10)); if (voiceEl) voiceEl.volume = cfg.voiceVolume / 100; save(); } },
      { label: 'Hiện câu gốc tiếng Anh', val: onOff(cfg.showSource), sub: 'Khi đang xem: bấm Kênh ∧',
        lr: function () { cfg.showSource = !cfg.showSource; save(); }, ok: function () { cfg.showSource = !cfg.showSource; save(); } },
      { label: 'Vị trí dải phụ đề', val: cfg.position === 'top' ? 'Trên cùng' : 'Dưới cùng', sub: '',
        lr: function () { cfg.position = cfg.position === 'top' ? 'bottom' : 'top'; save(); }, ok: function () { cfg.position = cfg.position === 'top' ? 'bottom' : 'top'; save(); } },
      { label: 'Tự ẩn phụ đề sau', val: cfg.hideAfter ? cfg.hideAfter + ' giây' : 'Không ẩn (giữ tới câu mới)', sub: '',
        lr: function (d) { var opts = [0, 5, 8, 12, 20]; var i = opts.indexOf(cfg.hideAfter); cfg.hideAfter = opts[(i + d + opts.length) % opts.length]; save(); } },
      { label: 'Hỏi chọn máy tính khi mở app', val: onOff(cfg.askOnStart), sub: 'Tắt thì tự kết nối máy đã chọn lần trước',
        lr: function () { cfg.askOnStart = !cfg.askOnStart; save(); }, ok: function () { cfg.askOnStart = !cfg.askOnStart; save(); } },
      { label: '▶ Quay lại xem', val: '', sub: '', ok: closeMenu },
      { label: 'Thoát app', val: '', sub: '', danger: true, ok: exitApp },
    ];
  }

  function connectItems() {
    var items = cfg.servers.map(function (s, i) {
      var st = probe[i] || '';
      return { label: '<span class="dot ' + st + '"></span>' + esc(s.name), html: true, val: delMark === i ? 'OK để XOÁ máy này' : host(s.url),
               sub: st === 'on' ? 'ScreenTranslator đang chạy' : st === 'off' ? 'Không trả lời (app chưa mở, khác mạng hoặc tường lửa chặn)' : 'Đang kiểm tra…',
               lr: i >= 2 ? function () { delMark = delMark === i ? -1 : i; } : null,
               ok: function () {
                 if (delMark === i) { cfg.servers.splice(i, 1); if (cfg.server === i) cfg.server = -1; else if (cfg.server > i) cfg.server--; delMark = -1; save(); return; }
                 chooseServer(i);
               } };
    });
    items.push({ label: '+ Nhập địa chỉ IP máy khác…', val: '', sub: '', ok: function () {
      var cur = cfg.servers[cfg.server];
      var m = cur ? /(\d+)\.(\d+)\.(\d+)\.(\d+)/.exec(cur.url) : null;
      ipEdit = { oct: m ? [+m[1], +m[2], +m[3], +m[4]] : [192, 168, 8, 0], idx: 3, typed: '' };
      screen = 'ip'; renderMenu();
    } });
    items.push({ label: 'Chỉ xem hình, không kết nối', val: '', sub: '', ok: function () { cfg.server = -1; save(); connect(); closeMenu(); } });
    return items;
  }

  function chooseServer(i) {
    cfg.server = i; save();
    connect();
    closeMenu();
  }

  function renderMenu() {
    if (!rt.menuOpen) return;
    var s = cfg.servers[cfg.server];
    var side = '<div class="side"><div class="logo"><span>Subtitle</span> TV</div>' +
      '<div class="hint">▲▼ chọn · OK xác nhận<br>◀▶ đổi giá trị<br>Back ' + (screen === 'settings' ? 'quay lại xem' : 'quay lại') +
      '<br><br>Khi đang xem game:<br>⏯ tạm dừng / tiếp tục dịch<br>OK dịch toàn màn hình<br>◀▶ dải phụ đề · ▲▼ cỡ chữ<br>Kênh ∧ câu gốc · Kênh ∨ ảnh đã dịch<br>Back mở menu này</div>' +
      '<div class="status">' +
      'Máy tính: ' + (s ? esc(s.name) : '<span class="dim">chưa chọn</span>') + '<br>' +
      'Kết nối: ' + esc(rt.sse) + '<br>' +
      'Hình: ' + (rt.hdmi ? 'HDMI ' + rt.hdmi : '<span class="dim">chưa có</span>') + '<br>' +
      (rt.game ? 'Game: ' + esc(rt.game) + (rt.running ? ' · <span class="ok">đang dịch</span>' : ' · <span class="dim">đã dừng</span>') : '') +
      '</div></div>';
    var main = '';
    if (screen === 'ip') {
      main = '<h2>Địa chỉ IP máy tính chạy ScreenTranslator</h2>' +
        '<div class="ip">' + ipEdit.oct.map(function (o, i) { return '<div class="oct' + (i === ipEdit.idx ? ' sel' : '') + '">' + o + '</div>' + (i < 3 ? '.' : ''); }).join('') + '<div class="dim">:8787</div></div>' +
        '<div class="hint" style="margin-top:30px">Bấm số để nhập · ◀▶ chuyển ô · ▲▼ tăng/giảm · OK kết nối · Back huỷ<br>' +
        'Bấm nút 123 trên remote để hiện bàn phím số. IP hiện trong app trên máy tính: Cài đặt → iPhone / Web (hoặc Điện thoại / Web).</div>';
    } else {
      var items = screen === 'connect' ? connectItems() : settingsItems();
      sel = Math.max(0, Math.min(items.length - 1, sel));
      main = '<h2>' + (screen === 'connect' ? 'Chọn máy tính đang chạy ScreenTranslator' : 'Cài đặt') + '</h2>' +
        items.map(function (it, i) {
          return '<div class="item' + (i === sel ? ' sel' : '') + (it.danger ? ' danger' : '') + (it.action ? ' action' : '') + '"><div><div>' + (it.html ? it.label : esc(it.label)) + '</div>' +
            (it.sub ? '<div class="sub">' + esc(it.sub) + '</div>' : '') + '</div>' +
            '<div class="val">' + (it.lr ? '<span class="arrow">◀</span>' : '') + esc(it.val) + (it.lr ? '<span class="arrow">▶</span>' : '') + '</div></div>';
        }).join('') +
        (screen === 'connect' && cfg.servers.length > 2 ? '<div class="hint">Máy tự thêm: bấm ◀ hoặc ▶ rồi OK để xoá</div>' : '');
    }
    menu.innerHTML = side + '<div class="main">' + main + '</div>';
  }

  function menuKey(code) {
    if (screen === 'ip') return ipKey(code);
    var items = screen === 'connect' ? connectItems() : settingsItems();
    var it = items[sel];
    switch (code) {
      case 38: sel = (sel - 1 + items.length) % items.length; break;
      case 40: sel = (sel + 1) % items.length; break;
      case 37: if (it.lr) it.lr(-1); break;
      case 39: if (it.lr) it.lr(1); break;
      case 13: if (it.ok) { it.ok(); if (!rt.menuOpen) return; } break;
      case 10252: case 415: case 19: toggleTranslate(); break;
      case 10009:
        if (screen === 'connect' && cfg.server >= 0) { openMenu('settings'); return; }
        if (screen === 'connect') { closeMenu(); return; }
        closeMenu(); return;
    }
    renderMenu();
  }

  function ipKey(code) {
    var o = ipEdit.oct;
    if (code >= 48 && code <= 57) {
      ipEdit.typed = (ipEdit.typed + (code - 48)).slice(-3);
      o[ipEdit.idx] = Math.min(255, parseInt(ipEdit.typed, 10));
      if (ipEdit.typed.length === 3 && ipEdit.idx < 3) { ipEdit.idx++; ipEdit.typed = ''; }
    } else switch (code) {
      case 37: ipEdit.idx = Math.max(0, ipEdit.idx - 1); ipEdit.typed = ''; break;
      case 39: ipEdit.idx = Math.min(3, ipEdit.idx + 1); ipEdit.typed = ''; break;
      case 38: o[ipEdit.idx] = (o[ipEdit.idx] + 1) % 256; ipEdit.typed = ''; break;
      case 40: o[ipEdit.idx] = (o[ipEdit.idx] + 255) % 256; ipEdit.typed = ''; break;
      case 13:
        var url = 'http://' + o.join('.') + ':8787';
        var i = -1;
        cfg.servers.forEach(function (s, k) { if (s.url === url) i = k; });
        if (i < 0) { cfg.servers.push({ name: 'Máy ' + o.join('.'), url: url }); i = cfg.servers.length - 1; }
        save();
        chooseServer(i);
        return;
      case 10009: screen = 'connect'; sel = 0; break;
    }
    renderMenu();
  }

  function exitApp() {
    hideVideo();
    try { tizen.application.getCurrentApplication().exit(); } catch (x) {}
  }

  // ---------- Remote ----------
  function registerKeys() {
    ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'ColorF0Red', 'ColorF1Green', 'MediaPlayPause', 'MediaPlay', 'MediaPause', 'ChannelUp', 'ChannelDown'].forEach(function (k) { try { tizen.tvinputdevice.registerKey(k); } catch (e) {} });
  }
  document.addEventListener('keydown', function (e) {
    if (rt.shotOpen) { e.preventDefault(); shotKey(e.keyCode); return; }
    if (rt.menuOpen) { e.preventDefault(); menuKey(e.keyCode); return; }
    switch (e.keyCode) {
      case 37: cfg.band = Math.max(20, cfg.band - (cfg.band > 60 ? 10 : 5)); save(); applyBand(); showVideo(); if (rt.last) showSubtitle(rt.last); toast('Dải phụ đề ' + cfg.band + ' px'); break;
      case 39: cfg.band = Math.min(260, cfg.band + (cfg.band >= 60 ? 10 : 5)); save(); applyBand(); showVideo(); if (rt.last) showSubtitle(rt.last); toast('Dải phụ đề ' + cfg.band + ' px'); break;
      case 38: cfg.fontScale = Math.min(1.6, Math.round((cfg.fontScale + 0.1) * 10) / 10); save(); if (rt.last) showSubtitle(rt.last); break;
      case 40: cfg.fontScale = Math.max(0.5, Math.round((cfg.fontScale - 0.1) * 10) / 10); save(); if (rt.last) showSubtitle(rt.last); break;
      case 427: case 403: cfg.showSource = !cfg.showSource; save(); if (rt.last) showSubtitle(rt.last); toast('Câu gốc: ' + (cfg.showSource ? 'hiện' : 'ẩn')); break;   // Kênh ∧
      case 428: openShot(-1); break;                                                                                                                            // Kênh ∨
      case 49: case 50: case 51: case 52: var n = e.keyCode - 48; withSources(function () { useHdmi(n); }); break;
      case 10009: e.preventDefault(); openMenu('settings'); break;            // Back: mở menu (không thoát app)
      case 10252: case 415: case 19: toggleTranslate(); break;                // ⏯: bật / tắt dịch
      case 13: case 404: case 48: analyzeScreen(); break;                     // OK (hoặc Xanh lá / 0): dịch toàn màn hình
    }
  });

  window.onload = function () {
    registerKeys();
    applyBand();
    withSources(function () {
      if (cfg.askOnStart || cfg.server < 0) { openMenu('connect'); }
      else { connect(); startVideo(); }
    });
    // Nguồn HDMI được cắm / rút → cập nhật danh sách (để menu hiện đúng).
    setInterval(function () { withSources(function () { if (rt.menuOpen) renderMenu(); }); }, 5000);
  };
})();
