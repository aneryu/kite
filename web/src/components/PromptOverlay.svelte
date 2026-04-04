<script lang="ts">
  let { onsubmit }: { onsubmit: (text: string) => void } = $props();
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
    <div class="options">
      <button class="opt-btn" onclick={() => handleOption('Yes')}>Yes</button>
      <button class="opt-btn" onclick={() => handleOption('No')}>No</button>
    </div>
    <div class="input-row">
      <input type="text" bind:value={inputText} onkeydown={handleKeydown} placeholder="Type a response..." />
      <button class="send-btn" onclick={handleSubmit}>Send</button>
    </div>
  </div>
</div>

<style>
  .overlay { position: absolute; bottom: 0; left: 0; right: 0; z-index: 20; padding-bottom: env(safe-area-inset-bottom, 0); }
  .prompt-bar { background: var(--card-bg); border-top: 2px solid var(--warn); padding: 0.75rem; }
  .options { display: flex; gap: 0.5rem; margin-bottom: 0.5rem; flex-wrap: wrap; }
  .opt-btn { padding: 0.4rem 1rem; border: 1px solid var(--accent); border-radius: 20px; background: transparent; color: var(--accent); font-size: 0.85rem; cursor: pointer; }
  .opt-btn:active { background: var(--accent); color: #000; }
  .input-row { display: flex; gap: 0.5rem; }
  input { flex: 1; padding: 0.6rem 0.8rem; border: 1px solid var(--border); border-radius: 8px; background: var(--bg); color: var(--fg); font-size: 0.9rem; }
  input:focus { outline: none; border-color: var(--accent); }
  .send-btn { padding: 0.6rem 1rem; border: none; border-radius: 8px; background: var(--accent); color: #000; font-weight: 600; cursor: pointer; }
</style>
