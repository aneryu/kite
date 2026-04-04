<script lang="ts">
  import type { SessionInfo } from '../lib/types';
  import { sessionStore } from '../stores/sessions';
  import { ws } from '../lib/ws';

  let { session, onclick }: { session: SessionInfo; onclick: () => void } = $props();
  let inputText = $state('');

  const prompt = $derived(sessionStore.prompts.get(session.id));
  const isAsking = $derived(session.state === 'asking' || session.state === 'waiting_input');

  function handleOption(e: Event, opt: string) {
    e.stopPropagation();
    ws.sendPromptResponse(opt, session.id);
  }

  function handleSubmit(e: Event) {
    e.stopPropagation();
    if (inputText.trim()) {
      ws.sendPromptResponse(inputText.trim(), session.id);
      inputText = '';
    }
  }

  function handleKeydown(e: KeyboardEvent) {
    e.stopPropagation();
    if (e.key === 'Enter') { e.preventDefault(); handleSubmit(e); }
  }

  function handleInputClick(e: Event) { e.stopPropagation(); }

  const completedTasks = $derived(session.tasks.filter((t) => t.completed).length);
  const pendingTasks = $derived(session.tasks.length - completedTasks);

  function formatElapsed(ms: number): string {
    if (ms < 1000) return `${ms}ms`;
    return `${Math.round(ms / 1000)}s`;
  }
</script>

<button class="card" class:waiting={session.state === 'waiting_input' || session.state === 'asking'} {onclick}>
  <div class="row">
    <span class="title">{session.cwd.split('/').pop() || session.command}</span>
    <span class="status {session.state}">{session.state.replace('_', ' ')}</span>
  </div>

  {#if session.activity}
    <div class="activity">{session.activity.tool_name}</div>
  {/if}

  {#if session.tasks.length > 0}
    <div class="section">
      <div class="section-header">Tasks ({completedTasks} done, {pendingTasks} pending)</div>
      {#each session.tasks.slice(0, 5) as task}
        <div class="item" class:done={task.completed}>
          <span class="icon">{task.completed ? '\u2705' : '\u2610'}</span>
          <span class="text">{task.subject}</span>
        </div>
      {/each}
      {#if session.tasks.length > 5}
        <div class="more">... +{session.tasks.length - 5} more</div>
      {/if}
    </div>
  {/if}

  {#if session.subagents.length > 0}
    <div class="section">
      <div class="section-header">Subagents ({session.subagents.length})</div>
      {#each session.subagents.slice(0, 4) as agent}
        <div class="item" class:done={agent.completed}>
          <span class="icon">{agent.completed ? '\ud83d\udfe2' : '\ud83d\udfe0'}</span>
          <span class="text">{agent.type}</span>
          <span class="elapsed">{agent.completed ? formatElapsed(agent.elapsed_ms) : '...'}</span>
        </div>
      {/each}
      {#if session.subagents.length > 4}
        <div class="more">... +{session.subagents.length - 4} more</div>
      {/if}
    </div>
  {/if}

  {#if isAsking && prompt}
    <div class="prompt-section">
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
    </div>
  {/if}
</button>

<style>
  .card {
    display: block; width: 100%; text-align: left;
    background: var(--card-bg); border: 1px solid var(--border); border-radius: 12px;
    padding: 0.85rem 1rem; cursor: pointer; transition: border-color 0.15s;
    color: var(--fg); font-family: inherit; font-size: inherit;
  }
  .card:active { border-color: var(--accent); }
  .card.waiting { border-color: var(--warn); }
  .row { display: flex; justify-content: space-between; align-items: center; }
  .title { font-weight: 600; font-size: 0.85rem; }
  .status { font-size: 0.7rem; padding: 0.15rem 0.5rem; border-radius: 4px; }
  .status.running { background: var(--success); color: #000; }
  .status.waiting_input { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
  .status.stopped { background: var(--danger); color: #fff; }
  .status.starting { background: var(--accent); color: #000; }
  .status.idle { background: var(--accent); color: #000; }
  .status.asking { background: var(--warn); color: #000; animation: pulse 1.5s infinite; }
  @keyframes pulse { 0%,100% { opacity:1 } 50% { opacity:.5 } }
  .activity { color: var(--accent); font-size: 0.8rem; margin-top: 0.3rem; font-family: monospace; }
  .section { margin-top: 0.5rem; padding-top: 0.5rem; border-top: 1px solid var(--border); }
  .section-header { font-size: 0.75rem; color: #888; margin-bottom: 0.3rem; }
  .item { display: flex; align-items: center; gap: 0.4rem; font-size: 0.8rem; padding: 0.1rem 0; }
  .item.done { opacity: 0.5; }
  .icon { flex-shrink: 0; font-size: 0.75rem; }
  .text { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .elapsed { color: #888; font-size: 0.7rem; flex-shrink: 0; }
  .more { color: #666; font-size: 0.75rem; padding-left: 1.2rem; }

  .prompt-section { margin-top: 0.5rem; padding-top: 0.5rem; border-top: 2px solid var(--warn); }
  .prompt-summary { font-size: 0.8rem; color: #ccc; margin-bottom: 0.4rem; max-height: 2.5rem; overflow: hidden; text-overflow: ellipsis; white-space: pre-wrap; word-break: break-word; }
  .prompt-options { display: flex; gap: 0.4rem; margin-bottom: 0.4rem; flex-wrap: wrap; }
  .prompt-opt { padding: 0.3rem 0.8rem; border: 1px solid var(--accent); border-radius: 16px; background: transparent; color: var(--accent); font-size: 0.8rem; cursor: pointer; }
  .prompt-opt:active { background: var(--accent); color: #000; }
  .prompt-input { display: flex; gap: 0.4rem; }
  .prompt-input input { flex: 1; padding: 0.4rem 0.6rem; border: 1px solid var(--border); border-radius: 6px; background: var(--bg); color: var(--fg); font-size: 0.8rem; }
  .prompt-input input:focus { outline: none; border-color: var(--accent); }
  .prompt-send { padding: 0.4rem 0.7rem; border: none; border-radius: 6px; background: var(--accent); color: #000; font-weight: 600; font-size: 0.8rem; cursor: pointer; }
</style>
