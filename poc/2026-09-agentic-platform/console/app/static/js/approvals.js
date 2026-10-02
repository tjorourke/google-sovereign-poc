// The platform admin's screen. Same grant the wizard used to do inline on /agents,
// taken out of the builder's hands so the two jobs are visibly two jobs.
const API = window.AGENTS_API || '/api/agents';
let agents = [];
let catalog = { mcp: [] };
let selected = null;
let mode = 'approve';

const el = id => document.getElementById(id);
const esc = s => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');

// Pending requests stay in the review queue. Existing grants share one searchable
// table, with their source distinguishing reviewed and platform-managed access.
const isAuto = id => !!((catalog.mcp || []).find(x => x.id === id) || {}).autoApprove;

function allGroups(a) {
  return (a.mcp || []).filter(m => (m.tools || []).length).map(m => {
    const server = (catalog.mcp || []).find(x => x.id === m.id);
    return { id: m.id, name: server ? server.name : m.id, tools: m.tools };
  });
}

const autoFor = (a, id) => isAuto(id) || (a.mcp_auto || []).includes(id);
const mcpGroups = a => allGroups(a).filter(g => !autoFor(a, g.id));
const autoGroups = a => allGroups(a).filter(g => autoFor(a, g.id));
const toolCount = a => mcpGroups(a).reduce((n, g) => n + g.tools.length, 0);
const approved = a => !!(a && (a.admin_approved || a.mcp_approved || a.github_approved));

function card(a, isApproved) {
  const n = toolCount(a);
  const groups = mcpGroups(a);
  const yaml = isApproved ? (a.policy_yaml || '') : (a.policy_preview || '');
  return `
    <div class="agent-card">
      <div class="kicker">${isApproved ? 'Security · approved' : 'Security · platform admin'}</div>
      <h3>${esc(a.name)}${a.version ? ' · ' + esc(a.version) : ''}</h3>
      <p class="sub">Identity <code>${esc(a.identity || 'kagent/' + a.name)}</code> · ${n} tool${n === 1 ? '' : 's'}
        across ${groups.length} server${groups.length === 1 ? '' : 's'}.</p>
      <p class="sub">${groups.map(g => `${esc(g.name)} (${g.tools.length})`).join(', ') || 'none'}</p>
      <div class="card-actions">
        <button class="btn ${isApproved ? '' : 'primary'}" data-act="${isApproved ? 'revoke' : 'approve'}"
                data-name="${esc(a.name)}">${isApproved ? 'Revoke MCP access' : 'Review MCP tools'}</button>
      </div>
      <details class="yaml" style="margin-top:10px" data-key="${isApproved ? 'allowed' : 'pending'}/${esc(a.name)}">
        <summary>${isApproved ? 'The policy in force' : 'The policy this would write'}</summary>
        <pre>${esc(yaml || 'No MCP tools requested.')}</pre>
      </details>
    </div>`;
}

const expandedGrants = new Set();
const PAGE_SIZE = 25;
let grantPage = 0;
const SOURCE_NAMES = { reviewed: 'Admin-approved', managed: 'Platform-managed', automatic: 'Auto-approved' };

function grants() {
  return agents.flatMap(a => {
    const out = [];
    const automatic = autoGroups(a), reviewed = mcpGroups(a);
    if (a.applied && automatic.length) out.push({ a, groups: automatic, source: a.granted_by ? 'managed' : 'automatic', yaml: a.auto_policy_yaml });
    if (approved(a) && reviewed.length) out.push({ a, groups: reviewed, source: 'reviewed', yaml: a.policy_yaml });
    return out;
  }).map(g => ({ ...g, key: g.source + '/' + g.a.name }))
    .sort((a, b) => a.a.name.localeCompare(b.a.name) || a.source.localeCompare(b.source));
}

function paintGrants() {
  const all = grants();
  const search = el('grant-search').value.trim().toLowerCase();
  const source = el('grant-source').value;
  const filtered = all.filter(g => (source === 'all' || g.source === source) &&
    [g.a.name, g.a.title, g.a.identity, ...g.groups.flatMap(s => [s.name, s.id, ...s.tools])]
      .filter(Boolean).join(' ').toLowerCase().includes(search));
  grantPage = Math.min(grantPage, Math.max(0, Math.ceil(filtered.length / PAGE_SIZE) - 1));
  const start = grantPage * PAGE_SIZE;
  el('grants-total').textContent = `${all.length} grant${all.length === 1 ? '' : 's'}`;
  el('grant-rows').innerHTML = filtered.slice(start, start + PAGE_SIZE).map(g => {
    const { a, groups, source, key } = g;
    const open = expandedGrants.has(key);
    const id = 'grant-' + encodeURIComponent(key);
    const identity = a.identity || 'kagent/' + a.name;
    const slash = identity.indexOf('/');
    const count = groups.reduce((n, s) => n + s.tools.length, 0);
    return `<tr class="grant-row${open ? ' expanded' : ''}" data-expand="${esc(key)}">
      <td><button class="grant-toggle" type="button" aria-expanded="${open}" aria-controls="${id}" aria-label="${esc((open ? 'Hide' : 'Show') + ' policy for ' + a.name)}">
        <span class="grant-chevron" aria-hidden="true">▸</span><span class="grant-agent">${esc(a.title || a.name)}
        <small>${a.title ? esc(a.name) + ' · ' : ''}${esc(a.version || 'latest')}</small></span></button></td>
      <td class="grant-identity"><span>${esc(slash < 0 ? '' : identity.slice(0, slash))}</span>${esc(slash < 0 ? identity : identity.slice(slash + 1))}</td>
      <td><div class="grant-servers">${groups.map(s => `<span>${esc(s.name)}</span>`).join('')}</div></td>
      <td><span class="grant-count">${count}</span></td>
      <td><span class="grant-source ${source}">${SOURCE_NAMES[source]}</span></td>
      <td>${source === 'reviewed' ? `<button class="grant-revoke" type="button" data-act="revoke" data-name="${esc(a.name)}" aria-label="Revoke MCP access for ${esc(a.name)}">Revoke</button>` : '<small>Source-managed</small>'}</td>
    </tr><tr class="grant-detail" id="${id}" ${open ? '' : 'hidden'}><td colspan="6"><div class="grant-detail-inner">
      <div class="grant-detail-head"><h3>Policy in force · ${esc(a.name)}</h3><button type="button" class="btn" data-copy-grant="${esc(key)}">Copy YAML</button></div>
      <p>${a.granted_by ? 'Managed in ' + esc(a.granted_by) : SOURCE_NAMES[source] + ' · ' + esc(identity)}</p>
      <div class="grant-tools">${groups.flatMap(s => s.tools.map(t => `<code>${esc(s.id + '/' + t)}</code>`)).join('')}</div>
      <pre class="grant-yaml">${esc(g.yaml || 'No gateway policy returned for this grant.')}</pre>
    </div></td></tr>`;
  }).join('');
  el('grants-empty').hidden = filtered.length > 0;
  el('grants-empty').textContent = all.length ? 'No grants match your search. Try another agent, identity or tool.' : 'No approved grants yet.';
  el('grant-range').textContent = filtered.length ? `${start + 1}–${Math.min(start + PAGE_SIZE, filtered.length)} of ${filtered.length} grants` : '0 grants';
  el('grants-prev').disabled = grantPage === 0;
  el('grants-next').disabled = start + PAGE_SIZE >= filtered.length;
}

// The list reloads every few seconds. Rebuilding it would snap shut a policy someone
// has open mid-explanation, so skip unchanged data and carry open panels across.
let painted = '';

function paint() {
  const sig = JSON.stringify([agents, catalog]);
  if (sig === painted) return;
  painted = sig;
  const open = new Set([...document.querySelectorAll('details[data-key][open]')].map(d => d.dataset.key));
  const waiting = agents.filter(a => a.applied && mcpGroups(a).length && !approved(a));
  el('pending').innerHTML = waiting.map(a => card(a, false)).join('');
  paintGrants();
  el('pending-empty').style.display = waiting.length ? 'none' : 'block';
  el('ap-dot').className = 'dot ' + (waiting.length ? 'warn' : 'live');
  el('ap-state').textContent = waiting.length
    ? waiting.length + ' waiting'
    : (grants().length ? 'all approved' : 'nothing deployed');
  for (const d of document.querySelectorAll('details[data-key]')) {
    if (open.has(d.dataset.key)) d.open = true;
  }
  for (const b of document.querySelectorAll('#pending [data-act]')) {
    b.onclick = () => openModal(b.dataset.name, b.dataset.act);
  }
}

function openModal(name, m) {
  const a = agents.find(x => x.name === name);
  if (!a) return;
  selected = name;
  mode = m;
  const groups = mcpGroups(a);
  el('mcp-modal-who').textContent = 'Identity ' + (a.identity || 'kagent/' + a.name) + (a.version ? ' · ' + a.version : '');
  el('mcp-modal-tools').innerHTML = groups.length
    ? groups.map(g => `<h4>${esc(g.name)} · ${g.tools.length}</h4><ul>${g.tools.map(t => `<li>${esc(t)}</li>`).join('')}</ul>`).join('')
    : '<p class="sub">No tools requested.</p>';
  el('mcp-modal-yaml').textContent = (m === 'revoke' ? a.policy_yaml : a.policy_preview) || 'No policy for this agent.';
  el('mcp-modal-msg').textContent = '';
  if (m === 'revoke') {
    el('mcp-modal-kicker').textContent = 'Security · revoke';
    el('mcp-modal-title').textContent = 'Revoke MCP tools';
    el('mcp-modal-lead').textContent = 'These tools are currently allowed for this identity. Revoke to deny them again.';
    el('mcp-modal-approve').style.display = 'none';
    el('mcp-modal-deny').textContent = 'Revoke';
  } else {
    el('mcp-modal-kicker').textContent = 'Security · platform admin';
    el('mcp-modal-title').textContent = 'Approve MCP tools';
    el('mcp-modal-lead').textContent = 'This identity is asking for the tools below. Approve or deny the lot.';
    el('mcp-modal-approve').style.display = '';
    el('mcp-modal-deny').textContent = 'Deny';
  }
  el('mcp-modal').style.display = 'flex';
}

function closeModal() {
  el('mcp-modal').style.display = 'none';
  selected = null;
}

async function act(path, working, done) {
  if (!selected) return;
  const msg = el('mcp-modal-msg');
  msg.textContent = working;
  el('mcp-modal-approve').disabled = true;
  el('mcp-modal-deny').disabled = true;
  try {
    const r = await fetch(API + '/' + encodeURIComponent(selected) + path, { method: 'POST' })
      .then(r => r.json());
    msg.textContent = r.ok ? done : (r.error || 'that did not work');
    await load();
    if (r.ok) setTimeout(closeModal, 900);
  } catch (e) {
    msg.textContent = String(e);
  }
  el('mcp-modal-approve').disabled = false;
  el('mcp-modal-deny').disabled = false;
}

const approve = () => act('/approve-github', 'writing the policy…', 'Approved. The gateway is allowing these tools now.');
const revoke = () => {
  if (mode === 'revoke') return act('/revoke-github', 'taking it back out…', 'Revoked. The identity is denied again.');
  if (API.startsWith('/api/google/')) return act('/revoke-github', 'denying access…', 'Denied. No tool grant is in place.');
  closeModal();
};

let loading = false;
let loadedOnce = false;

async function load() {
  if (loading) return;
  loading = true;
  el('approvals-retry').disabled = true;
  el('approvals-error').hidden = true;
  if (!loadedOnce) {
    el('approvals-loading').hidden = false;
    el('approvals-content').setAttribute('aria-busy', 'true');
  }
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 45000);
  const read = async url => {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error(`The console returned HTTP ${response.status}.`);
    const body = await response.json();
    if (body.error) throw new Error(body.error);
    return body;
  };
  try {
    const [cat, list] = await Promise.all([read(API + '/catalog'), read(API)]);
    catalog = cat;
    agents = list.agents || [];
    paint();
    loadedOnce = true;
    el('approvals-content').hidden = false;
    return true;
  } catch (error) {
    el('approvals-error-message').textContent = (loadedOnce ? 'Could not refresh approvals. Showing the last loaded grants. ' : 'Could not load approvals. ')
      + (error.name === 'AbortError' ? 'The registry took too long to respond.' : error.message);
    el('approvals-error').hidden = false;
    return false;
  } finally {
    clearTimeout(timeout);
    controller.abort();
    loading = false;
    el('approvals-loading').hidden = true;
    el('approvals-content').setAttribute('aria-busy', 'false');
    el('approvals-retry').disabled = false;
  }
}

el('mcp-modal-approve').onclick = approve;
el('mcp-modal-deny').onclick = revoke;
el('mcp-modal-close').onclick = closeModal;
el('mcp-modal').onclick = e => { if (e.target.id === 'mcp-modal') closeModal(); };
el('approvals-retry').onclick = load;
el('grant-search').addEventListener('input', () => { grantPage = 0; paintGrants(); });
el('grant-source').addEventListener('change', () => { grantPage = 0; paintGrants(); });
el('grants-prev').onclick = () => { grantPage = Math.max(0, grantPage - 1); paintGrants(); };
el('grants-next').onclick = () => { grantPage++; paintGrants(); };
el('grant-rows').onclick = async e => {
  const revokeButton = e.target.closest('[data-act]');
  if (revokeButton) { openModal(revokeButton.dataset.name, revokeButton.dataset.act); return; }
  const copy = e.target.closest('[data-copy-grant]');
  if (copy) {
    const grant = grants().find(g => g.key === copy.dataset.copyGrant);
    try { await navigator.clipboard.writeText(grant?.yaml || ''); copy.textContent = 'Copied'; }
    catch (_) { copy.textContent = 'Select the YAML to copy'; }
    return;
  }
  const row = e.target.closest('[data-expand]');
  if (!row) return;
  const key = row.dataset.expand;
  const focused = e.target.closest('.grant-toggle');
  const open = !expandedGrants.has(key);
  if (open) expandedGrants.add(key); else expandedGrants.delete(key);
  const toggle = row.querySelector('.grant-toggle');
  toggle.setAttribute('aria-expanded', String(open));
  toggle.setAttribute('aria-label', (open ? 'Hide' : 'Show') + ' policy for ' + grants().find(g => g.key === key).a.name);
  row.classList.toggle('expanded', open);
  document.getElementById(toggle.getAttribute('aria-controls')).hidden = !open;
  if (focused) toggle.focus();
};

const google = API.startsWith('/api/google/');
fetch(google ? '/api/google/status' : '/api/status').then(r => r.json()).then(s => {
  el('dot').className = 'dot ' + ((google ? s.reachable : s.decisions) ? 'live' : 'off');
  el('status-label').textContent = google ? (s.reachable ? 'Berlin connected' : 'Berlin unavailable')
    : (s.context ? 'live · ' + s.context.split('/').pop() : 'console only');
}).catch(() => {});

load();
setInterval(() => { if (el('mcp-modal').style.display === 'none') load(); }, 8000);
