// Subtitle TV: hiện hình HDMI (PS5) bằng tizen.tvwindow và phụ đề dịch từ ScreenTranslator (máy tính, Server-Sent Events).
// Trên TV Samsung (đã thử Q70T, Tizen 5.5), lớp video HDMI luôn nằm TRÊN lớp đồ hoạ của app, nên không vẽ đè lên hình được:
// hình được ép nhẹ chiều cao để chừa một dải đen, phụ đề nằm trong dải đó. Lúc mở menu, hình được tạm ẩn.
//
// Phím theo Samsung Smart Remote (chỉ có vòng điều hướng, OK, Back, ⏯, kênh ∧∨; nút 123 mở bàn phím số ảo):
//   ⏯ = tạm dừng / tiếp tục dịch, OK = dịch toàn màn hình, Back = menu, ◀ ▶ = dải mỏng / dày, ▲ ▼ = cỡ chữ,
//   Kênh ∧ = lịch sử phụ đề đã dịch, Kênh ∨ = xem lại ảnh đã dịch.
(function () {
  'use strict';

  // ---------- Chẩn đoán: in nhật ký lên màn hình TV (bản điều tra lỗi) ----------
  // Dòng CUỐI còn hiện trước khi app tự thoát = chỗ gây crash. Bật = true khi cần điều tra lỗi.
  var DBG = false;
  var dbgLines = [];
  function dbg(m) {
    if (!DBG) return;
    try {
      dbgLines.push(m);
      if (dbgLines.length > 14) dbgLines.shift();
      var el = document.getElementById('dbg');
      if (!el) {
        el = document.createElement('div');
        el.id = 'dbg';
        el.style.cssText = 'position:fixed;left:8px;top:8px;z-index:99999;background:rgba(0,0,0,.75);' +
          'color:#4ef06a;font:13px/1.45 monospace;padding:7px 10px;max-width:70%;white-space:pre-wrap;pointer-events:none;border-radius:6px';
        (document.body || document.documentElement).appendChild(el);
      }
      el.textContent = dbgLines.join('\n');
      try { console.error('[DBG] ' + m); } catch (x) {}
    } catch (x) {}
  }

  // Banner lỗi nổi bật, ở lại trên màn hình tới khi hết lỗi (để người dùng còn biết app gặp gì).
  function showErr(msg) {
    try {
      var el = document.getElementById('err');
      if (!el) {
        el = document.createElement('div');
        el.id = 'err';
        el.style.cssText = 'position:fixed;left:0;right:0;bottom:0;z-index:100000;background:rgba(176,32,32,.93);' +
          'color:#fff;font:16px/1.5 "Segoe UI",Roboto,sans-serif;padding:14px 18px;white-space:pre-wrap;text-align:center';
        (document.body || document.documentElement).appendChild(el);
      }
      el.textContent = '⚠ ' + msg;
      el.style.display = 'block';
      try { console.error('[ERR] ' + msg); } catch (x) {}
    } catch (x) {}
  }
  function clearErr() { try { var el = document.getElementById('err'); if (el) el.style.display = 'none'; } catch (x) {} }

  // Chống lặp crash: đánh dấu TRƯỚC khi gọi API hình HDMI (có thể làm app thoát ở tầng native, JS không bắt được).
  // Mở app lần sau mà dấu vẫn còn → lần trước app đã chết ngay ở bước đó → tự tắt hiện hình và báo lên màn hình.
  function markVideo(step) { try { localStorage.setItem('pendingVideo', step); } catch (e) {} }
  function clearVideo() { try { localStorage.removeItem('pendingVideo'); } catch (e) {} }
  function pendingVideo() { try { return localStorage.getItem('pendingVideo'); } catch (e) { return null; } }

  // ---------- Cài đặt (lưu trên TV) ----------
  var DEFAULTS = {
    servers: [
      { name: 'Mac mini', url: 'http://192.168.8.24:8787' },
      { name: 'PC Windows', url: 'http://192.168.8.22:8787' },
    ],
    server: -1,          // máy đang dùng (-1 = chưa chọn)
    askOnStart: true,    // mở app là hỏi chọn máy
    hdmi: 0,
    layout: 'overlay',   // overlay = phụ đề vẽ đè lên hình game | band = dải đen dưới hình (cách cũ)
    subBg: 'box',        // nền phụ đề khi đè lên game: box = nền mờ | solid = nền đậm | none = không nền (chữ viền đen)
    subY: 70,            // khoảng cách phụ đề tới mép dưới (hoặc trên) màn hình, px trên 1080
    band: 110,           // độ dày dải phụ đề (px trên 1080)
    fontScale: 1,
    showSource: false,
    showPrev: true,      // hiện câu phụ đề trước (chữ nhỏ, mờ) phía trên câu hiện tại
    position: 'bottom',  // bottom | top
    keepLast: 45,        // giây giữ câu phụ đề cuối khi không có câu mới, 0 = giữ mãi
    autoCollapse: true,  // hết thời gian giữ câu cuối → thu dải về 0, game full màn hình
    speakerColor: 'line', // line = tô cả câu theo màu nhân vật | name = chỉ tên | off
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
  var rt = { hdmi: 0, sources: [], sse: 'chưa kết nối', game: '', running: false, analyzing: false, names: true, speakers: [], last: null, menuOpen: false, shotOpen: false, histOpen: false, collapsed: false, lastSpeaker: '' };
  var histEl = document.getElementById('hist');
  var shotEl = document.getElementById('shot');
  var stEl = document.getElementById('st');

  function esc(s) {
    return String(s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; });
  }
  function host(url) { return url.replace(/^https?:\/\//, ''); }

  var toastTimer = null;
  /// Chỉ báo lỗi (mất kết nối, không dịch được…): chữ nhỏ sát icon trạng thái ở góc trái dải, tự tắt sau 3 giây.
  /// Thao tác thường (dải, cỡ chữ, tạm dừng / tiếp tục) không hiện thông báo để không che phụ đề; icon ● / ⏸ đã cho biết trạng thái.
  function toast(msg, isError) {
    if (!isError) return;
    setCollapsed(false);
    toastEl.textContent = msg;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.className = 'hidden'; if (rt.note) bandNote(rt.note); }, 3000);
    if (overlay()) { toastEl.className = 'ov'; toastEl.removeAttribute('style'); return; }
    toastEl.className = cfg.position === 'top' ? 'top' : '';
    var h = Math.max(14, Math.min(cfg.band, 34));
    toastEl.style.height = h + 'px';
    toastEl.style.lineHeight = h + 'px';
    toastEl.style.fontSize = Math.max(11, Math.min(18, cfg.band * 0.45)) + 'px';
    toastEl.style.left = (Math.max(12, Math.min(34, cfg.band * 0.55)) + 28) + 'px';
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.className = 'hidden'; if (rt.note) bandNote(rt.note); }, 3000);
  }
  /// Dòng trạng thái nhỏ cạnh icon (vd. "Đang dịch màn hình…"), giữ tới khi gọi bandNote(null). Không che phụ đề ở giữa dải.
  function bandNote(msg) {
    rt.note = msg;
    if (!msg) { if (toastEl.className.indexOf('note') >= 0) toastEl.className = 'hidden'; return; }
    toast(msg, true);
    clearTimeout(toastTimer);
    toastEl.className += ' note';
  }

  // ---------- Hình HDMI ----------
  // setSource cần đúng đối tượng SystemInfoVideoSourceInfo lấy từ systeminfo (VIDEOSOURCE), không nhận object tự tạo.
  function withSources(cb) {
    try {
      tizen.systeminfo.getPropertyValue('VIDEOSOURCE', function (vs) { rt.sources = vs.connected || []; cb(); }, function () { cb(); });
    } catch (e) { cb(); }
  }
  function hdmiPorts() { return rt.sources.filter(function (s) { return s.type === 'HDMI'; }).map(function (s) { return s.number; }); }

  function overlay() { return cfg.layout !== 'band'; }
  function videoRect() {
    if (overlay() || rt.collapsed) return ['0px', '0px', '1920px', '1080px'];
    var h = 1080 - cfg.band;
    return ['0px', (cfg.position === 'top' ? cfg.band : 0) + 'px', '1920px', h + 'px'];
  }
  /// BEHIND: hình game nằm SAU trang web → chỗ trang trong suốt thấy game, chữ / khung vẽ đè lên được.
  /// Menu, lịch sử, ảnh chụp có nền đặc nên che game mà không cần tắt hình (không chớp khi đóng / mở).
  var shownRect = '';
  function showVideo(force) {
    if (!rt.hdmi) return;
    var r = videoRect();
    if (!force && r.join() === shownRect) return;
    shownRect = r.join();
    dbg('show ' + r.join());
    markVideo('hiện hình HDMI' + rt.hdmi);
    try {
      tizen.tvwindow.show(function () { clearVideo(); clearErr(); },
        function (e) { shownRect = ''; clearVideo(); showErr('Lỗi hiện hình: ' + e.message); }, r, 'MAIN', 'BEHIND');
    } catch (e) { shownRect = ''; clearVideo(); showErr('Lỗi hiện hình: ' + (e && e.message || e)); }
  }
  function hideVideo() { shownRect = ''; try { tizen.tvwindow.hide(function () {}, function () {}, 'MAIN'); } catch (e) {} }
  /// Đổi kiểu hiển thị: nền trang trong suốt (đè lên game) hoặc đen (dải).
  function applyLayout() {
    document.body.className = document.documentElement.className = overlay() ? 'ovl' : '';
    if (overlay()) rt.collapsed = false;
    showVideo();
    applyBand();
    if (rt.last) showSubtitle(rt.last); else sub.innerHTML = '';
  }

  function useHdmi(n, quiet) {
    var src = null;
    rt.sources.forEach(function (s) { if (s.type === 'HDMI' && s.number === n) src = s; });
    if (!src) { if (!quiet) toast('HDMI ' + n + ' không có tín hiệu', true); return; }
    // Người dùng chủ động chọn HDMI → bật lại tự hiện hình (nếu trước đó đã bị tắt vì crash).
    if (!quiet && cfg.videoDisabled) { cfg.videoDisabled = false; save(); }
    dbg('setSource HDMI' + n);
    markVideo('chọn nguồn HDMI' + n);
    try {
      tizen.tvwindow.setSource(src, function () {
        rt.hdmi = n; cfg.hdmi = n; save();
        dbg('setSource ok HDMI' + n);
        showVideo(true);
        if (!quiet) toast('Đang xem HDMI ' + n);
        if (rt.menuOpen) renderMenu();
      }, function (e) { clearVideo(); showErr('Không chọn được HDMI ' + n + ': ' + e.message); }, 'MAIN');
    } catch (e) { clearVideo(); showErr('Lỗi tvwindow: ' + (e && e.message || e)); }
  }
  function startVideo() {
    // Lần trước hiện hình làm app thoát → đã tắt tự hiện hình. Không tự gọi lại (tránh thoát lặp lại); chờ người dùng bấm số HDMI.
    if (cfg.videoDisabled) { dbg('video disabled'); showErr('Đã tắt tự hiện hình HDMI vì lần trước làm app thoát. Bấm số HDMI (1–4) trên remote để thử lại.'); return; }
    withSources(function () {
      var ports = hdmiPorts();
      dbg('startVideo ports=' + ports.join(','));
      var pick = ports.indexOf(cfg.hdmi) >= 0 ? cfg.hdmi : ports[0];
      if (pick) useHdmi(pick, true); else toast('Không có cổng HDMI nào có tín hiệu. Bật PS5 lên.', true);
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
  /// Màu lời thoại: màu nhân vật pha trắng cho dễ đọc trên nền đen.
  function lighter(hex) {
    var n = parseInt(hex.slice(1), 16), mix = function (c) { return Math.round(c + (255 - c) * 0.45); };
    return 'rgb(' + mix(n >> 16 & 255) + ',' + mix(n >> 8 & 255) + ',' + mix(n & 255) + ')';
  }
  /// live = dải phụ đề: dòng không có tên vẫn giữ màu người nói gần nhất (rt.lastSpeaker). Lịch sử: mỗi dòng tự tính.
  function styled(text, live) {
    var speaker = live ? rt.lastSpeaker : '';
    var mode = cfg.speakerColor;
    var out = text.split('\n').map(function (line) {
      var m = rt.names && mode !== 'off' ? /^([^:：]{1,30}[:：])(.*)$/.exec(line) : null;
      if (m && m[1].split(' ').length <= 6) {
        speaker = m[1].slice(0, -1).trim();
        var c = colorFor(speaker);
        return '<span class="name" style="color:' + c + '">' + esc(m[1]) + '</span>' +
               (mode === 'line' ? '<span style="color:' + lighter(c) + '">' + esc(m[2]) + '</span>' : esc(m[2]));
      }
      if (mode === 'line' && speaker && rt.names) return '<span style="color:' + lighter(colorFor(speaker)) + '">' + esc(line) + '</span>';
      return esc(line);
    }).join('<br>');
    if (live) rt.lastSpeaker = speaker;
    return out;
  }

  function applyBand() {
    if (overlay()) {
      sub.style.height = '';
      sub.className = 'ov ' + (cfg.position === 'top' ? 'top ' : '') + 'bg-' + cfg.subBg;
      sub.style.bottom = cfg.position === 'top' ? '' : cfg.subY + 'px';
      sub.style.top = cfg.position === 'top' ? cfg.subY + 'px' : '';
    } else {
      sub.style.height = cfg.band + 'px';
      sub.style.bottom = sub.style.top = '';
      sub.className = cfg.position === 'top' ? 'top' : '';
    }
    updateStatus();
  }

  /// Icon ở góc trái dải: ● xanh = đang dịch, ⏸ vàng = tạm dừng, ⚠ đỏ = mất kết nối máy tính.
  function updateStatus() {
    var size = Math.max(12, Math.min(34, cfg.band * 0.55));
    stEl.style.height = overlay() ? '' : cfg.band + 'px';
    stEl.style.fontSize = overlay() ? '' : size + 'px';
    stEl.className = (overlay() ? 'ov ' : cfg.position === 'top' ? 'top ' : '') + (cfg.server < 0 ? 'none' : rt.sse !== 'đã kết nối' ? 'off' : (rt.analyzing || rt.analyzeReq) ? 'busy' : rt.running ? 'run' : 'pause');
    if (rt.collapsed && (!rt.running || rt.sse !== 'đã kết nối' || rt.analyzing || rt.analyzeReq)) setCollapsed(false);
    stEl.textContent = cfg.server < 0 ? '' : rt.sse !== 'đã kết nối' ? '⚠' : (rt.analyzing || rt.analyzeReq) ? '⟳' : rt.running ? '●' : '⏸';
  }

  var hideTimer = null;
  /// Thu dải về 0 (game full màn hình) / mở lại. Video nằm trên lớp web nên lúc thu gọn không thấy icon trạng thái.
  function setCollapsed(b) {
    b = !!b && cfg.autoCollapse && !overlay();
    if (rt.collapsed === b) return;
    rt.collapsed = b;
    showVideo();
  }
  /// Giới hạn bề ngang một khối chữ ở `maxW` px (không quá gần hết màn hình); nếu phải xuống dòng thì thu hẹp tới mức hẹp nhất
  /// mà vẫn giữ nguyên số dòng, để các dòng dài gần bằng nhau (không có dòng cuối chỉ một hai chữ).
  /// Tối đa 2 dòng: câu quá dài thì nới rộng dòng (tới 1640 px), vẫn không vừa thì thu nhỏ chữ (tối thiểu 60 %).
  function balanceLines(el, maxW) {
    var FULL = 1640;
    maxW = Math.min(FULL, maxW);
    var lineH = function () { return parseFloat(window.getComputedStyle(el).lineHeight) || el.offsetHeight; };
    var lines = function () { return Math.round(el.offsetHeight / lineH()); };
    el.style.maxWidth = maxW + 'px';
    if (lines() > 2) {
      el.style.maxWidth = FULL + 'px';
      var size0 = parseFloat(el.style.fontSize), size = size0;
      while (lines() > 2 && size > size0 * 0.6) { size *= 0.94; el.style.fontSize = size + 'px'; }
      if (lines() <= 2) {
        // Hẹp nhất mà vẫn vừa 2 dòng (không rộng hơn mức thường nếu đã đủ).
        var a = maxW, b = FULL;
        el.style.maxWidth = a + 'px';
        if (lines() > 2) {
          while (b - a > 4) { var m = (a + b) / 2; el.style.maxWidth = m + 'px'; if (lines() > 2) a = m; else b = m; }
          maxW = Math.ceil(b);
        }
      } else maxW = FULL;
      el.style.maxWidth = maxW + 'px';
    }
    var h = el.offsetHeight;
    if (h < lineH() * 1.5) return;   // vừa một dòng
    var lo = maxW * 0.35, hi = maxW;
    while (hi - lo > 4) {
      var mid = (lo + hi) / 2;
      el.style.maxWidth = mid + 'px';
      if (el.offsetHeight > h) lo = mid; else hi = mid;
    }
    el.style.maxWidth = Math.ceil(hi) + 'px';
  }
  /// Đang chỉnh vị trí / cỡ chữ mà chưa có câu nào: hiện câu mẫu vài giây để thấy kết quả.
  function previewSub() {
    if (rt.last) showSubtitle(rt.last);
    else showSubtitle({ translated: 'Kratos: Phụ đề mẫu — vị trí và cỡ chữ', source: 'Kratos: Sample subtitle' }, true);
  }
  /// Hết giờ giữ câu cuối: xoá chữ, quên người nói, thu dải nếu đang dịch bình thường (đang dừng / lỗi thì giữ dải để thấy icon).
  function expireSubtitle() {
    sub.innerHTML = '';
    rt.last = rt.prev = null;
    rt.lastSpeaker = '';
    if (!overlay() && rt.running && rt.sse === 'đã kết nối' && !rt.analyzeReq && !rt.note) setCollapsed(true);
  }
  /// Vẽ phụ đề trong dải và co chữ cho vừa (tối đa theo độ dày dải × cỡ chữ người chọn).
  function showSubtitle(d, preview) {
    if (!preview) {
      // Câu mới (không phải vẽ lại câu cũ): câu đang hiện lùi lên làm "câu trước".
      if (rt.last && d !== rt.last && rt.last.translated !== d.translated) rt.prev = rt.last;
      rt.last = d;
    }
    setCollapsed(false);
    applyBand();
    var withSrc = cfg.showSource && d.source;
    // Câu trước: dải đen mỏng quá thì bỏ (không đủ chỗ, chữ sẽ bị co quá nhỏ).
    var prev = !preview && cfg.showPrev && rt.prev && (overlay() || cfg.band >= 90) ? rt.prev : null;
    var inner = (prev ? '<div class="prev">' + styled(prev.translated || '', false) + '</div>' : '') + '<div class="tr">' + styled(d.translated || '', !preview) + '</div>' + (withSrc ? '<div class="src">' + esc(d.source) + '</div>' : '');
    if (overlay()) {
      // Đè lên game: cỡ chữ cố định theo người chọn, khung ôm sát chữ (tối đa 2 dòng rộng gần hết màn hình).
      sub.innerHTML = '<div class="box">' + inner + '</div>';
      var t = sub.querySelector('.tr'), sc = sub.querySelector('.src'), pv = sub.querySelector('.prev');
      t.style.fontSize = (46 * cfg.fontScale).toFixed(1) + 'px';
      if (pv) pv.style.fontSize = (29 * cfg.fontScale).toFixed(1) + 'px';
      if (sc) sc.style.fontSize = (27 * cfg.fontScale).toFixed(1) + 'px';
      // Câu vừa (tới ~60 ký tự) giữ một dòng; câu dài hơn mới tách 2 dòng dài gần bằng nhau.
      balanceLines(t, 34 * parseFloat(t.style.fontSize));
      if (pv) balanceLines(pv, 52 * parseFloat(pv.style.fontSize));
      if (sc) balanceLines(sc, 55 * parseFloat(sc.style.fontSize));
      clearTimeout(hideTimer);
      if (preview) hideTimer = setTimeout(function () { if (rt.last) showSubtitle(rt.last); else sub.innerHTML = ''; }, 2500);
      else if (cfg.keepLast > 0) hideTimer = setTimeout(expireSubtitle, cfg.keepLast * 1000);
      return;
    }
    sub.innerHTML = inner;
    var tr = sub.querySelector('.tr'), src = sub.querySelector('.src'), pv = sub.querySelector('.prev');
    var pad = cfg.band >= 60 ? 14 : 2;
    var size = Math.max(12, Math.min(52, (cfg.band - pad) / ((withSrc ? 1.75 : 1.18) + (pv ? 0.75 : 0))) * cfg.fontScale);
    for (var tries = 0; tries < 30; tries++) {
      tr.style.fontSize = size + 'px';
      if (src) src.style.fontSize = Math.max(10, size * 0.55) + 'px';
      if (pv) pv.style.fontSize = Math.max(10, size * 0.62) + 'px';
      if (sub.scrollHeight <= cfg.band + 1 || size <= 12) break;
      size *= 0.92;
    }
    clearTimeout(hideTimer);
    if (cfg.keepLast > 0) hideTimer = setTimeout(expireSubtitle, cfg.keepLast * 1000);
  }

  // ---------- Giọng đọc (máy tính tạo âm thanh, TV phát) ----------
  // Phát bằng Web Audio: trên TV Samsung, thẻ <audio> làm TV tắt tiếng nguồn HDMI (game), còn Web Audio được trộn chung với tiếng game.
  var actx = null, gain = null, voiceQueue = [], voiceSrc = null, voiceGen = 0;
  function audioCtx() {
    if (!actx) {
      var Ctx = window.AudioContext || window.webkitAudioContext;
      if (!Ctx) return null;
      actx = new Ctx();
      gain = actx.createGain();
      gain.connect(actx.destination);
    }
    if (actx.state !== 'running') { try { actx.resume(); } catch (e) {} }
    gain.gain.value = Math.max(0, Math.min(1, cfg.voiceVolume / 100));
    return actx;
  }
  /// Tải + giải mã ngay khi máy tính báo có câu (song song với câu đang đọc) để lúc tới lượt phát được ngay.
  function loadClip(clip) {
    var s = cfg.servers[cfg.server], ctx = audioCtx();
    clip.state = 'loading';
    if (!s || !ctx) { clip.state = 'error'; return; }
    var x = new XMLHttpRequest();
    x.open('GET', s.url + '/api/audio/' + clip.id + (clip.mime === 'audio/mpeg' ? '.mp3' : '.wav'));
    x.responseType = 'arraybuffer';
    x.timeout = 15000;
    var fail = function () { clip.state = 'error'; playNext(); };
    x.onload = function () {
      if (x.status !== 200) { fail(); return; }
      ctx.decodeAudioData(x.response, function (buf) { clip.buf = buf; clip.state = 'ready'; playNext(); }, fail);
    };
    x.onerror = x.ontimeout = fail;
    x.send();
  }
  function playNext() {
    if (voiceSrc) return;
    while (voiceQueue.length && voiceQueue[0].state === 'error') voiceQueue.shift();
    var clip = voiceQueue[0];
    if (!clip || clip.state !== 'ready') return;   // câu đầu hàng chưa tải xong → đợi
    voiceQueue.shift();
    var ctx = audioCtx(), gen = voiceGen;
    var src = ctx.createBufferSource();
    src.buffer = clip.buf;
    src.connect(gain);
    src.onended = function () { if (gen === voiceGen && voiceSrc === src) { voiceSrc = null; playNext(); } };
    voiceSrc = src;
    src.start(0);
  }
  function onAudio(clip) {
    if (!cfg.voice) return;
    // flush = câu mới cắt câu đang đọc (máy tính đang bật "ngắt câu đang đọc").
    if (clip.flush) stopVoice();
    voiceQueue.push(clip);
    if (voiceQueue.length > 8) voiceQueue.shift();   // tồn quá nhiều (mạng chậm) → bỏ câu cũ nhất
    loadClip(clip);
  }
  function stopVoice() {
    voiceGen++;
    voiceQueue = [];
    if (voiceSrc) { try { voiceSrc.stop(0); } catch (e) {} voiceSrc = null; }
  }

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
      if (rt.sse === 'đã kết nối') toast('Mất kết nối ' + s.name + ', đang thử lại…', true);
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
    es.addEventListener('entry', function (ev) {
      try { onEntry(JSON.parse(ev.data)); } catch (e) {}
    });
    es.addEventListener('cleared', function () { if (rt.histOpen) { hist = []; renderHistory(true); } });
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
      if (err || !j) { toast('Lỗi: ' + err, true); return; }
      if (!j.ok) { toast(j.error || 'Không bật được dịch', true); return; }
      // Trạng thái chính xác tới qua sự kiện "state"; báo ngay theo dự đoán.
      rt.running = !rt.running;
      updateStatus();
      toast(rt.running ? '▶ Đang dịch phụ đề' : '⏸ Đã tạm dừng dịch');
      if (rt.menuOpen) renderMenu();
    });
  }

  /// Dịch toàn màn hình: máy tính chụp hình game, OCR, dịch. Trong lúc chờ vẫn xem game, chỉ báo ⟳ ở dải phụ đề;
  /// xong mới mở ảnh với bản dịch đặt đè lên chữ gốc.
  function analyzeScreen() {
    if (rt.analyzeReq) return;   // đang chờ lần trước, ⟳ ở dải đã báo
    rt.analyzeReq = rt.analyzing = true;
    if (rt.menuOpen) { rt.menuOpen = false; menu.className = 'hidden'; showVideo(); }
    updateStatus();
    bandNote('Đang dịch màn hình…');
    api('POST', '/api/analyze', 90000, function (j, err) {
      rt.analyzeReq = rt.analyzing = false;
      bandNote(null);
      updateStatus();
      if (err || !j || !j.ok) { toast('Không dịch được màn hình: ' + (err || (j && j.error) || '?'), true); return; }
      if (rt.histOpen) closeHistory();
      if (rt.menuOpen) { rt.menuOpen = false; menu.className = 'hidden'; }
      openShot(j.id, overlay());
    });
  }

  // ---------- Xem ảnh "dịch màn hình" ----------
  var shots = [], shotIdx = 0, shotLive = false;   // shotLive: bản dịch vẽ thẳng lên hình game đang chạy, không hiện ảnh chụp
  // Nút OK xoay vòng: bản dịch → bản gốc → tóm tắt → bản dịch.
  var SHOT_MODES = ['trans', 'orig', 'sum'], SHOT_LABEL = { trans: 'bản dịch', orig: 'bản gốc', sum: 'tóm tắt' }, shotMode = 'trans';

  function loadShots(focusId) {
    api('GET', '/api/analyses', 15000, function (list, err) {
      if (err || !list) { closeShot(); toast('Không tải được ảnh: ' + err, true); return; }
      shots = list.filter(function (a) { return a.image; });   // mới nhất trước
      if (!shots.length) { closeShot(); toast('Chưa có ảnh dịch màn hình nào', true); return; }
      shotIdx = 0;
      for (var i = 0; i < shots.length; i++) if (shots[i].id === focusId) shotIdx = i;
      renderShot();
    });
  }

  /// focusId: -1 = mở ảnh mới nhất; số = mở đúng ảnh đó. live = vẽ bản dịch đè lên game (vừa dịch xong), không thì xem ảnh chụp.
  function openShot(focusId, live) {
    rt.shotOpen = true;
    shotLive = !!live;
    shotMode = 'trans';
    if (live) { shotEl.className = 'live'; shotEl.innerHTML = ''; }
    else { shotEl.className = ''; shotEl.innerHTML = '<div class="wait">Đang tải ảnh…</div>'; }
    loadShots(focusId);
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
    // Ảnh vừa khít 1920×1080, giữ tỉ lệ (hình game trên TV cũng full 1920×1080 nên khối chữ khớp đúng chỗ khi vẽ đè).
    var scale = Math.min(1920 / a.width, 1080 / a.height);
    var fw = a.width * scale, fh = a.height * scale, ox = (1920 - fw) / 2, oy = (1080 - fh) / 2;
    var html = shotLive ? '' : '<img src="' + s.url + '/api/shot/' + a.id + '.jpg" style="left:' + ox + 'px;top:' + oy + 'px;width:' + fw + 'px;height:' + fh + 'px">';
    if (shotMode === 'trans') {
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
    if (shotMode === 'sum') {
      html += '<div class="sumpanel"><div class="sumtitle">Tóm tắt</div>' +
              (a.summary ? esc(a.summary) : '<span class="dim">Không có tóm tắt cho lần dịch này (cần Gemini trên máy tính).</span>') + '</div>';
    }
    var nextMode = SHOT_MODES[(SHOT_MODES.indexOf(shotMode) + 1) % SHOT_MODES.length];
    if (shotLive) html += '<div class="livebar">Dịch màn hình · <b>' + SHOT_LABEL[shotMode] + '</b> · OK: xem ' + SHOT_LABEL[nextMode] + ' · ◀▶ xem ảnh chụp · Back: đóng</div>';
    else html += '<div class="bar"><span>Dịch màn hình · ' + (shotIdx + 1) + '/' + shots.length + ' · ' + hh + ' · đang xem: <b>' + SHOT_LABEL[shotMode] + '</b></span>' +
            '<span class="dim">◀▶ ảnh trước/sau · OK: xem ' + SHOT_LABEL[nextMode] + ' · Back: về game</span></div>';
    shotEl.innerHTML = html;
    shotEl.className = (shotLive ? 'live' : '') + (shotMode === 'sum' ? ' dimimg' : '');
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
    // Đang vẽ đè lên game: ◀▶ chuyển sang xem ảnh chụp (của lần dịch này, rồi lật sang ảnh cũ hơn).
    if (shotLive && (code === 37 || code === 39)) { shotLive = false; renderShot(); return; }
    switch (code) {
      case 37: if (shotIdx < shots.length - 1) { shotIdx++; renderShot(); } break;   // ◀ ảnh cũ hơn
      case 39: if (shotIdx > 0) { shotIdx--; renderShot(); } break;                   // ▶ ảnh mới hơn
      case 13: shotMode = SHOT_MODES[(SHOT_MODES.indexOf(shotMode) + 1) % SHOT_MODES.length]; renderShot(); break;   // OK: bản dịch → bản gốc → tóm tắt
      case 10252: case 415: case 19: toggleTranslate(); break;
      case 10009: closeShot(); break;                // Back: về game
    }
  }

  // ---------- Lịch sử phụ đề (Kênh ∧) ----------
  var hist = [], histScroll = 0, histSource = true, histNewFrom = Infinity;

  function openHistory() {
    rt.histOpen = true;
    histEl.className = '';
    histEl.innerHTML = '<div class="empty">Đang tải lịch sử…</div>';
    api('GET', '/api/log?limit=300', 15000, function (list, err) {
      if (!rt.histOpen) return;
      if (err || !list) { histEl.innerHTML = '<div class="empty">Không tải được lịch sử: ' + esc(err || '?') + '<br><br>Back để quay lại</div>'; return; }
      hist = list.slice().reverse();          // máy chủ trả mới nhất trước → đảo lại: cũ ở trên, mới ở dưới
      histNewFrom = Infinity;
      renderHistory(true);
    });
  }

  function closeHistory() {
    rt.histOpen = false;
    histEl.className = 'hidden';
    histEl.innerHTML = '';
    if (!rt.menuOpen && !rt.shotOpen) showVideo();
  }

  function renderHistory(toBottom) {
    var s = cfg.servers[cfg.server];
    var rows = '', prevAt = 0;
    hist.forEach(function (e, i) {
      // Cách nhau > 45 giây: sang đoạn hội thoại khác → mốc giờ.
      if (!prevAt || e.at - prevAt > 45) {
        var d = new Date(e.at * 1000);
        rows += '<div class="mark">— ' + ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2) + ' —</div>';
      }
      prevAt = e.at;
      var cls = 'row' + (e.skipped ? ' skip' : '') + (i >= histNewFrom ? ' new' : '');
      rows += '<div class="' + cls + '"><div class="tr">' + (e.skipped ? styled(e.source) : styled(e.translated)) + '</div>' +
              (histSource && !e.skipped ? '<div class="src">' + esc(e.source) + '</div>' : '') + '</div>';
    });
    histEl.innerHTML = '<div class="head"><span class="title">Lịch sử phụ đề' + (rt.game ? ' · ' + esc(rt.game) : '') + '</span>' +
      '<span class="dim">' + hist.length + ' câu · ▲▼ cuộn · ◀▶ lật trang · OK: ' + (histSource ? 'ẩn' : 'hiện') + ' câu gốc · Back: về game</span></div>' +
      '<div class="view"><div class="list">' + (rows || '<div class="empty">Chưa có câu nào được dịch trong game này.</div>') + '</div></div>';
    if (toBottom) histScroll = Infinity;
    scrollHistory(0);
  }

  function scrollHistory(dy) {
    var view = histEl.querySelector('.view'), list = histEl.querySelector('.list');
    if (!view || !list) return;
    var max = Math.max(0, list.scrollHeight - view.clientHeight);
    histScroll = Math.max(0, Math.min(max, (histScroll === Infinity ? max : histScroll) + dy));
    list.style.transform = 'translateY(' + (-histScroll) + 'px)';
  }

  /// Câu mới trong lúc đang xem lịch sử: thêm vào cuối; đang ở cuối thì cuộn theo.
  function onEntry(e) {
    if (!rt.histOpen || !hist) return;
    var view = histEl.querySelector('.view'), list = histEl.querySelector('.list');
    var atBottom = !view || !list || histScroll >= list.scrollHeight - view.clientHeight - 10;
    if (histNewFrom === Infinity) histNewFrom = hist.length;
    hist.push(e);
    if (hist.length > 600) { hist.shift(); histNewFrom--; }
    renderHistory(false);
    if (atBottom) { histScroll = Infinity; scrollHistory(0); }
  }

  function histKey(code) {
    switch (code) {
      case 38: scrollHistory(-160); break;
      case 40: scrollHistory(160); break;
      case 37: scrollHistory(-800); break;
      case 39: scrollHistory(800); break;
      case 13: histSource = !histSource; var keep = histScroll; renderHistory(false); histScroll = keep; scrollHistory(0); break;
      case 427: case 10009: closeHistory(); break;
      case 10252: case 415: case 19: toggleTranslate(); break;
    }
  }

  // ---------- Menu ----------
  var screen = 'connect';   // connect | settings | ip
  var delMark = -1;        // máy đang chờ xác nhận xoá
  var menuScroll = 0;      // vị trí cuộn của danh sách (giữ qua các lần vẽ lại)
  var sel = 0;
  var ipEdit = { oct: [192, 168, 8, 0], idx: 3, typed: '' };

  function openMenu(which) {
    screen = which; sel = 0; menuScroll = 0;
    rt.menuOpen = true;
    menu.className = '';
    if (which === 'connect') {
      sel = Math.max(0, cfg.server);
      for (var i = 0; i < cfg.servers.length; i++) probeServer(i);
      // Lần đầu mở màn chọn máy: tự dò LAN một lần để thêm máy đang chạy ScreenTranslator.
      if (!autoScanned) { autoScanned = true; scanLan(); }
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
      { label: 'Lịch sử phụ đề đã dịch', val: '', action: true, sub: 'Khi đang xem: bấm Kênh ∧',
        ok: function () { rt.menuOpen = false; menu.className = 'hidden'; openHistory(); } },
      { label: 'Xem lại ảnh đã dịch', val: '', action: true, sub: 'Khi đang xem: bấm Kênh ∨',
        ok: function () { rt.menuOpen = false; menu.className = 'hidden'; openShot(-1); } },
      { label: 'Máy tính', val: s ? s.name + ' · ' + host(s.url) : 'chưa chọn', sub: rt.sse + (rt.game ? ' · game: ' + rt.game + (rt.running ? ' (đang dịch)' : ' (đã dừng)') : ''),
        ok: function () { openMenu('connect'); } },
      { label: 'Cổng HDMI', val: rt.hdmi ? 'HDMI ' + rt.hdmi : 'chưa có', sub: 'Có tín hiệu: ' + (ports.length ? ports.map(function (p) { return 'HDMI ' + p; }).join(', ') : 'không'),
        lr: function (d) { if (!ports.length) return; var i = ports.indexOf(rt.hdmi); useHdmi(ports[(i + d + ports.length) % ports.length], true); } },
      { label: 'Kiểu hiển thị phụ đề', val: overlay() ? 'Đè lên hình game' : 'Dải đen dưới hình',
        sub: overlay() ? 'Game full màn hình, phụ đề / icon / bản dịch màn hình vẽ thẳng lên game' : 'Hình game thu nhỏ một chút, phụ đề nằm trong dải đen riêng',
        lr: function () { cfg.layout = overlay() ? 'band' : 'overlay'; save(); applyLayout(); }, ok: function () { cfg.layout = overlay() ? 'band' : 'overlay'; save(); applyLayout(); } },
    ].concat(overlay() ? [
      { label: 'Nền phụ đề', val: { box: 'Nền mờ', solid: 'Nền đậm', none: 'Không nền (chữ viền đen)' }[cfg.subBg] || 'Nền mờ', sub: 'Nền đậm che hẳn phụ đề tiếng Anh của game',
        lr: function (d) { var o = ['box', 'solid', 'none'], i = o.indexOf(cfg.subBg); cfg.subBg = o[((i < 0 ? 0 : i) + d + 3) % 3]; save(); applyBand(); } },
      { label: 'Vị trí phụ đề', val: cfg.subY + ' px từ mép ' + (cfg.position === 'top' ? 'trên' : 'dưới'), sub: 'Khi đang xem: ▲ ▼',
        lr: function (d) { cfg.subY = Math.max(0, Math.min(900, cfg.subY + d * 20)); save(); applyBand(); } },
      { label: 'Cỡ chữ', val: '×' + cfg.fontScale.toFixed(1), sub: 'Khi đang xem: ◀ ▶',
        lr: function (d) { cfg.fontScale = Math.round(Math.max(0.5, Math.min(2, cfg.fontScale + d * 0.1)) * 10) / 10; save(); } },
    ] : [
      { label: 'Độ dày dải phụ đề', val: cfg.band + ' px', sub: 'Khi đang xem: ◀ ▶ (20–260 px)',
        lr: function (d) { cfg.band = Math.max(20, Math.min(260, cfg.band + d * (cfg.band > 60 || (cfg.band === 60 && d > 0) ? 10 : 5))); save(); } },
      { label: 'Cỡ chữ', val: '×' + cfg.fontScale.toFixed(1), sub: 'Khi đang xem: ▲ ▼',
        lr: function (d) { cfg.fontScale = Math.round(Math.max(0.5, Math.min(1.6, cfg.fontScale + d * 0.1)) * 10) / 10; save(); } },
    ]).concat([
      { label: 'Giọng đọc trên TV', val: onOff(cfg.voice), sub: 'Cần bật "Phát giọng đọc trên TV / điện thoại" trong Cài đặt → Voice của app máy tính',
        lr: function () { cfg.voice = !cfg.voice; if (!cfg.voice) stopVoice(); save(); }, ok: function () { cfg.voice = !cfg.voice; if (!cfg.voice) stopVoice(); save(); } },
      { label: 'Âm lượng giọng đọc', val: cfg.voiceVolume + '%', sub: 'So với tiếng game (âm lượng chung vẫn chỉnh bằng nút + − trên remote)',
        lr: function (d) { cfg.voiceVolume = Math.max(10, Math.min(100, cfg.voiceVolume + d * 10)); if (gain) gain.gain.value = cfg.voiceVolume / 100; save(); } },
      { label: 'Hiện câu phụ đề trước', val: onOff(cfg.showPrev), sub: 'Chữ nhỏ, mờ ở phía trên câu hiện tại' + (overlay() ? '' : ' (dải đen cần dày từ 90 px)'),
        lr: function () { cfg.showPrev = !cfg.showPrev; save(); }, ok: function () { cfg.showPrev = !cfg.showPrev; save(); } },
      { label: 'Hiện câu gốc tiếng Anh', val: onOff(cfg.showSource), sub: 'Dưới bản dịch trong dải phụ đề',
        lr: function () { cfg.showSource = !cfg.showSource; save(); }, ok: function () { cfg.showSource = !cfg.showSource; save(); } },
      { label: overlay() ? 'Phụ đề ở phía' : 'Vị trí dải phụ đề', val: cfg.position === 'top' ? 'Trên cùng' : 'Dưới cùng', sub: '',
        lr: function () { cfg.position = cfg.position === 'top' ? 'bottom' : 'top'; save(); applyLayout(); }, ok: function () { cfg.position = cfg.position === 'top' ? 'bottom' : 'top'; save(); applyLayout(); } },
      { label: 'Giữ câu phụ đề cuối', val: cfg.keepLast ? cfg.keepLast + ' giây rồi ẩn' : 'Giữ mãi (tới câu mới)', sub: '',
        lr: function (d) {
          // Mỗi bước 2 giây tới 60 giây, sau đó 90, 120, rồi Giữ mãi (0).
          var opts = []; for (var s = 2; s <= 60; s += 2) opts.push(s); opts.push(90, 120, 0);
          var i = opts.indexOf(cfg.keepLast);
          if (i < 0) {   // giá trị cũ không nằm trong danh sách (vd. 45) → lấy mức gần nhất
            i = 0;
            for (var k = 1; k < opts.length - 1; k++) if (Math.abs(opts[k] - cfg.keepLast) < Math.abs(opts[i] - cfg.keepLast)) i = k;
          }
          cfg.keepLast = opts[(i + d + opts.length) % opts.length]; save();
        } },
    ]).concat(overlay() ? [] : [
      { label: 'Tự thu gọn dải khi hết phụ đề', val: onOff(cfg.autoCollapse),
        sub: 'Hết thời gian giữ câu cuối thì game full màn hình, có câu mới dải hiện lại' + (cfg.keepLast ? '' : ' (cần chọn thời gian giữ, không phải Giữ mãi)'),
        lr: function () { cfg.autoCollapse = !cfg.autoCollapse; if (!cfg.autoCollapse) rt.collapsed = false; save(); },
        ok: function () { cfg.autoCollapse = !cfg.autoCollapse; if (!cfg.autoCollapse) rt.collapsed = false; save(); } },
    ]).concat([
      { label: 'Màu theo nhân vật', val: { line: 'Cả câu', name: 'Chỉ tên', off: 'Tắt' }[cfg.speakerColor] || 'Cả câu',
        sub: 'Mỗi nhân vật một màu như app máy tính (cần bật hiện tên nhân vật trên máy tính)',
        lr: function (d) { var o = ['line', 'name', 'off'], i = o.indexOf(cfg.speakerColor); cfg.speakerColor = o[((i < 0 ? 0 : i) + d + 3) % 3]; save(); } },
      { label: 'Hỏi chọn máy tính khi mở app', val: onOff(cfg.askOnStart), sub: 'Tắt thì tự kết nối máy đã chọn lần trước',
        lr: function () { cfg.askOnStart = !cfg.askOnStart; save(); }, ok: function () { cfg.askOnStart = !cfg.askOnStart; save(); } },
      { label: 'Hướng dẫn phím remote', val: '', action: true, sub: '', ok: function () { screen = 'help'; sel = 1; menuScroll = 0; } },
      { label: '▶ Quay lại xem', val: '', sub: '', ok: closeMenu },
      { label: 'Thoát app', val: '', sub: '', danger: true, ok: exitApp },
    ]);
  }

  // ---------- Tự dò máy chạy ScreenTranslator trong mạng LAN ----------
  var scanning = false, scanFound = 0, autoScanned = false;
  /// Lấy IP của chính TV (Wi-Fi hoặc dây mạng) để biết subnet.
  function localIp(cb) {
    function tryProp(prop, next) {
      try {
        tizen.systeminfo.getPropertyValue(prop, function (d) {
          if (d && d.ipAddress && /^\d+\.\d+\.\d+\.\d+$/.test(d.ipAddress)) cb(d.ipAddress); else next();
        }, next);
      } catch (e) { next(); }
    }
    tryProp('WIFI_NETWORK', function () { tryProp('ETHERNET_NETWORK', function () { cb(null); }); });
  }
  function hasServer(url) { for (var i = 0; i < cfg.servers.length; i++) if (cfg.servers[i].url === url) return true; return false; }
  /// Quét x.y.z.1–254 cổng 8787, máy nào trả lời /api/log (JSON) thì là ScreenTranslator → tự thêm.
  function scanLan() {
    if (scanning) return;
    localIp(function (ip) {
      if (!ip) { toast('Không lấy được IP của TV để dò máy', true); return; }
      var base = ip.slice(0, ip.lastIndexOf('.') + 1);
      scanning = true; scanFound = 0;
      dbg('scanLan ' + base + '1-254');
      if (rt.menuOpen) renderMenu();
      var next = 1, done = 0;
      function finishOne() {
        if (++done >= 254) {
          scanning = false;
          toast(scanFound > 0 ? 'Tìm thấy ' + scanFound + ' máy' : 'Không thấy máy nào đang chạy ScreenTranslator (mở app trên máy tính, bật máy chủ Web)', scanFound === 0);
          for (var i = 0; i < cfg.servers.length; i++) probeServer(i);
          if (rt.menuOpen) renderMenu();
          return;
        }
        pump();
      }
      function probeHost(n) {
        var url = 'http://' + base + n + ':8787';
        if (hasServer(url)) { finishOne(); return; }
        var x = new XMLHttpRequest(), fin = false;
        x.timeout = 1500;
        function end() { if (fin) return; fin = true; finishOne(); }
        try { x.open('GET', url + '/api/log?limit=1'); } catch (e) { end(); return; }
        x.onload = function () {
          if (fin) return; fin = true;
          var ok = false;
          if (x.status === 200) { try { ok = JSON.parse(x.responseText) instanceof Array; } catch (e) {} }
          if (ok && !hasServer(url)) { cfg.servers.push({ name: 'Máy ' + base + n, url: url }); save(); scanFound++; if (rt.menuOpen) renderMenu(); }
          finishOne();
        };
        x.onerror = x.ontimeout = end;
        try { x.send(); } catch (e) { end(); }
      }
      // Chạy tối đa ~24 yêu cầu cùng lúc cho nhanh mà không nghẽn.
      function pump() { while ((next - 1) - done < 24 && next <= 254) probeHost(next++); }
      pump();
    });
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
    items.push({ label: (scanning ? '🔎 Đang dò… (thấy ' + scanFound + ')' : '🔎 Dò máy trong mạng'), val: '', action: true,
      sub: 'Tự tìm máy tính trong cùng mạng Wi-Fi/LAN đang chạy ScreenTranslator',
      ok: function () { scanLan(); } });
    items.push({ label: '+ Nhập địa chỉ IP máy khác…', val: '', sub: '', ok: function () {
      var cur = cfg.servers[cfg.server];
      var m = cur ? /(\d+)\.(\d+)\.(\d+)\.(\d+)/.exec(cur.url) : null;
      ipEdit = { oct: m ? [+m[1], +m[2], +m[3], +m[4]] : [192, 168, 8, 0], idx: 3, typed: '' };
      screen = 'ip'; renderMenu();
    } });
    items.push({ label: 'Chỉ xem hình, không kết nối', val: '', sub: '', ok: function () { cfg.server = -1; save(); connect(); closeMenu(); } });
    return items;
  }

  /// Sơ đồ phím remote (Samsung Smart Remote) cho từng màn hình.
  function helpGroups() { return [
    ['Đang xem game', [['⏯', 'Tạm dừng / tiếp tục dịch phụ đề'], ['OK', 'Dịch toàn màn hình (xong mới vẽ bản dịch lên game)']].concat(overlay()
      ? [['▲ ▼', 'Dời phụ đề lên / xuống'], ['◀ ▶', 'Cỡ chữ phụ đề']]
      : [['◀ ▶', 'Mỏng / dày dải phụ đề'], ['▲ ▼', 'Cỡ chữ phụ đề']]).concat(
      [['Kênh ∧', 'Lịch sử phụ đề đã dịch'], ['Kênh ∨', 'Xem lại ảnh đã dịch'], ['123 → 1–4', 'Chọn cổng HDMI'], ['Back', 'Mở menu']])],
    ['Bản dịch màn hình (vẽ đè lên game)', [['OK', 'Bản dịch → bản gốc → tóm tắt'], ['◀ ▶', 'Xem ảnh chụp'], ['Back', 'Đóng']]],
    ['Lịch sử phụ đề', [['▲ ▼', 'Cuộn'], ['◀ ▶', 'Lật trang'], ['OK', 'Hiện / ẩn câu gốc'], ['⏯', 'Tạm dừng / tiếp tục dịch'], ['Back, Kênh ∧', 'Về game']]],
    ['Ảnh dịch màn hình', [['◀ ▶', 'Ảnh trước / sau'], ['OK', 'Bản dịch → bản gốc → tóm tắt'], ['Back', 'Về game']]],
    ['Menu', [['▲ ▼', 'Chọn mục'], ['◀ ▶', 'Đổi giá trị'], ['OK', 'Chọn'], ['⏯', 'Tạm dừng / tiếp tục dịch'], ['Back', 'Quay lại']]],
  ]; }
  function helpItems() {
    var items = [];
    helpGroups().forEach(function (g) {
      items.push({ label: g[0], val: '', sub: '', group: true });
      g[1].forEach(function (k) { items.push({ label: k[1], val: k[0], sub: '' }); });
    });
    items.push({ label: '◀ Quay lại cài đặt', val: '', sub: '', ok: function () { screen = 'settings'; sel = 0; menuScroll = 0; } });
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
      '<br><br>Khi đang xem game:<br>⏯ tạm dừng / tiếp tục dịch<br>OK dịch toàn màn hình<br>' + (overlay() ? '▲▼ vị trí · ◀▶ cỡ chữ' : '◀▶ dải phụ đề · ▲▼ cỡ chữ') + '<br>Kênh ∧ lịch sử phụ đề<br>Kênh ∨ ảnh đã dịch<br>Back mở menu này</div>' +
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
      var items = menuItems();
      sel = Math.max(0, Math.min(items.length - 1, sel));
      main = '<h2>' + (screen === 'connect' ? 'Chọn máy tính đang chạy ScreenTranslator' : screen === 'help' ? 'Hướng dẫn phím remote' : 'Cài đặt') + '</h2>' +
        items.map(function (it, i) {
          if (it.group) return '<div class="group">' + esc(it.label) + '</div>';
          return '<div data-i="' + i + '" class="item' + (i === sel ? ' sel' : '') + (screen === 'help' && !it.ok ? ' key' : '') + (it.danger ? ' danger' : '') + (it.action ? ' action' : '') + '"><div><div>' + (it.html ? it.label : esc(it.label)) + '</div>' +
            (it.sub ? '<div class="sub">' + esc(it.sub) + '</div>' : '') + '</div>' +
            '<div class="val">' + (it.lr ? '<span class="arrow">◀</span>' : '') + esc(it.val) + (it.lr ? '<span class="arrow">▶</span>' : '') + '</div></div>';
        }).join('') +
        (screen === 'connect' && cfg.servers.length > 2 ? '<div class="hint">Máy tự thêm: bấm ◀ hoặc ▶ rồi OK để xoá</div>' : '');
    }
    menu.innerHTML = side + '<div class="main"><div class="list">' + main + '</div><div class="more up">▲</div><div class="more down">▼</div></div>';
    keepSelectedVisible();
  }

  /// Danh sách dài hơn màn hình: cuộn để mục đang chọn luôn nằm trong khung, kèm mũi tên báo còn mục phía trên / dưới.
  function keepSelectedVisible() {
    var box = menu.querySelector('.main'), list = menu.querySelector('.list');
    if (!box || !list) return;
    var it = list.querySelector('.item.sel');
    var view = box.clientHeight - 40;
    if (it) {
      var top = it.offsetTop, bottom = top + it.offsetHeight;
      if (top - 60 < menuScroll) menuScroll = Math.max(0, top - 60);
      if (bottom + 40 > menuScroll + view) menuScroll = bottom + 40 - view;
    }
    var max = Math.max(0, list.scrollHeight - view);
    menuScroll = Math.max(0, Math.min(max, menuScroll));
    list.style.transform = 'translateY(' + (-menuScroll) + 'px)';
    menu.querySelector('.more.up').style.visibility = menuScroll > 2 ? 'visible' : 'hidden';
    menu.querySelector('.more.down').style.visibility = menuScroll < max - 2 ? 'visible' : 'hidden';
  }

  function menuItems() { return screen === 'connect' ? connectItems() : screen === 'help' ? helpItems() : settingsItems(); }
  /// Bước ▲▼ bỏ qua dòng tiêu đề nhóm (không chọn được).
  function moveSel(items, d) {
    for (var n = 0; n < items.length; n++) { sel = (sel + d + items.length) % items.length; if (!items[sel].group) return; }
  }
  function menuKey(code) {
    if (screen === 'ip') return ipKey(code);
    var items = menuItems();
    if (items[sel] && items[sel].group) moveSel(items, 1);
    var it = items[sel];
    switch (code) {
      // ▲▼: chỉ dời khung chọn + cuộn, không vẽ lại cả menu (vẽ lại toàn bộ làm màn hình giật).
      case 38: case 40:
        var old = sel;
        moveSel(items, code === 38 ? -1 : 1);
        var a = menu.querySelector('.item[data-i="' + old + '"]'), b = menu.querySelector('.item[data-i="' + sel + '"]');
        if (a && b) { a.classList.remove('sel'); b.classList.add('sel'); keepSelectedVisible(); return; }
        break;
      case 37: if (it.lr) it.lr(-1); break;
      case 39: if (it.lr) it.lr(1); break;
      case 13: if (it.ok) { it.ok(); if (!rt.menuOpen) return; } break;
      case 10252: case 415: case 19: toggleTranslate(); break;
      case 10009:
        if (screen === 'help') { screen = 'settings'; sel = 0; menuScroll = 0; break; }
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
    try { handleKey(e); }
    catch (err) {
      try { console.error('Lỗi xử lý phím ' + e.keyCode + ': ' + (err && err.stack || err)); } catch (x) {}
      recover();
    }
  });
  /// Có lỗi ngoài ý muốn: đóng mọi màn hình phụ, quay lại hình game (không để app treo / thoát).
  function recover() {
    try { rt.histOpen = false; histEl.className = 'hidden'; histEl.innerHTML = ''; } catch (x) {}
    try { rt.shotOpen = false; shotEl.className = 'hidden'; shotEl.innerHTML = ''; } catch (x) {}
    try { rt.menuOpen = false; menu.className = 'hidden'; } catch (x) {}
    try { if (rt.hdmi) showVideo(); else startVideo(); } catch (x) {}
  }
  window.onerror = function (msg, src, line) {
    showErr('Lỗi: ' + msg + ' @' + line);
    recover();
    return true;
  };
  function handleKey(e) {
    if (rt.histOpen) { e.preventDefault(); histKey(e.keyCode); return; }
    if (rt.shotOpen) { e.preventDefault(); shotKey(e.keyCode); return; }
    if (rt.menuOpen) { e.preventDefault(); menuKey(e.keyCode); return; }
    if (overlay()) switch (e.keyCode) {
      case 38: case 40:   // ▲▼: dời phụ đề lên / xuống
        var up = e.keyCode === 38 ? 1 : -1;
        cfg.subY = Math.max(0, Math.min(900, cfg.subY + (cfg.position === 'top' ? -up : up) * 20)); save(); applyBand(); previewSub(); return;
      case 37: case 39:   // ◀▶: cỡ chữ
        cfg.fontScale = Math.round(Math.max(0.5, Math.min(2, cfg.fontScale + (e.keyCode === 39 ? 0.02 : -0.02))) * 50) / 50; save(); previewSub(); return;
    }
    switch (e.keyCode) {
      case 37: setCollapsed(false); cfg.band = Math.max(20, cfg.band - (cfg.band > 60 ? 10 : 5)); save(); applyBand(); showVideo(); if (rt.last) showSubtitle(rt.last); toast('Dải phụ đề ' + cfg.band + ' px'); break;
      case 39: setCollapsed(false); cfg.band = Math.min(260, cfg.band + (cfg.band >= 60 ? 10 : 5)); save(); applyBand(); showVideo(); if (rt.last) showSubtitle(rt.last); toast('Dải phụ đề ' + cfg.band + ' px'); break;
      case 38: cfg.fontScale = Math.min(1.6, Math.round((cfg.fontScale + 0.1) * 10) / 10); save(); if (rt.last) showSubtitle(rt.last); break;
      case 40: cfg.fontScale = Math.max(0.5, Math.round((cfg.fontScale - 0.1) * 10) / 10); save(); if (rt.last) showSubtitle(rt.last); break;
      case 427: openHistory(); break;                                                                                                                         // Kênh ∧: lịch sử phụ đề
      case 403: cfg.showSource = !cfg.showSource; save(); if (rt.last) showSubtitle(rt.last); toast('Câu gốc: ' + (cfg.showSource ? 'hiện' : 'ẩn')); break;
      case 428: openShot(-1); break;                                                                                                                            // Kênh ∨
      case 49: case 50: case 51: case 52: var n = e.keyCode - 48; withSources(function () { useHdmi(n); }); break;
      case 10009: e.preventDefault(); openMenu('settings'); break;            // Back: mở menu (không thoát app)
      case 10252: case 415: case 19: toggleTranslate(); break;                // ⏯: bật / tắt dịch
      case 13: case 404: case 48: analyzeScreen(); break;                     // OK (hoặc Xanh lá / 0): dịch toàn màn hình
    }
  }

  window.onload = function () {
    try {
      dbg('onload askOnStart=' + cfg.askOnStart + ' server=' + cfg.server);
      // Dấu crash còn sót → lần trước app thoát ngay khi đang làm việc này. Tắt tự hiện hình và báo lên màn hình.
      var pend = pendingVideo();
      if (pend) {
        clearVideo();
        cfg.videoDisabled = true; save();
        showErr('Lần trước app thoát khi đang: ' + pend + '. Đã tắt tự hiện hình HDMI. Bấm số HDMI (1–4) trên remote để thử lại, hoặc mở Menu (Back).');
      }
      registerKeys();
      document.body.className = document.documentElement.className = overlay() ? 'ovl' : '';
      applyBand();
      withSources(function () {
        if (cfg.askOnStart || cfg.server < 0) { openMenu('connect'); }
        else { connect(); startVideo(); }
      });
      // Nguồn HDMI được cắm / rút → cập nhật danh sách (để menu hiện đúng).
      setInterval(function () { withSources(function () { if (rt.menuOpen) renderMenu(); }); }, 5000);
    } catch (e) { showErr('Lỗi khởi động: ' + (e && e.message || e)); }
  };
})();
