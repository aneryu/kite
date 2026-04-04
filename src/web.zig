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
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\:root {
    \\  --bg: #0a0a0a; --fg: #e0e0e0; --accent: #4fc3f7;
    \\  --card-bg: #1a1a1a; --border: #333;
    \\  --danger: #ef5350; --success: #66bb6a; --warn: #ffa726;
    \\}
    \\body {
    \\  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
    \\  background: var(--bg); color: var(--fg);
    \\  height: 100dvh; display: flex; flex-direction: column; overflow: hidden;
    \\}
    \\#auth-screen { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100dvh; padding: 2rem; }
    \\#auth-screen h1 { font-size: 1.5rem; margin-bottom: 1rem; color: var(--accent); }
    \\#auth-screen input { width: 100%; max-width: 400px; padding: 0.75rem; border: 1px solid var(--border); border-radius: 8px; background: var(--card-bg); color: var(--fg); font-size: 1rem; margin-bottom: 1rem; }
    \\#auth-screen button { padding: 0.75rem 2rem; border: none; border-radius: 8px; background: var(--accent); color: #000; font-size: 1rem; font-weight: 600; cursor: pointer; }
    \\#auth-error { color: var(--danger); margin-top: 0.5rem; display: none; }
    \\#app { display: none; flex-direction: column; height: 100dvh; }
    \\header { display: flex; align-items: center; justify-content: space-between; padding: 0.5rem 1rem; background: var(--card-bg); border-bottom: 1px solid var(--border); flex-shrink: 0; }
    \\header h1 { font-size: 1rem; color: var(--accent); }
    \\.header-right { display: flex; align-items: center; gap: 0.5rem; }
    \\.status { font-size: 0.75rem; padding: 0.25rem 0.5rem; border-radius: 4px; }
    \\.status.running { background: var(--success); color: #000; }
    \\.status.waiting_input { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
    \\.status.stopped { background: var(--danger); color: #fff; }
    \\.status.starting { background: var(--accent); color: #000; }
    \\@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
    \\.view-toggle { display: flex; gap: 0; flex-shrink: 0; border-bottom: 1px solid var(--border); }
    \\.view-btn { flex: 1; padding: 0.5rem; text-align: center; cursor: pointer; border: none; background: transparent; color: var(--fg); font-size: 0.85rem; border-bottom: 2px solid transparent; }
    \\.view-btn.active { color: var(--accent); border-bottom-color: var(--accent); }
    \\.view-btn .badge { background: var(--warn); color: #000; border-radius: 10px; padding: 0 6px; font-size: 0.7rem; margin-left: 4px; }
    \\#status-view { flex: 1; padding: 1rem; overflow-y: auto; display: flex; flex-direction: column; gap: 1rem; }
    \\.session-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 12px; padding: 1rem; }
    \\.session-card .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.75rem; }
    \\.session-card .card-title { font-weight: 600; font-size: 0.9rem; }
    \\.session-card .card-activity { color: #888; font-size: 0.8rem; margin-bottom: 0.5rem; }
    \\#prompt-section { display: none; }
    \\.prompt-summary { background: #111; border: 1px solid var(--border); border-radius: 8px; padding: 0.75rem; margin-bottom: 0.75rem; font-size: 0.85rem; color: #ccc; max-height: 200px; overflow-y: auto; white-space: pre-wrap; font-family: 'Hack Nerd Font Mono', monospace; }
    \\.prompt-options { display: flex; flex-wrap: wrap; gap: 0.5rem; margin-bottom: 0.75rem; }
    \\.prompt-options button { padding: 0.5rem 1rem; border: 1px solid var(--accent); border-radius: 8px; background: transparent; color: var(--accent); font-size: 0.85rem; cursor: pointer; transition: all 0.2s; }
    \\.prompt-options button:hover { background: var(--accent); color: #000; }
    \\.prompt-input-row { display: flex; gap: 0.5rem; }
    \\.prompt-input-row input { flex: 1; padding: 0.6rem 0.75rem; border: 1px solid var(--border); border-radius: 8px; background: var(--card-bg); color: var(--fg); font-size: 0.9rem; }
    \\.prompt-input-row button { padding: 0.6rem 1.2rem; border: none; border-radius: 8px; background: var(--accent); color: #000; font-weight: 600; cursor: pointer; }
    \\.expand-terminal-btn { display: block; width: 100%; padding: 0.5rem; margin-top: 0.5rem; border: 1px solid var(--border); border-radius: 8px; background: transparent; color: #888; font-size: 0.8rem; cursor: pointer; text-align: center; }
    \\#terminal-view { flex: 1; display: none; flex-direction: column; min-height: 0; }
    \\#terminal-container { flex: 1; min-height: 0; padding: 4px; }
    \\#terminal-container .xterm { height: 100%; }
    \\#events-view { flex: 1; overflow-y: auto; padding: 0.5rem; display: none; -webkit-overflow-scrolling: touch; }
    \\.event-card { background: var(--card-bg); border: 1px solid var(--border); border-radius: 8px; padding: 0.75rem; margin-bottom: 0.5rem; }
    \\.event-card .event-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 0.25rem; }
    \\.event-card .event-type { font-size: 0.7rem; font-weight: 600; padding: 0.15rem 0.5rem; border-radius: 4px; }
    \\.event-type.PreToolUse { background: var(--warn); color: #000; }
    \\.event-type.PostToolUse { background: var(--success); color: #000; }
    \\.event-type.Notification { background: var(--accent); color: #000; }
    \\.event-type.SessionStart { background: #9c27b0; color: #fff; }
    \\.event-type.Stop { background: var(--danger); color: #fff; }
    \\.event-type.UserPromptSubmit { background: var(--accent); color: #000; }
    \\.event-card .event-time { font-size: 0.65rem; color: #888; }
    \\.event-card .event-detail { font-size: 0.75rem; color: #aaa; word-break: break-all; max-height: 4em; overflow: hidden; }
    \\.event-card .event-tool { font-weight: 600; color: var(--fg); font-size: 0.8rem; }
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
    \\    <h1>Kite</h1>
    \\    <div class="header-right">
    \\      <span id="status" class="status starting">starting</span>
    \\    </div>
    \\  </header>
    \\  <div class="view-toggle">
    \\    <button class="view-btn active" onclick="switchView('status')" id="tab-status">Status</button>
    \\    <button class="view-btn" onclick="switchView('terminal')" id="tab-terminal">Terminal</button>
    \\    <button class="view-btn" onclick="switchView('events')" id="tab-events">Events <span id="event-badge" class="badge" style="display:none">0</span></button>
    \\  </div>
    \\  <div id="status-view">
    \\    <div class="session-card">
    \\      <div class="card-header">
    \\        <span class="card-title" id="session-title">Session</span>
    \\        <span id="session-status" class="status starting">starting</span>
    \\      </div>
    \\      <div class="card-activity" id="session-activity">Waiting for session...</div>
    \\    </div>
    \\    <div id="prompt-section">
    \\      <div class="prompt-summary" id="prompt-summary"></div>
    \\      <div class="prompt-options" id="prompt-options"></div>
    \\      <div class="prompt-input-row">
    \\        <input id="prompt-input" type="text" placeholder="Type your response..." autocomplete="off">
    \\        <button onclick="sendPromptResponse()">Send</button>
    \\      </div>
    \\      <button class="expand-terminal-btn" onclick="switchView('terminal')">Show full terminal</button>
    \\    </div>
    \\  </div>
    \\  <div id="terminal-view">
    \\    <div id="terminal-container"></div>
    \\  </div>
    \\  <div id="events-view"></div>
    \\</div>
    \\<script>
    \\let ws=null,sessionToken=null,eventCount=0,term=null,fitAddon=null,currentView='status',currentSessionId=null,lastActivity='';
    \\const params=new URLSearchParams(location.search);
    \\const urlToken=params.get('token');
    \\if(urlToken)document.getElementById('token-input').value=urlToken;
    \\const saved=localStorage.getItem('kite_session');
    \\if(saved){sessionToken=saved;initApp();}
    \\function doAuth(){
    \\  const token=document.getElementById('token-input').value.trim();
    \\  if(!token)return;
    \\  fetch('/api/auth',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({setup_token:token})})
    \\  .then(function(r){return r.json();}).then(function(d){
    \\    if(d.success){sessionToken=d.token;localStorage.setItem('kite_session',d.token);initApp();}
    \\    else{document.getElementById('auth-error').style.display='block';}
    \\  }).catch(function(){document.getElementById('auth-error').style.display='block';});
    \\}
    \\function initApp(){
    \\  document.getElementById('auth-screen').style.display='none';
    \\  document.getElementById('app').style.display='flex';
    \\  initTerminal();connectWs();
    \\}
    \\function initTerminal(){
    \\  term=new window.Terminal({cursorBlink:true,fontSize:14,fontFamily:"'Hack Nerd Font Mono','SF Mono','Menlo',monospace",
    \\    theme:{background:'#0a0a0a',foreground:'#e0e0e0',cursor:'#4fc3f7',selectionBackground:'rgba(79,195,247,0.3)'},
    \\    allowProposedApi:true,scrollback:10000,convertEol:false});
    \\  fitAddon=new window.FitAddon.FitAddon();
    \\  term.loadAddon(fitAddon);
    \\  var wf=new window.WebFontsAddon.WebFontsAddon();term.loadAddon(wf);
    \\  term.open(document.getElementById('terminal-container'));
    \\  term.onData(function(data){if(ws&&ws.readyState===1)ws.send(JSON.stringify({type:'terminal_input',data:data,session_id:currentSessionId}));});
    \\  term.onResize(function(size){if(ws&&ws.readyState===1)ws.send(JSON.stringify({type:'resize',cols:size.cols,rows:size.rows,session_id:currentSessionId}));});
    \\  window.addEventListener('resize',function(){if(currentView==='terminal')fitAddon.fit();});
    \\  new ResizeObserver(function(){if(currentView==='terminal')fitAddon.fit();}).observe(document.getElementById('terminal-container'));
    \\}
    \\function connectWs(){
    \\  var proto=location.protocol==='https:'?'wss:':'ws:';
    \\  ws=new WebSocket(proto+'//'+location.host+'/ws');ws.binaryType='arraybuffer';
    \\  ws.onopen=function(){ws.send(JSON.stringify({type:'auth_token',token:sessionToken}));};
    \\  ws.onmessage=function(e){try{handleMessage(JSON.parse(e.data));}catch(err){console.error('ws error:',err);}};
    \\  ws.onclose=function(){setTimeout(connectWs,2000);};
    \\}
    \\function handleMessage(msg){
    \\  switch(msg.type){
    \\    case 'terminal_output':
    \\      if(term&&msg.data){var bin=atob(msg.data);var bytes=new Uint8Array(bin.length);for(var j=0;j<bin.length;j++)bytes[j]=bin.charCodeAt(j);term.write(bytes);}
    \\      break;
    \\    case 'hook_event':addEvent(msg);updateActivity(msg);break;
    \\    case 'session_state_change':updateSessionState(msg.state,msg.session_id);break;
    \\    case 'prompt_request':showPrompt(msg);break;
    \\    case 'auth_result':if(!msg.success){localStorage.removeItem('kite_session');location.reload();}break;
    \\  }
    \\}
    \\function switchView(view){
    \\  currentView=view;
    \\  document.getElementById('status-view').style.display=view==='status'?'flex':'none';
    \\  document.getElementById('terminal-view').style.display=view==='terminal'?'flex':'none';
    \\  document.getElementById('events-view').style.display=view==='events'?'block':'none';
    \\  document.querySelectorAll('.view-btn').forEach(function(b){b.classList.remove('active');});
    \\  document.getElementById('tab-'+view).classList.add('active');
    \\  if(view==='terminal')setTimeout(function(){fitAddon.fit();term.refresh(0,term.rows-1);},50);
    \\}
    \\function updateSessionState(state,sessionId){
    \\  currentSessionId=sessionId||currentSessionId;
    \\  var el=document.getElementById('status');el.textContent=state;el.className='status '+state;
    \\  var sel=document.getElementById('session-status');sel.textContent=state;sel.className='status '+state;
    \\  if(state==='running'){document.getElementById('prompt-section').style.display='none';document.getElementById('session-activity').textContent=lastActivity||'Running...';}
    \\  else if(state==='stopped'){document.getElementById('prompt-section').style.display='none';document.getElementById('session-activity').textContent='Session ended.';}
    \\}
    \\function showPrompt(msg){
    \\  currentSessionId=msg.session_id||currentSessionId;
    \\  var section=document.getElementById('prompt-section');section.style.display='block';
    \\  document.getElementById('prompt-summary').textContent=msg.summary||'';
    \\  document.getElementById('session-activity').textContent='Waiting for your input...';
    \\  var optionsEl=document.getElementById('prompt-options');optionsEl.innerHTML='';
    \\  if(msg.options&&msg.options.length>0){
    \\    msg.options.forEach(function(opt){var btn=document.createElement('button');btn.textContent=opt;btn.onclick=function(){sendText(opt);};optionsEl.appendChild(btn);});
    \\  }
    \\  document.getElementById('prompt-input').value='';
    \\  document.getElementById('prompt-input').focus();
    \\  if(currentView!=='status')switchView('status');
    \\}
    \\function sendPromptResponse(){var input=document.getElementById('prompt-input');var text=input.value.trim();if(!text)return;sendText(text);}
    \\function sendText(text){
    \\  if(ws&&ws.readyState===1)ws.send(JSON.stringify({type:'prompt_response',text:text,session_id:currentSessionId}));
    \\  document.getElementById('prompt-section').style.display='none';
    \\  document.getElementById('session-activity').textContent='Processing...';
    \\}
    \\function updateActivity(msg){
    \\  if(msg.event==='PreToolUse'&&msg.tool)lastActivity='Using '+msg.tool+'...';
    \\  else if(msg.event==='PostToolUse'&&msg.tool)lastActivity='Finished '+msg.tool;
    \\  else if(msg.event==='Notification')lastActivity='Notification received';
    \\  var el=document.getElementById('session-activity');if(el)el.textContent=lastActivity;
    \\}
    \\function addEvent(msg){
    \\  eventCount++;var badge=document.getElementById('event-badge');badge.style.display='inline';badge.textContent=eventCount;
    \\  var panel=document.getElementById('events-view');var card=document.createElement('div');card.className='event-card';
    \\  var time=msg.ts?new Date(msg.ts*1000).toLocaleTimeString():'';
    \\  card.innerHTML='<div class="event-header"><span class="event-type '+msg.event+'">'+msg.event+'</span><span class="event-time">'+time+'</span></div>'+
    \\    (msg.tool?'<div class="event-tool">'+msg.tool+'</div>':'')+
    \\    (msg.detail?'<div class="event-detail">'+msg.detail.substring(0,300)+'</div>':'');
    \\  panel.prepend(card);
    \\}
    \\document.getElementById('prompt-input').addEventListener('keydown',function(e){if(e.key==='Enter'){e.preventDefault();sendPromptResponse();}});
    \\</script>
    \\</body>
    \\</html>
;
