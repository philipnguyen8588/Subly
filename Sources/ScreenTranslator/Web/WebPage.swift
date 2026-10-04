/// Trang web một file (HTML + CSS + JS) mà WebServer trả về cho iPhone/iPad.
enum WebPage {
    static let html = #"""
<!doctype html>
<html lang="vi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Phụ đề">
<meta name="theme-color" content="#000000">
<link rel="apple-touch-icon" href="/icon.png">
<title>ScreenTranslator</title>
<style>
:root {
  --bg: #000; --panel: #131316; --line: #26262b; --text: #f4f1ea; --dim: #8d8d96; --faint: #5c5c66;
  --accent: #ffc857; --ok: #4cd08a; --bad: #ff6b5e; --fs: 30px;
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin: 0; height: 100%; background: var(--bg); color: var(--text); overscroll-behavior: none;
  font: 16px/1.4 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; -webkit-text-size-adjust: 100%; }
body { touch-action: manipulation; }
button, input { font: inherit; color: inherit; }
#app { display: flex; flex-direction: column; height: 100dvh;
  padding: env(safe-area-inset-top) env(safe-area-inset-right) 0 env(safe-area-inset-left); }

header { display: flex; align-items: center; gap: 8px; padding: 10px 16px; font-size: 13px; color: var(--dim); }
#dot { width: 8px; height: 8px; border-radius: 50%; background: var(--faint); flex: none; }
#dot.on { background: var(--ok); box-shadow: 0 0 8px var(--ok); }
#dot.off { background: var(--bad); }
#status { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.tools { display: flex; gap: 6px; }
.tools button { min-width: 40px; height: 32px; padding: 0 10px; border: 1px solid var(--line); border-radius: 8px;
  background: var(--panel); color: var(--dim); font-size: 13px; font-weight: 600; }
.tools button.active { color: var(--accent); border-color: var(--accent); }

main { flex: 1; min-height: 0; position: relative; }
section { position: absolute; inset: 0; display: none; }
section.show { display: flex; flex-direction: column; }
.empty { color: var(--faint); font-size: 16px; font-weight: 400; }

/* Phụ đề: câu cũ mờ ở trên (cuộn lên để xem lại), câu đang dịch chữ lớn ở dưới cùng. */
#live { overflow: hidden; }
#lines { flex: 1; min-height: 0; display: flex; flex-direction: column; gap: 14px; padding: 52px 22px 18px;
  text-align: center; overflow-y: auto; -webkit-overflow-scrolling: touch; }
#hist { margin-top: auto; display: flex; flex-direction: column; gap: 12px; font-size: calc(var(--fs) * .6);
  line-height: 1.3; text-wrap: balance; opacity: .5; }
#hist:empty { display: none; }
#cur { font-size: var(--fs); line-height: 1.28; font-weight: 600; text-wrap: balance; transition: opacity .6s; }
#hist:empty + #cur { margin-top: auto; }
#cur.old { opacity: .7; }
#src { color: var(--dim); font-size: calc(var(--fs) * .5); line-height: 1.35; text-wrap: balance; }
#live.nosrc #src { display: none; }
.name { font-weight: 700; }

/* Hai nút nổi ở góc trên trái của màn phụ đề */
#float { position: absolute; top: 6px; left: 14px; z-index: 2; display: flex; flex-wrap: wrap; gap: 8px; max-width: calc(100% - 28px); }
.pill { display: inline-flex; align-items: center; gap: 7px; height: 34px; padding: 0 14px 0 12px; border-radius: 17px;
  border: 1px solid rgba(255, 255, 255, .13); background: rgba(26, 26, 31, .72); -webkit-backdrop-filter: blur(14px);
  backdrop-filter: blur(14px); box-shadow: 0 4px 14px rgba(0, 0, 0, .45); color: var(--text); font-size: 13.5px; font-weight: 600; }
.pill svg { width: 13px; height: 13px; fill: currentColor; flex: none; }
.pill:active { transform: scale(.96); }
.pill:disabled { opacity: .5; }
#toggle svg { color: var(--ok); }
#toggle.running svg { color: var(--bad); }
#scanLive svg { color: var(--accent); }
#liveMsg { flex-basis: 100%; padding: 7px 12px; border-radius: 10px; background: rgba(60, 16, 12, .9); color: #ffb4ab; font-size: 13.5px; }
#liveMsg:empty { display: none; }

/* Nhật ký */
#filter { margin: 4px 16px 8px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 10px;
  background: var(--panel); outline: none; }
#filter:focus { border-color: var(--accent); }
.scroll { flex: 1; overflow-y: auto; -webkit-overflow-scrolling: touch; padding: 0 16px 16px; }
.row { padding: 11px 0; border-bottom: 1px solid var(--line); }
.row time { display: block; color: var(--faint); font-size: 12px; font-variant-numeric: tabular-nums; margin-bottom: 2px; }
.row .t { font-size: 17px; line-height: 1.35; }
.row .s { color: var(--dim); font-size: 14px; margin-top: 3px; }
.row.skip .t { color: var(--dim); font-size: 15px; }
#logList .row:last-child { border-bottom: 0; }

/* Dịch màn hình */
#scanBar { display: flex; align-items: center; gap: 12px; margin: 4px 16px 10px; }
#go { height: 40px; padding: 0 18px; border: 0; border-radius: 20px; background: var(--accent); color: #17130a;
  font-size: 15px; font-weight: 700; flex: none; }
#go:disabled { opacity: .55; }
#msg { font-size: 13.5px; color: var(--dim); }
#msg.err { color: var(--bad); }
#shots { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 10px; margin-bottom: 14px; }
#shots:empty { display: none; }
.shot { padding: 6px; border: 1px solid var(--line); border-radius: 12px; background: var(--panel); text-align: left; }
.shot img { display: block; width: 100%; aspect-ratio: 16 / 9; object-fit: cover; border-radius: 7px; background: #000; }
.shot p { margin: 6px 2px 2px; font-size: 13px; line-height: 1.3; display: -webkit-box; -webkit-line-clamp: 2;
  -webkit-box-orient: vertical; overflow: hidden; }
.shot time { display: block; margin: 0 2px 2px; color: var(--faint); font-size: 11.5px; font-variant-numeric: tabular-nums; }
.label { margin: 4px 2px 8px; color: var(--faint); font-size: 11px; font-weight: 600; letter-spacing: .08em; }
details { border: 1px solid var(--line); border-radius: 12px; background: var(--panel); margin-bottom: 10px; }
summary { padding: 12px 14px; list-style: none; cursor: pointer; }
summary::-webkit-details-marker { display: none; }
summary time { color: var(--faint); font-size: 12px; font-variant-numeric: tabular-nums; }
summary p { margin: 4px 0 0; font-size: 15px; line-height: 1.4; }
.pairs { padding: 0 14px 6px; border-top: 1px solid var(--line); }
.pairs .row:last-child { border-bottom: 0; }

nav { display: flex; border-top: 1px solid var(--line); background: #08080a; padding-bottom: env(safe-area-inset-bottom); }
nav button { flex: 1; padding: 13px 4px 12px; border: 0; background: none; color: var(--dim); font-size: 14px; font-weight: 600; }
nav button.active { color: var(--accent); }

/* Chạm vào phụ đề: ẩn hết thanh, chỉ còn chữ */
#app.focus header, #app.focus nav, #app.focus #float { display: none; }
#app.focus #lines { padding-top: 16px; }

/* Ảnh màn hình đã dịch, phủ kín điện thoại */
#viewer { position: fixed; inset: 0; z-index: 10; background: #000; display: none; align-items: center; justify-content: center; }
#viewer.show { display: flex; }
#stage { position: relative; flex: none; }
#stage img { position: absolute; inset: 0; width: 100%; height: 100%; display: block; }
.box span { min-width: 0; max-width: 100%; }
.box { position: absolute; overflow: hidden; display: flex; align-items: center; padding: 0 3px; border-radius: 3px;
  background: rgba(0, 0, 0, .88); color: #fff; font-weight: 500; line-height: 1.15; }
#viewer.orig .box { display: none; }
#vbar { position: absolute; top: calc(8px + env(safe-area-inset-top)); left: calc(10px + env(safe-area-inset-left));
  right: calc(10px + env(safe-area-inset-right)); display: flex; align-items: center; gap: 8px; pointer-events: none; }
#vbar > * { pointer-events: auto; }
#vcount { margin-right: auto; padding: 0 12px; height: 34px; display: inline-flex; align-items: center; border-radius: 17px;
  background: rgba(26, 26, 31, .72); color: var(--dim); font-size: 13px; font-variant-numeric: tabular-nums; }
.vnav { position: absolute; top: 50%; width: 42px; height: 42px; margin-top: -21px; padding: 0; justify-content: center; }
#vprev { left: calc(8px + env(safe-area-inset-left)); }
#vnext { right: calc(8px + env(safe-area-inset-right)); }
#vtip { position: absolute; left: 12px; right: 12px; bottom: calc(12px + env(safe-area-inset-bottom)); padding: 10px 12px;
  border-radius: 10px; background: rgba(0, 0, 0, .85); color: var(--text); font-size: 15px; text-align: center; }
#vtip:empty { display: none; }
</style>
</head>
<body>
<div id="app">
  <header>
    <span id="dot"></span><span id="status">Đang kết nối…</span>
    <div class="tools" id="tools">
      <button id="srcBtn">EN</button><button id="minus">A−</button><button id="plus">A+</button>
    </div>
  </header>
  <main>
    <section id="live" class="show">
      <div id="float">
        <button class="pill" id="toggle"><svg viewBox="0 0 12 12"><path id="toggleIcon" d="M2 1l9 5-9 5z"/></svg><span id="toggleText">Tiếp tục</span></button>
        <button class="pill" id="scanLive"><svg viewBox="0 0 12 12"><path d="M0 0h4v1.6H1.6V4H0zM8 0h4v4h-1.6V1.6H8zM0 8h1.6v2.4H4V12H0zM10.4 8H12v4H8v-1.6h2.4zM3 5.2h6v1.6H3z"/></svg><span id="scanText">Dịch màn hình</span></button>
        <div id="liveMsg"></div>
      </div>
      <div id="lines">
        <div id="hist"></div>
        <div id="cur"></div>
        <div id="src"></div>
      </div>
    </section>
    <section id="log">
      <input id="filter" type="search" placeholder="Tìm trong nhật ký" autocomplete="off">
      <div class="scroll" id="logList"></div>
    </section>
    <section id="scan">
      <div id="scanBar"><button id="go">Dịch màn hình</button><div id="msg"></div></div>
      <div class="scroll" id="scanList"><div id="shots"></div><div id="texts"></div></div>
    </section>
  </main>
  <nav>
    <button data-tab="live" class="active">Phụ đề</button>
    <button data-tab="log">Nhật ký</button>
    <button data-tab="scan">Dịch màn hình</button>
  </nav>
</div>
<div id="viewer">
  <div id="stage"><img id="shot" alt=""></div>
  <div id="vbar"><span id="vcount"></span><button class="pill" id="vorig">Xem bản gốc</button><button class="pill" id="vclose">Đóng</button></div>
  <button class="pill vnav" id="vprev"><svg viewBox="0 0 12 12"><path d="M8.5 1L3 6l5.5 5 1-1.2L5.4 6l4.1-3.8z"/></svg></button>
  <button class="pill vnav" id="vnext"><svg viewBox="0 0 12 12"><path d="M3.5 1L9 6l-5.5 5-1-1.2L6.6 6 2.5 2.2z"/></svg></button>
  <div id="vtip"></div>
</div>
<script>
const $ = id => document.getElementById(id);
const store = { get: (k, d) => { try { return localStorage.getItem(k) ?? d; } catch { return d; } },
                set: (k, v) => { try { localStorage.setItem(k, v); } catch {} } };
const time = at => new Date(at * 1000).toLocaleTimeString('vi-VN', { hour12: false });
const dayTime = at => new Date(at * 1000).toLocaleString('vi-VN', { hour12: false, day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
const post = async path => (await fetch(path, { method: 'POST', headers: { 'X-ScreenTranslator': '1' } })).json();
const OFFLINE = 'Không gọi được máy Mac. Kiểm tra app còn mở và cùng mạng Wi‑Fi.';
const EMPTY = 'Chưa có phụ đề. Câu dịch mới sẽ hiện ở đây.';

let state = { running: false, analyzing: false, profile: '', profileID: '', names: true, speakers: [] }, online = false;

// Màu tên nhân vật giống app Mac: mỗi nhân vật một màu cố định theo thứ tự trong danh sách tên đã học của game;
// tên chưa học thì lấy màu theo chữ. Pha sáng 45 % vì nền tối.
const PALETTE = [[.20,.47,.95],[.93,.47,.10],[.13,.64,.36],[.86,.24,.52],[.53,.35,.90],[.05,.62,.68],
                 [.87,.25,.22],[.72,.56,.05],[.33,.36,.80],[.60,.40,.22],[.42,.62,.12],[.75,.30,.78]];
function nameColor(name) {
  const n = name.toLowerCase();
  let i = state.speakers.findIndex(s => s.toLowerCase() === n);
  if (i < 0) {
    let h = 5381n;
    for (const ch of n) h = BigInt.asIntN(64, h * 33n + BigInt(ch.codePointAt(0)));
    i = Number((h < 0n ? -h : h) % 12n);
  }
  const c = PALETTE[i % 12].map(v => Math.round((v + (1 - v) * .45) * 255));
  return `rgb(${c[0]}, ${c[1]}, ${c[2]})`;
}
// "Tên: câu thoại" → tô màu + in đậm tên người nói (game không hiện tên thì để chữ thường).
function fill(el, text) {
  el.textContent = '';
  for (const line of text.split('\n')) {
    const div = document.createElement('div');
    const m = state.names && line.match(/^[^:：]{1,30}[:：]/);
    if (m && m[0].trim().split(/\s+/).length <= 3) {
      const name = document.createElement('span');
      name.className = 'name'; name.textContent = m[0];
      name.style.color = nameColor(m[0].slice(0, -1).trim());
      div.append(name, line.slice(m[0].length));
    } else div.textContent = line;
    el.append(div);
  }
}
const nearBottom = box => box.scrollHeight - box.scrollTop - box.clientHeight < 60;
const toBottom = box => { box.scrollTop = box.scrollHeight; };

// ---- Tab
let tab = 'live';
function show(name) {
  tab = name;
  for (const s of document.querySelectorAll('section')) s.classList.toggle('show', s.id === name);
  for (const b of document.querySelectorAll('nav button')) b.classList.toggle('active', b.dataset.tab === name);
  $('tools').style.visibility = name === 'live' ? 'visible' : 'hidden';
  if (name === 'log') loadLog();
  if (name === 'scan') loadScans();
}
for (const b of document.querySelectorAll('nav button')) b.onclick = () => show(b.dataset.tab);

// ---- Phụ đề
let fs = +store.get('fs', 30), showSrc = store.get('src', '1') === '1', current = null, ageTimer;
function applyLook() {
  document.documentElement.style.setProperty('--fs', fs + 'px');
  $('live').classList.toggle('nosrc', !showSrc);
  $('srcBtn').classList.toggle('active', showSrc);
}
$('minus').onclick = () => { fs = Math.max(18, fs - 3); store.set('fs', fs); applyLook(); };
$('plus').onclick = () => { fs = Math.min(72, fs + 3); store.set('fs', fs); applyLook(); };
$('srcBtn').onclick = () => { showSrc = !showSrc; store.set('src', showSrc ? '1' : '0'); applyLook(); };
$('lines').onclick = () => $('app').classList.toggle('focus');
applyLook();

// Các câu cũ (cũ → mới), tối đa 100. Lấy từ nhật ký lúc mở trang, sau đó tự nối thêm.
let hist = [];
function renderHist() {
  const stick = nearBottom($('lines'));
  const box = $('hist');
  box.textContent = '';
  let list = hist;
  // Câu đang hiện chữ lớn không lặp lại trong danh sách cũ.
  while (current && list.length && current.translated.includes(list[list.length - 1])) list = list.slice(0, -1);
  for (const t of list) { const d = document.createElement('div'); fill(d, t); box.append(d); }
  if (stick) toBottom($('lines'));
}
function renderCurrent() {
  if (current) { fill($('cur'), current.translated); fill($('src'), current.source); return; }
  $('cur').textContent = ''; $('src').textContent = '';
  const e = document.createElement('span'); e.className = 'empty'; e.textContent = EMPTY;
  $('cur').append(e);
}
async function loadHist() {
  try {
    const list = await (await fetch('/api/log?limit=100')).json();
    hist = list.filter(e => !e.skipped).reverse().map(e => e.translated);
    renderHist(); toBottom($('lines'));
  } catch {}
}
function onSubtitle(s) {
  // Lượt phụ đề mới: câu đang hiện lùi lên danh sách cũ. Cùng lượt: thay bằng bản đã nối thêm câu.
  if (current && s.at === current.at) return;      // nối lại kết nối: máy chủ gửi lại câu gần nhất
  const stick = nearBottom($('lines'));
  if (current && s.first) { hist.push(current.translated); if (hist.length > 100) hist.shift(); }
  current = s;
  renderCurrent();
  renderHist();
  if (stick) toBottom($('lines'));
  $('cur').classList.remove('old');
  clearTimeout(ageTimer);
  ageTimer = setTimeout(() => $('cur').classList.add('old'), 12000);
}
renderCurrent();

// ---- Nhật ký (cũ ở trên, mới nhất ở dưới cùng)
let entries = [];
function row(e) {
  const d = document.createElement('div'); d.className = 'row';
  const t = document.createElement('time'); t.textContent = time(e.at);
  const a = document.createElement('div'); a.className = 't'; fill(a, e.translated);
  if (e.skipped) { d.classList.add('skip'); d.append(t, a); return d; }     // câu đơn giản không dịch: chỉ có câu gốc, mờ
  const b = document.createElement('div'); b.className = 's'; b.textContent = e.source;
  d.append(t, a, b);
  return d;
}
function renderLog(forceBottom) {
  const box = $('logList'), stick = forceBottom || nearBottom(box);
  const q = $('filter').value.trim().toLowerCase();
  const list = q ? entries.filter(e => (e.translated + '\n' + e.source).toLowerCase().includes(q)) : entries;
  box.textContent = '';
  if (!list.length) {
    const p = document.createElement('p'); p.className = 'empty';
    p.textContent = q ? 'Không có câu nào khớp.' : 'Chưa có câu nào được dịch trong game này.';
    box.append(p);
  }
  for (const e of list) box.append(row(e));
  if (stick) toBottom(box);
}
async function loadLog() {
  try { entries = (await (await fetch('/api/log?limit=300')).json()).reverse(); renderLog(true); } catch {}
}
$('filter').oninput = () => renderLog(true);

// ---- Dịch màn hình: danh sách ảnh đã chụp (mới nhất trước), mục cũ chỉ còn chữ
let scans = [];
const shots = () => scans.filter(a => a.image);
async function loadScans() {
  try { scans = await (await fetch('/api/analyses')).json(); } catch { return; }
  const grid = $('shots'), texts = $('texts');
  grid.textContent = ''; texts.textContent = '';
  for (const a of shots()) {
    const b = document.createElement('button'); b.className = 'shot';
    const img = document.createElement('img'); img.loading = 'lazy'; img.alt = ''; img.src = `/api/shot/${a.id}.jpg?thumb=1`;
    const p = document.createElement('p'); p.textContent = a.summary;
    const t = document.createElement('time'); t.textContent = dayTime(a.at) + ' · ' + a.items.length + ' khối chữ';
    b.append(img, p, t);
    b.onclick = () => openViewer(a.id);
    grid.append(b);
  }
  const old = scans.filter(a => !a.image);
  if (!scans.length) {
    const p = document.createElement('p'); p.className = 'empty'; p.textContent = 'Chưa có lần dịch màn hình nào trong game này.';
    texts.append(p);
  }
  if (old.length) {
    const l = document.createElement('div'); l.className = 'label'; l.textContent = 'CŨ HƠN · CHỈ CÒN CHỮ';
    texts.append(l);
  }
  for (const a of old) {
    const d = document.createElement('details');
    const s = document.createElement('summary');
    const t = document.createElement('time'); t.textContent = dayTime(a.at) + ' · ' + a.lines.length + ' dòng';
    const p = document.createElement('p'); p.textContent = a.summary;
    s.append(t, p);
    const pairs = document.createElement('div'); pairs.className = 'pairs';
    for (const l of a.lines) pairs.append(row({ at: a.at, translated: l.target, source: l.source }));
    for (const x of pairs.querySelectorAll('time')) x.remove();
    d.append(s, pairs);
    texts.append(d);
  }
}
function setBusy(busy) {
  $('go').disabled = $('scanLive').disabled = busy;
  $('go').textContent = $('scanText').textContent = busy ? 'Đang dịch…' : 'Dịch màn hình';
}
// Dịch xong thì mở ảnh màn hình với bản dịch đặt đúng chỗ chữ gốc. `msg` = chỗ hiện lỗi của tab đang bấm.
async function scan(msg) {
  setBusy(true);
  msg.className = '';
  msg.textContent = msg.id === 'msg' ? 'Đang chụp và dịch, thường mất vài giây.' : '';
  try {
    const r = await post('/api/analyze');
    msg.className = r.ok ? '' : 'err';
    msg.textContent = r.ok ? '' : r.error;
    if (r.ok) { await loadScans(); if (r.id) openViewer(r.id); }
  } catch {
    msg.className = 'err'; msg.textContent = OFFLINE;
  }
  setBusy(false);
}
$('go').onclick = () => scan($('msg'));
$('scanLive').onclick = () => scan($('liveMsg'));

// ---- Dừng / tiếp tục dịch phụ đề
$('toggle').onclick = async () => {
  $('toggle').disabled = true;
  try {
    const r = await post('/api/toggle');
    $('liveMsg').textContent = r.ok ? '' : r.error;
  } catch { $('liveMsg').textContent = OFFLINE; }
  $('toggle').disabled = false;
};

// ---- Ảnh màn hình đã dịch: lùi / tới giữa các ảnh đã chụp
let shot = null;
function layoutViewer() {
  if (!shot) return;
  const k = Math.min(innerWidth / shot.width, innerHeight / shot.height);
  const W = shot.width * k, H = shot.height * k;
  const stage = $('stage');
  stage.style.width = W + 'px'; stage.style.height = H + 'px';
  for (const el of stage.querySelectorAll('.box')) {
    const it = el.item, w = it.w * W, h = it.h * H;
    // Tiếng Việt thường dài hơn tiếng Anh: hộp rộng thêm một chút, chữ tự co cho vừa (như trên app Mac).
    const boxW = Math.min(Math.max(w * 1.15, w + 12), W - it.x * W);
    el.style.left = (it.x * W - 3) + 'px'; el.style.top = (it.y * H - 1) + 'px';
    el.style.width = boxW + 'px'; el.style.height = (h + 2) + 'px';
    // Chữ co dần tới 45 % cho vừa hộp. Khối một dòng thì giữ một dòng; khối nhiều dòng được xuống dòng.
    const span = el.firstChild, base = Math.max(7, h / it.lines * 0.74);
    span.style.whiteSpace = it.lines === 1 ? 'nowrap' : 'normal';
    const over = () => span.offsetHeight > h + 2 || (it.lines === 1 && span.scrollWidth > boxW - 6);
    let size = base;
    el.style.fontSize = size + 'px';
    while (over() && size > base * 0.45) { size -= 0.5; el.style.fontSize = size + 'px'; }
  }
}
function openViewer(id) {
  const list = shots(), i = list.findIndex(a => a.id === id);
  if (i < 0) return;
  shot = list[i];
  const stage = $('stage');
  for (const el of stage.querySelectorAll('.box')) el.remove();
  $('shot').src = `/api/shot/${shot.id}.jpg`;
  for (const it of shot.items) {
    const el = document.createElement('div');
    el.className = 'box'; el.item = it;
    const span = document.createElement('span'); span.textContent = it.target;
    el.append(span);
    el.onclick = e => { e.stopPropagation(); $('vtip').textContent = it.source; };
    stage.append(el);
  }
  // Danh sách xếp mới nhất trước; số thứ tự đếm từ ảnh cũ nhất.
  $('vcount').textContent = `${list.length - i}/${list.length} · ${dayTime(shot.at)}`;
  $('vprev').disabled = i === list.length - 1;
  $('vnext').disabled = i === 0;
  $('vtip').textContent = '';
  $('viewer').classList.add('show');
  layoutViewer();
}
function stepViewer(d) {      // d = -1: ảnh chụp trước đó (cũ hơn), +1: ảnh sau (mới hơn)
  if (!shot) return;
  const list = shots(), i = list.findIndex(a => a.id === shot.id) - d;
  if (list[i]) openViewer(list[i].id);
}
function closeViewer() { $('viewer').classList.remove('show'); shot = null; }
$('vclose').onclick = closeViewer;
$('vprev').onclick = () => stepViewer(-1);
$('vnext').onclick = () => stepViewer(1);
$('vorig').onclick = () => {
  const orig = $('viewer').classList.toggle('orig');
  $('vorig').textContent = orig ? 'Xem bản dịch' : 'Xem bản gốc';
  $('vtip').textContent = '';
};
$('stage').onclick = () => { $('vtip').textContent = ''; };
addEventListener('resize', layoutViewer);
addEventListener('keydown', e => {
  if (!shot) return;
  if (e.key === 'ArrowLeft') stepViewer(-1);
  if (e.key === 'ArrowRight') stepViewer(1);
  if (e.key === 'Escape') closeViewer();
});
// Vuốt ngang để đổi ảnh.
let touchX = null;
$('viewer').addEventListener('touchstart', e => { touchX = e.touches.length === 1 ? e.touches[0].clientX : null; }, { passive: true });
$('viewer').addEventListener('touchend', e => {
  if (touchX === null) return;
  const dx = e.changedTouches[0].clientX - touchX;
  touchX = null;
  if (Math.abs(dx) > 60) stepViewer(dx > 0 ? -1 : 1);
}, { passive: true });

// ---- Kết nối trực tiếp
function renderStatus() {
  $('dot').className = !online ? 'off' : state.running ? 'on' : '';
  $('status').textContent = !online ? 'Mất kết nối với máy Mac, đang thử lại…'
    : (state.running ? 'Đang dịch' : 'Đã dừng') + (state.profile ? ' · ' + state.profile : '');
  $('toggleText').textContent = state.running ? 'Dừng' : 'Tiếp tục';
  $('toggleIcon').setAttribute('d', state.running ? 'M2 1h3v10H2zM7 1h3v10H7z' : 'M2 1l9 5-9 5z');
  $('toggle').classList.toggle('running', state.running);
  if (online) setBusy(state.analyzing);
}
// Trên app đổi sang game khác: bỏ hết dữ liệu của game cũ và nạp lại theo game mới.
function switchGame() {
  current = null; hist = []; entries = []; scans = [];
  closeViewer();
  renderCurrent(); renderHist();
  loadHist(); loadLog(); loadScans();
}
function connect() {
  const es = new EventSource('/events');
  es.onopen = () => { online = true; renderStatus(); loadHist(); if (tab === 'log') loadLog(); if (tab === 'scan') loadScans(); };
  es.onerror = () => { online = false; renderStatus(); };
  es.addEventListener('state', e => {
    const old = state.profileID;
    state = JSON.parse(e.data); renderStatus();
    if (old && old !== state.profileID) { switchGame(); return; }
    renderCurrent(); renderHist(); if (tab === 'log') renderLog();     // tên nhân vật mới học → tô lại màu
  });
  es.addEventListener('subtitle', e => onSubtitle(JSON.parse(e.data)));
  es.addEventListener('entry', e => { entries.push(JSON.parse(e.data)); if (tab === 'log') renderLog(); });
  es.addEventListener('cleared', () => { entries = []; hist = []; renderHist(); if (tab === 'log') renderLog(); });
  es.addEventListener('analysis', () => { if (tab === 'scan' && !shot) loadScans(); });
}
connect();

// Giữ màn hình sáng nếu trình duyệt cho phép (Safari chỉ cho trên HTTPS; nếu không được thì đặt Tự động khoá = Không).
async function keepAwake() { try { await navigator.wakeLock?.request('screen'); } catch {} }
keepAwake();
document.addEventListener('visibilitychange', () => { if (!document.hidden) keepAwake(); });
</script>
</body>
</html>
"""#
}
