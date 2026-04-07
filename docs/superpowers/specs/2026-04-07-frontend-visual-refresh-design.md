# Frontend Visual Refresh Design

## Overview

Full visual refresh of the Kite web frontend, with primary focus on the terminal detail page and secondary improvements across all other components.

## Part 1: Terminal Detail Page (SessionDetail)

### Nav Bar Redesign

- **Layout:** `[Back arrow] [Title] [Font A-/A+] [ConnectionStatus dot]`
- Remove status badge entirely
- Padding: `0.35rem 0.6rem` (up from `0.2rem 0.5rem`)
- Add bottom glow gradient line matching main header's `::after` style
- Title left-aligned with `flex: 1`

### Font Size Controls

- Two compact buttons `A-` / `A+` in the nav bar
- Default: 11px (down from 12px on mobile)
- Step: 1px, range: 8–18px
- Persisted in `localStorage`
- On change: call `fitAddon.fit()` to recalculate cols/rows and send resize to backend

### PromptOverlay Removal

- Remove `PromptOverlay.svelte` import and usage from `SessionDetail.svelte`
- Keep `PromptOverlay.svelte` file — it is not referenced elsewhere currently, but retaining avoids churn if needed later

### Shortcut Key Bar

- 6 buttons: `Ctrl+C | Tab | Up | Down | Esc | Enter`
- Enter button gets subtle accent-color background for emphasis (most frequently used)
- Add small icon hints: `↑` `↓` for Up/Down, `↵` for Enter
- Keep monospace font, `min-height: 44px`

### Web Font Loading (Powerline Support)

- Load Hack Nerd Font woff2 from CDN (jsdelivr) — includes Powerline symbols + full icon set
- Add `<link rel="preload">` in `index.html` for the woff2 file
- `@font-face` declaration with `font-display: swap`
- Terminal fontFamily: `'Hack Nerd Font Mono', 'Hack Nerd Font', 'PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC', monospace`
- Graceful fallback to system monospace if CDN unavailable

### ConnectionStatus in Terminal Page

- Move/duplicate `ConnectionStatus` component into SessionDetail's nav bar
- Same indicator dot + expand-on-click panel behavior as the main header version
- Pass `getPeerConnection` prop through

## Part 2: SessionCard Optimization

### Card Shell

- Border-radius: 12px → 10px
- Top highlight line (`::after`): change from fixed white to theme `accent` color with low opacity
- Add `:active` feedback: `translateY(-1px)` with subtle shadow change

### Terminal Button

- Slightly larger, more prominent accent-color border + background
- Position: bottom-right of card, increased visual weight

### Status Badge

- Keep pill shape, 0.6rem font
- Running state: add slow breathing animation (2.5s cycle vs asking/waiting's 1.5s)

### Meta Chips (Tasks/Agents Count)

- Add accent-color hover effect
- Icon opacity: 0.6 → 0.75

### Prompt Section (Inline in Card)

- Keep all existing functionality (questions, options, input)
- Top border: `2px solid var(--warn)` → `1px solid var(--warn)`

## Part 3: Global & Other Components

### Main Header

- Padding aligned with terminal nav: `0.35rem 0.6rem`
- Brand size and style unchanged
- ConnectionStatus and theme toggle gap unified

### SessionList

- Add `padding-bottom: 4.5rem` to list to prevent fab button occlusion
- Empty state unchanged

### Fab Button (+)

- Bottom position: `calc(1.5rem + env(safe-area-inset-bottom, 0px))`
- Add `backdrop-filter: blur(8px)` for clarity over content

### Global Styles (app.css)

- Add `-webkit-text-size-adjust: 100%` to body
- Add `will-change` hints on animated properties for performance
- Keep existing `:active` scale(0.96) on buttons
- New CSS variable: `--nav-height` for unified header/nav height reference

### Theme

- No changes to existing color palettes
- All 4 themes + auto mode preserved

### Font Strategy Details

- CDN source: use `https://cdn.jsdelivr.net/gh/ryanoasis/nerd-fonts@latest/patched-fonts/Hack/Regular/HackNerdFontMono-Regular.woff2` (verify exact path at implementation time; if unavailable, fall back to self-hosting the woff2 in `web/public/fonts/`)
- `font-display: swap` — text renders immediately with fallback, swaps after load
- If CDN fails, graceful degradation to system monospace (Powerline symbols show as boxes but terminal remains functional)

## Files to Modify

| File | Changes |
|---|---|
| `web/src/components/SessionDetail.svelte` | Remove PromptOverlay, remove status badge, add ConnectionStatus, add font size controls, add Enter button, add glow line, update padding |
| `web/src/components/TerminalView.svelte` | Default 11px, accept fontSize prop, update fontFamily |
| `web/src/components/SessionCard.svelte` | Border-radius, highlight line, terminal button, meta chips, prompt border, animations |
| `web/src/components/ConnectionStatus.svelte` | No API changes, may need minor style tweaks for terminal nav context |
| `web/src/components/SessionList.svelte` | Add bottom padding |
| `web/src/components/PromptOverlay.svelte` | No longer imported by SessionDetail (keep file if SessionCard references pattern) |
| `web/src/App.svelte` | Align header padding |
| `web/src/app.css` | Add @font-face, -webkit-text-size-adjust, will-change, --nav-height variable |
| `signal/static/index.html` | Add font preload link |

## Out of Scope

- Scrollback / scroll behavior changes
- Theme color palette changes
- Backend protocol changes
- New features or components
