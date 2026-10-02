// Shared by generated pages and the hand-written overview chapters.
(function () {
  const status = document.querySelector('.console-nav .nav-status');
  if (!status || status.closest('.nav-status-area')) return;
  const area = document.createElement('div');
  area.className = 'nav-status-area';
  status.replaceWith(area);
  area.append(status);
  const link = document.createElement('a');
  link.href = '/admin';
  link.className = 'nav-admin';
  link.textContent = 'Admin';
  link.title = 'Lab reset controls';
  area.append(link);
})();
