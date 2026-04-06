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

  function formatElapsed(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    return `${Math.round(ms / 1000)}s`;
  }
</script>

<div class="card glass" class:waiting={isAsking}>
  <div class="row">
    <div class="title-group">
      <span class="sid">#{session.id}</span>
      <span class="title">{session.cwd.split('/').pop() || session.command}</span>
    </div>
    <div class="row-right">
      <span class="status {session.state}">{session.state.replace('_', ' ')}</span>
      <button class="terminal-btn" onclick={onterminal}>Terminal</button>
    </div>
  </div>

  {#if session.activity}
    <div class="activity">{session.activity.tool_name}</div>
  {:else if session.last_message}
    <div class="last-msg">{session.last_message}</div>
  {/if}

  {#if session.tasks.length > 0}
    <button class="section-toggle" onclick={() => tasksExpanded = !tasksExpanded}>
      <span>Tasks: {completedTasks}/{session.tasks.length} done</span>
      <span class="chevron" class:open={tasksExpanded}></span>
    </button>
    {#if tasksExpanded}
      <div class="section-content">
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
  {/if}

  {#if session.subagents.length > 0}
    <button class="section-toggle" onclick={() => agentsExpanded = !agentsExpanded}>
      <span>Subagents: {runningAgents > 0 ? `${runningAgents} running` : `${session.subagents.length} done`}</span>
      <span class="chevron" class:open={agentsExpanded}></span>
    </button>
    {#if agentsExpanded}
      <div class="section-content">
        {#each session.subagents.slice(0, 4) as agent}
          <div class="item" class:done={agent.completed}>
            <span class="dot" class:running={!agent.completed}></span>
            <span class="text">{agent.type}</span>
            <span class="elapsed">{agent.completed ? formatElapsed(agent.elapsed_ms) : '...'}</span>
          </div>
        {/each}
        {#if session.subagents.length > 4}
          <div class="more">+{session.subagents.length - 4} more</div>
        {/if}
      </div>
    {/if}
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

<style>
  .card {
    display: block; width: 100%; text-align: left;
    background: var(--card-bg-alpha); backdrop-filter: blur(12px); -webkit-backdrop-filter: blur(12px);
    border: 1px solid var(--border-glow); border-radius: 12px;
    padding: 0.85rem 1rem;
    color: var(--fg); font-family: inherit; font-size: inherit;
    transition: border-color 0.15s, background-color 0.2s, box-shadow 0.2s;
  }
  .card.waiting { border-color: var(--warn); box-shadow: 0 0 12px rgba(255, 167, 38, 0.15); }
  .row { display: flex; justify-content: space-between; align-items: center; }
  .row-right { display: flex; align-items: center; gap: 0.4rem; }
  .terminal-btn {
    padding: 0.2rem 0.6rem; border: 1px solid var(--accent); border-radius: 6px;
    background: transparent; color: var(--accent); font-size: 0.7rem;
    font-family: monospace; min-height: 32px; min-width: 44px;
    display: flex; align-items: center; justify-content: center;
  }
  .terminal-btn:active { background: var(--accent); color: #000; }
  .title-group { display: flex; align-items: center; gap: 0.4rem; min-width: 0; }
  .sid { color: var(--text-secondary); font-size: 0.7rem; font-family: monospace; flex-shrink: 0; }
  .title { font-weight: 600; font-size: 0.85rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .status { font-size: 0.7rem; padding: 0.15rem 0.5rem; border-radius: 4px; white-space: nowrap; }
  .status.running { background: var(--success); color: #000; box-shadow: 0 0 8px rgba(102, 187, 106, 0.3); }
  .status.waiting { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
  .status.stopped { background: var(--text-muted); color: #fff; }
  .status.waiting_permission { background: var(--warn); color: #000; }
  .status.asking { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
  @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.5 } }

  .activity { color: var(--accent); font-size: 0.8rem; margin-top: 0.3rem; font-family: monospace; }
  .last-msg { color: var(--text-secondary); font-size: 0.75rem; margin-top: 0.3rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* Collapsible sections */
  .section-toggle {
    display: flex; justify-content: space-between; align-items: center; width: 100%;
    margin-top: 0.5rem; padding: 0.4rem 0; border: none; border-top: 1px solid var(--border);
    background: none; color: var(--text-secondary); font-size: 0.75rem; text-align: left;
  }
  .chevron { display: inline-block; width: 0; height: 0; border-left: 4px solid transparent; border-right: 4px solid transparent; border-top: 5px solid var(--text-secondary); transition: transform 0.15s; }
  .chevron.open { transform: rotate(180deg); }
  .section-content { overflow: hidden; }
  .item { display: flex; align-items: center; gap: 0.4rem; font-size: 0.8rem; padding: 0.1rem 0; }
  .item.done { opacity: 0.5; }
  .check { flex-shrink: 0; font-size: 0.75rem; color: var(--text-secondary); }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--text-muted); flex-shrink: 0; }
  .dot.running { background: var(--success); box-shadow: 0 0 6px rgba(102, 187, 106, 0.5); }
  .text { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .elapsed { color: var(--text-secondary); font-size: 0.7rem; flex-shrink: 0; }
  .more { color: var(--text-muted); font-size: 0.75rem; padding-left: 1.2rem; }

  /* Prompt section */
  .prompt-section { margin-top: 0.5rem; padding-top: 0.5rem; border-top: 2px solid var(--warn); }
  .question-block { margin-bottom: 0.6rem; }
  .question-block:last-of-type { margin-bottom: 0; }
  .question-block.answered { opacity: 0.5; }
  .prompt-summary { font-size: 0.8rem; color: var(--fg); margin-bottom: 0.4rem; max-height: 2.5rem; overflow: hidden; text-overflow: ellipsis; white-space: pre-wrap; word-break: break-word; }
  .prompt-options { display: flex; gap: 0.4rem; margin-bottom: 0.4rem; flex-wrap: wrap; }
  .prompt-opt { padding: 0.3rem 0.8rem; border: 1px solid var(--accent); border-radius: 16px; background: transparent; color: var(--accent); font-size: 0.8rem; transition: background 0.1s, color 0.1s; min-height: 36px; }
  .prompt-opt:active { background: var(--accent); color: #000; }
  .prompt-opt.selected { background: var(--accent); color: #000; }
  .prompt-input { display: flex; gap: 0.4rem; }
  .prompt-input input { flex: 1; padding: 0.4rem 0.6rem; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--fg); font-size: 0.8rem; min-height: 36px; }
  .prompt-input input:focus { border-color: var(--accent); }
  .prompt-send { padding: 0.4rem 0.7rem; border: none; border-radius: 6px; background: var(--accent); color: #000; font-weight: 600; font-size: 0.8rem; box-shadow: 0 0 8px var(--glow-color); min-height: 36px; }
</style>
