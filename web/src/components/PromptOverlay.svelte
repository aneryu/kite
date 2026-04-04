<script lang="ts">
  let { options = [], summary = '', onsubmit }: { options?: string[]; summary?: string; onsubmit: (text: string) => void } = $props();
  let inputText = $state('');

  function handleSubmit() {
    if (inputText.trim()) { onsubmit(inputText.trim()); inputText = ''; }
  }

  function handleOption(opt: string) { onsubmit(opt); }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); handleSubmit(); }
  }
</script>

<div class="overlay">
  <div class="prompt-bar">
    {#if summary}
      <div class="summary">{summary}</div>
    {/if}
    {#if options.length > 0}
      <div class="options">
        {#each options as opt}
          <button class="opt-btn" onclick={() => handleOption(opt)}>{opt}</button>
        {/each}
      </div>
    {/if}
    <div class="input-row">
      <input type="text" bind:value={inputText} onkeydown={handleKeydown} placeholder="Type a response..." />
      <button class="send-btn" onclick={handleSubmit}>Send</button>
    </div>
  </div>
</div>

<style>
  .overlay { position: absolute; bottom: 0; left: 0; right: 0; z-index: 20; padding-bottom: env(safe-area-inset-bottom, 0); }
  .prompt-bar { background: var(--card-bg); border-top: 2px solid var(--warn); padding: 0.75rem; }
  .summary { font-size: 0.85rem; color: #ccc; margin-bottom: 0.5rem; max-height: 3rem; overflow-y: auto; white-space: pre-wrap; word-break: break-word; }
  .options { display: flex; gap: 0.5rem; margin-bottom: 0.5rem; flex-wrap: wrap; }
  .opt-btn { padding: 0.4rem 1rem; border: 1px solid var(--accent); border-radius: 20px; background: transparent; color: var(--accent); font-size: 0.85rem; cursor: pointer; }
  .opt-btn:active { background: var(--accent); color: #000; }
  .input-row { display: flex; gap: 0.5rem; }
  input { flex: 1; padding: 0.6rem 0.8rem; border: 1px solid var(--border); border-radius: 8px; background: var(--bg); color: var(--fg); font-size: 0.9rem; }
  input:focus { outline: none; border-color: var(--accent); }
  .send-btn { padding: 0.6rem 1rem; border: none; border-radius: 8px; background: var(--accent); color: #000; font-weight: 600; cursor: pointer; }
</style>
