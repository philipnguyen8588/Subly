// Trang quản trị: nút Copy token và ô Base URL chỉ hiện khi chọn Custom.
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-copy]');
  if (!b) return;
  const input = document.getElementById(b.dataset.copy);
  input.select();
  const done = () => { const t = b.textContent; b.textContent = 'Đã copy'; setTimeout(() => { b.textContent = t; }, 1500); };
  if (navigator.clipboard) navigator.clipboard.writeText(input.value).then(done, () => { document.execCommand('copy'); done(); });
  else { document.execCommand('copy'); done(); }
});

function syncProvider() {
  const sel = document.getElementById('provider');
  const row = document.getElementById('base-url-row');
  if (sel && row) row.style.display = sel.value === 'custom' ? 'contents' : 'none';
}
document.addEventListener('change', (e) => { if (e.target.id === 'provider') syncProvider(); });
syncProvider();

// Nút xoá có data-confirm: hỏi lại trước khi gửi.
document.addEventListener('click', (e) => {
  const b = e.target.closest('[data-confirm]');
  if (b && !confirm(b.dataset.confirm)) e.preventDefault();
});
