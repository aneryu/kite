<script lang="ts">
  import type { SessionInfo } from '../lib/types';
  import { sessionStore } from '../stores/sessions';
  import { transport } from '../lib/connection';

  let { session, onterminal }: { session: SessionInfo; onterminal: () => void } = $props();
  let inputText = $state('');
  let selectedAnswers = $state<Record<string, string>>({});
  let questionInputs = $state<Record<string, string>>({});
  let tasksExpanded = $state(false);
  let agentsExpanded = $state(false);

  const prompt = $derived(sessionStore.prompts.get(session.id));
  const isAsking = $derived(session.state === 'asking' || session.state === 'waiting');
  const hasQuestions = $derived(prompt?.questions && prompt.questions.length > 0);
  const totalQuestions = $derived(prompt?.questions?.length ?? 0);

  function handleOption(e: Event, opt: string, questionText?: string) {
    e.stopPropagation();
    if (session.state === 'asking' && hasQuestions && questionText) {
      const updated = { ...selectedAnswers, [questionText]: opt };
      selectedAnswers = updated;
      if (Object.keys(updated).length >= totalQuestions) {
        transport.send({ type: 'prompt_response', text: JSON.stringify(updated), session_id: session.id });
        selectedAnswers = {};
      }
    } else {
      transport.send({ type: 'prompt_response', text: opt, session_id: session.id });
    }
  }

  function handleQuestionInput(e: Event, questionText: string) {
    e.stopPropagation();
    const text = (questionInputs[questionText] ?? '').trim();
    if (!text) return;
    questionInputs = { ...questionInputs, [questionText]: '' };
    handleOption(e, text, questionText);
  }

  function handleQuestionKeydown(e: KeyboardEvent, questionText: string) {
    e.stopPropagation();
    if (e.key === 'Enter') { e.preventDefault(); handleQuestionInput(e, questionText); }
  }

  function handleSubmit(e: Event) {
    e.stopPropagation();
    if (!inputText.trim()) return;
    const text = inputText.trim();
    inputText = '';
    transport.send({ type: 'prompt_response', text, session_id: session.id });
  }

  function handleKeydown(e: KeyboardEvent) {
    e.stopPropagation();
    if (e.key === 'Enter') { e.preventDefault(); handleSubmit(e); }
  }

  function handleInputClick(e: Event) { e.stopPropagation(); }

  const completedTasks = $derived(session.tasks.filter((t) => t.completed).length);
  const runningAgents = $derived(session.subagents.filter((a) => !a.completed).length);

  const stateLabel = $derived(
    session.state === 'waiting' ? 'Waiting for input'
    : session.state === 'asking' ? 'Needs your response'
    : session.state === 'running' ? 'Running'
    : session.state === 'waiting_permission' ? 'Permission needed'
    : 'Stopped'
  );

  const subtitle = $derived(
    session.activity ? session.activity.tool_name
    : session.last_message ? session.last_message
    : stateLabel
  );

  function formatElapsed(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    return `${Math.round(ms / 1000)}s`;
  }
</script>

<div class="card" class:waiting={isAsking} class:running={session.state === 'running'}>
  <div class="state-bar {session.state}"></div>
  <div class="card-body">
    <div class="row-top">
      <div class="title-group">
        <span class="title">{session.cwd.split('/').pop() || session.command}</span>
        <span class="sid">#{session.id}</span>
      </div>
      <span class="status {session.state}">{session.state.replace('_', ' ')}</span>
    </div>

    <div class="row-sub">
      {#if session.activity}
        <span class="activity-dot"></span>
        <span class="subtitle mono">{session.activity.tool_name}</span>
      {:else}
        <span class="subtitle">{subtitle}</span>
      {/if}
    </div>

    {#if session.tasks.length > 0 || session.subagents.length > 0}
      <div class="meta-row">
        {#if session.tasks.length > 0}
          <button class="meta-chip" onclick={() => tasksExpanded = !tasksExpanded}>
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><polyline points="9 11 12 14 22 4"></polyline><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"></path></svg>
            {completedTasks}/{session.tasks.length}
          </button>
        {/if}
        {#if session.subagents.length > 0}
          <button class="meta-chip" onclick={() => agentsExpanded = !agentsExpanded}>
            <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
            {runningAgents > 0 ? `${runningAgents} active` : `${session.subagents.length}`}
          </button>
        {/if}
        <div class="meta-spacer"></div>
        <button class="terminal-btn" onclick={onterminal}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"></polyline><line x1="12" y1="19" x2="20" y2="19"></line></svg>
          Terminal
        </button>
      </div>
    {:else}
      <div class="meta-row">
        <div class="meta-spacer"></div>
        <button class="terminal-btn" onclick={onterminal}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 17 10 11 4 5"></polyline><line x1="12" y1="19" x2="20" y2="19"></line></svg>
          Terminal
        </button>
      </div>
    {/if}

    {#if tasksExpanded && session.tasks.length > 0}
      <div class="expand-section">
        {#each session.tasks.slice(0, 5) as task}
          <div class="item" class:done={task.completed}>
            <span class="check">{task.completed ? '\u2713' : '\u2610'}</span>
            <span class="text">{task.subject}</span>
          </div>
        {/each}
        {#if session.tasks.length > 5}
          <div class="more">+{session.tasks.length - 5} more</div>
        {/if}
      </div>
    {/if}

    {#if agentsExpanded && session.subagents.length > 0}
      <div class="expand-section">
        {#each session.subagents.slice(0, 4) as agent}
          <div class="item" class:done={agent.completed}>
            <span class="dot" class:active={!agent.completed}></span>
            <span class="text">{agent.type}</span>
            <span class="elapsed">{agent.completed ? formatElapsed(agent.elapsed_ms) : '...'}</span>
          </div>
        {/each}
        {#if session.subagents.length > 4}
          <div class="more">+{session.subagents.length - 4} more</div>
        {/if}
      </div>
    {/if}

    {#if isAsking && prompt}
      <div class="prompt-section">
        {#if prompt.questions && prompt.questions.length > 0}
          {#each prompt.questions as q}
            <div class="question-block" class:answered={q.question in selectedAnswers}>
              <div class="prompt-summary">{q.question}</div>
              {#if q.options.length > 0}
                <div class="prompt-options">
                  {#each q.options as opt}
                    <button
                      class="prompt-opt"
                      class:selected={selectedAnswers[q.question] === opt}
                      onclick={(e) => handleOption(e, opt, q.question)}
                    >{opt}</button>
                  {/each}
                </div>
              {/if}
              <div class="prompt-input">
                <input type="text"
                  value={questionInputs[q.question] ?? ''}
                  oninput={(e) => { questionInputs = { ...questionInputs, [q.question]: (e.target as HTMLInputElement).value }; }}
                  onkeydown={(e) => handleQuestionKeydown(e, q.question)}
                  onclick={handleInputClick}
                  placeholder={selectedAnswers[q.question] ? selectedAnswers[q.question] : 'Type answer...'}
                />
                <button class="prompt-send" onclick={(e) => handleQuestionInput(e, q.question)}>OK</button>
              </div>
            </div>
          {/each}
        {:else}
          {#if prompt.summary}
            <div class="prompt-summary">{prompt.summary}</div>
          {/if}
          {#if prompt.options.length > 0}
            <div class="prompt-options">
              {#each prompt.options as opt}
                <button class="prompt-opt" onclick={(e) => handleOption(e, opt)}>{opt}</button>
              {/each}
            </div>
          {/if}
          <div class="prompt-input">
            <input type="text" bind:value={inputText} onkeydown={handleKeydown} onclick={handleInputClick} placeholder="Type a response..." />
            <button class="prompt-send" onclick={handleSubmit}>Send</button>
          </div>
        {/if}
      </div>
    {/if}
  </div>
</div>

<style>
  /* Card layout with left state bar */
  .card {
    display: flex; width: 100%; overflow: hidden; position: relative;
    background: linear-gradient(180deg, color-mix(in srgb, var(--card-bg) 100%, #fff 3%), var(--card-bg));
    border: 1px solid var(--border); border-radius: 10px;
    box-shadow: 0 2px 4px rgba(0,0,0,0.25), 0 8px 24px rgba(0,0,0,0.15);
    color: var(--fg); font-family: inherit; font-size: inherit;
    transition: border-color 0.15s, box-shadow 0.2s, transform 0.15s;
  }
  /* Top highlight line */
  .card::after {
    content: ''; position: absolute; top: 0; left: 16px; right: 16px; height: 1px;
    background: linear-gradient(90deg, transparent, color-mix(in srgb, var(--accent) 15%, transparent), transparent);
    pointer-events: none;
  }
  .card.waiting {
    border-color: var(--warn);
    box-shadow: 0 2px 4px rgba(0,0,0,0.25), 0 0 24px rgba(255, 167, 38, 0.12), inset 0 1px 0 rgba(255, 167, 38, 0.06);
  }
  .card.running {
    border-color: var(--border-glow);
    box-shadow: 0 2px 4px rgba(0,0,0,0.25), 0 8px 24px rgba(0,0,0,0.15);
  }
  .card:active {
    transform: translateY(-1px);
    box-shadow: 0 4px 8px rgba(0,0,0,0.3), 0 8px 24px rgba(0,0,0,0.2);
  }

  /* Left accent bar */
  .state-bar { width: 3px; flex-shrink: 0; border-radius: 10px 0 0 10px; }
  .state-bar.running { background: linear-gradient(180deg, var(--success), color-mix(in srgb, var(--success) 60%, transparent)); box-shadow: 0 0 10px rgba(102, 187, 106, 0.5); }
  .state-bar.waiting, .state-bar.asking { background: linear-gradient(180deg, var(--warn), color-mix(in srgb, var(--warn) 60%, transparent)); box-shadow: 0 0 10px rgba(255, 167, 38, 0.5); }
  .state-bar.waiting_permission { background: var(--warn); }
  .state-bar.stopped { background: var(--text-muted); opacity: 0.5; }

  .card-body { flex: 1; padding: 0.75rem 0.85rem; min-width: 0; display: flex; flex-direction: column; gap: 0.4rem; }

  /* Row 1: title + status */
  .row-top { display: flex; justify-content: space-between; align-items: center; }
  .title-group { display: flex; align-items: baseline; gap: 0.4rem; min-width: 0; }
  .title { font-weight: 600; font-size: 0.9rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sid { color: var(--text-muted); font-size: 0.65rem; font-family: monospace; flex-shrink: 0; }
  .status {
    font-size: 0.6rem; padding: 0.15rem 0.5rem; border-radius: 10px; white-space: nowrap;
    font-weight: 600; letter-spacing: 0.03em; text-transform: uppercase;
  }
  .status.running { background: rgba(102, 187, 106, 0.12); color: var(--success); border: 1px solid rgba(102, 187, 106, 0.2); animation: pulse-slow 2.5s infinite; }
  .status.waiting { background: rgba(255, 167, 38, 0.12); color: var(--warn); border: 1px solid rgba(255, 167, 38, 0.2); animation: pulse 1.5s infinite; }
  .status.stopped { background: rgba(128, 128, 128, 0.1); color: var(--text-muted); border: 1px solid rgba(128, 128, 128, 0.15); }
  .status.waiting_permission { background: rgba(255, 167, 38, 0.12); color: var(--warn); border: 1px solid rgba(255, 167, 38, 0.2); }
  .status.asking { background: rgba(255, 167, 38, 0.12); color: var(--warn); border: 1px solid rgba(255, 167, 38, 0.2); animation: pulse 1.5s infinite; }
  @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.5 } }
  @keyframes pulse-slow { 0%,100% { opacity:1 } 50% { opacity:.6 } }

  /* Row 2: subtitle */
  .row-sub { display: flex; align-items: center; gap: 0.35rem; }
  .subtitle { color: var(--text-secondary); font-size: 0.75rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .subtitle.mono { font-family: monospace; color: var(--accent); }
  .activity-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--accent); flex-shrink: 0; box-shadow: 0 0 6px var(--glow-color); animation: pulse 1s infinite; }

  /* Row 3: meta chips + terminal button */
  .meta-row { display: flex; align-items: center; gap: 0.4rem; margin-top: 0.05rem; }
  .meta-chip {
    display: flex; align-items: center; gap: 0.25rem;
    padding: 0.2rem 0.55rem; border: 1px solid var(--border); border-radius: 10px;
    background: rgba(255,255,255,0.02); color: var(--text-secondary); font-size: 0.65rem;
    font-family: monospace;
  }
  .meta-chip svg { opacity: 0.75; }
  .meta-chip:hover { border-color: var(--accent); color: var(--accent); }
  .meta-spacer { flex: 1; }
  .terminal-btn {
    display: flex; align-items: center; gap: 0.3rem;
    padding: 0.35rem 0.85rem; border: 1px solid var(--accent); border-radius: 8px;
    background: linear-gradient(135deg, color-mix(in srgb, var(--accent) 18%, transparent), color-mix(in srgb, var(--accent) 6%, transparent));
    color: var(--accent); font-size: 0.75rem; font-weight: 600;
    font-family: monospace; min-height: 34px;
    box-shadow: 0 0 0 1px var(--border-glow), 0 2px 8px rgba(0,0,0,0.2);
  }
  .terminal-btn:active { background: var(--accent); color: #000; box-shadow: 0 0 12px var(--glow-color); }
  .terminal-btn svg { flex-shrink: 0; }

  /* Expandable sections */
  .expand-section { padding-top: 0.3rem; border-top: 1px solid var(--border); }
  .item { display: flex; align-items: center; gap: 0.4rem; font-size: 0.75rem; padding: 0.1rem 0; }
  .item.done { opacity: 0.5; }
  .check { flex-shrink: 0; font-size: 0.7rem; color: var(--text-secondary); }
  .dot { width: 7px; height: 7px; border-radius: 50%; background: var(--text-muted); flex-shrink: 0; }
  .dot.active { background: var(--success); box-shadow: 0 0 6px rgba(102, 187, 106, 0.5); }
  .text { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .elapsed { color: var(--text-secondary); font-size: 0.65rem; flex-shrink: 0; }
  .more { color: var(--text-muted); font-size: 0.7rem; padding-left: 1rem; }

  /* Prompt section */
  .prompt-section { padding-top: 0.4rem; border-top: 1px solid var(--warn); }
  .question-block { margin-bottom: 0.5rem; }
  .question-block:last-of-type { margin-bottom: 0; }
  .question-block.answered { opacity: 0.5; }
  .prompt-summary { font-size: 0.8rem; color: var(--fg); margin-bottom: 0.35rem; max-height: 2.5rem; overflow: hidden; text-overflow: ellipsis; white-space: pre-wrap; word-break: break-word; }
  .prompt-options { display: flex; gap: 0.35rem; margin-bottom: 0.35rem; flex-wrap: wrap; }
  .prompt-opt { padding: 0.25rem 0.7rem; border: 1px solid var(--accent); border-radius: 16px; background: transparent; color: var(--accent); font-size: 0.8rem; transition: background 0.1s, color 0.1s; min-height: 32px; }
  .prompt-opt:active { background: var(--accent); color: #000; }
  .prompt-opt.selected { background: var(--accent); color: #000; }
  .prompt-input { display: flex; gap: 0.35rem; }
  .prompt-input input { flex: 1; padding: 0.35rem 0.5rem; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--fg); font-size: 0.8rem; min-height: 32px; }
  .prompt-input input:focus { border-color: var(--accent); }
  .prompt-send { padding: 0.35rem 0.6rem; border: none; border-radius: 6px; background: var(--accent); color: #000; font-weight: 600; font-size: 0.8rem; box-shadow: 0 0 8px var(--glow-color); min-height: 32px; }
</style>
