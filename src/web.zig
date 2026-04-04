pub const index_html =
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="UTF-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
    \\<title>Kite - Remote Control</title>
    \\<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/css/xterm.min.css">
    \\<script src="https://cdn.jsdelivr.net/npm/@xterm/xterm@5.5.0/lib/xterm.min.js"></script>
    \\<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-fit@0.10.0/lib/addon-fit.min.js"></script>
    \\<script src="https://cdn.jsdelivr.net/npm/@xterm/addon-web-fonts@0.1.0/lib/addon-web-fonts.min.js"></script>
    \\<style>
    \\@font-face {
    \\  font-family: "Hack Nerd Font Mono";
    \\  src: url("https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/fonts/HackNerdFontMono-Regular.woff2") format("woff2");
    \\  font-weight: 400; font-style: normal;
    \\}
    \\@font-face {
    \\  font-family: "Hack Nerd Font Mono";
    \\  src: url("https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/fonts/HackNerdFontMono-Bold.woff2") format("woff2");
    \\  font-weight: 700; font-style: normal;
    \\}
    \\@font-face {
    \\  font-family: "Hack Nerd Font Mono";
    \\  src: url("https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/fonts/HackNerdFontMono-Italic.woff2") format("woff2");
    \\  font-weight: 400; font-style: italic;
    \\}
    \\@font-face {
    \\  font-family: "Hack Nerd Font Mono";
    \\  src: url("https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/fonts/HackNerdFontMono-BoldItalic.woff2") format("woff2");
    \\  font-weight: 700; font-style: italic;
    \\}
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\:root { --bg: #0a0a0a; --fg: #e0e0e0; --accent: #4fc3f7; --card-bg: #1a1a1a; --border: #333; --danger: #ef5350; --success: #66bb6a; --warn: #ffa726; }
    \\body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif; background: var(--bg); color: var(--fg); height: 100dvh; display: flex; flex-direction: column; overflow: hidden; }
    \\
    \\#auth-screen { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100dvh; padding: 2rem; }
    \\#auth-screen h1 { font-size: 1.5rem; margin-bottom: 1rem; color: var(--accent); }
    \\#auth-screen input { width: 100%; max-width: 400px; padding: 0.75rem; border: 1px solid var(--border); border-radius: 8px; background: var(--card-bg); color: var(--fg); font-size: 1rem; margin-bottom: 1rem; }
    \\#auth-screen button { padding: 0.75rem 2rem; border: none; border-radius: 8px; background: var(--accent); color: #000; font-size: 1rem; font-weight: 600; cursor: pointer; }
    \\#auth-error { color: var(--danger); margin-top: 0.5rem; display: none; }
    \\
    \\#app { display: none; flex-direction: column; height: 100dvh; }
    \\
    \\header { display: flex; align-items: center; justify-content: space-between; padding: 0.5rem 1rem; background: var(--card-bg); border-bottom: 1px solid var(--border); flex-shrink: 0; }
    \\header h1 { font-size: 1rem; color: var(--accent); }
    \\.status { font-size: 0.75rem; padding: 0.25rem 0.5rem; border-radius: 4px; }
    \\.status.running { background: var(--success); color: #000; }
    \\.status.stopped { background: var(--danger); color: #fff; }
    \\
    \\.tabs { display: flex; border-bottom: 1px solid var(--border); flex-shrink: 0; }
    \\.tab { flex: 1; padding: 0.5rem; text-align: center; cursor: pointer; border: none; background: transparent; color: var(--fg); font-size: 0.875rem; border-bottom: 2px solid transparent; }
    \\.tab.active { color: var(--accent); border-bottom-color: var(--accent); }
    \\
    \\#terminal-panel { flex: 1; display: flex; flex-direction: column; min-height: 0; }
    \\#terminal-container { flex: 1; min-height: 0; padding: 4px; }
    \\#terminal-container .xterm { height: 100%; }
    \\
    \\#events-panel { flex: 1; overflow-y: auto; padding: 0.5rem; display: none; -webkit-overflow-scrolling: touch; }
    \\.event-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; padding: 0.75rem; margin-bottom: 0.5rem; }
    \\.event-card .event-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.5rem; }
    \\.event-card .event-type { font-size: 0.75rem; font-weight: 600; padding: 0.15rem 0.5rem; border-radius: 4px; }
    \\.event-type.PreToolUse { background: var(--warn); color: #000; }
    \\.event-type.PostToolUse { background: var(--success); color: #000; }
    \\.event-type.Notification { background: var(--accent); color: #000; }
    \\.event-type.SessionStart { background: #9c27b0; color: #fff; }
    \\.event-type.Stop { background: var(--danger); color: #fff; }
    \\.event-card .event-time { font-size: 0.7rem; color: #888; }
    \\.event-card .event-detail { font-size: 0.8rem; color: #aaa; word-break: break-all; max-height: 6em; overflow: hidden; }
    \\.event-card .event-tool { font-weight: 600; color: var(--fg); }
    \\
    \\.approval-bar { display: flex; gap: 0.5rem; margin-top: 0.5rem; }
    \\.approval-bar button { flex: 1; padding: 0.5rem; border: none; border-radius: 6px; font-weight: 600; cursor: pointer; }
    \\.btn-approve { background: var(--success); color: #000; }
    \\.btn-reject { background: var(--danger); color: #fff; }
    \\</style>
    \\</head>
    \\<body>
    \\
    \\<div id="auth-screen">
    \\  <h1>Kite</h1>
    \\  <p style="margin-bottom:1rem;color:#888">Enter setup token to connect</p>
    \\  <input id="token-input" type="text" placeholder="Setup token..." autocomplete="off">
    \\  <button onclick="doAuth()">Connect</button>
    \\  <p id="auth-error">Invalid or expired token</p>
    \\</div>
    \\
    \\<div id="app">
    \\  <header>
    \\    <h1>Kite</h1>
    \\    <span id="status" class="status running">running</span>
    \\  </header>
    \\
    \\  <div class="tabs">
    \\    <button class="tab active" onclick="switchTab('terminal')">Terminal</button>
    \\    <button class="tab" onclick="switchTab('events')">Events <span id="event-count"></span></button>
    \\  </div>
    \\
    \\  <div id="terminal-panel">
    \\    <div id="terminal-container"></div>
    \\  </div>
    \\
    \\  <div id="events-panel"></div>
    \\</div>
    \\
    \\<script>
    \\let ws = null;
    \\let sessionToken = null;
    \\let eventCount = 0;
    \\let term = null;
    \\let fitAddon = null;
    \\
    \\const params = new URLSearchParams(location.search);
    \\const urlToken = params.get('token');
    \\if (urlToken) document.getElementById('token-input').value = urlToken;
    \\
    \\const saved = localStorage.getItem('kite_session');
    \\if (saved) { sessionToken = saved; initApp(); }
    \\
    \\function doAuth() {
    \\  const token = document.getElementById('token-input').value.trim();
    \\  if (!token) return;
    \\  fetch('/api/auth', {
    \\    method: 'POST',
    \\    headers: {'Content-Type':'application/json'},
    \\    body: JSON.stringify({setup_token: token})
    \\  }).then(r => r.json()).then(d => {
    \\    if (d.success) {
    \\      sessionToken = d.token;
    \\      localStorage.setItem('kite_session', d.token);
    \\      initApp();
    \\    } else {
    \\      document.getElementById('auth-error').style.display = 'block';
    \\    }
    \\  }).catch(() => {
    \\    document.getElementById('auth-error').style.display = 'block';
    \\  });
    \\}
    \\
    \\function initApp() {
    \\  document.getElementById('auth-screen').style.display = 'none';
    \\  document.getElementById('app').style.display = 'flex';
    \\  initTerminal();
    \\  connectWs();
    \\}
    \\
    \\function initTerminal() {
    \\  term = new window.Terminal({
    \\    cursorBlink: true,
    \\    fontSize: 14,
    \\    fontFamily: "'Hack Nerd Font Mono', 'SF Mono', 'Menlo', 'Monaco', 'Courier New', monospace",
    \\    theme: {
    \\      background: '#0a0a0a',
    \\      foreground: '#e0e0e0',
    \\      cursor: '#4fc3f7',
    \\      selectionBackground: 'rgba(79, 195, 247, 0.3)'
    \\    },
    \\    allowProposedApi: true,
    \\    scrollback: 10000,
    \\    convertEol: false
    \\  });
    \\  fitAddon = new window.FitAddon.FitAddon();
    \\  term.loadAddon(fitAddon);
    \\  var webFontsAddon = new window.WebFontsAddon.WebFontsAddon();
    \\  term.loadAddon(webFontsAddon);
    \\  term.open(document.getElementById('terminal-container'));
    \\  fitAddon.fit();
    \\
    \\  term.onData(function(data) {
    \\    if (ws && ws.readyState === WebSocket.OPEN) {
    \\      ws.send(JSON.stringify({type: 'terminal_input', data: data}));
    \\    }
    \\  });
    \\
    \\  term.onResize(function(size) {
    \\    if (ws && ws.readyState === WebSocket.OPEN) {
    \\      ws.send(JSON.stringify({type: 'resize', cols: size.cols, rows: size.rows}));
    \\    }
    \\  });
    \\
    \\  window.addEventListener('resize', function() { fitAddon.fit(); });
    \\  new ResizeObserver(function() { fitAddon.fit(); }).observe(document.getElementById('terminal-container'));
    \\
    \\  setTimeout(function() {
    \\    fitAddon.fit();
    \\    if (ws && ws.readyState === WebSocket.OPEN) {
    \\      ws.send(JSON.stringify({type: 'resize', cols: term.cols, rows: term.rows}));
    \\    }
    \\  }, 200);
    \\}
    \\
    \\function connectWs() {
    \\  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    \\  ws = new WebSocket(proto + '//' + location.host + '/ws');
    \\  ws.binaryType = 'arraybuffer';
    \\  ws.onopen = function() {
    \\    ws.send(JSON.stringify({type: 'auth_token', token: sessionToken}));
    \\  };
    \\  ws.onmessage = function(e) {
    \\    try { handleMessage(JSON.parse(e.data)); } catch(err) { console.error('ws msg error:', err); }
    \\  };
    \\  ws.onclose = function() {
    \\    setTimeout(connectWs, 2000);
    \\  };
    \\}
    \\
    \\function handleMessage(msg) {
    \\  switch (msg.type) {
    \\    case 'terminal_output':
    \\      if (term && msg.data) {
    \\        var bin = atob(msg.data);
    \\        var bytes = new Uint8Array(bin.length);
    \\        for (var j = 0; j < bin.length; j++) bytes[j] = bin.charCodeAt(j);
    \\        term.write(bytes);
    \\      }
    \\      break;
    \\    case 'hook_event': addEvent(msg); break;
    \\    case 'session_status': updateStatus(msg.state); break;
    \\    case 'approval_request': addApproval(msg); break;
    \\    case 'auth_result':
    \\      if (!msg.success) { localStorage.removeItem('kite_session'); location.reload(); }
    \\      break;
    \\  }
    \\}
    \\
    \\function switchTab(tab) {
    \\  document.querySelectorAll('.tab').forEach(function(t, i) {
    \\    t.classList.toggle('active', (tab === 'terminal' ? i === 0 : i === 1));
    \\  });
    \\  document.getElementById('terminal-panel').style.display = tab === 'terminal' ? 'flex' : 'none';
    \\  document.getElementById('events-panel').style.display = tab === 'events' ? 'block' : 'none';
    \\  if (tab === 'terminal' && fitAddon) {
    \\    setTimeout(function() { fitAddon.fit(); }, 50);
    \\  }
    \\}
    \\
    \\function addEvent(msg) {
    \\  eventCount++;
    \\  document.getElementById('event-count').textContent = '(' + eventCount + ')';
    \\  var panel = document.getElementById('events-panel');
    \\  var card = document.createElement('div');
    \\  card.className = 'event-card';
    \\  var time = new Date(msg.ts * 1000).toLocaleTimeString();
    \\  card.innerHTML = '<div class="event-header"><span class="event-type ' + msg.event + '">' + msg.event + '</span><span class="event-time">' + time + '</span></div>' +
    \\    (msg.tool ? '<div class="event-tool">' + msg.tool + '</div>' : '') +
    \\    (msg.detail ? '<div class="event-detail">' + msg.detail.substring(0, 500) + '</div>' : '');
    \\  panel.prepend(card);
    \\}
    \\
    \\function addApproval(msg) {
    \\  eventCount++;
    \\  document.getElementById('event-count').textContent = '(' + eventCount + ')';
    \\  switchTab('events');
    \\  var panel = document.getElementById('events-panel');
    \\  var card = document.createElement('div');
    \\  card.className = 'event-card';
    \\  card.innerHTML = '<div class="event-header"><span class="event-type PreToolUse">Approval Required</span></div>' +
    \\    '<div class="event-tool">' + msg.tool + '</div>' +
    \\    '<div class="event-detail">' + (msg.input || '').substring(0, 300) + '</div>' +
    \\    '<div class="approval-bar"><button class="btn-approve" onclick="respond(\'' + msg.request_id + '\',true,this)">Approve</button>' +
    \\    '<button class="btn-reject" onclick="respond(\'' + msg.request_id + '\',false,this)">Reject</button></div>';
    \\  panel.prepend(card);
    \\}
    \\
    \\function respond(id, approved, btn) {
    \\  ws.send(JSON.stringify({type: 'approval_response', request_id: id, approved: approved}));
    \\  btn.parentElement.innerHTML = approved ?
    \\    '<span style="color:var(--success)">Approved</span>' :
    \\    '<span style="color:var(--danger)">Rejected</span>';
    \\}
    \\
    \\function updateStatus(state) {
    \\  var el = document.getElementById('status');
    \\  el.textContent = state;
    \\  el.className = 'status ' + state;
    \\}
    \\</script>
    \\</body>
    \\</html>
;
