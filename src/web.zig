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
    \\@font-face { font-family:"Hack Nerd Font Mono"; src:url("https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/fonts/HackNerdFontMono-Regular.woff2") format("woff2"); font-weight:400; font-style:normal; }
    \\@font-face { font-family:"Hack Nerd Font Mono"; src:url("https://cdn.jsdelivr.net/gh/mshaugh/nerdfont-webfonts@v3.3.0/build/fonts/HackNerdFontMono-Bold.woff2") format("woff2"); font-weight:700; font-style:normal; }
    \\*{margin:0;padding:0;box-sizing:border-box}
    \\:root{--bg:#0a0a0a;--fg:#e0e0e0;--accent:#4fc3f7;--card-bg:#1a1a1a;--border:#333;--danger:#ef5350;--success:#66bb6a;--warn:#ffa726}
    \\body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--fg);height:100dvh;display:flex;flex-direction:column;overflow:hidden}
    \\#auth-screen{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100dvh;padding:2rem}
    \\#auth-screen h1{font-size:1.5rem;margin-bottom:1rem;color:var(--accent)}
    \\#auth-screen input{width:100%;max-width:400px;padding:.75rem;border:1px solid var(--border);border-radius:8px;background:var(--card-bg);color:var(--fg);font-size:1rem;margin-bottom:1rem}
    \\#auth-screen button{padding:.75rem 2rem;border:none;border-radius:8px;background:var(--accent);color:#000;font-size:1rem;font-weight:600;cursor:pointer}
    \\#auth-error{color:var(--danger);margin-top:.5rem;display:none}
    \\#app{display:none;flex-direction:column;height:100dvh}
    \\header{display:flex;align-items:center;justify-content:space-between;padding:.5rem 1rem;background:var(--card-bg);border-bottom:1px solid var(--border);flex-shrink:0}
    \\header h1{font-size:1rem;color:var(--accent)}
    \\.hdr-back{background:none;border:none;color:var(--accent);font-size:1.2rem;cursor:pointer;padding:0 .5rem 0 0;display:none}
    \\.status{font-size:.75rem;padding:.25rem .5rem;border-radius:4px}
    \\.status.running{background:var(--success);color:#000}
    \\.status.waiting_input{background:var(--warn);color:#000;animation:pulse 1.5s infinite}
    \\.status.stopped{background:var(--danger);color:#fff}
    \\.status.starting{background:var(--accent);color:#000}
    \\@keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}
    \\/* Session List */
    \\#list-page{flex:1;display:flex;flex-direction:column;overflow:hidden}
    \\#session-list{flex:1;overflow-y:auto;padding:.75rem;display:flex;flex-direction:column;gap:.5rem;-webkit-overflow-scrolling:touch}
    \\.s-card{background:var(--card-bg);border:1px solid var(--border);border-radius:12px;padding:.85rem 1rem;cursor:pointer;transition:border-color .15s}
    \\.s-card:active{border-color:var(--accent)}
    \\.s-card .s-row{display:flex;justify-content:space-between;align-items:center}
    \\.s-card .s-title{font-weight:600;font-size:.85rem}
    \\.s-card .s-meta{color:#888;font-size:.75rem;margin-top:.3rem}
    \\.s-card .s-del{background:none;border:none;color:#666;font-size:.8rem;padding:.2rem .4rem;cursor:pointer}
    \\.s-card .s-del:hover{color:var(--danger)}
    \\#add-btn{position:fixed;bottom:1.5rem;right:1.5rem;width:52px;height:52px;border-radius:50%;border:none;background:var(--accent);color:#000;font-size:1.5rem;font-weight:700;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.4);z-index:10}
    \\/* Detail Page */
    \\#detail-page{flex:1;display:none;flex-direction:column;overflow:hidden}
    \\.view-toggle{display:flex;gap:0;flex-shrink:0;border-bottom:1px solid var(--border)}
    \\.view-btn{flex:1;padding:.5rem;text-align:center;cursor:pointer;border:none;background:transparent;color:var(--fg);font-size:.85rem;border-bottom:2px solid transparent}
    \\.view-btn.active{color:var(--accent);border-bottom-color:var(--accent)}
    \\.view-btn .badge{background:var(--warn);color:#000;border-radius:10px;padding:0 6px;font-size:.7rem;margin-left:4px}
    \\#status-view{flex:1;padding:1rem;overflow-y:auto;display:flex;flex-direction:column;gap:1rem}
    \\.detail-card{background:var(--card-bg);border:1px solid var(--border);border-radius:12px;padding:1rem}
    \\.detail-card .card-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:.75rem}
    \\.detail-card .card-title{font-weight:600;font-size:.9rem}
    \\.detail-card .card-activity{color:#888;font-size:.8rem;margin-bottom:.5rem}
    \\#prompt-section{display:none}
    \\.prompt-summary{background:#111;border:1px solid var(--border);border-radius:8px;padding:.75rem;margin-bottom:.75rem;font-size:.85rem;color:#ccc;max-height:200px;overflow-y:auto;white-space:pre-wrap;font-family:'Hack Nerd Font Mono',monospace}
    \\.prompt-options{display:flex;flex-wrap:wrap;gap:.5rem;margin-bottom:.75rem}
    \\.prompt-options button{padding:.5rem 1rem;border:1px solid var(--accent);border-radius:8px;background:transparent;color:var(--accent);font-size:.85rem;cursor:pointer;transition:all .2s}
    \\.prompt-options button:hover{background:var(--accent);color:#000}
    \\.prompt-input-row{display:flex;gap:.5rem}
    \\.prompt-input-row input{flex:1;padding:.6rem .75rem;border:1px solid var(--border);border-radius:8px;background:var(--card-bg);color:var(--fg);font-size:.9rem}
    \\.prompt-input-row button{padding:.6rem 1.2rem;border:none;border-radius:8px;background:var(--accent);color:#000;font-weight:600;cursor:pointer}
    \\.expand-btn{display:block;width:100%;padding:.5rem;margin-top:.5rem;border:1px solid var(--border);border-radius:8px;background:transparent;color:#888;font-size:.8rem;cursor:pointer;text-align:center}
    \\#terminal-view{flex:1;display:none;flex-direction:column;min-height:0}
    \\#terminal-container{flex:1;min-height:0;padding:4px}
    \\#terminal-container .xterm{height:100%}
    \\#events-view{flex:1;overflow-y:auto;padding:.5rem;display:none;-webkit-overflow-scrolling:touch}
    \\.event-card{background:var(--card-bg);border:1px solid var(--border);border-radius:8px;padding:.75rem;margin-bottom:.5rem}
    \\.event-card .event-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:.25rem}
    \\.event-card .event-type{font-size:.7rem;font-weight:600;padding:.15rem .5rem;border-radius:4px}
    \\.event-type.PreToolUse{background:var(--warn);color:#000}
    \\.event-type.PostToolUse{background:var(--success);color:#000}
    \\.event-type.Notification{background:var(--accent);color:#000}
    \\.event-type.SessionStart{background:#9c27b0;color:#fff}
    \\.event-type.Stop{background:var(--danger);color:#fff}
    \\.event-type.UserPromptSubmit{background:var(--accent);color:#000}
    \\.event-card .event-time{font-size:.65rem;color:#888}
    \\.event-card .event-detail{font-size:.75rem;color:#aaa;word-break:break-all;max-height:4em;overflow:hidden}
    \\.event-card .event-tool{font-weight:600;color:var(--fg);font-size:.8rem}
    \\/* Create dialog */
    \\#create-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:20;align-items:center;justify-content:center}
    \\#create-dialog{background:var(--card-bg);border:1px solid var(--border);border-radius:12px;padding:1.5rem;width:90%;max-width:360px}
    \\#create-dialog h2{font-size:1rem;margin-bottom:1rem;color:var(--accent)}
    \\#create-dialog input{width:100%;padding:.6rem;border:1px solid var(--border);border-radius:8px;background:var(--bg);color:var(--fg);font-size:.9rem;margin-bottom:.75rem}
    \\#create-dialog .dlg-btns{display:flex;gap:.5rem}
    \\#create-dialog .dlg-btns button{flex:1;padding:.6rem;border:none;border-radius:8px;font-size:.9rem;font-weight:600;cursor:pointer}
    \\.btn-cancel{background:var(--border);color:var(--fg)}
    \\.btn-create{background:var(--accent);color:#000}
    \\</style>
    \\</head>
    \\<body>
    \\<div id="auth-screen">
    \\  <h1>Kite</h1>
    \\  <p style="margin-bottom:1rem;color:#888">Enter setup token to connect</p>
    \\  <input id="token-input" type="text" placeholder="Setup token..." autocomplete="off">
    \\  <button onclick="doAuth()">Connect</button>
    \\  <p id="auth-error">Invalid or expired token</p>
    \\</div>
    \\<div id="app">
    \\  <header>
    \\    <div style="display:flex;align-items:center">
    \\      <button class="hdr-back" id="back-btn" onclick="showList()">&larr;</button>
    \\      <h1 id="hdr-title">Kite</h1>
    \\    </div>
    \\    <span id="hdr-status" class="status" style="display:none"></span>
    \\  </header>
    \\  <!-- Session List Page -->
    \\  <div id="list-page">
    \\    <div id="session-list"></div>
    \\    <button id="add-btn" onclick="showCreateDialog()">+</button>
    \\  </div>
    \\  <!-- Session Detail Page -->
    \\  <div id="detail-page">
    \\    <div class="view-toggle">
    \\      <button class="view-btn active" onclick="switchTab('status')" id="tab-status">Status</button>
    \\      <button class="view-btn" onclick="switchTab('terminal')" id="tab-terminal">Terminal</button>
    \\      <button class="view-btn" onclick="switchTab('events')" id="tab-events">Events <span id="event-badge" class="badge" style="display:none">0</span></button>
    \\    </div>
    \\    <div id="status-view">
    \\      <div class="detail-card">
    \\        <div class="card-header">
    \\          <span class="card-title" id="detail-title">Session</span>
    \\          <span id="detail-status" class="status starting">starting</span>
    \\        </div>
    \\        <div class="card-activity" id="detail-activity">Running...</div>
    \\      </div>
    \\      <div id="prompt-section">
    \\        <div class="prompt-summary" id="prompt-summary"></div>
    \\        <div class="prompt-options" id="prompt-options"></div>
    \\        <div class="prompt-input-row">
    \\          <input id="prompt-input" type="text" placeholder="Type your response..." autocomplete="off">
    \\          <button onclick="sendPromptResponse()">Send</button>
    \\        </div>
    \\        <button class="expand-btn" onclick="switchTab('terminal')">Show full terminal</button>
    \\      </div>
    \\    </div>
    \\    <div id="terminal-view"><div id="terminal-container"></div></div>
    \\    <div id="events-view"></div>
    \\  </div>
    \\</div>
    \\<!-- Create Session Dialog -->
    \\<div id="create-overlay" onclick="if(event.target===this)hideCreateDialog()">
    \\  <div id="create-dialog">
    \\    <h2>New Session</h2>
    \\    <input id="create-cmd" type="text" value="claude" placeholder="Command..." autocomplete="off">
    \\    <div class="dlg-btns">
    \\      <button class="btn-cancel" onclick="hideCreateDialog()">Cancel</button>
    \\      <button class="btn-create" onclick="createSession()">Create</button>
    \\    </div>
    \\  </div>
    \\</div>
    \\<script>
    \\var ws=null,sessionToken=null,term=null,fitAddon=null;
    \\var sessions={};  // id -> {id,state,command,cwd,activity,events:[]}
    \\var activeId=null; // currently viewed session
    \\var currentTab='status';
    \\var params=new URLSearchParams(location.search);
    \\var urlToken=params.get('token');
    \\if(urlToken)document.getElementById('token-input').value=urlToken;
    \\var saved=localStorage.getItem('kite_session');
    \\if(saved){sessionToken=saved;initApp();}
    \\
    \\function doAuth(){
    \\  var token=document.getElementById('token-input').value.trim();
    \\  if(!token)return;
    \\  fetch('/api/auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({setup_token:token})})
    \\  .then(function(r){return r.json()}).then(function(d){
    \\    if(d.success){sessionToken=d.token;localStorage.setItem('kite_session',d.token);initApp();}
    \\    else document.getElementById('auth-error').style.display='block';
    \\  }).catch(function(){document.getElementById('auth-error').style.display='block';});
    \\}
    \\function initApp(){
    \\  document.getElementById('auth-screen').style.display='none';
    \\  document.getElementById('app').style.display='flex';
    \\  initTerminal();connectWs();fetchSessions();
    \\}
    \\function initTerminal(){
    \\  term=new window.Terminal({cursorBlink:true,fontSize:14,
    \\    fontFamily:"'Hack Nerd Font Mono','SF Mono','Menlo',monospace",
    \\    theme:{background:'#0a0a0a',foreground:'#e0e0e0',cursor:'#4fc3f7',selectionBackground:'rgba(79,195,247,0.3)'},
    \\    allowProposedApi:true,scrollback:10000,convertEol:false});
    \\  fitAddon=new window.FitAddon.FitAddon();
    \\  term.loadAddon(fitAddon);
    \\  term.loadAddon(new window.WebFontsAddon.WebFontsAddon());
    \\  term.open(document.getElementById('terminal-container'));
    \\  term.onData(function(d){if(ws&&ws.readyState===1&&activeId)ws.send(JSON.stringify({type:'terminal_input',data:d,session_id:activeId}));});
    \\  term.onResize(function(s){if(ws&&ws.readyState===1&&activeId)ws.send(JSON.stringify({type:'resize',cols:s.cols,rows:s.rows,session_id:activeId}));});
    \\  window.addEventListener('resize',function(){if(currentTab==='terminal')fitAddon.fit();});
    \\  new ResizeObserver(function(){if(currentTab==='terminal')fitAddon.fit();}).observe(document.getElementById('terminal-container'));
    \\}
    \\function connectWs(){
    \\  var proto=location.protocol==='https:'?'wss:':'ws:';
    \\  ws=new WebSocket(proto+'//'+location.host+'/ws');ws.binaryType='arraybuffer';
    \\  ws.onopen=function(){ws.send(JSON.stringify({type:'auth_token',token:sessionToken}));};
    \\  ws.onmessage=function(e){try{handleMsg(JSON.parse(e.data))}catch(err){console.error(err)}};
    \\  ws.onclose=function(){setTimeout(connectWs,2000)};
    \\}
    \\function fetchSessions(){
    \\  fetch('/api/sessions').then(function(r){return r.json()}).then(function(list){
    \\    list.forEach(function(s){
    \\      if(!sessions[s.id])sessions[s.id]={id:s.id,state:s.state,command:s.command,cwd:s.cwd,activity:'',events:[]};
    \\      else{sessions[s.id].state=s.state;sessions[s.id].command=s.command;sessions[s.id].cwd=s.cwd;}
    \\    });
    \\    renderList();
    \\  }).catch(function(){});
    \\}
    \\function handleMsg(msg){
    \\  switch(msg.type){
    \\    case 'terminal_output':
    \\      if(term&&msg.data&&msg.session_id===activeId){
    \\        var bin=atob(msg.data);var bytes=new Uint8Array(bin.length);
    \\        for(var j=0;j<bin.length;j++)bytes[j]=bin.charCodeAt(j);term.write(bytes);
    \\      }
    \\      break;
    \\    case 'hook_event':
    \\      var sid=msg.session_id||activeId;
    \\      if(sid&&sessions[sid]){
    \\        if(msg.event==='PreToolUse'&&msg.tool)sessions[sid].activity='Using '+msg.tool+'...';
    \\        else if(msg.event==='PostToolUse'&&msg.tool)sessions[sid].activity='Finished '+msg.tool;
    \\        sessions[sid].events.unshift(msg);
    \\      }
    \\      if(sid===activeId){addEventCard(msg);updateDetailActivity();}
    \\      renderList();
    \\      break;
    \\    case 'session_state_change':
    \\      ensureSession(msg.session_id);
    \\      sessions[msg.session_id].state=msg.state;
    \\      renderList();
    \\      if(msg.session_id===activeId)updateDetailState();
    \\      break;
    \\    case 'prompt_request':
    \\      ensureSession(msg.session_id);
    \\      sessions[msg.session_id].state='waiting_input';
    \\      sessions[msg.session_id].prompt=msg;
    \\      renderList();
    \\      if(msg.session_id===activeId)showPrompt(msg);
    \\      break;
    \\    case 'auth_result':
    \\      if(!msg.success){localStorage.removeItem('kite_session');location.reload();}
    \\      break;
    \\  }
    \\}
    \\function ensureSession(id){if(!sessions[id])sessions[id]={id:id,state:'starting',command:'',cwd:'',activity:'',events:[]};}
    \\/* ---- Session List ---- */
    \\function renderList(){
    \\  var el=document.getElementById('session-list');
    \\  var ids=Object.keys(sessions).map(Number);
    \\  // Sort: waiting_input first, then running, then stopped
    \\  ids.sort(function(a,b){
    \\    var order={waiting_input:0,running:1,starting:2,stopped:3};
    \\    var oa=order[sessions[a].state]||9,ob=order[sessions[b].state]||9;
    \\    return oa!==ob?oa-ob:a-b;
    \\  });
    \\  el.innerHTML='';
    \\  if(ids.length===0){el.innerHTML='<div style="text-align:center;color:#666;padding:3rem">No sessions. Tap + to create one.</div>';return;}
    \\  ids.forEach(function(id){
    \\    var s=sessions[id];
    \\    var card=document.createElement('div');card.className='s-card';
    \\    card.onclick=function(){openSession(id)};
    \\    card.innerHTML='<div class="s-row"><span class="s-title">#'+s.id+' '+s.command+'</span>'
    \\      +'<span class="status '+s.state+'">'+s.state+'</span></div>'
    \\      +'<div class="s-meta">'+(s.activity||s.cwd||'')+'</div>';
    \\    el.appendChild(card);
    \\  });
    \\}
    \\/* ---- Session Detail ---- */
    \\function openSession(id){
    \\  activeId=id;
    \\  var s=sessions[id];
    \\  document.getElementById('list-page').style.display='none';
    \\  document.getElementById('detail-page').style.display='flex';
    \\  document.getElementById('back-btn').style.display='block';
    \\  document.getElementById('add-btn').style.display='none';
    \\  document.getElementById('hdr-title').textContent='#'+id+' '+s.command;
    \\  document.getElementById('hdr-status').style.display='inline';
    \\  updateDetailState();
    \\  updateDetailActivity();
    \\  // Rebuild events panel
    \\  document.getElementById('events-view').innerHTML='';
    \\  document.getElementById('event-badge').style.display='none';
    \\  s.events.forEach(function(ev){addEventCard(ev)});
    \\  if(s.events.length>0){document.getElementById('event-badge').style.display='inline';document.getElementById('event-badge').textContent=s.events.length;}
    \\  // Reset terminal for this session
    \\  term.reset();
    \\  // Check if prompt is pending
    \\  if(s.state==='waiting_input'&&s.prompt)showPrompt(s.prompt);
    \\  else document.getElementById('prompt-section').style.display='none';
    \\  switchTab('status');
    \\}
    \\function showList(){
    \\  activeId=null;
    \\  document.getElementById('list-page').style.display='flex';
    \\  document.getElementById('detail-page').style.display='none';
    \\  document.getElementById('back-btn').style.display='none';
    \\  document.getElementById('add-btn').style.display='block';
    \\  document.getElementById('hdr-title').textContent='Kite';
    \\  document.getElementById('hdr-status').style.display='none';
    \\  renderList();
    \\}
    \\function updateDetailState(){
    \\  if(!activeId||!sessions[activeId])return;
    \\  var s=sessions[activeId];
    \\  var el=document.getElementById('hdr-status');el.textContent=s.state;el.className='status '+s.state;
    \\  var dl=document.getElementById('detail-status');dl.textContent=s.state;dl.className='status '+s.state;
    \\  document.getElementById('detail-title').textContent='#'+s.id+' '+s.command;
    \\  if(s.state==='running')document.getElementById('prompt-section').style.display='none';
    \\  if(s.state==='stopped')document.getElementById('prompt-section').style.display='none';
    \\}
    \\function updateDetailActivity(){
    \\  if(!activeId||!sessions[activeId])return;
    \\  var s=sessions[activeId];
    \\  var txt=s.activity||'Running...';
    \\  if(s.state==='waiting_input')txt='Waiting for your input...';
    \\  if(s.state==='stopped')txt='Session ended.';
    \\  document.getElementById('detail-activity').textContent=txt;
    \\}
    \\function switchTab(tab){
    \\  currentTab=tab;
    \\  document.getElementById('status-view').style.display=tab==='status'?'flex':'none';
    \\  document.getElementById('terminal-view').style.display=tab==='terminal'?'flex':'none';
    \\  document.getElementById('events-view').style.display=tab==='events'?'block':'none';
    \\  document.querySelectorAll('.view-btn').forEach(function(b){b.classList.remove('active')});
    \\  document.getElementById('tab-'+tab).classList.add('active');
    \\  if(tab==='terminal')setTimeout(function(){fitAddon.fit();term.refresh(0,term.rows-1)},50);
    \\}
    \\function showPrompt(msg){
    \\  document.getElementById('prompt-section').style.display='block';
    \\  document.getElementById('prompt-summary').textContent=msg.summary||'';
    \\  var opts=document.getElementById('prompt-options');opts.innerHTML='';
    \\  if(msg.options&&msg.options.length>0){
    \\    msg.options.forEach(function(o){var b=document.createElement('button');b.textContent=o;b.onclick=function(){sendText(o)};opts.appendChild(b)});
    \\  }
    \\  document.getElementById('prompt-input').value='';
    \\  document.getElementById('prompt-input').focus();
    \\  if(currentTab!=='status')switchTab('status');
    \\}
    \\function sendPromptResponse(){var t=document.getElementById('prompt-input').value.trim();if(t)sendText(t);}
    \\function sendText(text){
    \\  if(ws&&ws.readyState===1&&activeId)ws.send(JSON.stringify({type:'prompt_response',text:text,session_id:activeId}));
    \\  document.getElementById('prompt-section').style.display='none';
    \\  if(activeId&&sessions[activeId]){sessions[activeId].prompt=null;sessions[activeId].activity='Processing...';}
    \\  updateDetailActivity();
    \\}
    \\function addEventCard(msg){
    \\  var panel=document.getElementById('events-view');
    \\  var card=document.createElement('div');card.className='event-card';
    \\  var time=msg.ts?new Date(msg.ts*1000).toLocaleTimeString():'';
    \\  card.innerHTML='<div class="event-header"><span class="event-type '+(msg.event||'')+'">'+msg.event+'</span><span class="event-time">'+time+'</span></div>'
    \\    +(msg.tool?'<div class="event-tool">'+msg.tool+'</div>':'')
    \\    +(msg.detail?'<div class="event-detail">'+msg.detail.substring(0,300)+'</div>':'');
    \\  panel.prepend(card);
    \\  var badge=document.getElementById('event-badge');badge.style.display='inline';
    \\  badge.textContent=parseInt(badge.textContent||'0')+1;
    \\}
    \\/* ---- Create / Delete ---- */
    \\function showCreateDialog(){document.getElementById('create-overlay').style.display='flex';document.getElementById('create-cmd').focus();}
    \\function hideCreateDialog(){document.getElementById('create-overlay').style.display='none';}
    \\function createSession(){
    \\  var cmd=document.getElementById('create-cmd').value.trim()||'claude';
    \\  hideCreateDialog();
    \\  fetch('/api/sessions',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({command:cmd})})
    \\  .then(function(r){return r.json()}).then(function(d){
    \\    if(d.session_id){
    \\      sessions[d.session_id]={id:d.session_id,state:'running',command:cmd,cwd:'',activity:'',events:[]};
    \\      renderList();
    \\    }
    \\  }).catch(function(){});
    \\}
    \\function deleteSession(id,ev){
    \\  ev.stopPropagation();
    \\  if(!confirm('Delete session #'+id+'?'))return;
    \\  fetch('/api/sessions/'+id,{method:'DELETE'}).then(function(){
    \\    delete sessions[id];
    \\    if(activeId===id)showList();
    \\    renderList();
    \\  }).catch(function(){});
    \\}
    \\document.getElementById('prompt-input').addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();sendPromptResponse();}});
    \\document.getElementById('create-cmd').addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();createSession();}});
    \\</script>
    \\</body>
    \\</html>
;
