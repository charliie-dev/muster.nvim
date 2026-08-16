# Muster Dashboard UI Design

**Date:** 2026-08-15
**Status:** Approved

## Summary

Replace the current plain `:Muster` floating report with a polished, read-only dashboard inspired by
mason.nvim's tool-list structure and lazy.nvim's visual treatment. The dashboard keeps Muster's
inspection-only safety boundary while adding responsive layout, tabs, row details, search, help,
refresh, path copying, highlights, a backdrop, and complete UI configuration.

The implementation remains dependency-free. It borrows design principles from lazy.nvim and
mason.nvim without importing either plugin's internal UI framework.

## Research

The design was checked against these installed revisions:

- lazy.nvim `306a05526ada86a7b30af95c5cc81ffba93fef97`
- mason.nvim `2a6940af80375532e5e9e7c1f2fc6319a1b7a69d`

Relevant lazy.nvim implementation:

- `lua/lazy/view/float.lua`: proportional geometry, centering, backdrop, resize, and cleanup
- `lua/lazy/view/text.lua`: segment-based text rendering and extmarks
- `lua/lazy/view/render.lua`: pills, progress, sections, details, and generated help
- `lua/lazy/view/colors.lua`: colorscheme-linked highlight groups

Relevant mason.nvim implementation:

- `lua/mason-core/ui/display.lua`: state rendering, cursor preservation, extmarks, keymaps, float,
  backdrop, resize, and cleanup
- `lua/mason/ui/instance.lua`: UI state, tabs, effects, refresh, and event-driven redraws
- `lua/mason/ui/components/header.lua`: branded in-buffer header
- `lua/mason/ui/components/tabs.lua`: active and inactive category pills
- `lua/mason/ui/components/main/package_list.lua`: status groups, compact rows, expanded details, and
  virtual text

Both plugins use a large proportional modal float, a scratch buffer, an optional full-screen backdrop,
in-buffer navigation, dedicated highlight groups, state-driven redraws, and explicit cleanup. Muster's
current `lua/muster/overlay.lua` instead opens a content-height float of at most 100 columns and renders
one unstyled fixed-width text table.

## Goals

- Preserve the existing inspection-only behavior of `:Muster`.
- Make current-buffer status, all configured tools, and actionable issues easy to distinguish.
- Keep the default list compact while making complete probe details available on demand.
- Remain readable after resizing and in narrow editor windows.
- Preserve cursor identity and scroll position across asynchronous version updates and refreshes.
- Allow users to configure geometry, border, backdrop, icons, labels, and keymaps.
- Keep rendering, window lifecycle, and data collection independently testable.

## Non-goals

- Installing, updating, uninstalling, or reconfiguring tools from the dashboard.
- Entering the Mason handoff or automatic reporting path.
- Replacing `:checkhealth muster`.
- Building a generic node-based UI framework for other plugins.
- Adding a runtime dependency on lazy.nvim, mason.nvim, nui.nvim, or snacks.nvim.
- Adding mouse-specific behavior in this iteration.

## Safety boundary

Opening or interacting with `:Muster` must never:

- require or start `muster.runner`;
- emit the startup notification report;
- enter the Mason handoff;
- install, remove, update, or reconfigure a package;
- mutate the source buffer or the user's tool configuration.

The only external effects added by this design are an explicit refresh probe against one canonical
source-buffer ID and an explicit path copy to an allowlisted inert writable register. Copy never targets
expression, command, search, filename, alternate-file, or other special registers.

## Architecture

The public entry point and successful return values remain compatible:

```lua
require("muster.overlay").open(source_bufnr)
-- success: returns report_bufnr, winid
-- contained UI failure: returns nil, nil after cleanup and notification
```

The implementation has three responsibility layers.

### Controller: `lua/muster/overlay.lua`

The controller owns data and user interaction:

- collect live and declared entries for the source buffer;
- canonicalize the source buffer once before collection and retain only that explicit valid buffer ID;
- maintain the active tab, search query, help mode, expanded row, selected tool, versions, monotonic
  state revision, search-request token, and refresh generation;
- translate configured key actions into state transitions;
- start version resolution only for found entries;
- coalesce asynchronous updates into scheduled redraws;
- reject callbacks from stale generations or closed views;
- request rendering and apply the result to the window.

The controller continues to expose `collect()` for direct testing. Existing report semantics remain the
source of truth for probing and adapter containment.

### Window lifecycle: `lua/muster/ui/window.lua`

The window layer owns Neovim resources:

- one main scratch buffer and floating window;
- one optional backdrop buffer and floating window;
- proportional or fixed geometry and viewport clamping;
- buffer and window options;
- `VimResized`, `WinClosed`, `BufHidden`, and buffer cleanup;
- singleton focus behavior;
- buffer-local keymap installation.

It does not collect tools or construct visible rows.

### Help overlay lifecycle: `lua/muster/ui/help.lua`

The Help overlay is a child float owned by the UI window layer. It is centered relative to the main
Muster window, uses 80% of the parent's content width and height, renders above it, and owns its scratch
buffer, fixed `q`/`<Esc>` close mappings, resize, external-close, and cleanup behavior. Cleanup retains
resource IDs until deletion succeeds, retries two passes, and blocks reopen while retirement remains
incomplete. Closing Help returns focus to the main list without closing, redrawing, revising, or replacing
the dashboard.

### Renderer: `lua/muster/ui/render.lua`

The renderer is a pure transformation from state and available width to a render result:

```lua
---@class muster.UiRender
---@field lines string[]
---@field extmarks muster.UiExtmark[]
---@field virtual_text muster.UiVirtualText[]
---@field row_by_line table<integer, muster.UiRow>
---@field line_by_key table<string, integer>
---@field anchors table<string, integer>
---@field revision integer
```

It owns:

- the in-buffer header, tabs, column headings, list rows, expanded details, empty states, centered footer,
  and independent Help-overlay contents;
- wide and compact layouts;
- highlight spans and search-match spans;
- row metadata used by details and copy actions;
- stable tool-identity anchors used to restore the cursor after redraws.

It does not call adapters, resolve versions, create windows, or install keymaps.

## State and data flow

The controller maintains state equivalent to:

```lua
{
  source_bufnr = 12,
  view = collected_view,
  tab = "active",
  query = "",
  showing_help = false,
  expanded_key = nil,
  selected_key = nil,
  versions = {},
  generation = 1,
  revision = 1,
  search_request = 0,
}
```

Opening follows this sequence:

```text
open
  -> resolve nil or 0 to the invoking buffer and validate one canonical source ID
  -> collect only against that canonical source buffer
  -> create the window and backdrop
  -> render the initial state
  -> resolve versions asynchronously
  -> accept callbacks for the current generation
  -> schedule one coalesced redraw
  -> restore cursor by tool identity
```

Refresh increments `generation`, `revision`, and the search token before collecting again. Late version
or search callbacks from previous generations and prompts are ignored. The current tab and committed
search query survive refresh. An expanded row remains open only if its identity still exists in the
refreshed view. `open()`, `open(0)`, refresh after focus changes, and explicit buffer IDs all retain the
same canonical source ID and never substitute the dashboard buffer.

## Dashboard layout

The default presentation is:

```text
                              muster.nvim
                           lua  •  buf 12

              [ Active (3) ] [ All (14) ] [ Issues (2) ]

   STATUS   TOOL                     TYPE          VERSION
   ●        lua_ls                   LSP           3.14.0
   ●        stylua                   Formatter     2.5.2
   ○        prettier                 Formatter     missing
            source      mason
            executable  prettier
            path        ~/.local/share/nvim/mason/bin/prettier
            reason      not on $PATH
            advice      available from Mason

                       / Muster search:   ? Help
```

The title and source context are two separately centered header rows. Tab rows and the stable footer are
also centered. The footer contains only the exact default Search and Help hint text shown above; an active
query filters rows but is never appended to the footer.

### Tabs

- **Active:** tools detected as active for the source buffer.
- **All:** the deduplicated union of active entries and setup declarations.
- **Issues:** entries whose probe status is `missing`, `unknown`, `broken`, or `unverifiable`, followed
  by adapter diagnostics, report notes, and any source-buffer error.

Tab counts describe the unfiltered underlying view and do not change while searching. Issues count each
non-found entry, diagnostic, note, and source-buffer error once.

Rows remain sorted by adapter and name in Active and All. Issues use the explicit severity order
`broken`, `unknown`, `unverifiable`, then `missing`, followed by adapter and name.

### Rows and details

Compact rows show:

- a status icon and matching highlight;
- tool name;
- adapter label;
- resolved version, pending marker, or probe status.

`<CR>` toggles details directly below the selected row. Details include available values for source,
executable, path, realpath, reason, advice, and whether the row came from live discovery rather than
`setup()`. Empty values are omitted instead of rendered as placeholder noise.

Status is never conveyed by color alone. The icon and visible status or detail text remain present.

Built-in adapter labels default to `LSP`, `Formatter`, `Linter`, `DAP`, and `none-ls`. A third-party
adapter falls back to its registry ID. Users may override either built-in or third-party display labels
through `ui.labels.adapters`.

### Search

The search action opens an input prompt. Input is limited to 256 bytes. Matching is case-insensitive and
literal across normalized tool name, adapter, probe status, source, executable, path, and realpath. The
query filters only the current tab. An empty query clears the filter; cancelling leaves the previous
query unchanged. Each prompt captures the current generation and a monotonically increasing request
token; refresh, close, or a newer prompt invalidates older callbacks. Query matches receive a dedicated
highlight.

### Help

Help opens in a separate child float centered above the dashboard at 80% of the main window's content
width and height. It always displays and installs fixed `q/<Esc>  close Help` controls. The full Help also
lists every enabled configured dashboard mapping; its configured close action is labeled `close dashboard`.
Disabling or remapping dashboard close never changes the fixed child controls. Help-only open captures the
selected tool, renders the child directly, and preserves the main revision and buffer bytes. Help-only close
sets `showing_help=false`, returns focus, and performs no scheduled or main draw. Main resize, refresh, and
version redraws may relayout and redraw an open child using the current revision. Main close retires the
child first; external child window or buffer close retires the remaining Help resources and returns focus
when the parent remains valid.

### Read-only actions

- `1`, `2`, and `3` select Active, All, and Issues.
- `<Tab>` and `<S-Tab>` cycle tabs.
- `<CR>` toggles row details.
- `/` edits the search filter.
- `?` toggles help.
- `r` refreshes the source-buffer probe.
- `y` copies the selected row's raw `path`, falling back to raw `realpath`, only when the active register
  is `"`, `a-z`, `A-Z`, `0-9`, `+`, `*`, `-`, or `_`.
- `q` and `<Esc>` close the dashboard by default. An explicit `ui.keymaps.close` override may remap or
  disable them; any enabled close mapping closes immediately instead of being intercepted by help or
  search state.

Copying a row without either path, with a non-string or unsafe path, with a path over 4096 bytes, or to
any non-allowlisted register emits a WARN notification and leaves registers unchanged. `setreg` runs in
a protected call and success is reported only after it returns successfully. Display escaping and
clipping never change the raw value selected for a validated copy.

## Geometry and responsive behavior

The default main float is centered at 80% of editor width and 80% of editor height with a rounded
border. A full-editor backdrop uses blend 60 and sits one z-index below the main float.

The backdrop is omitted when:

- `backdrop` is 100;
- `termguicolors` is disabled; or
- the active `Normal` highlight has no background.

On `VimResized`, geometry is recomputed, clamped to the usable viewport, and rendered again at the new
content width. Border cells and command-line height are included in placement calculations.

The renderer chooses its layout from available display width and configured label widths:

- the wide layout shows status, tool, adapter, and version columns when each minimum column fits;
- the compact layout keeps status and tool on the primary line and moves adapter and version to
  right-side virtual text or a continuation line;
- expanded detail keys keep a stable indent and values wrap to the remaining display width;
- tabs wrap as complete pills rather than splitting a label;
- all alignment uses `vim.fn.strdisplaywidth()`, while extmark columns use byte offsets.

All adapter identities, probe fields, diagnostics, notes, labels, icons, and queries cross one display
normalization boundary before layout. It visibly escapes line breaks, C0 U+0000-U+001F, DEL U+007F, C1 U+0080-U+009F, and the bidi controls
U+061C, U+200E, U+200F, U+202A-U+202E, and U+2066-U+2069; limits one raw display field to 4096 bytes and 512 display cells; and uses a stable
ellipsis when clipped. Labels are limited to 128 bytes, icons to 32 bytes, keymap source strings to 64
bytes, normalized keymap lhs values to Neovim's 50-byte `MAXMAPLEN`, and queries to 256 bytes. Widths 1 and 2 use deterministic clipping even when one glyph or pill is wider
than the viewport. Raw path metadata remains separate for validated copy behavior.

The window size remains stable while switching tabs, filtering, showing help, and expanding rows.

## Rendering and cursor preservation

A redraw performs these operations in order:

1. capture the selected tool identity and `winsaveview()`;
2. render lines and metadata without mutating Neovim state;
3. temporarily set the scratch buffer modifiable and replace all lines once;
4. clear the Muster namespace;
5. apply highlight extmarks and virtual text;
6. restore the selected identity using `line_by_key`;
7. restore the view when the selected row still exists, otherwise move to the relevant tab anchor.

Every initial and later redraw runs through one protected path. It always clears the coalescing guard and
restores `modifiable`, including renderer, line write, namespace, extmark, virtual-text, and scheduler
failures. A redraw failure closes all owned resources, notifies once, and makes later callbacks no-ops.
Multiple version callbacks in one event-loop turn schedule only one redraw. Rendering after close,
buffer wipe, or generation replacement is a no-op. Each result carries `state.revision`; copy refuses
stale row metadata when a newer state revision is waiting to render.

## Highlight groups

Muster defines default links without fixed RGB values:

- `MusterNormal` -> `NormalFloat`
- `MusterBackdrop` -> `Normal`
- `MusterHeader` -> `Title`
- `MusterTabActive` -> `Visual`
- `MusterTabInactive` -> `Comment`
- `MusterStatusFound` -> `DiagnosticOk`
- `MusterStatusMissing` -> `DiagnosticWarn`
- `MusterStatusBroken` -> `DiagnosticError`
- `MusterStatusUnknown` -> `DiagnosticWarn`
- `MusterStatusUnverifiable` -> `DiagnosticInfo`
- `MusterAdapter` -> `Type`
- `MusterVersion` -> `String`
- `MusterMuted` -> `Comment`
- `MusterDetailKey` -> `Identifier`
- `MusterSearchMatch` -> `IncSearch`

Definitions use `default = true`, so users and colorschemes may override them. A `ColorScheme` autocmd
reapplies only missing default links.

## Public configuration

The default setup additions are:

```lua
require("muster").setup({
  ui = {
    width = 0.8,
    height = 0.8,
    border = "rounded",
    backdrop = 60,

    icons = {
      found = "●",
      missing = "○",
      unknown = "?",
      broken = "×",
      unverifiable = "!",
      pending = "…",
      discovered = "*",
      expanded = "▾",
      collapsed = "▸",
    },

    labels = {
      title = "muster.nvim",
      tabs = {
        active = "Active",
        all = "All",
        issues = "Issues",
      },
      adapters = {
        lsp = "LSP",
        conform = "Formatter",
        nvim_lint = "Linter",
        dap = "DAP",
        none_ls = "none-ls",
      },
      columns = {
        status = "STATUS",
        tool = "TOOL",
        adapter = "TYPE",
        version = "VERSION",
      },
      details = {
        source = "source",
        executable = "executable",
        path = "path",
        realpath = "realpath",
        reason = "reason",
        advice = "advice",
      },
      empty = "No tools found.",
      no_matches = "No matching tools.",
      no_issues = "No issues found.",
      search_prompt = "Muster search: ",
      help = "Help",
    },

    keymaps = {
      close = { "q", "<Esc>" },
      active = "1",
      all = "2",
      issues = "3",
      next_tab = "<Tab>",
      previous_tab = "<S-Tab>",
      details = "<CR>",
      search = "/",
      help = "?",
      refresh = "r",
      copy_path = "y",
    },
  },
})
```

### Validation

- `width` and `height` must be finite positive numbers. Values in `(0, 1]` are viewport ratios;
  values above 1 are fixed cells.
- `border` accepts a Neovim border name or a valid eight-element border table with the shapes accepted
  by `nvim_open_win()`.
- `backdrop` must be an integer from 0 through 100.
- every UI map and list must be plain, acyclic, and free of metatables; lists must be dense.
- icon and structural label values must be strings. Empty strings may hide optional text or icons.
  Labels are limited to 128 bytes and icons to 32 bytes after rejecting control and bidi characters.
- `labels.adapters` keys follow the existing registry ID rule unchanged: non-empty, at most 128 bytes,
  and no C0 U+0000-U+001F or DEL U+007F. C1 and bidi code points remain valid lookup-key bytes so an
  existing third-party adapter ID can be labelled; keys are never rendered without display
  normalization. Adapter display-label values use the full UI text exclusions above.
- each keymap accepts `false`, a non-empty string, or a dense non-empty list of non-empty strings. A raw
  mapping is limited to 64 bytes, cannot contain NUL or control characters, and must normalize through
  `vim.keycode()` to a non-empty lhs of at most 50 bytes so every accepted mapping is installable by
  Neovim.
- duplicate keys and semantic aliases such as `<Tab>`/`<C-I>` or `<Esc>`/`<C-[>` are rejected using the
  same normalized lhs.
- border tables must be dense eight-part lists. Each character is a plain string of at most 16 bytes,
  contains none of C0 U+0000-U+001F, DEL U+007F, C1 U+0080-U+009F, U+061C, U+200E, U+200F,
  U+202A-U+202E, or U+2066-U+2069, and has display width at most one. A tuple highlight name is a
  non-empty plain string of at most 128 bytes with the same exact exclusions. Border-part tables cannot
  have metatables, cycles, sparse indices, extra tuple fields, or malformed string/tuple shapes.
- unknown nested keys are rejected. Empty structural maps at `ui`, `icons`, `labels`, `tabs`,
  `adapters`, `columns`, `details`, and `keymaps` are valid no-op partial overrides and retain defaults;
  empty keymap lists remain invalid.
- setup snapshots the complete UI table so later caller mutation cannot alter active configuration.

Invalid UI configuration participates in Muster's existing fail-closed setup behavior: the entire user
configuration is rejected and defaults remain active. There is no partial merge after a validation
failure.

## Lifecycle and edge cases

- Opening `:Muster` while its singleton is visible focuses the existing window and retains its original
  canonical source buffer.
- Initial nil/0 source arguments are canonicalized before adapter calls. Invalid explicit source IDs are
  contained as `nil, nil` without invoking an adapter.
- Closing through a key, direct `nvim_win_close`, `WinClosed`, `BufHidden`, `BufDelete`, `BufWipeout`, or
  explicit buffer deletion marks the instance closing before recursive events and removes the main
  window, non-focusable backdrop, autocmds, namespaces, and scratch buffers exactly once. `current()`
  retires an invalid singleton before returning.
- If the source buffer becomes invalid, the last snapshot remains visible. Refresh adds a source-buffer
  diagnostic to Issues and does not probe the report buffer.
- Empty Active and All tabs, an issue-free Issues tab, and a filtered set with no matches each render a
  distinct empty state.
- Search callbacks verify controller identity, generation, request token, buffer, and window validity.
  Version callbacks and scheduled redraws verify controller identity, generation, buffer, and window
  validity before updating state.
- UI construction or rendering errors clean all partially created resources, notify the user at ERROR,
  and return `nil, nil` without entering a report or provisioning path.

## Test strategy

### Configuration specs

Cover defaults, ratio and fixed dimensions, finite-number checks, border names and dense tables,
backdrop boundaries, nested icons and labels, size/control limits, plain acyclic containers, disabled and
dense-list keymaps, semantic mapping aliases, unknown keys, deep copying, and setup's fail-closed
behavior.

### Renderer specs

Cover all tabs, sorting, counts, status mapping, empty states, compact rows, expanded details, bounded
literal search, help generation, custom labels and icons, widths 1 and 2, oversized and malformed fields,
control/bidi escaping, wide and compact layouts, multibyte display width, extmark byte columns, virtual
text, render revisions, row metadata, and cursor anchors.

### Window specs

Cover geometry, viewport clamping, border compensation, backdrop conditions, resize, scratch-buffer
and window options, non-focusable backdrop, singleton retirement/focus, protected keymap installation,
partial construction, every post-open draw failpoint, scheduler rejection, direct window close,
`BufHidden`, `BufDelete`, `BufWipeout`, and recursive cleanup orderings.

### Controller specs

Cover tab selection and cycling, details, out-of-order/synchronous/stale search callbacks, refresh,
safe-register path copying and rejected special registers, copy against stale render revisions, missing
and unsafe paths, canonical and invalid source buffers, redraw coalescing/failure containment, cursor
identity after versions/filter/refresh/resize and its missing-row fallback, and stale version callbacks.

### Safety regression specs

Use `package.preload` traps with cleared `package.loaded` entries to prove that dashboard open, every
mapping, refresh, search completion, version completion, resize, close, and reopen never even require
`muster.runner`, `muster.automatic`, `muster.report`, `muster.enrich`, or `muster.handoff.mason`. Control
requires prove each trap is active. A final baseline diff separately proves all probe, version,
enrichment, reporting, and installation-authority source files are unchanged.

### Integration verification

Use real Neovim to exercise tabs, search, details, refresh, copy, help, resize, close, and reopen. Run
at both wide and narrow editor dimensions. Confirm the source buffer is unchanged and no provisioning
path is reached.

## Acceptance criteria

- `:Muster` opens one centered dashboard using configured geometry and backdrop.
- Active, All, and Issues display the specified entries and counts.
- Every status remains understandable without relying on color.
- Details, bounded search, help, refresh, safe-register path copy, and stale-render refusal behave as
  specified.
- Direct assertions prove cursor identity survives asynchronous version updates, filtering, refresh,
  and resize when the row still exists, and moves to the documented tab anchor when it does not.
- Narrow layouts remain readable without invalid extmarks or off-screen fixed columns.
- All UI resources are removed after every close path.
- Existing inspection-only and no-provisioning guarantees remain covered by direct specs.
- README, generated vimdoc, and LuaDoc document all public UI options and keymaps.
- The complete project verification suite remains green.
