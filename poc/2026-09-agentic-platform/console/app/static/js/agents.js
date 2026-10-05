// The same page drives other platforms: a page can set window.AGENTS_API (and the overrides
// below) before this script, as /google/agents does for Berlin.
const API = window.AGENTS_API || '/api/agents';
let catalog = { skills: [], mcp: [], platform: null };
let agents = [];
let prompts = [];
let selected = null;
let mcpPicked = {};
let mcpTab = null;
let wizStep = 1;
let editing = false;

const DEMO = {
  description: 'Release briefing for open slice-manager pull requests and telco tickets.',
  prompt: `You are the network-slice-manager copilot for an EMEA telco platform team.

When asked for a release report or open work, use GitHub on tjorourke/network-slice-manager. List open pull requests, read status, reviews and labels, and classify each as ready to merge, needs work, or do not merge. Prefer the labels ready-to-merge, needs-work and do-not-merge when they are present.

Keep the answer as a short briefing, not a dump. Use only the tools you have been given. Do not merge, comment or write.

Only report what a tool returned in this conversation. If you have no GitHub tools, or a call fails or is denied, say "I can't read GitHub yet: <the reason>. A platform admin has to approve my GitHub access." and stop. Never invent pull request numbers, titles, reviews or labels, and never show example or placeholder data.`,
  skills: ['github-briefing'],
  githubTools: [
    'list_pull_requests', 'pull_request_read', 'search_pull_requests',
    'list_issues', 'issue_read', 'search_issues', 'get_file_contents',
    'search_code', 'get_repository_tree',
  ],
};

const STEP_TITLES = { 1: 'Start', 2: 'Describe it', 3: 'Skill', 4: 'What it can use', 5: 'Deploy' };
const LAST = 5;

// Starting points for someone who has never written a prompt. Every skill and tool named
// here is in the catalogue; applyTemplate drops anything the catalogue does not carry.
const TEMPLATES = window.AGENT_TEMPLATES || [
  {
    id: 'climb', icon: '🗼', title: 'Tower climb planner', name: 'climb-planner',
    blurb: 'Plans safe daylight windows for site work. Ready to use straight away.',
    description: 'Plans safe daylight windows for tower climbs and rooftop work at EMEA sites.',
    prompt: `You help field engineers plan outdoor work at mobile sites: tower climbs, antenna swaps and rooftop jobs.

When asked about a site and a day, give the safe work window, sunrise and sunset, and how long the job can run. If the sun does not rise, say plainly that there is no safe daylight window and suggest the nearest day that has one.

Always state the work window rule the tool gives you. Only report what a tool returned in this conversation.`,
    skill: '',
    tools: { daylight: ['list_places', 'daylight', 'work_window', 'local_time'] },
  },
  {
    id: 'quiz', icon: '🍻', title: 'IT pub quiz host', name: 'quiz-host',
    blurb: 'Runs ten random questions on Kubernetes, code and IT. New round any time.',
    description: 'A cheerful pub quiz host: ten random IT, development and Kubernetes questions a round.',
    prompt: `You are a cheerful pub quiz host for a room full of IT people.

When someone wants to play, call start_quiz. Pass a topic if they name one: kubernetes, development or it. Otherwise leave it mixed.

Ask one question at a time with its four options, then wait for their answer. Call check_answer with the quiz_id, the question_id and their letter, tell them whether they got it right, read out the explanation and the score so far. If they are stuck, offer a fifty_fifty, once per round.

After the tenth question, call quiz_score and read out the verdict with some ceremony. If they want another round, call start_quiz again: every round is new and random.

Never give away an answer before they guess, and only use questions the tools give you.`,
    skill: '',
    tools: { quiz: ['start_quiz', 'check_answer', 'fifty_fifty', 'quiz_score', 'list_topics'] },
  },
  {
    id: 'excuses', icon: '🙈', title: 'Excuse generator', name: 'excuse-bot',
    blurb: 'Why is it late? Ready-to-send excuses, each with a believability score.',
    description: 'Writes excuses for late work, from believable to cosmic, and rates your own.',
    prompt: `You help people explain why their work is late, with a sense of humour.

When someone asks for an excuse, call excuse with the thing that is late and a style if they name one (technical, corporate, heroic, animal or cosmic). Give them the message ready to send, the believability score and the verdict.

If they give you their own excuse, score it with rate_excuse and pass on the notes. If they want a laugh, run an excuse_battle.

Keep it light. Never suggest covering up anything serious, such as a security issue, an outage or a safety problem: for those, tell them to be honest and tell the right people.`,
    skill: '',
    tools: { excuses: ['excuse', 'excuse_battle', 'rate_excuse', 'excuse_styles'] },
  },
  {
    id: 'release', icon: '📋', title: 'Release briefing', name: 'release-briefer',
    blurb: 'Reads open pull requests and says which are ready to ship.',
    description: DEMO.description, prompt: DEMO.prompt, skill: 'github-briefing',
    tools: { github: DEMO.githubTools },
  },
  {
    id: 'k8s', icon: '🩺', title: 'Kubernetes health check', name: 'cluster-doctor',
    blurb: 'Finds unhealthy pods, shows the evidence and the next check.',
    description: 'Read-only health check for a Kubernetes namespace.',
    prompt: `You help a platform team check the health of their Kubernetes cluster.

When asked about a namespace or a workload, find anything unhealthy, show the evidence from events and logs, and suggest the single next check. Keep it short.

You are read-only. Never change anything. Only report what a tool returned in this conversation, and say so plainly when a tool call fails or is denied.`,
    skill: 'k8s-sre',
    tools: { k8s: ['k8s_get_resources', 'k8s_describe_resource', 'k8s_get_pod_logs', 'k8s_get_events'] },
  },
  {
    id: 'incident', icon: '🚨', title: 'Network incident triage', name: 'incident-triage',
    blurb: 'Turns alarms into a short field briefing with next steps.',
    description: 'Field briefing for network alarms: symptom, domain and the next two checks.',
    prompt: `You help a telco operations team triage network incidents.

When asked about an alarm, a site or a slice, read the alarms and congestion first, then give a short briefing: the symptom, which domain it sits in, and the next two checks.

Only report what a tool returned in this conversation. Never invent telemetry, site names or alarm numbers.`,
    skill: 'incident-triage',
    tools: { telco: ['list_sites', 'get_site', 'list_alarms', 'congestion_now', 'list_slices', 'get_slice'] },
  },
  {
    id: 'slice', icon: '📡', title: '5G slice explainer', name: 'slice-explainer',
    blurb: 'Explains a network slice, its SLA and how it behaves under load.',
    description: 'Explains a 5G slice as a committed service, with its SLA and congestion behaviour.',
    prompt: `You explain 5G network slices to people who are not network engineers.

When asked about a slice, read it and the current congestion, then explain in plain language what the customer is promised, whether it is being met right now, and what happens when the network is busy.

Only report what a tool returned in this conversation.`,
    skill: 'slice-planner',
    tools: { telco: ['list_slices', 'get_slice', 'congestion_now'] },
  },
  {
    id: 'tickets', icon: '🏷️', title: 'Ticket classifier', name: 'ticket-sorter',
    blurb: 'Sorts incoming tickets and names the team that owns each one.',
    description: 'Classifies tickets as network, billing, device or unknown, and names the owning team.',
    prompt: `You sort incoming support tickets.

For each ticket, say whether it is network, billing, device or unknown, name the team that should own it, and give one line of reasoning.

Only use what the ticket and your tools say. If you cannot tell, say unknown.`,
    skill: 'ticket-classifier',
    tools: { github: ['list_issues', 'issue_read', 'search_issues'] },
  },
  {
    id: 'change', icon: '🗓️', title: 'Change advisory', name: 'change-advisor',
    blurb: 'Writes a one-page change window: risk, back-out, who is on call.',
    description: 'One-page change window: what changes, the risk, the back-out and who is on call.',
    prompt: `You prepare change advisories for a platform team.

When asked about an upcoming change, read the pull requests and the current state of the cluster, then write one page: what changes, the risk, how to back it out, and what to watch afterwards.

Only report what a tool returned in this conversation.`,
    skill: 'change-advisory',
    tools: { github: ['list_pull_requests', 'pull_request_read'], k8s: ['k8s_get_resources', 'k8s_get_events'] },
  },
];

const AVATAR_COLOURS = [
  ['#ede9fe', '#5b21b6'], ['#dbeafe', '#1d4ed8'], ['#dcfce7', '#15803d'], ['#fef3c7', '#b45309'],
  ['#fce7f3', '#be185d'], ['#cffafe', '#0e7490'], ['#ffe4e6', '#be123c'], ['#e0e7ff', '#4338ca'],
];
let justDeployed = null;
let celebrated = new Set();
const GLYPH = Object.assign({ github: 'GH', k8s: 'K8', telco: 'TC', everything: 'EV', daylight: 'SD', quiz: 'QZ', excuses: 'EX' },
  window.AGENT_GLYPHS || {});
let previewSeq = 0;

function esc(s) {
  return String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function initials(name) {
  const parts = String(name || '?').split(/[-_\s.]+/).filter(Boolean);
  const s = parts.length > 1 ? parts[0][0] + parts[1][0] : (parts[0] || '?').slice(0, 2);
  return s.toUpperCase();
}

function ago(iso) {
  if (!iso) return '';
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 90) return 'just now';
  if (s < 3600) return Math.round(s / 60) + 'm ago';
  if (s < 86400) return Math.round(s / 3600) + 'h ago';
  return Math.round(s / 86400) + 'd ago';
}

function modelOf(a) {
  const m = /modelName:\s*(\S+)/.exec(a.yaml || '');
  return m ? m[1] : '';
}

function avatarStyle(name) {
  let h = 0;
  for (const c of String(name || '')) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  const [bg, fg] = AVATAR_COLOURS[h % AVATAR_COLOURS.length];
  return `background:${bg};color:${fg}`;
}

// list_pull_requests -> List pull requests. The raw id still shows underneath for engineers.
function humanTool(id) {
  const words = String(id).replace(/^k8s_/, '').split('_');
  const fixed = words.map(w => ({ pr: 'PR', api: 'API', yaml: 'YAML', istio: 'Istio', ztunnel: 'ztunnel', me: 'me' }[w] || w));
  const s = fixed.join(' ');
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function tidyName(v) {
  return String(v).toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+/, '').slice(0, 48);
}

function glyph(id) {
  return `<i class="ag-glyph ${esc(id)}">${esc(GLYPH[id] || String(id).slice(0, 2).toUpperCase())}</i>`;
}

function serverAuto(id) {
  const s = (catalog.mcp || []).find(x => x.id === id);
  return !!(s && s.autoApprove);
}

// Split what an agent asked for. The server says so on saved agents; a draft is worked out
// from the catalogue labels.
function tiers(a) {
  if (a.mcp_auto && a.mcp_restricted) return { auto: a.mcp_auto, restricted: a.mcp_restricted };
  const ids = (a.mcp || []).filter(m => (m.tools || []).length).map(m => m.id);
  return { auto: ids.filter(serverAuto), restricted: ids.filter(id => !serverAuto(id)) };
}

function adminApproved(a) {
  return !!(a && (a.admin_approved || a.mcp_approved || a.github_approved));
}

function serverName(id) {
  const s = (catalog.mcp || []).find(x => x.id === id);
  return s ? s.name : id;
}

function skillTitle(id) {
  const s = (catalog.skills || []).find(x => x.id === id);
  return s ? s.title : id;
}

// One word for where an agent is, shared by the card, the detail header and the counts.
function stateOf(a) {
  if (!a.applied) return a.apply_error ? 'failed' : 'off';
  if (tiers(a).restricted.length && !adminApproved(a)) return 'pending';
  return 'live';
}

const STATE_LABEL = {
  live: 'Live',
  pending: 'Awaiting approval',
  failed: 'Deploy failed',
  off: 'Not deployed',
  draft: 'Draft',
};

function chipsHtml(a) {
  const out = [];
  const model = modelOf(a);
  if (model) out.push(`<span class="ag-chip model">${esc(model)}</span>`);
  (a.skills || []).forEach(id => out.push(`<span class="ag-chip skill">${esc(skillTitle(id))}</span>`));
  (a.mcp || []).filter(m => (m.tools || []).length).forEach(m => {
    const auto = serverAuto(m.id);
    out.push(`<span class="ag-chip ${auto ? 'auto' : ''}" title="${auto ? 'Ready to use: no approval needed' : 'Needs a platform admin to approve'}">${glyph(m.id)}${esc(serverName(m.id))} <em>${m.tools.length}</em>${auto ? '<b class="ag-tick">✓</b>' : ''}</span>`);
  });
  return out.length ? `<div class="ag-chips">${out.join('')}</div>` : '';
}

function cardHtml(a, opts = {}) {
  const state = opts.state || stateOf(a);
  const by = [a.version, a.updated ? 'updated ' + ago(a.updated) : ''].filter(Boolean).join(' · ');
  const menu = opts.preview || a.builder === false ? '' : `
      <div class="ag-card-menu">
        <button type="button" class="ag-icon-btn" data-edit="${esc(a.name)}">Edit</button>
        <button type="button" class="ag-icon-btn del" data-del="${esc(a.name)}">Delete</button>
      </div>`;
  return `<div class="ag-card ${state}" ${opts.preview ? '' : `data-name="${esc(a.name)}" tabindex="0"`}>
    <div class="ag-card-head">
      <div class="ag-avatar" style="${avatarStyle(a.name)}">${esc(initials(a.name))}</div>
      <div style="min-width:0">
        <h3>${esc(a.title || a.name || 'unnamed-agent')}</h3>
        <div class="by">${a.title ? esc(a.name) + ' · ' : ''}${esc(by || opts.by || 'on kagent')}</div>
      </div>
    </div>
    <p class="ag-card-desc">${esc(a.description || 'No description yet.')}</p>
    ${chipsHtml(a)}
    <div class="ag-card-foot">
      <span class="ag-status ${state}">${STATE_LABEL[state]}</span>${menu}
      ${!opts.preview && a.applied ? `<button type="button" class="btn primary ag-chat-btn" data-chat="${esc(a.name)}">Chat</button>` : ''}
    </div>
  </div>`;
}

async function boot() {
  // Agents answer in a fraction of a second; the catalogue reads the registry and is slower.
  // Paint the cards as soon as the agents land, then repaint with proper names.
  const catP = fetch(API + '/catalog').then(r => r.json());
  const listP = refreshList().catch(() => listFailed());
  catalog = await catP;
  paintPlatform();
  paintForm();
  await listP;
  if (loaded) paintList();
  document.getElementById('deploy').onclick = deploy;
  document.getElementById('new-agent').onclick = startNew;
  document.getElementById('detail-close').onclick = closeDetail;
  document.getElementById('detail-edit').onclick = () => { if (selected) loadIntoForm(selected); };
  document.getElementById('detail-del').onclick = () => { if (selected) remove(selected); };
  document.getElementById('wiz-next').onclick = wizNext;
  document.getElementById('wiz-back').onclick = wizBack;
  document.getElementById('wiz-cancel').onclick = cancelWizard;
  document.getElementById('wiz-nav').onclick = e => {
    const li = e.target.closest('[data-goto]');
    if (!li) return;
    const n = parseInt(li.dataset.goto, 10);
    if (n >= 1 && n <= LAST) goStep(n);
  };
  document.getElementById('prompt-load').onclick = pullPrompt;
  document.getElementById('skill-cancel').onclick = closeSkillModal;
  document.getElementById('skill-save').onclick = saveSkill;
  document.getElementById('skill-title').oninput = paintSkillTarget;
  document.getElementById('yaml-copy').onclick = copyYaml;
  document.getElementById('templates').onclick = e => {
    const t = e.target.closest('[data-template]');
    if (t) applyTemplate(t.dataset.template);
  };
  document.getElementById('name').addEventListener('input', e => {
    const el = e.target;
    if (el.readOnly) return;
    const tidy = tidyName(el.value);
    if (tidy !== el.value) el.value = tidy;
  });
  document.getElementById('name').addEventListener('blur', e => {
    e.target.value = e.target.value.replace(/-+$/, '');
    paintPreview();
  });
  paintTemplates();
  ['name', 'description', 'prompt'].forEach(id => {
    document.getElementById(id).addEventListener('input', paintPreview);
  });
  showHome();
  loadPrompts();
  // /agents?new=1 or #new opens straight onto the wizard, for a link from a story page.
  if (location.hash === '#new' || new URLSearchParams(location.search).has('new')) startNew();
}

// The registry read is not on the critical path: the wizard works with the box typed by
// hand, so a slow or absent registry must not hold the page up.
async function loadPrompts() {
  const sel = document.getElementById('prompt-pick');
  try {
    const r = await fetch(API + '/prompts').then(x => x.json());
    prompts = r.prompts || [];
  } catch (e) {
    prompts = [];
  }
  if (!prompts.length) {
    sel.innerHTML = '<option value="">No prompts in the registry</option>';
    return;
  }
  const opt = p => `<option value="${esc(p.id)}|${esc(p.tag)}">${esc(p.id)} · ${esc(p.tag)}${p.description ? ' · ' + esc(p.description) : ''}</option>`;
  const standalone = prompts.filter(p => !p.generated);
  const fromAgents = prompts.filter(p => p.generated);
  sel.innerHTML = '<option value="">Choose a prompt…</option>'
    + (standalone.length ? `<optgroup label="In the registry">${standalone.map(opt).join('')}</optgroup>` : '')
    + (fromAgents.length ? `<optgroup label="From an agent">${fromAgents.map(opt).join('')}</optgroup>` : '');
}

function pullPrompt() {
  const v = document.getElementById('prompt-pick').value;
  const msg = document.getElementById('form-msg');
  if (!v) { msg.textContent = 'Choose a prompt first.'; return; }
  const [id, tag] = v.split('|');
  const p = prompts.find(x => x.id === id && x.tag === tag);
  if (!p) { msg.textContent = 'That prompt is no longer in the registry.'; return; }
  document.getElementById('prompt').value = p.content || '';
  msg.textContent = `Pulled ${p.id}:${p.tag} from AgentRegistry. Edit it freely.`;
}

function paintPlatform() {
  const p = catalog.platform || {};
  const dot = document.getElementById('dot');
  const label = document.getElementById('status-label');
  const note = document.getElementById('platform-note');
  if (p.kagent) {
    dot.className = 'dot live';
    label.textContent = p.label || 'kagent on mesh1';
  } else {
    dot.className = 'dot off';
    label.textContent = 'YAML only · kagent not installed';
  }
  note.innerHTML = p.note || '';
  note.style.display = p.note ? '' : 'none';
  const k = document.getElementById('btn-kagent');
  const r = document.getElementById('btn-registry');
  if (p.ui) { k.href = p.ui.replace(/\/$/, '') + '/agents'; k.style.display = ''; }
  else k.style.display = 'none';
  if (p.registry_ui) { r.href = p.registry_ui; r.style.display = ''; }
  else r.style.display = 'none';
}

function toolId(t) { return typeof t === 'string' ? t : t.id; }
function toolDesc(t) { return typeof t === 'string' ? '' : (t.description || ''); }

let chosenSkill = '';
function pickedSkill() { return chosenSkill; }

// One skill shapes one agent. "No skill" is a card of its own so the choice can be cleared.
function paintSkills() {
  const card = (id, dom, title, desc, extra = '') => `
    <label class="ag-pick ${chosenSkill === id ? 'on' : ''}">
      <input type="radio" name="wiz-skill" data-skill="${esc(id)}" ${chosenSkill === id ? 'checked' : ''}>
      <span class="tick">✓</span>
      <span class="dom">${esc(dom)}</span>
      <strong>${esc(title)}</strong>
      <p>${esc(desc)}${extra}</p>
    </label>`;
  document.getElementById('skills').innerHTML = `<div class="ag-pick-grid">
    ${card('', 'None', 'No skill', 'The prompt on its own.')}
    ${catalog.skills.map(s => card(s.id, s.domain || 'Skill', s.title, s.description || '',
      s.ready === false ? ' <span class="warn">Not ready in registry.</span>' : '')).join('')}
    ${window.SKILL_AUTHORING === false ? '' : `<button type="button" class="ag-pick add" id="new-skill"><b>＋</b><strong>Write a skill</strong><p>Commit it to git and register it</p></button>`}
  </div>`;
}

function selectSkill(id) {
  chosenSkill = id || '';
  paintSkills();
  paintPreview();
}

function paintForm() {
  paintSkills();
  document.getElementById('skills').addEventListener('change', e => {
    if (e.target.matches('[data-skill]')) selectSkill(e.target.dataset.skill);
  });
  document.getElementById('skills').addEventListener('click', e => {
    if (e.target.closest('#new-skill')) openSkillModal();
  });
  if (!mcpTab && catalog.mcp.length) mcpTab = catalog.mcp[0].id;
  catalog.mcp.forEach(m => {
    if (!mcpPicked[m.id]) mcpPicked[m.id] = new Set();
  });
  paintMcp();
  document.getElementById('mcp').onclick = onMcpClick;
  applyDemo();
}

function pickedFor(id) {
  if (!mcpPicked[id]) mcpPicked[id] = new Set();
  return mcpPicked[id];
}

function paintMcp() {
  const servers = catalog.mcp || [];
  if (!servers.length) { document.getElementById('mcp').innerHTML = ''; return; }
  if (!servers.some(s => s.id === mcpTab)) mcpTab = servers[0].id;
  const active = servers.find(s => s.id === mcpTab) || servers[0];
  const picked = pickedFor(active.id);
  document.getElementById('mcp').innerHTML = `
    <div class="ag-servers">
      ${servers.map(s => {
        const n = pickedFor(s.id).size;
        return `<button type="button" class="ag-server ${s.id === mcpTab ? 'on' : ''} ${n ? 'has' : ''}" data-mcp-tab="${esc(s.id)}">
          ${glyph(s.id)}
          <span><strong>${esc(s.name)}</strong><em>${n ? n + ' of ' + s.tools.length + ' tools' : s.tools.length + ' tools · ' + esc(s.domain || '')}</em>
          ${tierBadge(s)}</span>
        </button>`;
      }).join('')}
    </div>
    <div class="ag-tools-panel">
      <div class="ag-tier-note ${active.autoApprove ? 'auto' : ''}">${active.autoApprove
        ? `<b>✓ Ready to use.</b> Its AgentRegistry record is labelled <code>${esc(catalog.autoApproveLabel || '')}=true</code>, so the agent gets access the moment it deploys. No ticket, no waiting.`
        : `<b>🛡 Needs approval.</b> No auto-approve label on its AgentRegistry record, so a platform admin signs off before the agent can use it.`}</div>
      <div class="ag-tools-head">
        <div><strong>${esc(active.name)}</strong><p>${esc(active.description)}</p></div>
        <div class="btns">
          <button type="button" class="btn" data-all="${esc(active.id)}">Select all</button>
          <button type="button" class="btn" data-none="${esc(active.id)}">Clear</button>
        </div>
      </div>
      <div class="ag-tool-list">
        ${active.tools.map(t => {
          const id = toolId(t);
          return `<label class="ag-tool">
            <input type="checkbox" data-tool="${esc(active.id)}:${esc(id)}" ${picked.has(id) ? 'checked' : ''}>
            <span><span class="th">${esc(humanTool(id))}</span>${toolDesc(t) ? `<span class="td">${esc(toolDesc(t))}</span>` : ''}<span class="tn">${esc(id)}</span></span>
          </label>`;
        }).join('')}
      </div>
    </div>`;
  paintPreview();
}

function tierBadge(s) {
  return s.autoApprove
    ? '<span class="ag-tier auto">✓ Ready to use</span>'
    : '<span class="ag-tier">🛡 Needs approval</span>';
}

function onMcpClick(e) {
  const tab = e.target.closest('[data-mcp-tab]');
  if (tab) {
    mcpTab = tab.dataset.mcpTab;
    paintMcp();
    return;
  }
  const all = e.target.closest('[data-all]');
  const none = e.target.closest('[data-none]');
  const sid = (all || none)?.dataset.all || (all || none)?.dataset.none;
  if (sid) {
    const server = catalog.mcp.find(m => m.id === sid);
    const set = pickedFor(sid);
    set.clear();
    if (all && server) server.tools.forEach(t => set.add(toolId(t)));
    paintMcp();
    return;
  }
  const box = e.target.closest('input[data-tool]');
  if (box) {
    const [id, tid] = box.dataset.tool.split(':');
    const set = pickedFor(id);
    if (box.checked) set.add(tid); else set.delete(tid);
    // Keep the scroll position of the tool list: repainting the whole block would jump it.
    const list = document.querySelector('.ag-tool-list');
    const top = list ? list.scrollTop : 0;
    paintMcp();
    const again = document.querySelector('.ag-tool-list');
    if (again) again.scrollTop = top;
  }
}

function paintTemplates() {
  document.getElementById('templates').innerHTML = TEMPLATES.map(t => {
    const servers = Object.keys(t.tools).map(id => `<span class="ag-chip ${serverAuto(id) ? 'auto' : ''}">${glyph(id)}${esc(serverName(id))}${serverAuto(id) ? '<b class="ag-tick">✓</b>' : ''}</span>`).join('');
    const instant = Object.keys(t.tools).every(serverAuto);
    return `<button type="button" class="ag-template" data-template="${t.id}">
      <span class="ag-template-icon">${t.icon}</span>
      <strong>${esc(t.title)}</strong>${instant ? '<span class="ag-tier auto">✓ No approval needed</span>' : ''}
      <p>${esc(t.blurb)}</p>
      <div class="ag-chips">${servers}</div>
    </button>`;
  }).join('') + `<button type="button" class="ag-template blank" data-template="blank">
      <span class="ag-template-icon">✏️</span>
      <strong>Start from scratch</strong>
      <p>A blank agent. Write your own instructions and pick its tools.</p>
    </button>`;
}

function uniqueName(base) {
  // Names are used exactly as typed (no forced prefix). Keep the generated "-N"
  // tail within the server's 24-char cap (kagent's waypoint label must fit 63 bytes).
  const taken = new Set(agents.map(a => a.name));
  if (!taken.has(base)) return base;
  let i = 2;
  while (true) {
    const tail = `-${i}`;
    const candidate = base.slice(0, 24 - tail.length) + tail;
    if (!taken.has(candidate)) return candidate;
    i++;
  }
}

function applyTemplate(id) {
  const t = TEMPLATES.find(x => x.id === id);
  mcpPicked = {};
  (catalog.mcp || []).forEach(m => { mcpPicked[m.id] = new Set(); });
  if (!t) {
    document.getElementById('name').value = '';
    document.getElementById('description').value = '';
    document.getElementById('prompt').value = '';
    selectSkill('');
    paintMcp();
    goStep(2);
    document.getElementById('name').focus();
    return;
  }
  document.getElementById('name').value = uniqueName(t.name);
  document.getElementById('description').value = t.description;
  document.getElementById('prompt').value = t.prompt;
  selectSkill(catalog.skills.some(s => s.id === t.skill) ? t.skill : '');
  for (const [sid, tools] of Object.entries(t.tools)) {
    const server = catalog.mcp.find(m => m.id === sid);
    if (!server) continue;
    const have = new Set(server.tools.map(toolId));
    tools.filter(x => have.has(x)).forEach(x => pickedFor(sid).add(x));
  }
  mcpTab = Object.keys(t.tools)[0] || mcpTab;
  paintMcp();
  goStep(2);
}

function applyDemo() {
  // The release-briefing defaults need the github server; a platform without it starts blank.
  if (!(catalog.mcp || []).some(m => m.id === 'github')) return;
  document.getElementById('description').value = DEMO.description;
  document.getElementById('prompt').value = DEMO.prompt;
  selectSkill(DEMO.skills[0] || '');
  mcpPicked = {};
  (catalog.mcp || []).forEach(m => { mcpPicked[m.id] = new Set(); });
  const want = new Set(DEMO.githubTools);
  (catalog.mcp.find(m => m.id === 'github')?.tools || []).forEach(t => {
    const id = toolId(t);
    if (want.has(id)) pickedFor('github').add(id);
  });
  mcpTab = 'github';
  paintMcp();
}

function skillSlug(title) {
  return title.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 48);
}

function paintSkillTarget() {
  const sid = skillSlug(document.getElementById('skill-title').value.trim());
  document.getElementById('skill-target').textContent = sid
    ? `Writes vision-demo-2026/demo-scripts/agentregistry/skill/${sid}/, commits it and pushes to main.`
    : '';
}

function openSkillModal() {
  ['skill-title', 'skill-desc', 'skill-body'].forEach(id => { document.getElementById(id).value = ''; });
  document.getElementById('skill-msg').textContent = '';
  paintSkillTarget();
  document.getElementById('skill-modal').style.display = 'flex';
  document.getElementById('skill-title').focus();
}

function closeSkillModal() {
  document.getElementById('skill-modal').style.display = 'none';
}

async function saveSkill() {
  const msg = document.getElementById('skill-msg');
  const btn = document.getElementById('skill-save');
  const body = {
    title: document.getElementById('skill-title').value.trim(),
    description: document.getElementById('skill-desc').value.trim(),
    body: document.getElementById('skill-body').value,
  };
  btn.disabled = true;
  msg.textContent = 'Writing the package, committing and pushing…';
  let r;
  try {
    r = await fetch(API + '/skills', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(x => x.json());
  } catch (e) {
    btn.disabled = false;
    msg.textContent = 'The console could not reach the server.';
    return;
  }
  btn.disabled = false;
  if (!r.ok) { msg.textContent = r.error || 'Could not create the skill.'; return; }

  catalog = await fetch(API + '/catalog').then(x => x.json());
  selectSkill(r.id);
  closeSkillModal();

  const parts = [];
  parts.push(r.commit ? `Committed ${r.commit}` : 'Not committed');
  parts.push(r.pushed ? 'pushed to main' : 'not pushed');
  parts.push(r.registered ? `registered as ${r.id}` : 'not registered');
  const detail = r.detail ? ` ${r.detail}` : '';
  document.getElementById('form-msg').textContent =
    `${parts.join(', ')}. Usable here now; the body reaches the public mirror when the `
    + `mirror action has run.${detail}`;
}

function specFromForm() {
  const chosen = pickedSkill();
  const skills = chosen ? [chosen] : [];
  const mcp = [];
  for (const m of catalog.mcp) {
    const tools = [...pickedFor(m.id)];
    if (tools.length) mcp.push({ id: m.id, tools });
  }
  return {
    name: document.getElementById('name').value.trim(),
    description: document.getElementById('description').value.trim(),
    prompt: document.getElementById('prompt').value.trim(),
    skills, mcp,
  };
}

// The side card is the same card the list shows, so what you build is what you get.
function paintPreview() {
  const box = document.getElementById('preview-card');
  if (!box || !catalog.mcp) return;
  const spec = specFromForm();
  const current = editing ? agents.find(a => a.name === spec.name) : null;
  box.innerHTML = cardHtml({
    ...spec,
    name: spec.name || 'your-agent',
    yaml: current ? current.yaml : 'modelName: ' + (window.AGENT_MODEL || 'claude-haiku-4-5'),
  }, { preview: true, state: 'draft', by: editing && current ? 'next version after ' + current.version : 'v1 on first deploy' });
}

function showHome() {
  document.getElementById('home-view').style.display = '';
  document.getElementById('wizard-view').style.display = 'none';
  const chatView = document.getElementById('chat-view');
  if (chatView) chatView.style.display = 'none';
  editing = false;
}

function showWizard(start = 1) {
  document.getElementById('home-view').style.display = 'none';
  document.getElementById('wizard-view').style.display = '';
  if (poll) clearInterval(poll);
  goStep(start);
  paintPreview();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function cancelWizard() {
  showHome();
  if (selected) show(selected); else closeDetail();
}

function goStep(n) {
  if (n >= 3) {
    const name = document.getElementById('name').value.trim();
    if (!name) {
      n = 2;
      setTimeout(() => {
        document.getElementById('form-msg').textContent = 'Give it a name first.';
        document.getElementById('name').focus();
      });
    }
  }
  wizStep = n;
  document.querySelectorAll('.wiz-step').forEach(el => {
    el.classList.toggle('on', el.dataset.step === String(n));
  });
  document.querySelectorAll('#wiz-nav li').forEach(el => {
    const g = parseInt(el.dataset.goto, 10);
    el.classList.toggle('on', g === n);
    el.classList.toggle('done', g < n);
  });
  document.getElementById('wiz-stepno').textContent = `Step ${n} of ${LAST}`;
  document.getElementById('wiz-back').style.visibility = n === 1 ? 'hidden' : '';
  const next = document.getElementById('wiz-next');
  // Step 1 moves on by choosing a card, so a Next button there would only skip the choice.
  next.style.display = n === LAST || n === 1 ? 'none' : '';
  if (n < LAST) next.textContent = 'Next: ' + STEP_TITLES[n + 1];
  document.getElementById('deploy').style.display = n === LAST ? '' : 'none';
  document.querySelector('.ag-wiz').classList.toggle('pick', n === 1);
  if (n === LAST) paintReview();
  if (n !== 1) document.getElementById('form-msg').textContent = '';
}

function wizNext() { goStep(Math.min(LAST, wizStep + 1)); }
function wizBack() { goStep(Math.max(1, wizStep - 1)); }

// Colour keys and values, and leave block scalars (the prompt) alone so a colon in prose
// is not painted as a key.
function highlightYaml(text) {
  let blockIndent = -1;
  return text.split('\n').map(line => {
    const ind = line.length - line.trimStart().length;
    if (blockIndent >= 0) {
      if (line.trim() === '' || ind > blockIndent) return esc(line);
      blockIndent = -1;
    }
    if (/^\s*#/.test(line)) return `<span class="c">${esc(line)}</span>`;
    const m = /^(\s*-?\s*)([A-Za-z_][\w.-]*):(.*)$/.exec(line);
    if (!m) return esc(line);
    if (/\|\s*$/.test(m[3])) blockIndent = ind;
    return `${esc(m[1])}<span class="k">${esc(m[2])}</span>:${m[3] ? `<span class="v">${esc(m[3])}</span>` : ''}`;
  }).join('\n');
}

async function paintReview() {
  const spec = specFromForm();
  const tools = (spec.mcp || []).reduce((n, m) => n + m.tools.length, 0);
  const current = editing ? agents.find(a => a.name === spec.name) : null;
  document.getElementById('review-sub').textContent = editing
    ? `Publishes a new version of ${spec.name}${current && current.version ? ' after ' + current.version : ''}. MCP tools still need a platform admin.`
    : 'Check it, then deploy. It lands in AgentRegistry first, then on kagent.';
  const mcpHtml = (spec.mcp || []).length
    ? `<div class="ag-chips">${spec.mcp.map(m => `<span class="ag-chip ${serverAuto(m.id) ? 'auto' : ''}">${glyph(m.id)}${esc(serverName(m.id))} <em>${m.tools.length}</em>${serverAuto(m.id) ? '<b class="ag-tick">✓</b>' : ''}</span>`).join('')}</div>`
    : 'No tools';
  const skill = spec.skills.length ? skillTitle(spec.skills[0]) : '';
  const sys = m => `<b>${esc(serverName(m.id))}</b> (${m.tools.length} action${m.tools.length === 1 ? '' : 's'})`;
  const now = (spec.mcp || []).filter(m => serverAuto(m.id)).map(sys);
  const later = (spec.mcp || []).filter(m => !serverAuto(m.id)).map(sys);
  const joinList = xs => xs.length < 2 ? xs.join('') : xs.slice(0, -1).join(', ') + ' and ' + xs[xs.length - 1];
  document.getElementById('review-plain').innerHTML = `
    <div class="ag-avatar lg" style="${avatarStyle(spec.name)}">${esc(initials(spec.name))}</div>
    <p><b>${esc(spec.name)}</b>: ${esc(endStop(spec.description || 'An agent that answers questions'))}
    ${skill ? `It follows the <b>${esc(skill)}</b> skill.` : ''}
    ${now.length ? `It can use ${joinList(now)} straight away.` : ''}
    ${later.length ? `${joinList(later)} ${later.length === 1 ? 'needs' : 'need'} a platform admin to approve first.` : ''}
    ${!now.length && !later.length ? 'It uses no outside systems.' : ''}
    It runs on kagent in your cluster.</p>`;
  document.getElementById('yaml-details').open = false;
  document.getElementById('review').innerHTML = `<dl class="ag-review">
    <div><dt>Name</dt><dd>${esc(spec.name)}</dd></div>
    <div><dt>Version</dt><dd>${editing ? 'next version' : 'v1'}</dd></div>
    <div class="wide"><dt>What it is for</dt><dd>${esc(spec.description || '—')}</dd></div>
    <div><dt>Skill</dt><dd>${spec.skills.length ? esc(skillTitle(spec.skills[0])) : 'None'}</dd></div>
    <div><dt>MCP tools · ${tools}</dt><dd>${mcpHtml}</dd></div>
  </dl>`;
  const pre = document.getElementById('review-yaml');
  pre.textContent = 'Rendering…';
  const seq = ++previewSeq;
  try {
    const r = await fetch(API + '/preview', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(spec),
    }).then(x => x.json());
    if (seq !== previewSeq) return;
    pre.dataset.raw = r.yaml || '';
    pre.innerHTML = highlightYaml(r.yaml || '');
  } catch (e) {
    if (seq === previewSeq) pre.textContent = 'Could not render the YAML preview.';
  }
}

function endStop(s) {
  s = String(s).trim().replace(/\.+$/, '');
  return s.charAt(0).toUpperCase() + s.slice(1) + '.';
}

function copyYaml() {
  const pre = document.getElementById('review-yaml');
  const btn = document.getElementById('yaml-copy');
  navigator.clipboard.writeText(pre.dataset.raw || pre.textContent).then(() => {
    btn.textContent = 'Copied';
    setTimeout(() => { btn.textContent = 'Copy'; }, 1400);
  });
}

function startNew() {
  if (!catalog.platform) return;
  editing = false;
  document.getElementById('name').readOnly = false;
  document.getElementById('name').value = '';
  document.getElementById('form-title').textContent = 'New agent';
  document.getElementById('deploy').textContent = 'Deploy to kagent';
  document.getElementById('form-msg').textContent = '';
  showWizard(1);
}

function loadIntoForm(name) {
  const a = agents.find(x => x.name === name);
  if (!a) return;
  editing = true;
  document.getElementById('form-title').textContent = 'Editing ' + a.name + (a.version ? ' · ' + a.version : '');
  document.getElementById('deploy').textContent = 'Publish new version';
  const nameEl = document.getElementById('name');
  nameEl.value = a.name;
  nameEl.readOnly = true;
  document.getElementById('description').value = a.description || '';
  document.getElementById('prompt').value = a.prompt || '';
  selectSkill((a.skills || [])[0] || '');
  mcpPicked = {};
  (catalog.mcp || []).forEach(m => { mcpPicked[m.id] = new Set(); });
  for (const m of a.mcp || []) {
    mcpPicked[m.id] = new Set(m.tools || []);
  }
  mcpTab = (a.mcp && a.mcp[0] && a.mcp[0].id) || mcpTab || 'github';
  paintMcp();
  document.getElementById('form-msg').textContent = '';
  showWizard(2);
  editing = true;
  paintPreview();
}

async function deploy() {
  const msg = document.getElementById('form-msg');
  const btn = document.getElementById('deploy');
  const isEdit = document.getElementById('name').readOnly;
  msg.textContent = '';
  btn.disabled = true;
  const spec = specFromForm();
  const overlay = document.getElementById('deploy-overlay');
  document.getElementById('deploy-title').textContent = isEdit ? `Publishing a new version of ${spec.name}` : `Deploying ${spec.name}`;
  overlay.style.display = 'flex';
  const t0 = Date.now();
  const tick = setInterval(() => {
    document.getElementById('deploy-elapsed').textContent = Math.round((Date.now() - t0) / 1000) + 's';
  }, 500);
  let r;
  try {
    r = await fetch(API, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(spec),
    }).then(x => x.json());
  } catch (e) {
    r = { ok: false, error: 'The console could not reach the server.' };
  }
  clearInterval(tick);
  overlay.style.display = 'none';
  document.getElementById('deploy-elapsed').textContent = '0s';
  btn.disabled = false;
  if (!r.ok) { msg.textContent = r.error || 'failed'; return; }
  msg.textContent = '';
  justDeployed = r.agent.name;
  celebrated.delete(r.agent.name);
  await refreshList();
  showHome();
  show(r.agent.name);
}

let loaded = false;

function listFailed() {
  document.getElementById('count-sub').textContent = 'Could not load your agents. Is the console still running?';
}

async function refreshList() {
  const r = await fetch(API).then(x => x.json());
  agents = r.agents || [];
  loaded = true;
  paintList();
}

function paintList() {
  document.getElementById('list-view').classList.remove('loading');
  const states = agents.map(stateOf);
  const live = states.filter(s => s === 'live').length;
  const pending = states.filter(s => s === 'pending').length;
  const off = states.length - live - pending;
  document.getElementById('count-total').textContent = agents.length;
  document.getElementById('count-label').textContent = agents.length === 1 ? 'agent built' : 'agents built';
  const bits = [];
  if (live) bits.push(`<b>${live}</b> live`);
  if (pending) bits.push(`<b>${pending}</b> waiting on a platform admin`);
  if (off) bits.push(`<b>${off}</b> not deployed`);
  document.getElementById('count-sub').innerHTML = agents.length
    ? bits.join(' · ') + '. Each one is published to AgentRegistry and runs as a pod on kagent.'
    : 'Pick a prompt, a skill and MCP tools. AgentRegistry publishes it and kagent runs it as a pod.';
  const add = `<div class="ag-card add" data-new="1" tabindex="0"><b>＋</b><strong>New agent</strong><span>Prompt, skill, tools, deploy</span></div>`;
  document.getElementById('list').innerHTML = agents.map(a => cardHtml(a)).join('') + add;
  document.getElementById('list').onclick = e => {
    const del = e.target.closest('[data-del]');
    const edit = e.target.closest('[data-edit]');
    if (del) { e.stopPropagation(); remove(del.dataset.del); return; }
    if (edit) { e.stopPropagation(); loadIntoForm(edit.dataset.edit); return; }
    if (e.target.closest('[data-new]')) { startNew(); return; }
    const card = e.target.closest('[data-name]');
    if (card) show(card.dataset.name);
  };
  document.getElementById('list').onkeydown = e => {
    if (e.key !== 'Enter') return;
    const card = e.target.closest('[data-name]');
    if (card) show(card.dataset.name);
    else if (e.target.closest('[data-new]')) startNew();
  };
}

let poll = null;

function closeDetail() {
  selected = null;
  document.getElementById('detail').style.display = 'none';
  document.getElementById('list-view').style.display = '';
  if (poll) clearInterval(poll);
  refreshList();
}

function paintDetailHead(a) {
  document.getElementById('detail-edit').style.display = a.builder === false ? 'none' : '';
  document.getElementById('detail-del').style.display = a.builder === false ? 'none' : '';
  const state = stateOf(a);
  const st = document.getElementById('detail-state');
  st.className = 'ag-state ' + state;
  st.textContent = STATE_LABEL[state];
  const av = document.getElementById('detail-avatar');
  av.textContent = initials(a.name);
  av.setAttribute('style', avatarStyle(a.name));
  document.getElementById('detail-name').textContent = a.version ? (a.name + ' · ' + a.version) : a.name;
  document.getElementById('detail-desc').textContent = a.description || '';
  const rows = [];
  const model = modelOf(a);
  if (model) rows.push(['Model', `<span class="ag-chip model">${esc(model)}</span>`]);
  rows.push(['Skill', (a.skills || []).length
    ? `<div class="ag-chips">${a.skills.map(id => `<span class="ag-chip skill">${esc(skillTitle(id))}</span>`).join('')}</div>`
    : '<span class="by">None, the prompt on its own</span>']);
  const groups = mcpGroups(a);
  rows.push(['MCP tools', groups.length ? groups.map(g => `<div class="ag-mcp-group">
      <span class="ag-chip ${serverAuto(g.id) ? 'auto' : ''}">${glyph(g.id)}${esc(g.name)} <em>${g.tools.length}</em></span>
      ${tierBadge({ autoApprove: serverAuto(g.id) })}
      <div class="ag-tools">${g.tools.map(t => `<code title="${esc(t)}">${esc(humanTool(t))}</code>`).join('')}</div>
    </div>`).join('') : '<span class="by">None</span>']);
  if (a.updated) rows.push(['Updated', esc(ago(a.updated))]);
  document.getElementById('detail-runs').innerHTML = rows.map(([k, v]) =>
    `<div class="ag-runs-row"><span>${k}</span><div>${v}</div></div>`).join('');
}

function show(name) {
  const a = agents.find(x => x.name === name);
  selected = name;
  const box = document.getElementById('detail');
  if (!a) { box.style.display = 'none'; if (poll) clearInterval(poll); return; }
  showHome();
  document.getElementById('list-view').style.display = 'none';
  box.style.display = 'block';
  paintDetailHead(a);
  document.getElementById('yaml-view').innerHTML = highlightYaml(a.yaml || '');
  document.getElementById('yaml-view').classList.add('ag-yaml');
  const pol = document.getElementById('policy-details');
  const polView = document.getElementById('policy-view');
  const polText = [a.policy_yaml, a.auto_policy_yaml].filter(Boolean).join('---\n');
  if (polText) {
    pol.style.display = '';
    polView.innerHTML = highlightYaml(polText);
    polView.classList.add('ag-yaml');
  } else {
    pol.style.display = 'none';
    polView.textContent = '';
  }
  document.getElementById('life').innerHTML = '';
  paintApproval(a);
  pollStatus(name);
  if (poll) clearInterval(poll);
  poll = setInterval(() => pollStatus(name), 3000);
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

function mcpApproved(a) {
  return adminApproved(a) || !tiers(a).restricted.length;
}

function mcpGroups(a) {
  return (a.mcp || []).filter(m => (m.tools || []).length).map(m => ({ id: m.id, name: serverName(m.id), tools: m.tools }));
}

function mcpToolCount(a) {
  return mcpGroups(a).reduce((n, g) => n + g.tools.length, 0);
}

function paintApproval(a) {
  const t = tiers(a);
  const pending = document.getElementById('approve-card');
  const done = document.getElementById('approved-card');
  const auto = document.getElementById('auto-card');
  if (t.auto.length && a.applied) {
    auto.style.display = 'block';
    const names = t.auto.map(id => `<b>${esc(serverName(id))}</b>`).join(', ');
    document.getElementById('auto-detail').innerHTML =
      `${names} ${t.auto.length === 1 ? 'is' : 'are'} labelled <code>${esc(catalog.autoApproveLabel || '')}=true</code> in AgentRegistry, so the gateway grant for <code>kagent/${esc(a.name)}</code> was written at deploy. Nobody had to approve it.`;
  } else {
    auto.style.display = 'none';
  }
  if (!t.restricted.length || !a.applied) {
    pending.style.display = 'none';
    done.style.display = 'none';
    return;
  }
  const n = mcpGroups(a).filter(g => t.restricted.includes(g.id)).reduce((k, g) => k + g.tools.length, 0);
  if (adminApproved(a)) {
    pending.style.display = 'none';
    done.style.display = 'block';
    document.getElementById('approved-detail').textContent =
      'ServiceAccount ' + a.name + ' may call ' + n + ' MCP tool' + (n === 1 ? '' : 's') + '.';
    return;
  }
  done.style.display = 'none';
  pending.style.display = 'block';
  const note = document.getElementById('approve-msg');
  note.textContent = n + ' tool' + (n === 1 ? '' : 's') + ' on ' + t.restricted.map(serverName).join(', ') + ' requested.';
}

async function pollStatus(name) {
  const st = await fetch(API + '/' + encodeURIComponent(name) + '/status').then(r => r.json());
  if (selected !== name) return;
  const known = ['done', 'wait', 'fail'];
  document.getElementById('life').innerHTML = (st.steps || []).map(s => {
    const cls = known.includes(s.state) ? s.state : 'todo';
    const mark = cls === 'done' ? '✓' : cls === 'fail' ? '!' : '';
    const det = s.id === 'saved' && s.detail ? ago(s.detail) : (s.detail || '');
    return `<li class="${cls}"><span class="mark">${mark}</span><span><strong>${esc(s.label)}</strong><span class="det">${esc(det)}</span></span></li>`;
  }).join('');
  if (st.agent) {
    const i = agents.findIndex(x => x.name === name);
    if (i >= 0) agents[i] = { ...agents[i], ...st.agent };
  }
  const a = agents.find(x => x.name === name) || st.agent || {};
  paintApproval(a);
  paintDetailHead(a);
  const needsMcp = tiers(a).restricted.length > 0;
  const chat = document.getElementById('open-chat');
  const canChat = st.ready && st.urls && st.urls.prompt && (!needsMcp || adminApproved(a));
  if (canChat) {
    chat.href = st.urls.prompt;
    chat.style.display = '';
  } else {
    chat.style.display = 'none';
  }
  paintCelebrate(a, st, needsMcp);
  const log = document.getElementById('life-log');
  if (st.logs) log.textContent = st.logs;
  const line = document.getElementById('detail-status');
  if (needsMcp && a.applied && !adminApproved(a)) {
    line.textContent = 'Deployed. Waiting for a platform admin to allow MCP tools.';
  } else {
    line.textContent = st.ready ? 'Green. Prompt it in kagent.' : '';
  }
}

// Only for an agent deployed in this visit: a banner on every old agent would be noise.
function paintCelebrate(a, st, needsMcp) {
  const box = document.getElementById('celebrate');
  if (a.name !== justDeployed) { box.style.display = 'none'; return; }
  const waiting = needsMcp && a.applied && !adminApproved(a);
  const live = st.ready && !waiting;
  const autoNames = tiers(a).auto.map(serverName);
  let html;
  if (live) {
    html = `<div class="ag-cele-icon">🎉</div><div><h3>${esc(a.name)} is live</h3>
      <p>Deployed on kagent and ready to talk to.${autoNames.length ? ` ${esc(autoNames.join(', '))} ${autoNames.length === 1 ? 'was' : 'were'} granted automatically, so there was nothing to approve.` : ''}</p></div>
      <button type="button" class="btn primary" data-chat="${esc(a.name)}">Chat with it</button>`;
  } else if (waiting) {
    html = `<div class="ag-cele-icon">🛡️</div><div><h3>${esc(a.name)} is deployed. One step left.</h3>
      <p>${autoNames.length ? `${esc(autoNames.join(', '))} already work${autoNames.length === 1 ? 's' : ''}. ` : ''}A platform admin approves ${esc(tiers(a).restricted.map(serverName).join(', '))}. Until then those tools stay closed.</p></div>
      <a class="btn primary" href="${window.APPROVALS_PAGE || '/approvals'}">Ask for approval</a>`;
  } else {
    html = `<div class="ag-cele-icon"><span class="ag-spinner sm"></span></div><div><h3>Starting ${esc(a.name)}</h3>
      <p>AgentRegistry has it. kagent is starting it now; the steps below go green as it comes up.</p></div>`;
  }
  box.className = 'ag-celebrate ' + (live ? 'live' : waiting ? 'wait' : 'busy');
  box.innerHTML = html;
  box.style.display = '';
  if ((live || waiting) && !celebrated.has(a.name)) {
    celebrated.add(a.name);
    if (live || window.CONFETTI_ON_DEPLOY) confetti();
  }
}

function confetti() {
  const colours = ['#7c3aed', '#a855f7', '#22c55e', '#f59e0b', '#3b82f6', '#ec4899'];
  const layer = document.createElement('div');
  layer.className = 'ag-confetti';
  for (let i = 0; i < 90; i++) {
    const b = document.createElement('i');
    b.style.left = Math.random() * 100 + 'vw';
    b.style.background = colours[i % colours.length];
    b.style.animationDelay = (Math.random() * 0.6) + 's';
    b.style.animationDuration = (2.2 + Math.random() * 1.6) + 's';
    b.style.transform = `rotate(${Math.random() * 360}deg)`;
    layer.appendChild(b);
  }
  document.body.appendChild(layer);
  setTimeout(() => layer.remove(), 4500);
}

async function remove(name) {
  const who = name || selected;
  if (!who) return;
  if (!confirm('Delete ' + who + ' from AgentRegistry and kagent?')) return;
  await fetch(API + '/' + encodeURIComponent(who), { method: 'DELETE' });
  if (selected === who) {
    selected = null;
    document.getElementById('detail').style.display = 'none';
    document.getElementById('list-view').style.display = '';
    if (poll) clearInterval(poll);
  }
  showHome();
  await refreshList();
}

boot();
