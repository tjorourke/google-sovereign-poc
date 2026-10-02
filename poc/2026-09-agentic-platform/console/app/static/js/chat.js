// Chat with a deployed agent, streamed over A2A through the console. Every agent gets the
// same chat; an agent with the IT pub quiz also gets answer buttons and a scoreboard, built
// only from the quiz server's own tool results (check_answer, fifty_fifty, quiz_score).
(() => {
  let chatName = null;
  let contextId = null;
  let busy = false;
  let route = null;         // the last turn's `agent` event: who called, as which identity, on which pod
  let quiz = null;          // { id, questions: {qid: {...}}, answers: [{qid, correct, ...}], verdict }
  let activity = [];        // every tool call this chat, for the side panel
  const cards = {};         // question id -> its card element, so check_answer can mark it
  let lastLetters = {};     // letter -> option text for the question on screen

  const $ = id => document.getElementById(id);
  const FRIENDLY = {
    start_quiz: 'Started a new round', check_answer: 'Checked your answer', fifty_fifty: 'Used a 50/50',
    quiz_score: 'Worked out the final score', list_topics: 'Looked up the topics',
    excuse: 'Wrote an excuse', excuse_battle: 'Ran an excuse battle', rate_excuse: 'Rated your excuse',
    work_window: 'Worked out the safe work window', daylight: 'Looked up sunrise and sunset',
  };

  // The runtime prefixes tools with the MCP server name (it_pub_quiz_start_quiz). Drop it.
  function baseTool(name) {
    const servers = (catalog.mcp || []).map(m => (m.registryName || m.id).replace(/-/g, '_') + '_');
    const hit = servers.find(p => name.startsWith(p));
    return hit ? name.slice(hit.length) : name;
  }
  const friendly = n => FRIENDLY[baseTool(n)] || humanTool(baseTool(n));
  const isQuizAgent = a => (a.mcp || []).some(m => m.id === 'quiz' && (m.tools || []).length);

  // Gemma sometimes writes a tool call out as text (```tool_code\nget_app_settings()```)
  // instead of making it: usually a tool it has not been allowed. Never show that as a reply.
  const CALL_BLOCK = /```[a-z_]*\s*\[?\s*[A-Za-z_][\w.]*\s*\([^`]*\)\s*\]?\s*(```|$)/g;
  const CALL_BARE = /^\s*\[?\s*[A-Za-z_][\w.]*\s*\([^)]*\)\s*\]?\s*$/;
  // The pythonic list form with keyword arguments, whose strings may hold anything,
  // brackets and newlines included: [create_issue(title="...", body="...")].
  const CALL_LIST = /^\s*\[\s*[A-Za-z_][\w.]*\s*\(\s*(\)|[A-Za-z_]\w*\s*=)[\s\S]*\)\s*\]\s*$/;
  function clean(text) {
    const t = String(text || '').replace(CALL_BLOCK, '').trim();
    return CALL_BARE.test(t) || CALL_LIST.test(t) ? '' : t;
  }
  function calledName(text) {
    const m = String(text || '').match(/([A-Za-z_][\w.]*)\s*\(/);
    return m ? baseTool(m[1]) : '';
  }

  // A tool result that is an error, in any of the shapes MCP servers use. The model tends to
  // explain these away ("the configuration file is missing"), so the chat shows them as they are.
  function toolError(r) {
    if (r == null) return '';
    if (typeof r === 'string') return /^\s*(error|failed)\b|\b(40[134]|5\d\d)\b.*(not found|forbidden|unauthori[sz]ed|error)/i.test(r) ? r : '';
    if (typeof r === 'object') {
      if (r.isError) return (r.content || []).map(c => c.text || '').join(' ') || 'the tool reported an error';
      if (r.error) return typeof r.error === 'string' ? r.error : (r.error.message || JSON.stringify(r.error));
    }
    return '';
  }

  // Small, safe markdown: escape first, then headings, lists, fenced code, quotes
  // and inline bold/italic/code. Re-rendered on every chunk, so an unclosed fence
  // mid-stream still shows as code.
  function inline(t) {
    return t.replace(/`([^`]+)`/g, '<code>$1</code>')
            .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
            .replace(/(^|[^*\w])\*([^*\n]+)\*(?!\w)/g, '$1<em>$2</em>');
  }
  function md(text) {
    const lines = esc(text || '').split('\n');
    let out = '', list = null, para = [], code = null;
    const flushPara = () => { if (para.length) out += `<p>${inline(para.join('<br>'))}</p>`; para = []; };
    const closeList = () => { if (list) out += `</${list}>`; list = null; };
    for (const line of lines) {
      if (code !== null) {
        if (/^\s*```/.test(line)) { out += `<pre><code>${code.join('\n')}</code></pre>`; code = null; }
        else code.push(line);
        continue;
      }
      let m;
      if (/^\s*```/.test(line)) { flushPara(); closeList(); code = []; continue; }
      if ((m = line.match(/^\s*(#{1,6})\s+(.*)$/))) {
        flushPara(); closeList();
        const n = Math.min(m[1].length + 2, 6);
        out += `<h${n}>${inline(m[2].replace(/\s*#+\s*$/, ''))}</h${n}>`; continue;
      }
      if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { flushPara(); closeList(); out += '<hr>'; continue; }
      if ((m = line.match(/^\s*(?:[-•*+]|(\d+)[.)])\s+(.*)$/))) {
        flushPara();
        const kind = m[1] ? 'ol' : 'ul';
        if (list !== kind) { closeList(); out += kind === 'ol' && m[1] !== '1' ? `<ol start="${m[1]}">` : `<${kind}>`; list = kind; }
        out += `<li>${inline(m[2])}</li>`; continue;
      }
      if ((m = line.match(/^\s*&gt;\s?(.*)$/))) { flushPara(); closeList(); out += `<blockquote>${inline(m[1])}</blockquote>`; continue; }
      if (!line.trim()) { flushPara(); closeList(); continue; }
      if (list && /^\s{2,}\S/.test(line)) { out = out.replace(/<\/li>$/, ` ${inline(line.trim())}</li>`); continue; }
      closeList(); para.push(line.trim());
    }
    flushPara(); closeList();
    if (code !== null) out += `<pre><code>${code.join('\n')}</code></pre>`;
    return out;
  }

  // A to D options in the agent's latest message, however it formats them.
  function options(text) {
    const found = {};
    for (const line of (text || '').split('\n')) {
      const m = line.match(/^\s*[-*]?\s*\**\(?([A-D])[).:]\**\s+(.+?)\s*$/);
      if (m) found[m[1]] = m[2].replace(/\*\*/g, '');
    }
    return Object.keys(found).length >= 2 ? found : null;
  }

  function openChat(name, fresh = true) {
    const a = agents.find(x => x.name === name);
    if (!a) return;
    chatName = name;
    if (fresh) { contextId = null; quiz = null; activity = []; $('chat-log').innerHTML = ''; }
    route = null;
    if (typeof poll !== 'undefined' && poll) clearInterval(poll);
    $('home-view').style.display = 'none';
    $('wizard-view').style.display = 'none';
    $('chat-view').style.display = '';
    document.querySelector('header.hero')?.classList.add('ag-hide');
    document.getElementById('platform-note').style.display = 'none';
    $('chat-avatar').textContent = initials(a.name);
    $('chat-avatar').setAttribute('style', avatarStyle(a.name));
    $('chat-name').textContent = a.title || a.name;
    const tools = (a.mcp || []).filter(m => (m.tools || []).length).map(m => serverName(m.id));
    $('chat-sub').textContent = (a.description || '') + (tools.length ? ` · uses ${tools.join(', ')}` : '');
    $('chat-view').classList.toggle('quiz', isQuizAgent(a));
    $('chat-text').placeholder = isQuizAgent(a) ? 'Type an answer, or ask anything' : `Message ${a.title || a.name}`;
    if (location.hash !== '#chat/' + name) history.replaceState(null, '', '#chat/' + name);
    if (fresh) welcome(a);
    paintSide();
    $('chat-text').focus();
    window.scrollTo({ top: 0 });
  }

  function closeChat() {
    $('chat-view').style.display = 'none';
    document.querySelector('header.hero')?.classList.remove('ag-hide');
    history.replaceState(null, '', location.pathname);
    showHome();
    closeDetail();
  }

  function welcome(a) {
    const quizMode = isQuizAgent(a);
    const picks = quizMode
      ? ['Start a mixed round', 'Kubernetes round please', 'Development round please', 'What topics do you have?']
      : ['What can you do?', 'Give me a quick example of what you are for'];
    $('chat-log').innerHTML = `<div class="ag-chat-empty">
      <div class="ag-avatar lg" style="${avatarStyle(a.name)}">${esc(initials(a.name))}</div>
      <h3>${esc(a.title || a.name)}</h3>
      <p>${esc(a.description || 'Say hello.')}</p>
      <div class="ag-suggest">${picks.map(p => `<button type="button" data-say="${esc(p)}">${esc(p)}</button>`).join('')}</div>
    </div>`;
    $('chat-answers').innerHTML = '';
  }

  function bubble(role, html) {
    $('chat-log').querySelector('.ag-chat-empty')?.remove();
    const el = document.createElement('div');
    el.className = 'ag-msg ' + role;
    if (role === 'agent') {
      el.innerHTML = `<div class="ag-avatar sm" style="${avatarStyle(chatName)}">${esc(initials(chatName))}</div><div class="ag-msg-body"><div class="ag-msg-text">${html}</div></div>`;
    } else {
      el.innerHTML = `<div class="ag-msg-body"><div class="ag-msg-text">${html}</div></div>`;
    }
    $('chat-log').appendChild(el);
    scroll();
    return el;
  }
  const scroll = () => { const log = $('chat-log'); log.scrollTop = log.scrollHeight; };

  function toolChip(ev, host) {
    const chip = document.createElement('div');
    chip.className = 'ag-toolchip';
    chip.dataset.id = ev.id;
    chip.innerHTML = `<span class="spin"></span>${esc(friendly(ev.name))}<em>via ${esc(serverOf(ev.name))}</em>`;
    host.querySelector('.ag-msg-body').insertBefore(chip, host.querySelector('.ag-msg-text'));
    scroll();
  }
  function serverOf(name) {
    let m = (catalog.mcp || []).find(x => name.startsWith((x.registryName || x.id).replace(/-/g, '_') + '_'));
    if (!m) {
      // Unprefixed tool names (kagent in Berlin): the agent's own server that lists the tool.
      const a = agents.find(x => x.name === chatName) || {};
      const own = (a.mcp || []).find(x => (x.tools || []).includes(baseTool(name))) || ((a.mcp || []).length === 1 && a.mcp[0]);
      if (own) m = (catalog.mcp || []).find(x => x.id === own.id) || { name: own.id };
    }
    return m ? m.name : 'an MCP server';
  }

  async function send(text) {
    text = (text || '').trim();
    if (!text || busy || !chatName) return;
    busy = true;
    $('chat-send').disabled = true;
    $('chat-answers').innerHTML = '';
    const letter = /^[A-D]$/i.test(text) ? text.toUpperCase() : null;
    bubble('user', letter && lastLetters[letter]
      ? `<span class="ag-pick-letter">${letter}</span>${esc(lastLetters[letter])}` : md(text));
    $('chat-text').value = '';
    const agentEl = bubble('agent', '<span class="ag-typing"><i></i><i></i><i></i></span>');
    const textEl = agentEl.querySelector('.ag-msg-text');
    let shown = '', started = false;
    try {
      const res = await fetch(`${window.AGENTS_API || "/api/agents"}/${encodeURIComponent(chatName)}/chat/stream`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ text, contextId }),
      });
      const reader = res.body.getReader();
      const dec = new TextDecoder();
      let buf = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buf += dec.decode(value, { stream: true });
        let cut;
        while ((cut = buf.indexOf('\n\n')) >= 0) {
          const line = buf.slice(0, cut).trim();
          buf = buf.slice(cut + 2);
          if (!line.startsWith('data:')) continue;
          const ev = JSON.parse(line.slice(5));
          if (ev.t === 'delta') {
            if (!started) { shown = ''; started = true; }
            shown += ev.text;
            textEl.innerHTML = clean(shown) ? md(clean(shown)) + '<span class="ag-caret"></span>'
              : '<span class="ag-typing"><i></i><i></i><i></i></span>';
            scroll();
          } else if (ev.t === 'message') {
            shown = ev.text; started = false;
            if (clean(shown)) textEl.innerHTML = md(clean(shown));
          } else if (ev.t === 'tool_call') {
            toolChip(ev, agentEl);
            activity.push({ id: ev.id, name: ev.name, args: ev.args, result: undefined });
          } else if (ev.t === 'tool_result') {
            const chip = agentEl.querySelector(`.ag-toolchip[data-id="${CSS.escape(ev.id)}"]`);
            if (chip) chip.classList.add('done');
            const err = toolError(ev.result);
            if (err) {
              if (chip) chip.classList.add('failed');
              const note = document.createElement('p');
              note.className = 'ag-chat-err ag-toolerr';
              note.textContent = `${friendly(ev.name)} failed: ${String(err).slice(0, 400)}`;
              agentEl.querySelector('.ag-msg-body').insertBefore(note, textEl);
            }
            const act = activity.find(x => x.id === ev.id);
            if (act) act.result = ev.result;
            track(ev);
            paintSide();
          } else if (ev.t === 'agent') {
            route = ev;
            paintSide();
          } else if (ev.t === 'done') {
            contextId = ev.contextId || contextId;
          } else if (ev.t === 'error') {
            textEl.innerHTML = `<p class="ag-chat-err">${esc(ev.error)}</p>`;
          }
        }
      }
    } catch (e) {
      textEl.innerHTML = `<p class="ag-chat-err">The console lost the connection: ${esc(e.message || e)}</p>`;
    }
    if (shown && !clean(shown) && !textEl.querySelector('.ag-chat-err')) {
      const n = calledName(shown);
      textEl.innerHTML = `<p class="ag-muted">The agent wrote a call to ${n ? `<code>${esc(n)}</code>` : 'a tool'} as text instead of running it, so it did not run. `
        + 'Either that tool is not allowed for this agent yet, or the model garbled the call: send the request again.</p>';
    } else if (!shown && !textEl.querySelector('.ag-chat-err')) textEl.innerHTML = '<p class="ag-muted">No reply.</p>';
    shown = clean(shown);
    busy = false;
    $('chat-send').disabled = false;
    if (!questionCard(shown, agentEl, textEl)) answerButtons(shown);
    $('chat-text').focus();
  }

  // The question on screen, drawn from the quiz server's own start_quiz data rather than the
  // model's retelling of it. The host's commentary stays; the repeated question and options go.
  function questionCard(text, agentEl, textEl) {
    if (!quiz || !text) return false;
    const q = Object.values(quiz.questions).find(x => text.includes(x.question));
    if (!q) return false;
    const opts = Object.values(q.options);
    const keep = text.split('\n').filter(line => {
      const l = line.replace(/\*\*/g, '').trim();
      if (!l) return true;
      if (l.includes(q.question)) return false;
      if (/^[-*]?\s*\(?[A-D][).:]\s+/.test(l) && opts.some(o => l.includes(o))) return false;
      if (/^(what'?s|what is) your (answer|guess)\??$/i.test(l) || /^take your time/i.test(l)) return false;
      if (/your answer be\??$/i.test(l) || /question:?$/i.test(l) || /^please answer with/i.test(l)) return false;
      return true;
    }).join('\n').trim();
    textEl.innerHTML = keep ? md(keep) : '';
    if (!keep) textEl.style.display = 'none';
    const n = quiz.order.indexOf(q.id) + 1;
    lastLetters = { ...q.options };
    const card = document.createElement('div');
    card.className = 'ag-qcard';
    card.dataset.qid = q.id;
    card.innerHTML = `<div class="ag-qcard-top"><span>Question ${n} of ${quiz.order.length}</span><span>${esc(q.topic || quiz.topic || '')}</span></div>
      <h4>${esc(q.question)}</h4>
      <div class="ag-qopts">${Object.entries(q.options).map(([k, v]) =>
        `<button type="button" class="ag-qopt" data-say="${k}" data-letter="${k}"><b>${k}</b><span>${esc(v)}</span></button>`).join('')}</div>
      <div class="ag-qcard-foot"><button type="button" class="ag-link" data-say="Can I have a 50/50 on this one?">Use a 50/50</button></div>`;
    agentEl.querySelector('.ag-msg-body').appendChild(card);
    cards[q.id] = card;
    $('chat-answers').innerHTML = '';
    scroll();
    return true;
  }

  function markCard(qid, r) {
    const card = cards[qid];
    if (!card) return;
    const right = String(r.correct_answer || '').trim().charAt(0).toUpperCase();
    card.classList.add('answered');
    card.querySelectorAll('.ag-qopt').forEach(b => {
      b.disabled = true;
      b.removeAttribute('data-say');
      if (b.dataset.letter === right) b.classList.add('right');
      else if (b.dataset.letter === r.your_answer) b.classList.add('wrong');
    });
    card.querySelector('.ag-qcard-foot').innerHTML =
      `<span class="ag-qverdict ${r.correct ? 'ok' : 'no'}">${r.correct ? 'Correct' : 'Not quite'}</span><span class="ag-muted">${esc(r.explanation || '')}</span>`;
    if (r.correct) cheer(card);
    else card.classList.add('shake');
  }

  // A small burst from the card on every right answer, and a +1 on the scoreboard.
  function cheer(card) {
    card.classList.add('win');
    const box = card.getBoundingClientRect();
    const colours = ['#16a34a', '#22c55e', '#7c3aed', '#a855f7', '#f59e0b'];
    const layer = document.createElement('div');
    layer.className = 'ag-burst';
    for (let i = 0; i < 26; i++) {
      const b = document.createElement('i');
      const angle = (Math.PI * 2 * i) / 26;
      const dist = 70 + Math.random() * 90;
      b.style.left = (box.left + box.width / 2) + 'px';
      b.style.top = (box.top + 40) + 'px';
      b.style.background = colours[i % colours.length];
      b.style.setProperty('--dx', Math.cos(angle) * dist + 'px');
      b.style.setProperty('--dy', Math.sin(angle) * dist - 40 + 'px');
      layer.appendChild(b);
    }
    document.body.appendChild(layer);
    setTimeout(() => layer.remove(), 1100);
    setTimeout(() => {
      const big = document.querySelector('.ag-score-big');
      if (!big) return;
      const plus = document.createElement('span');
      plus.className = 'ag-plus';
      plus.textContent = '+1';
      big.appendChild(plus);
      setTimeout(() => plus.remove(), 1200);
    }, 60);
  }

  function markFifty(r) {
    const card = cards[r.question_id];
    if (!card || !r.remaining) return;
    card.querySelectorAll('.ag-qopt').forEach(b => {
      if (!(b.dataset.letter in r.remaining)) { b.disabled = true; b.classList.add('gone'); b.removeAttribute('data-say'); }
    });
    const foot = card.querySelector('.ag-qcard-foot');
    if (foot) foot.innerHTML = '<span class="ag-muted">50/50 used: two wrong answers removed by the quiz server.</span>';
  }

  // Quiz state comes only from what the quiz MCP server returned.
  function track(ev) {
    const tool = baseTool(ev.name);
    const r = ev.result;
    if (!r || typeof r !== 'object') return;
    if (tool === 'start_quiz' && r.quiz_id) {
      quiz = { id: r.quiz_id, topic: r.topic, questions: {}, order: [], answers: [], verdict: null, fifty: 0 };
      (r.questions || []).forEach(q => { quiz.questions[q.id] = q; quiz.order.push(q.id); });
    } else if (tool === 'check_answer' && quiz && r.question_id) {
      if (!quiz.answers.some(x => x.qid === r.question_id)) {
        quiz.answers.push({ qid: r.question_id, correct: !!r.correct, yours: r.your_answer,
                            right: r.correct_answer, why: r.explanation });
      }
      markCard(r.question_id, r);
    } else if (tool === 'fifty_fifty' && quiz) {
      quiz.fifty += 1;
      markFifty(r);
    } else if (tool === 'quiz_score' && quiz && !r.error) {
      quiz.verdict = r.verdict;
      quiz.final = r;
      if ((r.correct || 0) >= 6 && typeof confetti === 'function') confetti();
    }
  }

  function answerButtons(text) {
    const box = $('chat-answers');
    const a = agents.find(x => x.name === chatName) || {};
    const opts = isQuizAgent(a) ? options(text) : null;
    if (!opts) { box.innerHTML = ''; return; }
    box.innerHTML = Object.entries(opts).map(([k, v]) =>
      `<button type="button" class="ag-answer" data-say="${k}"><b>${k}</b><span>${esc(v)}</span></button>`).join('')
      + `<button type="button" class="ag-answer ghost" data-say="Can I have a 50/50 on this one?"><b>½</b><span>50/50</span></button>`;
  }

  function paintSide() {
    const side = $('chat-side');
    const a = agents.find(x => x.name === chatName) || {};
    if (isQuizAgent(a)) {
      side.innerHTML = scoreboard();
      return;
    }
    // The route a turn takes, from the backend's `agent` event (Berlin sends one; kind does not).
    const hop = (label, sub) => `<li><strong>${esc(label)}</strong>${sub ? `<span>${esc(sub)}</span>` : ''}</li>`;
    const routeCard = route ? `<div class="ag-kicker">Route</div><ol class="ag-route">
        ${hop(route.user || 'signed out', 'Keycloak')}
        ${hop(route.agent_id || chatName, route.identity_detail || (route.own_identity === false ? "no identity of its own: the user's token" : 'its own identity'))}
        ${hop('kagent', route.deployment)}
        ${hop('agentgateway', '')}
        ${hop(window.CHAT_ROUTE_MODEL || window.AGENT_MODEL || 'the model', '')}</ol>` : '';
    const via = x => route ? `agentgateway → ${serverOf(x.name)}` : serverOf(x.name);
    side.innerHTML = routeCard + `<div class="ag-kicker">What it did</div>` + (activity.length
      ? `<ol class="ag-activity">${activity.map(x => `<li class="${x.result === undefined ? 'wait' : (toolError(x.result) ? 'failed' : 'done')}">
          <strong>${esc(friendly(x.name))}</strong><span>via ${esc(via(x))}</span></li>`).join('')}</ol>`
      : `<p class="ag-muted">Tool calls show here as the agent makes them, through agentgateway with its own identity.</p>`);
  }

  function scoreboard() {
    if (!quiz) {
      return `<div class="ag-kicker">Scoreboard</div>
        <div class="ag-score-empty"><p>Start a round and the score keeps itself here, straight from the quiz server.</p>
        <button type="button" class="btn primary" data-say="Start a mixed round">Start a round</button></div>`;
    }
    const right = quiz.answers.filter(x => x.correct).length;
    const wrong = quiz.answers.length - right;
    const total = quiz.order.length || 10;
    const dots = quiz.order.map((qid, i) => {
      const ans = quiz.answers.find(x => x.qid === qid);
      const cls = ans ? (ans.correct ? 'ok' : 'no') : (i === quiz.answers.length ? 'now' : '');
      return `<i class="${cls}" title="Question ${i + 1}">${ans ? (ans.correct ? '✓' : '✗') : i + 1}</i>`;
    }).join('');
    const last = quiz.answers[quiz.answers.length - 1];
    return `<div class="ag-kicker">Scoreboard · ${esc(quiz.topic || 'Mixed')}</div>
      <div class="ag-score-big"><b>${right}</b><span>out of ${quiz.answers.length} answered</span></div>
      <div class="ag-score-split"><div class="ok"><b>${right}</b><span>Right</span></div>
        <div class="no"><b>${wrong}</b><span>Wrong</span></div>
        <div><b>${total - quiz.answers.length}</b><span>To go</span></div></div>
      <div class="ag-score-dots">${dots}</div>
      ${quiz.fifty ? `<p class="ag-muted">50/50 used ${quiz.fifty} time${quiz.fifty === 1 ? '' : 's'}.</p>` : ''}
      ${last ? `<div class="ag-score-last ${last.correct ? 'ok' : 'no'}"><small>Last answer</small>
        <strong>${last.correct ? 'Right' : 'Wrong'}: ${esc(last.right || '')}</strong><p>${esc(last.why || '')}</p></div>` : ''}
      ${quiz.verdict ? `<div class="ag-score-verdict"><small>Final score</small><b>${quiz.final ? quiz.final.correct + ' / ' + quiz.final.out_of : ''}</b>${esc(quiz.verdict)}</div>` : ''}
      <button type="button" class="btn" data-say="Start a new round">New round</button>
      <p class="ag-foot-note">Read from the quiz server's check_answer results, not from the chat text.</p>`;
  }

  document.addEventListener('click', e => {
    const say = e.target.closest('[data-say]');
    if (say && $('chat-view').style.display !== 'none') { send(say.dataset.say); return; }
    const c = e.target.closest('[data-chat]');
    if (c) { e.stopPropagation(); openChat(c.dataset.chat); }
  }, true);
  $('chat-form').addEventListener('submit', e => { e.preventDefault(); send($('chat-text').value); });
  $('chat-back').onclick = closeChat;
  $('chat-new').onclick = () => openChat(chatName, true);
  $('detail-chat').onclick = () => { if (selected) openChat(selected); };

  // Deep link: /agents#chat/quiz-host2 or /agents?chat=quiz-host2 opens straight into the
  // chat once the list has loaded.
  const want = (location.hash.match(/^#chat\/(.+)$/) || [])[1] || new URLSearchParams(location.search).get('chat');
  if (want) {
    const wait = setInterval(() => {
      if (typeof loaded !== 'undefined' && loaded && catalog.platform) { clearInterval(wait); openChat(decodeURIComponent(want)); }
    }, 150);
  }
  window.openChat = openChat;
})();
