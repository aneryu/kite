<script lang="ts">
  import type { SessionInfo } from '../lib/types';
  import { sessionStore } from '../stores/sessions';
  import { rtc } from '../lib/webrtc';

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
        rtc.sendPromptResponse(JSON.stringify(updated), session.id);
        selectedAnswers = {};
      }
    } else {
      rtc.sendPromptResponse(opt, session.id);
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
    rtc.sendPromptResponse(text, session.id);
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
    display: flex; width: 100%; overflow: hidden;
    background: var(--card-bg); border: 1px solid var(--border); border-radius: 10px;
    color: var(--fg); font-family: inherit; font-size: inherit;
    transition: border-color 0.15s, box-shadow 0.2s;
  }
  .card.waiting { border-color: var(--warn); box-shadow: 0 0 16px rgba(255, 167, 38, 0.12); }
  .card.running { border-color: var(--border-glow); }

  /* Left accent bar */
  .state-bar { width: 4px; flex-shrink: 0; border-radius: 10px 0 0 10px; }
  .state-bar.running { background: var(--success); box-shadow: 0 0 8px rgba(102, 187, 106, 0.4); }
  .state-bar.waiting, .state-bar.asking { background: var(--warn); box-shadow: 0 0 8px rgba(255, 167, 38, 0.4); }
  .state-bar.waiting_permission { background: var(--warn); }
  .state-bar.stopped { background: var(--text-muted); }

  .card-body { flex: 1; padding: 0.7rem 0.8rem; min-width: 0; display: flex; flex-direction: column; gap: 0.35rem; }

  /* Row 1: title + status */
  .row-top { display: flex; justify-content: space-between; align-items: center; }
  .title-group { display: flex; align-items: baseline; gap: 0.4rem; min-width: 0; }
  .title { font-weight: 600; font-size: 0.9rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .sid { color: var(--text-muted); font-size: 0.65rem; font-family: monospace; flex-shrink: 0; }
  .status { font-size: 0.65rem; padding: 0.1rem 0.45rem; border-radius: 4px; white-space: nowrap; font-weight: 500; }
  .status.running { background: rgba(102, 187, 106, 0.15); color: var(--success); }
  .status.waiting { background: rgba(255, 167, 38, 0.15); color: var(--warn); animation: pulse 1.5s infinite; }
  .status.stopped { background: rgba(128, 128, 128, 0.15); color: var(--text-muted); }
  .status.waiting_permission { background: rgba(255, 167, 38, 0.15); color: var(--warn); }
  .status.asking { background: rgba(255, 167, 38, 0.15); color: var(--warn); animation: pulse 1.5s infinite; }
  @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.5 } }

  /* Row 2: subtitle */
  .row-sub { display: flex; align-items: center; gap: 0.35rem; }
  .subtitle { color: var(--text-secondary); font-size: 0.75rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .subtitle.mono { font-family: monospace; color: var(--accent); }
  .activity-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--accent); flex-shrink: 0; animation: pulse 1s infinite; }

  /* Row 3: meta chips + terminal button */
  .meta-row { display: flex; align-items: center; gap: 0.4rem; margin-top: 0.1rem; }
  .meta-chip {
    display: flex; align-items: center; gap: 0.25rem;
    padding: 0.15rem 0.5rem; border: 1px solid var(--border); border-radius: 12px;
    background: none; color: var(--text-secondary); font-size: 0.7rem;
    font-family: monospace;
  }
  .meta-chip svg { opacity: 0.7; }
  .meta-spacer { flex: 1; }
  .terminal-btn {
    display: flex; align-items: center; gap: 0.3rem;
    padding: 0.25rem 0.65rem; border: 1px solid var(--accent); border-radius: 6px;
    background: transparent; color: var(--accent); font-size: 0.7rem;
    font-family: monospace; min-height: 30px;
  }
  .terminal-btn:active { background: var(--accent); color: #000; }
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
  .prompt-section { padding-top: 0.4rem; border-top: 2px solid var(--warn); }
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
