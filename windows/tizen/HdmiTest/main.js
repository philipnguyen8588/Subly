// HDMI Test: app tối giản để thử trên TV lạ. Mở lên → lấy danh sách nguồn → setSource HDMI đầu tiên có tín hiệu
// → tvwindow.show BEHIND toàn màn hình → vẽ câu phụ đề mẫu (đổi mỗi 4 giây).
// Phím: 1–4 chọn cổng HDMI · OK ẩn/hiện phụ đề · Back thoát app.
// Góc trái: nhật ký lần này (giây kể từ lúc mở). Góc phải (cam): 14 bước cuối của LẦN TRƯỚC nếu lần trước thoát bất thường.
(function () {
  'use strict';
  var T0 = Date.now(), trail = [], lines = [];
  var logEl = document.getElementById('log'), prevEl = document.getElementById('prev'), subEl = document.getElementById('sub');

  function log(m) {
    var line = ((Date.now() - T0) / 1000).toFixed(1) + 's ' + m;
    lines.push(line); if (lines.length > 16) lines.shift();
    trail.push(line); if (trail.length > 14) trail.shift();
    try { logEl.textContent = lines.join('\n'); } catch (e) {}
    try { localStorage.setItem('trail', trail.join('\n')); } catch (e) {}
    try { console.error('[HDMI-TEST] ' + line); } catch (e) {}
  }

  // Dấu vết lần trước (sống sót qua việc app bị tắt).
  try {
    var prev = localStorage.getItem('trail') || '';
    localStorage.removeItem('trail');
    if (prev && prev.indexOf('nguoi dung thoat') < 0) prevEl.textContent = 'LẦN TRƯỚC (trước khi app thoát):\n' + prev;
    else prevEl.style.display = 'none';
  } catch (e) {}

  // Vòng đời: TV ẩn app (đổi nguồn, popup…) / app bị đóng.
  document.addEventListener('visibilitychange', function () { log(document.hidden ? 'TV AN APP (hidden)' : 'app hien lai'); });
  window.addEventListener('pagehide', function () { log('pagehide'); });
  window.addEventListener('beforeunload', function () { log('beforeunload'); });
  window.addEventListener('unload', function () { log('unload'); });
  window.addEventListener('blur', function () { log('window blur'); });
  window.addEventListener('focus', function () { log('window focus'); });
  try {
    if (window.tizen && tizen.application && tizen.application.addAppStatusChangeListener)
      tizen.application.addAppStatusChangeListener(function (appId, on) { log('app TV ' + (on ? 'MO' : 'tat') + ': ' + appId); });
  } catch (e) { log('khong nghe duoc app status: ' + e.message); }
  window.onerror = function (msg, src, line) { log('JS LOI: ' + msg + ' @' + line); return true; };

  // ---------- Hình HDMI ----------
  var sources = [];
  function useHdmi(n) {
    var src = null;
    for (var i = 0; i < sources.length; i++) if (sources[i].type === 'HDMI' && sources[i].number === n) src = sources[i];
    if (!src) { log('HDMI' + n + ' khong co tin hieu'); return; }
    log('setSource HDMI' + n);
    try {
      tizen.tvwindow.setSource(src, function () {
        log('setSource OK HDMI' + n);
        try {
          tizen.tvwindow.show(function () { log('show OK (BEHIND 1920x1080)'); },
            function (e) { log('show LOI: ' + e.message); }, ['0px', '0px', '1920px', '1080px'], 'MAIN', 'BEHIND');
          log('show da goi');
        } catch (e) { log('show exception: ' + e.message); }
      }, function (e) { log('setSource LOI: ' + e.message); }, 'MAIN');
    } catch (e) { log('setSource exception: ' + e.message); }
  }
  function start() {
    log('lay VIDEOSOURCE');
    try {
      tizen.systeminfo.getPropertyValue('VIDEOSOURCE', function (vs) {
        sources = vs.connected || [];
        var hdmi = [];
        for (var i = 0; i < sources.length; i++) if (sources[i].type === 'HDMI') hdmi.push(sources[i].number);
        log('HDMI co tin hieu: ' + (hdmi.length ? hdmi.join(', ') : 'KHONG CO'));
        if (hdmi.length) useHdmi(hdmi[0]); else log('Bat PS5 len roi bam so cong HDMI (1-4)');
      }, function (e) { log('VIDEOSOURCE LOI: ' + e.message); });
    } catch (e) { log('systeminfo exception: ' + e.message); }
  }

  // ---------- Phụ đề mẫu ----------
  var SAMPLES = ['Kratos: Phụ đề mẫu số một — hình HDMI phải thấy phía sau.', 'Atreus: Câu thứ hai, đổi mỗi 4 giây.',
    'Mimir: Nếu app sống quá 30 giây mà vẫn thấy hình là ổn.', 'Freya: Bấm Back để thoát, bấm OK để ẩn / hiện phụ đề.'];
  var si = 0, subOn = true;
  function nextSub() { if (subOn) subEl.innerHTML = '<span>' + SAMPLES[si++ % SAMPLES.length] + '</span>'; }
  setInterval(nextSub, 4000);
  setInterval(function () { log('song ' + Math.round((Date.now() - T0) / 1000) + 's'); }, 10000);

  // ---------- Phím ----------
  try { ['1', '2', '3', '4'].forEach(function (k) { tizen.tvinputdevice.registerKey(k); }); } catch (e) {}
  document.addEventListener('keydown', function (e) {
    var c = e.keyCode;
    if (c >= 49 && c <= 52) { useHdmi(c - 48); return; }
    if (c === 13) { subOn = !subOn; subEl.innerHTML = ''; if (subOn) nextSub(); return; }
    if (c === 10009) {
      log('nguoi dung thoat');
      try { tizen.tvwindow.hide(function () {}, function () {}, 'MAIN'); } catch (x) {}
      try { tizen.application.getCurrentApplication().exit(); } catch (x) {}
    }
  });

  window.onload = function () {
    log('onload');
    try { tizen.tvwindow.hide(function () {}, function () {}, 'MAIN'); } catch (e) {}   // dọn cửa sổ mồ côi
    nextSub();
    start();
  };
})();
