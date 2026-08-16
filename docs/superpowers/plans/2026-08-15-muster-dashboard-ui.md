# Muster Dashboard UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox
> (`- [ ]`) syntax for tracking.

**Goal:** Replace the plain `:Muster` report with a configurable, responsive, read-only dashboard that
provides Active, All, and Issues tabs, expandable details, search, help, refresh, path copy, stable
asynchronous redraws, and complete cleanup.

**Architecture:** Keep `lua/muster/overlay.lua` as the stateful controller, add a pure
`lua/muster/ui/render.lua` renderer, and add a resource-owning `lua/muster/ui/window.lua` floating-window
layer. Configuration remains in `lua/muster/config.lua`; all provisioning boundaries stay unchanged.

**Tech Stack:** Neovim 0.12 Lua API, Lua 5.1/LuaJIT, Busted, luassert, StyLua, Selene, LuaLS,
panvimdoc, and the existing pinned Nix development shell.

## Global Constraints

- Preserve `require("muster.overlay").open(source_bufnr)` and its successful `report_bufnr, winid`
  returns; contained UI construction/render failures return `nil, nil`.
- `:Muster` must remain read-only and must never require `muster.runner`, emit the startup report, enter
  the Mason handoff, or install, remove, update, or reconfigure a package.
- Keep runtime dependencies unchanged; do not depend on lazy.nvim, mason.nvim, nui.nvim, or snacks.nvim.
- Default geometry is width `0.8`, height `0.8`, border `"rounded"`, and backdrop `60`.
- Tabs are Active, All, and Issues. Rows are compact and expand with `<CR>`.
- `q` and `<Esc>` close by default; an explicit `ui.keymaps.close` override may remap or disable them.
- Any enabled close mapping closes immediately instead of being intercepted by help or search state.
- Every behavior change starts with a direct failing Busted spec and ends with the same spec passing.
- Prefix project verification commands with `nix develop --command`.
- Keep comments short and factual; document only non-obvious lifecycle or safety constraints.
- Commit each task separately with Conventional Commits and a lowercase subject.

## Program Envelope

**ID:** `MUSTER-UI-1`

**Outcome:** A dependency-free dashboard replaces the current plain overlay without changing probe,
version, enrichment, reporting, or Mason installation authority.

**Scope:** UI configuration and types, renderer, float lifecycle, controller interactions, tests,
README, LuaDoc, and generated vimdoc.

**Non-goals:** Mouse support, package-management actions, a reusable UI DSL, adapter API changes, and
changes to startup automation.

**Prerequisite:** Approved design at
`docs/superpowers/specs/2026-08-15-muster-dashboard-ui-design.md` in commit `b39befd`.

**Acceptance:** All seven slices below pass their direct specs; final StyLua, Selene, LuaLS, vimdoc,
and Busted gates pass; the worktree is clean after the final commit.

**Current readiness:** The program envelope is `READY`; UI-1 through UI-6 and supplemental UI-6A are
integrated and independently `CONFIRMED`; UI-7 has a fresh `READY` verdict. Task review previously exposed Neovim's 50-byte normalized
lhs limit, and the user-approved UI-1 amendment keeps raw mapping sources at most 64 bytes while
requiring `vim.keycode(lhs)` at most 50 bytes. Each later slice still requires its own fresh just-in-time
readiness review after prerequisites integrate.

**Rollback:** Revert the task commits in reverse order. Each slice is independently committed and does
not migrate persistent data.

**Stop conditions:** Stop the affected slice if the inspection-only boundary cannot be proven, if a
public configuration requirement conflicts with existing fail-closed setup semantics, or if the same
claim-relevant test state fails after three materially different fixes.

## Security Review Dispositions

A read-only `security-reviewer` completed the pre-approval review. No P0 or P4 finding was reported. All
P1, P2, and in-scope P3 findings are accepted as `FIX`; none is deferred or rejected.

| Finding | Priority | Disposition | Owning slice and required evidence |
|---|---:|---|---|
| Canonical source buffer before refresh | P1 | FIX | UI-5/UI-6 record every adapter buffer ID for nil, 0, explicit, focus-change, refresh, and deletion cases. |
| No-provisioning test does not trap bare require | P1 | FIX | UI-5 uses active `package.preload` traps for runner, automatic, report, enrich, and Mason handoff; UI-7 retains the authority diff. |
| Unsafe active-register sink | P2 | FIX | UI-6 allowlists inert writable registers, rejects special registers and unsafe paths, protects `setreg`, and verifies zero unsafe writes. |
| Unbounded/untrusted display strings | P2 | FIX | UI-1 bounds config text; UI-2 normalizes, escapes, clips, and tests hostile adapter/query text and widths 1/2. |
| Later redraw failures leak state/resources | P2 | FIX | UI-4 restores `modifiable` at every failpoint; UI-5 protects every draw and scheduler outcome, closes once, and ignores late callbacks. |
| External close paths under-specified | P2 | FIX | UI-4 owns guarded WinClosed/BufHidden/BufDelete/BufWipeout handlers, invalid-singleton retirement, and event-order tests. |
| Search callbacks lack freshness | P2 | FIX | UI-5 uses generation plus monotonic prompt tokens and tests out-of-order, synchronous, refreshed, closed, and cancelled prompts. |
| UI containers/keymaps not explicitly plain and installable | P3 | FIX | UI-1 rejects metatables, cycles, sparse lists, controls, oversize strings, and semantic key aliases; UI-4 contains installation failure. |
| Copy may read stale render metadata | P3 | FIX | UI-2 tags output revisions; UI-6 refuses copy while output revision differs from state revision. |

Readiness requires all table rows to have direct passing evidence and no unresolved P0-P2 security
finding.

## File Map

### Create

- `lua/muster/ui/render.lua`: pure dashboard layout, text spans, metadata, search, help, and highlight
  defaults.
- `lua/muster/ui/window.lua`: float and backdrop resources, geometry, drawing, keymaps, resize, singleton,
  and cleanup.
- `lua/muster/ui/help.lua`: separate 80% Help child, fixed close controls, drawing, relayout, external-close,
  and retryable retained cleanup.
- `spec/ui_render_spec.lua`: direct renderer behavior and layout specs.
- `spec/ui_window_spec.lua`: direct floating-window lifecycle specs.
- `spec/ui_help_spec.lua`: real-buffer Help controls, geometry, resource ownership, and failure cleanup specs.

### Modify

- `lua/muster/config.lua:10-175`: defaults, strict UI validation, nested merge, snapshots, and `ui()`.
- `lua/muster/types.lua:35-54,250-256`: public UI types and internal render/window types.
- `lua/muster/overlay.lua:1-310`: retain collection, replace plain text/window code with dashboard
  state and actions, and integrate the separate Help child without Help-only main redraws or revisions.
- `spec/config_spec.lua:1-302`: public UI configuration contract.
- `spec/overlay_spec.lua:330-561`: replace plain-line assertions and extend controller interaction and
  safety coverage.
- `lua/muster/init.lua:8-20`: setup example for the new public UI option.
- `README.md`: dashboard behavior, configuration, highlight groups, keymaps, and safety boundary.
- `spec/documentation_spec.lua:98-214`: direct documentation assertions.
- `doc/muster.txt`: generated from README through `scripts/generate-vimdoc`.

### Unchanged authority surfaces

Probe and host resolution:

- `lua/muster/check.lua`
- `lua/muster/probe.lua`
- `lua/muster/host.lua`
- `lua/muster/source.lua`
- `lua/muster/adapters/`

Version and read-only enrichment:

- `lua/muster/version.lua`
- `lua/muster/enrich.lua`
- `lua/muster/providers/`

Reporting and automatic execution:

- `lua/muster/report.lua`
- `lua/muster/runner.lua`
- `lua/muster/automatic.lua`

Mason installation authority and result validation:

- `lua/muster/handoff/mason.lua`
- `lua/muster/mason_result.lua`
- `lua/muster/mason_source.lua`

No dashboard task may edit any path in this authority list. UI-7 diffs every listed path from the
approved-design baseline through committed HEAD.

## Slice Order

```text
UI-1 config and types
  -> UI-2 renderer core
    -> UI-3 search and help
      -> UI-4 window lifecycle
        -> UI-5 controller integration
          -> UI-6 refresh, copy, and async safety
            -> UI-7 documentation and full verification
```

---

### Task 1: UI Configuration Contract

**Slice ID:** `UI-1`

**Outcome:** `setup({ ui = user_options })` accepts, validates, merges, and snapshots every approved UI option;
`config.ui()` always returns an isolated complete UI configuration, even before setup.

**Non-goals:** No renderer, window, overlay, documentation, adapter declaration grammar, probe behavior,
or provisioning-authority change belongs to UI-1.

**Prerequisites:** Program envelope READY; approved design commit named in the envelope; clean worktree
containing only the committed design and plan before execution; existing config specs green.

**Exclusive ownership:** One UI-1 writer exclusively owns `lua/muster/config.lua`,
`lua/muster/types.lua`, and `spec/config_spec.lua` until the slice result is collected. No concurrent
writer or main-session edit may touch these paths.

**Execution budget:** One writer, eight TDD steps, one targeted config suite per RED/green boundary, one
static-check set, and at most three materially changed claim-relevant fix/reverify passes. No network or
external mutation beyond reads from the existing pinned Nix development environment.

**Stop conditions:** Stop UI-1 if accepted UI config cannot remain plain and snapshot-isolated, if adding
`ui` changes adapter-list or nil-before-setup semantics, if fail-closed setup retains any rejected
candidate field, if an accepted keymap cannot be installed safely, or when the fix/reverify budget is
exhausted.

**Files:**
- Modify: `lua/muster/config.lua:10-175`
- Modify: `lua/muster/types.lua:35-54`
- Test: `spec/config_spec.lua`

**Interfaces:**
- Consumes: existing `config.setup()`, `config.get()`, `config.error()`, and `config.is_option()`.
- Produces: `config.ui() -> muster.UiConfig` and the public `muster.UiOpts` / `muster.UiConfig` types.
- Later slices rely on `config.ui()` returning a fresh deep copy and never `nil`.

- [ ] **Step 1: Add failing default, merge, and isolation specs**

Add one exact helper containing every approved default field:

```lua
local function expected_ui_defaults()
  return {
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
      tabs = { active = "Active", all = "All", issues = "Issues" },
      adapters = {
        lsp = "LSP",
        conform = "Formatter",
        nvim_lint = "Linter",
        dap = "DAP",
        none_ls = "none-ls",
      },
      columns = { status = "STATUS", tool = "TOOL", adapter = "TYPE", version = "VERSION" },
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
  }
end

it("provides the exact complete dashboard UI defaults before and after setup", function()
  assert.same(expected_ui_defaults(), config.ui())
  config.setup({})
  assert.same(expected_ui_defaults(), config.ui())
end)

it("accepts an override for every public UI field including mixed tuple borders", function()
  local ui = {
    width = 72,
    height = 0.75,
    border = {
      "─",
      { "│", "BorderSide" },
      "─",
      { "│", "BorderSide" },
      { "╭", "BorderCorner" },
      "╮",
      { "╯", "BorderCorner" },
      "╰",
    },
    backdrop = 0,
    icons = {
      found = "F",
      missing = "M",
      unknown = "U",
      broken = "B",
      unverifiable = "V",
      pending = "P",
      discovered = "D",
      expanded = "E",
      collapsed = "C",
    },
    labels = {
      title = "Tools",
      tabs = { active = "Current", all = "Everything", issues = "Problems" },
      adapters = {
        lsp = "Language",
        conform = "Format",
        nvim_lint = "Lint",
        dap = "Debug",
        none_ls = "Sources",
        custom = "Custom",
      },
      columns = { status = "S", tool = "T", adapter = "A", version = "V" },
      details = {
        source = "from",
        executable = "exec",
        path = "path-name",
        realpath = "real-path",
        reason = "why",
        advice = "next",
      },
      empty = "Empty",
      no_matches = "No match",
      no_issues = "Clean",
      search_prompt = "Filter: ",
      help = "Keys",
    },
    keymaps = {
      close = { "x", "z" },
      active = "<F1>",
      all = "<F2>",
      issues = "<F3>",
      next_tab = "<F4>",
      previous_tab = "<F5>",
      details = "<F6>",
      search = "<F7>",
      help = false,
      refresh = { "<F8>", "R" },
      copy_path = "<F9>",
    },
  }
  config.setup({ ui = ui })
  assert.is_nil(config.error())
  assert.same(ui, config.ui())
end)

it("preserves defaults through each empty structural map override", function()
  local fixtures = {
    {},
    { icons = {} },
    { labels = {} },
    { labels = { tabs = {} } },
    { labels = { adapters = {} } },
    { labels = { columns = {} } },
    { labels = { details = {} } },
    { keymaps = {} },
  }
  for index, ui in ipairs(fixtures) do
    config.setup({ ui = ui })
    assert.is_nil(config.error(), ("empty structural fixture %d must pass"):format(index))
    assert.same(expected_ui_defaults(), config.ui())
  end
end)

it("deep-merges partial UI maps while replacing list-valued keymaps", function()
  config.setup({
    ui = {
      width = 72,
      icons = { found = "+" },
      labels = { tabs = { active = "Current" }, adapters = { custom = "Custom" } },
      keymaps = { close = { "x" }, help = false },
    },
  })
  local ui = config.ui()
  assert.equals(72, ui.width)
  assert.equals(0.8, ui.height)
  assert.equals("+", ui.icons.found)
  assert.equals("Current", ui.labels.tabs.active)
  assert.equals("All", ui.labels.tabs.all)
  assert.equals("Custom", ui.labels.adapters.custom)
  assert.same({ "x" }, ui.keymaps.close)
  assert.is_false(ui.keymaps.help)
end)

it("isolates defaults, setup input, config.ui(), and config.get().ui snapshots", function()
  local before_setup = config.ui()
  before_setup.icons.found = "mutated default"
  before_setup.keymaps.close[1] = "mutated default"
  assert.same(expected_ui_defaults(), config.ui())

  local opts = { ui = { icons = { found = "+" }, keymaps = { close = { "x" } } } }
  config.setup(opts)
  opts.ui.icons.found = "mutated input"
  opts.ui.keymaps.close[1] = "mutated input"

  local from_ui = config.ui()
  from_ui.icons.found = "mutated ui snapshot"
  from_ui.keymaps.close[1] = "mutated ui snapshot"
  local from_get = config.get()
  from_get.ui.icons.found = "mutated get snapshot"
  from_get.ui.keymaps.close[1] = "mutated get snapshot"

  assert.equals("+", config.ui().icons.found)
  assert.same({ "x" }, config.ui().keymaps.close)
  assert.equals("+", config.get().ui.icons.found)
  assert.same({ "x" }, config.get().ui.keymaps.close)
end)
```

- [ ] **Step 2: Run the new specs and verify the expected failure**

Run:

```bash
nix develop --command busted spec/config_spec.lua
```

Expected: FAIL because `config.ui` does not exist and `ui` is currently treated as an adapter list.

- [ ] **Step 3: Add failing validation fixtures**

Add table-driven cases for every rejected shape:

```lua
it("rejects non-table root UI values without retaining any candidate field", function()
  local invalid = { boolean = false, number = 7, string = "ui" }
  for name, ui in pairs(invalid) do
    config.setup({
      mason_install_fallback = true,
      notify_on_startup = false,
      lsp = { "lua_ls" },
      ui = ui,
    })
    assert.is_string(config.error(), name .. " root must fail")
    assert.is_false(config.get().mason_install_fallback)
    assert.is_true(config.get().notify_on_startup)
    assert.is_nil(config.list("lsp"))
    assert.same(expected_ui_defaults(), config.ui())
  end
end)

it("rejects malformed dashboard UI options and key collisions", function()
  local cyclic = {}
  cyclic.icons = cyclic
  local cyclic_border_part = { "│" }
  cyclic_border_part[2] = cyclic_border_part
  local sparse_border = { [1] = "─", [8] = "╰" }
  local cyclic_keymap = {}
  cyclic_keymap[1] = cyclic_keymap
  local overlong_character = "a" .. vim.fn.nr2char(0x0301):rep(8)
  assert.equals(17, #overlong_character)
  assert.equals(1, vim.fn.strdisplaywidth(overlong_character))
  local base_border = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }
  local invalid = {
    { width = 0 },
    { width = 0 / 0 },
    { height = math.huge },
    { border = "zigzag" },
    { border = { "+" } },
    { border = sparse_border },
    { border = setmetatable(vim.deepcopy(base_border), {}) },
    { border = { setmetatable({ "─", "Border" }, {}), unpack(base_border, 2) } },
    { border = { overlong_character, unpack(base_border, 2) } },
    { border = { "界", unpack(base_border, 2) } },
    { border = { { "─", string.rep("H", 129) }, unpack(base_border, 2) } },
    { border = { { "─", "Bad\nHighlight" }, unpack(base_border, 2) } },
    { border = { { "─", vim.fn.nr2char(0x202E) }, unpack(base_border, 2) } },
    { border = { { "─", "Border", "extra" }, unpack(base_border, 2) } },
    { border = { cyclic_border_part, unpack(base_border, 2) } },
    { backdrop = -1 },
    { backdrop = 101 },
    { backdrop = 1.5 },
    { icons = { found = 1 } },
    { icons = { found = string.rep("x", 33) } },
    { icons = { found = "\n" } },
    { labels = { tabs = { active = 1 } } },
    { labels = { tabs = { active = string.rep("x", 129) } } },
    { labels = { tabs = { active = vim.fn.nr2char(0x202E) } } },
    { labels = { adapters = { custom = string.rep("x", 129) } } },
    { labels = { adapters = { [""] = "Empty" } } },
    { labels = { adapters = { [1] = "Numeric" } } },
    { keymaps = { close = "" } },
    { keymaps = { close = {} } },
    { keymaps = { close = { "q", "" } } },
    { keymaps = { close = setmetatable({ "q" }, {}) } },
    { keymaps = { close = cyclic_keymap } },
    { keymaps = { close = { [1] = "q", [3] = "x" } } },
    { keymaps = { close = { "q", "q" } } },
    { keymaps = { close = "q", help = "q" } },
    { keymaps = { close = "<Tab>", next_tab = "<C-I>" } },
    { keymaps = { close = "<Esc>", help = "<C-[>" } },
    { keymaps = { close = string.rep("x", 51) } },
    { keymaps = { close = string.rep("x", 65) } },
    { keymaps = { close = "x\ny" } },
    setmetatable({ width = 0.8 }, {}),
    cyclic,
    { "positional UI is invalid" },
    { unexpected = true },
  }
  for index, ui in ipairs(invalid) do
    config.setup({
      mason_install_fallback = true,
      notify_on_startup = false,
      lsp = { "lua_ls" },
      ui = ui,
    })
    assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
    assert.is_false(config.get().mason_install_fallback)
    assert.is_true(config.get().notify_on_startup)
    assert.is_nil(config.list("lsp"))
    assert.same(expected_ui_defaults(), config.ui())
  end
end)

local function prohibited_ui_texts()
  local hostile = {}
  for codepoint = 0x00, 0x1F do
    hostile[#hostile + 1] = codepoint == 0 and "\0" or vim.fn.nr2char(codepoint)
  end
  hostile[#hostile + 1] = vim.fn.nr2char(0x7F)
  for codepoint = 0x80, 0x9F do
    hostile[#hostile + 1] = vim.fn.nr2char(codepoint)
  end
  for _, codepoint in ipairs({
    0x061C,
    0x200E,
    0x200F,
    0x202A,
    0x202B,
    0x202C,
    0x202D,
    0x202E,
    0x2066,
    0x2067,
    0x2068,
    0x2069,
  }) do
    hostile[#hostile + 1] = vim.fn.nr2char(codepoint)
  end
  return hostile
end

it("rejects unknown keys and non-plain nested UI containers", function()
  local cyclic_labels = {}
  cyclic_labels.tabs = cyclic_labels
  local invalid = {
    { icons = { found = "x", extra = "x" } },
    { icons = setmetatable({ found = "x" }, {}) },
    { labels = { title = "x", extra = "x" } },
    { labels = setmetatable({ title = "x" }, {}) },
    { labels = cyclic_labels },
    { labels = { tabs = { active = "x", extra = "x" } } },
    { labels = { tabs = setmetatable({ active = "x" }, {}) } },
    { labels = { adapters = setmetatable({ custom = "Custom" }, {}) } },
    { labels = { adapters = { custom = {} } } },
    { labels = { columns = { status = "x", extra = "x" } } },
    { labels = { columns = setmetatable({ status = "x" }, {}) } },
    { labels = { details = { source = "x", extra = "x" } } },
    { labels = { details = setmetatable({ source = "x" }, {}) } },
    { keymaps = { close = "x", extra = "x" } },
    { keymaps = setmetatable({ close = "x" }, {}) },
  }
  for index, ui in ipairs(invalid) do
    config.setup({ ui = ui })
    assert.is_string(config.error(), ("nested fixture %d must fail"):format(index))
  end
end)

it("rejects every prohibited code point in every UI text-value category", function()
  for text_index, text in ipairs(prohibited_ui_texts()) do
    local categories = {
      { icons = { found = text } },
      { labels = { title = text } },
      { labels = { adapters = { custom = text } } },
      { keymaps = { close = text } },
    }
    for category_index, ui in ipairs(categories) do
      config.setup({ ui = ui })
      assert.is_string(
        config.error(),
        ("text fixture %d category %d must fail"):format(text_index, category_index)
      )
    end
  end
end)

it("keeps adapter label keys aligned with the existing registry ID rule", function()
  local c1 = vim.fn.nr2char(0x80)
  local bidi = vim.fn.nr2char(0x202E)
  local boundary = string.rep("k", 128)
  local overlong = string.rep("k", 129)
  config.setup({
    ui = { labels = { adapters = { [c1] = "C1", [bidi] = "Bidi", [boundary] = "Boundary" } } },
  })
  assert.is_nil(config.error())
  assert.equals("C1", config.ui().labels.adapters[c1])
  assert.equals("Bidi", config.ui().labels.adapters[bidi])
  assert.equals("Boundary", config.ui().labels.adapters[boundary])

  config.setup({ ui = { labels = { adapters = { [overlong] = "Rejected" } } } })
  assert.is_string(config.error())

  local rejected = { "\0", vim.fn.nr2char(0x7F) }
  for codepoint = 0x01, 0x1F do
    rejected[#rejected + 1] = vim.fn.nr2char(codepoint)
  end
  for index, key in ipairs(rejected) do
    config.setup({ ui = { labels = { adapters = { [key] = "Rejected" } } } })
    assert.is_string(config.error(), ("adapter key fixture %d must fail"):format(index))
  end
end)

it("rejects every control and bidi code point in border text", function()
  local base = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }
  for index, text in ipairs(prohibited_ui_texts()) do
    local plain = vim.deepcopy(base)
    plain[1] = text
    config.setup({ ui = { border = plain } })
    assert.is_string(config.error(), ("plain border fixture %d must fail"):format(index))

    local tuple = vim.deepcopy(base)
    tuple[1] = { "─", text }
    config.setup({ ui = { border = tuple } })
    assert.is_string(config.error(), ("tuple highlight fixture %d must fail"):format(index))
  end
end)

it("rejects the entire setup candidate when UI validation fails", function()
  config.setup({
    mason_install_fallback = true,
    notify_on_startup = false,
    lsp = { "lua_ls" },
    conform = { "stylua" },
    ui = { width = 0 },
  })
  assert.is_string(config.error())
  assert.is_false(config.get().mason_install_fallback)
  assert.is_true(config.get().notify_on_startup)
  assert.is_nil(config.list("lsp"))
  assert.is_nil(config.list("conform"))
  assert.same(expected_ui_defaults(), config.ui())
end)
```

Add exact inclusive-boundary acceptance before the RED run:

```lua
it("accepts exact custom-border text limits", function()
  local character = "a" .. vim.fn.nr2char(0x0301):rep(6) .. vim.fn.nr2char(0x20DD)
  local highlight = "H" .. string.rep("x", 127)
  assert.equals(16, #character)
  assert.equals(1, vim.fn.strdisplaywidth(character))
  assert.equals(128, #highlight)

  local plain = { character, "│", "─", "│", "╭", "╮", "╯", "╰" }
  config.setup({ ui = { border = plain } })
  assert.is_nil(config.error())
  assert.same(plain, config.ui().border)

  local tuple = { { character, highlight }, "│", "─", "│", "╭", "╮", "╯", "╰" }
  config.setup({ ui = { border = tuple } })
  assert.is_nil(config.error())
  assert.same(tuple, config.ui().border)
end)

it("accepts exact icon, label, adapter-label, and keymap text limits", function()
  local icon = string.rep("i", 32)
  local label = string.rep("l", 128)
  local adapter_label = string.rep("a", 128)
  local keymap = ("<F1>"):rep(16)
  assert.equals(64, #keymap)
  assert.equals(48, #vim.keycode(keymap))
  config.setup({
    ui = {
      icons = { found = icon },
      labels = { title = label, adapters = { custom = adapter_label } },
      keymaps = { close = keymap },
    },
  })
  assert.is_nil(config.error())
  local ui = config.ui()
  assert.equals(icon, ui.icons.found)
  assert.equals(label, ui.labels.title)
  assert.equals(adapter_label, ui.labels.adapters.custom)
  assert.equals(keymap, ui.keymaps.close)

  local bufnr = vim.api.nvim_create_buf(false, true)
  local ok, err = xpcall(function()
    vim.keymap.set("n", keymap, function() end, { buffer = bufnr })
    vim.keymap.del("n", keymap, { buffer = bufnr })
  end, debug.traceback)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  assert.is_true(ok, err)
end)
```

Also accept fixed dimensions; borders `none`, `single`, `double`, `rounded`, `solid`, and `shadow`; a
dense custom eight-part border; backdrop 0 and 100; empty icon/label strings; arbitrary printable
adapter IDs; list mappings; and `false` mappings. Include a control test proving accepted lhs values
install through `vim.keymap.set` in a temporary scratch buffer.

- [ ] **Step 4: Run the complete validation suite and verify the RED state**

```bash
nix develop --command busted spec/config_spec.lua
```

Expected: FAIL on UI shape acceptance/rejection, tuple borders, semantic key collisions, complete
candidate rejection, or missing `config.ui()` because none of the UI-1 implementation exists yet.

- [ ] **Step 5: Define the public UI types**

Add exact types before `muster.SetupOpts` in `lua/muster/types.lua`:

```lua
---@alias muster.UiBorderPart string|[string, string]
---@alias muster.UiBorder string|muster.UiBorderPart[]
---@alias muster.UiKeymap string|string[]|false

---@class (exact) muster.UiIcons
---@field found string
---@field missing string
---@field unknown string
---@field broken string
---@field unverifiable string
---@field pending string
---@field discovered string
---@field expanded string
---@field collapsed string

---@class (exact) muster.UiKeymaps
---@field close muster.UiKeymap
---@field active muster.UiKeymap
---@field all muster.UiKeymap
---@field issues muster.UiKeymap
---@field next_tab muster.UiKeymap
---@field previous_tab muster.UiKeymap
---@field details muster.UiKeymap
---@field search muster.UiKeymap
---@field help muster.UiKeymap
---@field refresh muster.UiKeymap
---@field copy_path muster.UiKeymap
```

Define exact nested tab, column, detail, and structural label types; define
`muster.UiAdapterLabels` with `---@field [string] string`; define optional `muster.UiOpts` and complete
`muster.UiConfig`. Add `ui? muster.UiOpts` to `muster.SetupOpts` and required `ui muster.UiConfig` to
`muster.Config`.

- [ ] **Step 6: Implement defaults, strict validation, merging, and snapshots**

In `lua/muster/config.lua`, reserve `ui`, add the approved defaults, and use map-aware merging that
replaces lists rather than merging list indices:

```lua
local OPTIONS = {
  install = true,
  lint = true,
  mason_install_fallback = true,
  notify_on_startup = true,
  ui = true,
}

local STRUCTURAL_UI_PATHS = {
  icons = true,
  labels = true,
  ["labels.tabs"] = true,
  ["labels.adapters"] = true,
  ["labels.columns"] = true,
  ["labels.details"] = true,
  keymaps = true,
}

local function merge_ui_map(base, override, path)
  local result = vim.deepcopy(base)
  for key, value in pairs(override or {}) do
    local child = path == "" and key or (path .. "." .. key)
    if STRUCTURAL_UI_PATHS[child] then
      result[key] = merge_ui_map(result[key], value, child)
    else
      result[key] = vim.deepcopy(value)
    end
  end
  return result
end
```

Before any deep copy or merge, walk the entire UI value with a visited-table set. Require every map and
list to be plain and acyclic, every list to be dense, and every nested map to contain only its declared
keys. Determine structural maps from the declared schema path, never from `vim.islist({})`; empty
structural maps are valid no-op overrides, while empty keymap lists are invalid values. Treat `labels.adapters` as the only arbitrary-key map. Its keys follow the current registry ID rule
unchanged: non-empty, at most 128 bytes, and no C0 U+0000-U+001F or DEL U+007F. Explicitly accept C1
and bidi code points in lookup keys so existing third-party adapter IDs remain addressable; renderer
normalization protects any fallback display. Adapter display-label values use the full UI text policy.

Apply exact text limits before storage: labels 128 bytes, icons 32 bytes, and raw keymap source strings
64 bytes. Every enabled mapping string and every list element must be non-empty; mapping lists must be
plain, acyclic, dense, and non-empty. Normalize each source string with `vim.keycode()` and require the
normalized lhs to be non-empty and at most 50 bytes before accepting it.
For every UI text value other than adapter-map keys, reject C0 U+0000-U+001F, DEL U+007F, C1
U+0080-U+009F, and every bidi control U+061C, U+200E, U+200F, U+202A-U+202E, and U+2066-U+2069. Require each custom border to be a dense eight-part list. Each plain character string is at most 16
bytes, excludes the exact C0/DEL/C1/bidi set above, and has display width at most one. Each tuple is a
dense plain two-item list with one such character and a non-empty highlight name of at most 128 bytes
with the same exclusions. Reject tuple extras, nested cycles, metatables, and sparse indices before
calling `vim.deepcopy()`. Use that normalized lhs for both installability and exact/semantic collision checks, while preserving
the original source string for installation.

Create the active configuration with a complete UI map:

```lua
local base = snapshot(defaults)
local candidate_copy = snapshot(candidate)
base.ui = merge_ui_map(defaults.ui, candidate.ui or {}, "")
candidate_copy.ui = nil
current = vim.tbl_extend("force", base, candidate_copy)
```

Special-case `ui` in `snapshot()` with `vim.deepcopy()`. Add:

```lua
---@return muster.UiConfig
function M.ui()
  return vim.deepcopy((current or defaults).ui)
end
```

- [ ] **Step 7: Run direct and static checks**

Run:

```bash
nix develop --command busted spec/config_spec.lua
nix develop --command stylua --check lua/muster/config.lua lua/muster/types.lua spec/config_spec.lua
nix develop --command selene lua/muster/config.lua lua/muster/types.lua spec/config_spec.lua
nix develop --command scripts/typecheck
```

Expected: all commands exit 0; Selene reports 0 errors, warnings, and parse errors.

- [ ] **Step 8: Commit UI-1**

```bash
git add lua/muster/config.lua lua/muster/types.lua spec/config_spec.lua
git commit -m "feat(config): add dashboard ui options"
```

**Acceptance:** All approved defaults and overrides round-trip through `config.ui()`; malformed or
ambiguous input triggers existing fail-closed setup behavior; caller mutation cannot alter active UI
configuration.

**Rollback:** Revert only the UI-1 commit; no later code exists yet.

---

### Task 2: Core Dashboard Renderer

**Slice ID:** `UI-2`

**Outcome:** A pure renderer produces header, tabs, counts, ordered compact rows, details, empty states,
responsive layouts, highlights, virtual text, and row anchors without touching buffers or windows.

**Non-goals:** UI-2 does not implement search filtering/help content, open windows, install keymaps, collect
adapters, resolve versions, mutate controller state, change UI config, or touch reporting/provisioning.

**Prerequisites:** UI-1 is integrated on main through commit `5b9a5d1`; `config.ui()` and public UI types
are available; full Busted baseline is 332 successes with a clean worktree.

**Exclusive ownership:** One UI-2 writer exclusively owns `lua/muster/ui/render.lua`,
`spec/ui_render_spec.lua`, and UI render-result additions in `lua/muster/types.lua`. No concurrent writer
or main-session edit may touch these paths until review completes.

**Execution budget:** One writer, eight TDD steps, one renderer RED/green suite, one static-check set, and
at most three materially changed claim-relevant fix/reverify passes. No external mutation or new runtime
dependency.

**Stop conditions:** Stop UI-2 if rendering cannot remain buffer/window-pure, if raw untrusted values
must bypass normalization, if any line/extmark cannot be bounded at widths 1 and 2, if UI-1 public types
must be broken, or when the fix/reverify budget is exhausted.

**Files:**
- Create: `lua/muster/ui/render.lua`
- Create: `spec/ui_render_spec.lua`
- Modify: `lua/muster/types.lua:250-256`

**Interfaces:**
- Consumes: `muster.UiConfig`, `muster.OverlayView`, `muster.Entry`, and `muster.Version`.
- Produces:
  `render.render(state: muster.UiRenderState, width: integer) -> muster.UiRender`,
  `render.setup_highlights()`, and render metadata with 1-based cursor lines and 0-based extmark lines.
- Task 3 extends the same renderer with query filtering and help; Task 5 supplies controller state.

- [ ] **Step 1: Write failing renderer specs for tabs, rows, issues, and details**

Create fixtures with found, missing, unknown, broken, unverifiable, live-discovered, diagnostic, and note
entries. Use `config.setup({})` and pass `config.ui()` into state.

```lua
local render = require("muster.ui.render")

local output = render.render({
  view = view,
  ui = config.ui(),
  tab = "all",
  query = "",
  showing_help = false,
  expanded_key = "lsp\0lua_ls",
  versions = { ["lsp\0lua_ls"] = { value = "3.14.0", tier = 1 } },
  source_error = nil,
  revision = 7,
}, 100)

local text = table.concat(output.lines, "\n")
assert.is_truthy(text:find("muster.nvim", 1, true))
assert.is_truthy(text:find("Active (", 1, true))
assert.is_truthy(text:find("lua_ls", 1, true))
assert.is_truthy(text:find("3.14.0", 1, true))
assert.is_truthy(text:find("source", 1, true))
assert.is_truthy(text:find("/mason/bin/lua-language-server", 1, true))
assert.equals("lsp\0lua_ls", output.row_by_line[output.line_by_key["lsp\0lua_ls"]].key)
assert.equals(7, output.revision)
```

Add separate examples proving:

- Active includes only active rows.
- All deduplicates active and declared rows.
- Issues orders `broken`, `unknown`, `unverifiable`, then `missing` and includes diagnostics, notes, and
  one source-buffer error.
- Tab counts use the unfiltered underlying view; Issues counts each non-found entry, diagnostic, note,
  and source-buffer error once.
- Empty Active, All, and issue-free Issues use distinct configured labels.
- Undeclared live rows show the discovered marker.
- Missing detail values are omitted.
- Shuffled but equivalent Active/Other inputs produce identical adapter/name-sorted Active and All lines,
  counts, `row_by_line`, and `line_by_key`; Active identity wins an All dedupe collision.

Before production code, add all responsive and hostile-input cases. Render normal state at widths 100,
60, and 36, then hostile state at widths 2 and 1. Table-drive malformed UTF-8, non-string values, every
C0/DEL/C1/bidi control, 4096/4097-byte values, and 512/513-cell values independently through tool name,
adapter, probe fields, `view.filetype`, version value/reason, every advice display field, diagnostics,
notes, source error, labels, icons, and query. Assert:

- every line display width is at most the requested width;
- every extmark line/byte range is valid for its generated line;
- details wrap or deterministically clip and rendering always consumes input;
- normal-width pills remain intact and over-wide pills use the stable ellipsis;
- no raw malformed/control/bidi content reaches lines, extmarks, or virtual text;
- all affected fields clip at the exact boundaries;
- raw path remains unchanged only in `row_by_line` metadata;
- `output.revision == state.revision`.

Add a direct purity spec that temporarily traps `nvim_create_buf`, `nvim_open_win`,
`nvim_win_set_config`, `nvim_buf_set_lines`, `nvim_buf_clear_namespace`, `nvim_buf_set_extmark`,
`nvim_buf_add_highlight`, `nvim_set_hl`, and `nvim_create_autocmd`, calls
`render.render()`, restores every API in protected cleanup, and asserts every mutation trap remained
untouched and the result contains only plain tables. Test `render.setup_highlights()` separately: verify
default links, clear one Muster group, emit `ColorScheme`, confirm the missing default returns, and
confirm a user-defined non-default group is not replaced.

- [ ] **Step 2: Run the complete renderer spec and verify the RED state**

```bash
nix develop --command busted spec/ui_render_spec.lua
```

Expected: ERROR because `muster.ui.render` does not exist.

- [ ] **Step 3: Define render result types**

Add these documentation-only types to `lua/muster/types.lua`:

```lua
---@alias muster.UiTab '"active"'|'"all"'|'"issues"'

---@class muster.UiRenderState
---@field view muster.OverlayView
---@field ui muster.UiConfig
---@field tab muster.UiTab
---@field query string
---@field showing_help boolean
---@field expanded_key? string
---@field versions table<string, muster.Version>
---@field source_error? string
---@field revision integer

---@class muster.UiExtmark
---@field line integer 0-based line
---@field col integer 0-based byte column
---@field opts vim.api.keyset.set_extmark

---@class muster.UiVirtualText
---@field line integer 0-based line
---@field chunks [string, string][]
---@field pos? "eol"|"right_align"

---@class muster.UiRow
---@field kind "entry"|"diagnostic"|"note"
---@field key? string
---@field entry? muster.Entry

---@class muster.UiRender
---@field lines string[]
---@field extmarks muster.UiExtmark[]
---@field virtual_text muster.UiVirtualText[]
---@field row_by_line table<integer, muster.UiRow>
---@field line_by_key table<string, integer>
---@field anchors table<string, integer>
---@field revision integer
```

- [ ] **Step 4: Implement highlight defaults and render primitives**

Create `lua/muster/ui/render.lua` with:

```lua
local M = {}

local HIGHLIGHTS = {
  MusterNormal = "NormalFloat",
  MusterBackdrop = "Normal",
  MusterHeader = "Title",
  MusterTabActive = "Visual",
  MusterTabInactive = "Comment",
  MusterStatusFound = "DiagnosticOk",
  MusterStatusMissing = "DiagnosticWarn",
  MusterStatusBroken = "DiagnosticError",
  MusterStatusUnknown = "DiagnosticWarn",
  MusterStatusUnverifiable = "DiagnosticInfo",
  MusterAdapter = "Type",
  MusterVersion = "String",
  MusterMuted = "Comment",
  MusterDetailKey = "Identifier",
  MusterSearchMatch = "IncSearch",
}

local highlights_registered = false

local function apply_highlights()
  for name, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.setup_highlights()
  apply_highlights()
  if highlights_registered then
    return
  end
  highlights_registered = true
  local group = vim.api.nvim_create_augroup("muster_ui_highlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = apply_highlights })
end
```

Implement `setup_highlights()` until the prewritten Step 1 ColorScheme/default-link preservation spec
passes; do not add behavior that is absent from that RED contract.

Create one `normalize_display(value, max_cells)` boundary used by every adapter identity, probe field,
`view.filetype`, version value/reason, advice provider/action/package/command/reason, diagnostic, note,
source error, label, icon, and query before layout. Strings are capped at 4096 input
bytes and 512 display cells; labels, icons, and queries retain their tighter UI-1/runtime limits. Escape newlines, carriage returns, tabs, C0 U+0000-U+001F, DEL U+007F, C1 U+0080-U+009F, U+061C,
U+200E, U+200F, U+202A-U+202E, and U+2066-U+2069 into visible ASCII tokens. Replace malformed UTF-8 and non-string optional values with a
bounded `<invalid:type>` marker without invoking attacker-controlled `__tostring`. Preserve raw entry
fields only inside `row_by_line` metadata for later validated copy behavior.

Use one internal line builder that appends normalized text segments, tracks display width with
`vim.fn.strdisplaywidth()`, and records byte ranges with `#text`. Its output must be plain Lua tables;
it must not call `nvim_buf_set_lines`, `nvim_buf_set_extmark`, or `nvim_open_win`. Set
`output.revision = state.revision` unchanged.

- [ ] **Step 5: Implement the core render path**

Use these exact status and adapter mappings:

```lua
local STATUS_ORDER = { broken = 1, unknown = 2, unverifiable = 3, missing = 4, found = 5 }
local STATUS_HL = {
  found = "MusterStatusFound",
  missing = "MusterStatusMissing",
  unknown = "MusterStatusUnknown",
  broken = "MusterStatusBroken",
  unverifiable = "MusterStatusUnverifiable",
}
```

Copy and sort Active rows by adapter then name without mutating `state.view.active`. Build All by taking
Active identities first, adding unseen Other identities, then sorting the deduplicated copy by adapter
then name. Equivalent shuffled inputs must produce identical row order and metadata. Derive Issues from non-found
entries plus diagnostics, notes, and `state.source_error`. Compute tab counts before applying the search
query so counts remain stable while filtering. Render the in-buffer title, counts, pills, columns, rows,
details, and footer from configured labels/icons/keymaps.

Choose wide layout only when status, minimum 16-cell tool name, adapter, version, gaps, and configured
column labels all fit. Otherwise render status and tool in the main text and adapter/version as
right-aligned virtual text when it fits, falling back to a continuation line.

- [ ] **Step 6: Run the complete renderer suite and verify the GREEN state**

```bash
nix develop --command busted spec/ui_render_spec.lua
```

Expected: all prewritten core, sorting, purity, highlight, hostile-input, exact-boundary, responsive,
multibyte, extmark, metadata, and revision assertions pass with 0 failures and 0 errors.

- [ ] **Step 7: Run static checks**

```bash
nix develop --command stylua --check lua/muster/ui/render.lua lua/muster/types.lua spec/ui_render_spec.lua
nix develop --command selene lua/muster/ui/render.lua lua/muster/types.lua spec/ui_render_spec.lua
nix develop --command scripts/typecheck
```

Expected: all commands exit 0.

- [ ] **Step 8: Commit UI-2**

```bash
git add lua/muster/ui/render.lua lua/muster/types.lua spec/ui_render_spec.lua
git commit -m "feat(ui): add dashboard renderer"
```

**Acceptance:** Renderer output is deterministic and adapter/name sorted, mutation traps prove
`render.render()` does not alter Neovim buffers/windows, every rendered untrusted field crosses the
bounded normalization boundary, and direct specs cover tabs, statuses, details, widths 1/2 and normal
widths, extmark byte ranges, revisioned metadata, and empty states.

**Rollback:** Revert UI-2; UI-1 remains independently useful but dormant.

---

### Task 3: Renderer Search and Help

**Slice ID:** `UI-3`

**Outcome:** Renderer filtering is literal and case-insensitive, matched text is highlighted, and help is
generated from the active configured mappings and labels.

**Non-goals:** UI-3 does not open prompts/windows, mutate controller state, install mappings, refresh
probes, copy paths, change renderer core normalization/layout contracts, or touch provisioning.

**Prerequisites:** UI-2 is integrated and independently `CONFIRMED` through main commit `3a45d04`; the
pure renderer and `UiRenderState`/`UiRender` contracts exist; full Busted baseline is 354 successes with
a clean worktree.

**Exclusive ownership:** One UI-3 writer exclusively owns `lua/muster/ui/render.lua` and
`spec/ui_render_spec.lua`. No concurrent writer or main-session edit may touch these paths until review
completes.

**Execution budget:** One writer, seven TDD steps, one complete renderer RED/green suite, one static
check set, and at most three materially changed claim-relevant fix/reverify passes. No external mutation
or new dependency.

**Stop conditions:** Stop UI-3 if search requires pattern execution or unnormalized raw values, if help
cannot be generated from the same enabled keymap source as the footer, if filtering corrupts renderer
metadata/counts/purity, or when the fix/reverify budget is exhausted.

**Files:**
- Modify: `lua/muster/ui/render.lua`
- Test: `spec/ui_render_spec.lua`

**Interfaces:**
- Consumes: the UI-2 `render.render(state, width)` state and result.
- Produces: filtering through `render.render(state, width)` and full keymap content through
  `render.help(state, width)` for the independent Help overlay.

- [ ] **Step 1: Add failing literal-search specs**

Before production code, create table-driven field-isolated cases for normalized tool name, adapter ID,
adapter display label, probe status, source, executable/binary, path, and realpath. Give every case one
matching row and one nonmatching row in the selected tab, render with an uppercase/lowercase-inverted
query, and assert exactly the matching identity remains in `line_by_key`/`row_by_line` with its complete
plain metadata unchanged.

Add direct cases for:

- a name containing `%[` queried literally, proving no Lua pattern execution;
- a raw newline/control field queried by its visible escaped token, proving normalized matching and no raw
  display bypass;
- a metatable-bearing non-string field whose `__tostring` raises, queried by `<invalid:table>`, proving
  no `tostring` invocation;
- a row that matches only in All while Active is selected, proving selected-tab isolation;
- identical Active/All/Issues pill counts before and after filtering;
- no-match output with configured empty-state text and no entry metadata;
- `MusterSearchMatch` extmarks only on visible matched text, with each extmark line in range and byte
  columns selecting the exact matching bytes in the generated line;
- the 256-byte normalized query cap and literal handling of query metacharacters.

The same fixture rendered without a query and with a query must preserve `state.revision`; filtered output
must contain metadata only for visible rows.

- [ ] **Step 2: Add failing generated-help specs**

Configure one action with a list, one remapped action, and one disabled action. Render the main state
with `render.render()` and Help with `render.help()`. Before production code, assert the help result:

- is returned by `render.help(state, width)` and keeps `output.revision == state.revision`;
- includes every string from list mappings and the remapped key, omits the old default and every `false`
  action, and uses configured title plus all tab labels;
- contains no ordinary tool row, expanded detail, or list empty-state text;
- has empty `row_by_line` and `line_by_key`, and no tool identity in structural anchors;
- always includes the fixed `q/<Esc>  close Help` child controls; the enabled configured dashboard close
  mapping remains a separate `close dashboard` entry;
- keeps the centered main footer limited to Search and Help. With defaults its exact text is
  `/ Muster search:   ? Help`, independent of the active query.

Reuse the existing recursive plain-table assertion and Neovim mutation traps for both a nonempty-query
state and a help state. Assert neither branch calls any buffer/window/highlight/autocmd mutation API and
both return only plain tables with the exact input revision.

- [ ] **Step 3: Verify the new specs fail for missing behavior**

```bash
nix develop --command busted spec/ui_render_spec.lua
```

Expected: FAIL because UI-2 does not filter, emit search highlights, or render help.

- [ ] **Step 4: Implement literal field matching and search spans**

Use plain-string matching only:

```lua
local function contains(haystack, needle)
  return type(haystack) == "string" and haystack:lower():find(needle:lower(), 1, true) ~= nil
end
```

Match the renderer-normalized name, adapter ID, adapter display label, status, source, binary, path, and
realpath. Normalize and cap the query at 256 bytes before lowercasing. Add search extmarks only for
visible occurrences in rendered text. Do not execute Lua patterns or invoke `tostring` on untrusted
values.

- [ ] **Step 5: Implement generated help**

Implement one internal `action_hints(ui)` helper that normalizes each dashboard keymap to a list, omits
`false`, and returns enabled key/description tokens. Render Help sections for navigation, rows, inspection,
and closing from those tokens, plus an unconditional fixed `q/<Esc>  close Help` row. Label the configured
close action `close dashboard`. Render only Search and Help from the shared hints in the centered main
footer, without appending the active query. Help emits only structural anchors plus empty entry metadata
maps.

- [ ] **Step 6: Run direct and static checks**

```bash
nix develop --command busted spec/ui_render_spec.lua
nix develop --command stylua --check lua/muster/ui/render.lua spec/ui_render_spec.lua
nix develop --command selene lua/muster/ui/render.lua spec/ui_render_spec.lua
nix develop --command scripts/typecheck
```

Expected: all commands exit 0.

- [ ] **Step 7: Commit UI-3**

```bash
git add lua/muster/ui/render.lua spec/ui_render_spec.lua
git commit -m "feat(ui): add dashboard search and help"
```

**Acceptance:** Field-isolated direct specs prove normalized literal tab-local filtering, stable counts,
visible-byte-valid search extmarks, exact visible-row metadata, no pattern/`__tostring` execution, and
query/help branch purity/revision. Help is independent from list content, always exposes fixed child-close
controls, and lists every enabled configured dashboard mapping; the stable footer exposes only Search and Help.

**Rollback:** Revert UI-3; the core UI-2 renderer remains valid.

---

### Task 4: Floating Window Lifecycle

**Slice ID:** `UI-4`

**Outcome:** A singleton dashboard window owns main and backdrop resources, applies render output,
relayouts on resize, preserves selection, installs configured keymaps, and cleans up exactly once.

**Non-goals:** UI-4 does not collect/render tool data, manage tabs/search/help/controller state, resolve
versions, refresh probes, copy paths, change UI configuration, or touch reporting/provisioning.

**Prerequisites:** UI-3 is integrated and independently `CONFIRMED` through main commit `629968b`; the
`UiConfig` and `UiRender` contracts are available; full Busted baseline is 362 successes with a clean
worktree.

**Exclusive ownership:** One UI-4 writer exclusively owns `lua/muster/ui/window.lua`,
`spec/ui_window_spec.lua`, and UI-4 window type additions in `lua/muster/types.lua`. No concurrent writer
or main-session edit may touch these paths until review completes.

**Execution budget:** One writer, eight TDD steps, one complete window RED/green suite, one static-check
set, and at most three materially changed claim-relevant fix/reverify passes. No external mutation or new
dependency.

**Stop conditions:** Stop UI-4 if any construction/draw/close path can leak a main/backdrop window,
buffer, augroup, namespace state, or modifiable buffer; if external close recursion cannot be absorbed;
if accepted keymaps cannot install transactionally; if the renderer/window interface must change; or
when the fix/reverify budget is exhausted.

**Files:**
- Create: `lua/muster/ui/window.lua`
- Create: `spec/ui_window_spec.lua`
- Modify: `lua/muster/types.lua`

**Interfaces:**
- Consumes: `muster.UiConfig`, `muster.UiRender`, and typed resize/error callbacks.
- Produces:
  - `window.current() -> muster.UiWindow?`
  - `window.open(opts: muster.UiWindowOpenOpts) -> muster.UiWindow, boolean created`
  - methods `valid()`, `focus()`, `content_width()`, `cursor_line()`, `draw(output, selected_key)`,
    `map(lhs, callback, desc)`, and `close()` with the exact signatures in Step 4.
- Task 5 is the only owner of controller callbacks passed to this module.

- [ ] **Step 1: Add failing geometry and option specs**

Create a cleanup helper that restores `vim.o.columns`, `vim.o.lines`, `vim.o.cmdheight`,
`termguicolors`, and modified highlights even when assertions fail. Define usable height as
`max(1, lines - cmdheight)`. A configured non-`none` border consumes two rows and columns only when both
viewport dimensions are at least three; otherwise effective border is `none`. Ratio requests use the
full viewport before content clamp; fixed requests use `floor(value)`. Clamp content to
`1..(viewport - border_cells)`, then center the total content-plus-border rectangle:

```text
requested_width  = width <= 1  ? floor(columns * width)       : floor(width)
requested_height = height <= 1 ? floor(usable_lines * height) : floor(height)
content_width  = clamp(requested_width,  1, columns - border_cells)
content_height = clamp(requested_height, 1, usable_lines - border_cells)
col = max(0, floor((columns - content_width - border_cells) / 2))
row = max(0, floor((usable_lines - content_height - border_cells) / 2))
```

Table-drive exact configurations:

- columns 120, lines 40, cmdheight 1, 0.8/0.8, rounded: width 96, height 31, col 11, row 3;
- same viewport and ratios, border none: width 96, height 31, col 12, row 4;
- same viewport, fixed 40x10, rounded: width 40, height 10, col 39, row 13;
- columns 120, lines 40, cmdheight 2, rounded ratio: width 96, height 30, col 11, row 3;
- columns 2, lines 3, cmdheight 2, oversized fixed values, rounded: effective border none, width 2,
  height 1, col 0, row 0.

Assert the main `nvim_open_win` config exactly equals `{ relative = "editor", style = "minimal",
focusable = true, zindex = 50, width, height, row, col, border = effective_border }`. Assert main buffer
options: `buftype=nofile`, `bufhidden=wipe`, `swapfile=false`, `modifiable=false`, `buflisted=false`,
`undolevels=-1`, `textwidth=0`, `filetype=muster`. Assert main window options: `number=false`,
`relativenumber=false`, `wrap=false`, `spell=false`, `foldenable=false`, `signcolumn=no`,
`colorcolumn=""`, `cursorline=true`, `winhighlight=Normal:MusterNormal`.

Backdrop eligibility requires all three: `ui.backdrop < 100`, `termguicolors == true`, and
`nvim_get_hl(0, { name = "Normal" }).bg` is an integer. Its exact open config is editor-relative,
row/col 0, width `columns`, height `usable_lines`, style minimal, border none, focusable false, zindex 49.
Assert backdrop `winblend=ui.backdrop`, `winhighlight=Normal:MusterBackdrop`, and scratch-buffer options
`buftype=nofile`, `bufhidden=wipe`, `swapfile=false`, `buflisted=false`, `filetype=muster_backdrop`.
Table-drive backdrop omission for blend 100, disabled termguicolors, absent Normal background, and failed
highlight inspection.

- [ ] **Step 2: Add failing backdrop, resize, draw, singleton, and cleanup specs**

Before production code, cover the complete lifecycle:

- `draw()` captures `winsaveview()` in the owned window, writes all lines once, clears the namespace,
  applies every `output.extmarks` item with its zero-based line/byte column and copied opts, and applies
  every `output.virtual_text` item with `{ virt_text = chunks, virt_text_pos = pos or "eol" }` at column
  zero. It sets saved `lnum` to `output.line_by_key[selected_key]`; if absent, fallback is
  `anchors.body`, then `anchors.tabs`, then `anchors.title`, then line 1. One `winrestview()` restores
  topline/leftcol and target cursor together so a later view restore cannot overwrite identity.
- Move the same selected identity to a different line while changing topline/leftcol and assert both the
  new identity line and saved scroll state. Remove the identity and assert exact fallback-anchor cursor.
- Fail independently at `nvim_win_call`/`winsaveview`, modifiable=true, `nvim_buf_set_lines`,
  modifiable=false, namespace clear, each highlight extmark, each virtual-text extmark,
  `winrestview`, and cursor/view restoration. Always attempt modifiable=false and full retirement;
  preserve the initiating error over cleanup errors, otherwise return the first cleanup error.
- Install two or more mappings, fail the second/later `vim.keymap.set`, and assert the instance retires,
  the owned buffer deletion removes earlier maps, all resources disappear, `current()` is nil, the
  original mapping error is rethrown, and reopen plus all mappings succeeds.
- `VimResized` no-ops when closing or invalid. On a valid instance it recomputes both exact configs,
  applies main then backdrop config/options, and calls `on_resize(instance)` exactly once only after
  successful relayout. Inject failure at geometry, each `nvim_win_set_config`/option stage, and callback;
  each failure retires resources once and calls `on_error(original_error)` without recursive events.
- A second `open()` while active is valid focuses and returns the same instance with `created=false`,
  creates no resource, and retains original source/callback/ui state.
- Scope `WinClosed` by `pattern=tostring(main_win)` and `BufHidden`/`BufDelete`/`BufWipeout` by
  `buffer=main_buf`. Unrelated events do nothing. Every owned-event ordering, direct `nvim_win_close`,
  and explicit buffer deletion retires exactly once and allows clean reopen.
- `current()` returns a valid singleton; when resources are invalid it best-effort retires them and
  returns nil. Backdrop can never become current/focused.
- Inject construction failure after highlight inspection, each buffer creation, each option phase, each
  window creation, augroup creation, and every autocmd registration. Define `active = instance` as the
  non-failing commit point after the final fallible stage. A commit-point invariant spec proves every
  injected pre-commit failure leaves `active=nil`, while successful return publishes exactly one fully
  initialized instance. Snapshot all resources before/after each case.
- Cleanup marks closing, detaches module `active`, and stores the instance in module-local `retiring`
  before recursive APIs. A separate `cleanup_running` guard suppresses only recursive callbacks during
  the current pass. Each pass retries every still-valid augroup/namespace/window/buffer release despite
  individual errors; a second pass handles one-shot failures. If anything remains after bounded passes,
  `retiring` keeps it reachable.
- For each later entry point, inject a release failure through both cleanup passes, then remove the
  failpoint: a later explicit `instance:close()` must drain retirement; `current()` must drain then return
  nil; `open(opts)` must drain before creating exactly one new instance. In every case assert all retained
  resource IDs and `retiring` clear before success.
- With a persistent release failure, both `current()` and `open()` must raise the retirement error,
  preserve the reachable retiring instance, and create/focus nothing; they may proceed only after the
  failure is removed and cleanup completes.
- Separately inject one-shot failure before each cleanup effect, preserve initiating-error precedence,
  and prove retry removes every window, buffer, augroup, namespace mark, mapping, autocmd, singleton, and
  retiring reference.

- [ ] **Step 3: Run the window spec and verify module-not-found failure**

```bash
nix develop --command busted spec/ui_window_spec.lua
```

Expected: ERROR because `muster.ui.window` does not exist.

- [ ] **Step 4: Define the window type and implement geometry**

Add complete internal interfaces:

```lua
---@class muster.UiWindowOpenOpts
---@field source_bufnr integer
---@field ui muster.UiConfig
---@field on_resize fun(window: muster.UiWindow)
---@field on_error fun(err: any)

---@class muster.UiWindow
---@field source_bufnr integer
---@field buf integer
---@field win integer
---@field backdrop_buf? integer
---@field backdrop_win? integer
---@field valid fun(self: muster.UiWindow): boolean
---@field focus fun(self: muster.UiWindow)
---@field content_width fun(self: muster.UiWindow): integer
---@field cursor_line fun(self: muster.UiWindow): integer
---@field draw fun(self: muster.UiWindow, output: muster.UiRender, selected_key?: string)
---@field map fun(self: muster.UiWindow, lhs: string, callback: fun(), desc: string)
---@field close fun(self: muster.UiWindow)
```

Add a typecheck fixture that calls `current()`, `open(opts)`, every method, both callbacks, and both open
returns exactly as UI-5 will consume them.

Implement one geometry function returning both configs. Use the Step 1 equations verbatim, including
`usable_lines = max(1, vim.o.lines - vim.o.cmdheight)`, effective-border downgrade on a viewport below
3x3, content clamps after ratio/fixed requests, total-rectangle centering, and exact main/backdrop config
keys. No caller recomputes geometry independently.

- [ ] **Step 5: Implement resource ownership and drawing**

Use module-local `active` and namespace `vim.api.nvim_create_namespace("muster_ui")`. Build an instance
inside one protected acquisition transaction and assign `active` only after buffer/window options,
backdrop, augroup, and all lifecycle autocmds succeed. On construction failure, call the same idempotent
cleanup used by `close()` and rethrow the initiating error.

`close()` sets `closing=true`, detaches `active`, and publishes the instance as module-local `retiring`.
A `cleanup_running` guard makes only recursively emitted callbacks return immediately. Cleanup performs
two complete passes over still-valid namespace marks, augroup, main/backdrop windows, and main/backdrop
buffers; every operation is attempted despite earlier errors. Successful release clears each stored ID.
When all resources are gone it clears `retiring` and marks closed. If resources remain, later explicit
`close()`, `current()`, or `open()` retries before proceeding, and `open()` refuses a new instance while
retirement remains incomplete. An initiating construction/draw/map error always wins; otherwise report
the first cleanup error after all attempts.

`draw()` runs one protected transaction:

1. capture the owned window view with `nvim_win_call(win, vim.fn.winsaveview)`;
2. set modifiable true, call `nvim_buf_set_lines()` once, and restore modifiable false in guaranteed
   cleanup;
3. clear the namespace;
4. apply each highlight as `nvim_buf_set_extmark(buf, ns, mark.line, mark.col, vim.deepcopy(mark.opts))`;
5. apply each virtual text as `nvim_buf_set_extmark(buf, ns, item.line, 0,
   { virt_text = vim.deepcopy(item.chunks), virt_text_pos = item.pos or "eol" })`;
6. resolve target line from selected identity, then body/tabs/title/1 fallback;
7. set `saved_view.lnum=target` and `saved_view.col=0`, then call one
   `nvim_win_call(win, function() vim.fn.winrestview(saved_view) end)` so saved scroll and resolved cursor
   are restored together.

Any draw-stage failure attempts modifiable restoration and instance cleanup before rethrowing the
original error. A successful draw returns no mutable alias to renderer output.

- [ ] **Step 6: Implement mappings, resize, focus, and singleton access**

`map()` calls buffer-local `vim.keymap.set(..., { nowait=true, silent=true, desc=desc })`. Any mapping
failure immediately retires the instance, so buffer deletion removes all prior mappings, then rethrows
the original mapping error. No partially mapped valid singleton may survive.

`open(opts)` first drains any module-local `retiring` instance, then calls `current()`. When a valid
instance exists it focuses the main window and returns
that instance with `created=false`, without replacing source buffer, UI, or callbacks. A new successful
instance returns `created=true`. `focus()` uses only the main window.

Create one instance augroup. Scope `WinClosed` to `pattern=tostring(main_win)` and each buffer lifecycle
autocmd to `buffer=main_buf`; all callbacks first check instance identity and `closing`. `current()`
first drains `retiring`, then returns a fully valid active instance; otherwise it retires the invalid
instance and returns nil only after cleanup succeeds.

The `VimResized` callback no-ops when closing or invalid. Otherwise it runs a protected resize transaction:
recompute geometry, set main config, set backdrop config when present, reapply owned window options, then
call `on_resize(instance)` exactly once. Failure at any stage retires the instance and invokes
`on_error(original_error)` once after cleanup; callback errors never escape into repeated autocmd handling.
Unrelated windows/buffers cannot trigger ownership cleanup.

- [ ] **Step 7: Run direct and static checks**

```bash
nix develop --command busted spec/ui_window_spec.lua
nix develop --command stylua --check lua/muster/ui/window.lua lua/muster/types.lua spec/ui_window_spec.lua
nix develop --command selene lua/muster/ui/window.lua lua/muster/types.lua spec/ui_window_spec.lua
nix develop --command scripts/typecheck
```

Expected: all commands exit 0 and no buffer/window remains after spec cleanup.

- [ ] **Step 8: Commit UI-4**

```bash
git add lua/muster/ui/window.lua lua/muster/types.lua spec/ui_window_spec.lua
git commit -m "feat(ui): add dashboard window"
```

**Acceptance:** Table-driven specs prove exact geometry/options/backdrop eligibility; typed interfaces
match UI-5; draw preserves identity plus scroll and applies every mark exactly; all construction/draw/map/
resize failpoints and one-shot cleanup failures retire resources through reachable retries with
original-error precedence; active assignment is a proven non-failing commit point; singleton and scoped lifecycle
events behave deterministically; no mapping, namespace mark, window, buffer, augroup, singleton, or
autocmd survives retirement, and clean reopen always succeeds.

**Rollback:** Revert UI-4; renderer and configuration remain dormant.

---

### Task 5: Dashboard Controller Integration

**Slice ID:** `UI-5`

**Outcome:** `:Muster` opens the new dashboard, preserves current collection semantics, resolves versions,
and supports tabs, details, search, help, and close without entering reporting or provisioning paths.

**Non-goals:** UI-5 does not implement refresh or path copy, modify config/renderer/window contracts,
change adapter collection/probe semantics, enrich results, report startup state, or enter provisioning.

**Prerequisites:** UI-4 is integrated and independently `CONFIRMED` through main commit `8d707ca`; config,
renderer/search/help, and window interfaces are available; full Busted baseline is 380 successes with a
clean worktree.

**Exclusive ownership:** One UI-5 writer exclusively owns `lua/muster/overlay.lua` and
`spec/overlay_spec.lua`. UI renderer/window specs are run-only dependencies; no concurrent writer or
main-session edit may touch owned paths until review completes.

**Execution budget:** One writer, nine TDD steps, focused integration/security suites, one static-check
set, and at most three materially changed claim-relevant fix/reverify passes. No external mutation or new
dependency.

**Stop conditions:** Stop UI-5 if any dashboard interaction can require reporting/provisioning modules,
if canonical source identity cannot be retained, if search/version/scheduler callbacks cannot be made
late-safe and exact-once, if UI-4 interfaces must change, or when the fix/reverify budget is exhausted.

**Files:**
- Modify: `lua/muster/overlay.lua:1-310`
- Modify: `spec/overlay_spec.lua:330-561`
- Test: `spec/ui_render_spec.lua`
- Test: `spec/ui_window_spec.lua`

**Interfaces:**
- Consumes: `config.ui()`, `render.render()`, `render.setup_highlights()`, `window.current()`, and
  `window.open()`.
- Produces: `overlay.open(source_bufnr) -> report_bufnr?, winid?`; successful calls preserve the current
  integer returns and contained UI failures return `nil, nil`.
- Task 6 extends the controller with refresh, copy, source invalidation, and generation transitions.

- [ ] **Step 1: Replace the old plain-line expectation with failing dashboard integration specs**

Keep every existing `overlay.collect` test. Replace `overlay.lines` tests with renderer specs already
owned by `spec/ui_render_spec.lua`. Update `overlay.open` to assert:

```lua
report_buf, win = overlay.open(source_buf)
assert.is_true(vim.api.nvim_win_is_valid(win))
assert.equals("muster", vim.bo[report_buf].filetype)
local text = table.concat(vim.api.nvim_buf_get_lines(report_buf, 0, -1, false), "\n")
assert.is_truthy(text:find("muster.nvim", 1, true))
assert.is_truthy(text:find("Active", 1, true))
assert.is_truthy(text:find("lua_ls", 1, true))
```

Before production code, write one complete controller matrix:

- Capture the exact `window.open` options: canonical `source_bufnr`, a runtime UI copy, and callable
  `on_resize`/`on_error`. Assert `window, created=true` binds exactly one active controller only after
  highlight setup, all mapping installation, and first draw succeed. Invoke both callbacks and prove
  valid resize requests one redraw while error retires/fails once.
- Stub `created=false` and prove overlay focuses/returns the existing buffer/window IDs without replacing
  source/UI/callback/controller state, installing mappings, drawing, or resolving versions. Also cover the
  real early `window.current()` singleton path before collection.
- For default and overridden configs, deep-copy runtime UI then force `keymaps.refresh=false` and
  `keymaps.copy_path=false` without mutating `config.ui()`. Assert neither mapping is installed and neither
  configured/default key nor action text appears in normal footer/help. All UI-5 actions remain advertised
  and functional.
- Install each basic action from string, list, and `false` mapping forms. Assert default and remapped close
  semantics and absent disabled mappings by invoking buffer-local callbacks.
- Table-drive action transitions. Tab selection sets tab and closes Help only when state changes; same tab
  outside Help is no-op. Next/previous cycle tabs and close Help. Details toggles only an entry at cursor.
  Help-only open captures selection and opens the child directly; Help-only close focuses main. Neither
  Help-only direction increments revision, schedules, or draws main. Accepted search changes query and
  closes Help. Other accepted render-state mutations capture selected identity, increment revision exactly
  once, and schedule once. No-op, invalid-row, cancellation, same query, over-limit/rejected prompt, and
  close do not increment revision or schedule. Close clears active controller, invalidates callbacks, and
  closes main and Help without a redraw.
- For every action assert resulting fields, revision delta, selected identity, redraw count, and cursor
  identity/fallback. Exercise filtering and resize with a selected non-first row.
- Search prompt fixtures cover string/list/false mappings; cancel; empty clear; exact 256-byte accept;
  257-byte reject; out-of-order/newer prompt; completion after close; synchronous success; ordinary throw;
  and callback-then-throw. Ordinary and invoke-then-throw rejection invalidate the token, discard buffered
  values, preserve query/revision/controller, draw zero times, and emit exactly one WARN. Accepted sync or
  async completion settles once; duplicate/stale callbacks no-op.
- Scheduler fixtures cover accepted async, accepted synchronous, rejection, callback-then-throw, duplicate,
  and late callback. Accepted modes draw exactly once. Rejection and invoke-then-throw draw zero, call
  `fail_once` exactly once, clear `redraw_pending`, and make later callbacks inert.
- Fail initial highlight setup, window open, initial render/draw, and each mapping installation separately.
  Each returns `nil,nil`, emits one ERROR, clears active controller, closes all acquired resources, and
  leaves every captured callback inert with original-error precedence.
- Version fixtures deduplicate found identities across Active/All and invoke once each. Cover synchronous
  success, asynchronous success, ordinary resolver throw, callback-then-throw, duplicate callback, and
  completion after direct/external close. Each invocation buffers pre-return callbacks and accepts exactly
  one only after successful return; throw discards buffered completion and fails open/controller once.
  Accepted live completion captures selection, increments revision once, stores one version, schedules one
  redraw, and preserves cursor identity.
- Preserve every existing `M.collect()` behavior and record adapter buffer IDs for `open()`, `open(0)`,
  explicit source, focus changes, and invalid input. No adapter ever receives report buffer or invalid ID.

- [ ] **Step 2: Add failing no-provisioning assertions for every interaction**

Install active bare-require traps for the complete authority entry chain:

```lua
local blocked = {
  "muster.runner",
  "muster.automatic",
  "muster.report",
  "muster.enrich",
  "muster.handoff.mason",
}
local saved_loaded, saved_preload, tripped = {}, {}, {}
for _, name in ipairs(blocked) do
  saved_loaded[name] = package.loaded[name]
  saved_preload[name] = package.preload[name]
  package.loaded[name] = nil
  package.preload[name] = function()
    tripped[name] = true
    error("forbidden dashboard require: " .. name)
  end
end
```

Exercise open, every UI-5 mapping, search completion, asynchronous version completion, resize, close,
and reopen. Assert `tripped` remains empty. Then run a control `pcall(require, name)` for each blocked
module and assert its trap fires, proving the sentinel is active. Restore both `package.loaded` and
`package.preload` for every name in protected cleanup. UI-6 extends the same trap fixture through refresh
and copy.

- [ ] **Step 3: Run the overlay spec and verify the old UI fails expectations**

```bash
nix develop --command busted spec/overlay_spec.lua
```

Expected: FAIL because the current overlay has no tabs, help, details, search, or singleton controller.

- [ ] **Step 4: Refactor overlay state without changing collection**

Keep `key`, sorting, live collection, and `M.collect()` behavior. Remove `row()`, `section()`, `M.lines()`,
`report_buffer()`, `replace_lines()`, and direct `nvim_open_win()` use.

Canonicalize before any adapter call. Resolve nil or 0 with `nvim_get_current_buf()`, require an integer
valid buffer, and contain invalid input as `nil, nil` before calling `M.collect()`. Store
`collected.bufnr`, never the raw argument:

```lua
local canonical = source_bufnr
if canonical == nil or canonical == 0 then
  canonical = vim.api.nvim_get_current_buf()
end
if type(canonical) ~= "number" or canonical % 1 ~= 0 or not vim.api.nvim_buf_is_valid(canonical) then
  vim.notify("muster: cannot open dashboard for an invalid source buffer", vim.log.levels.ERROR, {
    title = "muster",
  })
  return nil, nil
end
local collected = M.collect(canonical)
local configured_ui = require("muster.config").ui()
local runtime_ui = vim.deepcopy(configured_ui)
runtime_ui.keymaps.refresh = false
runtime_ui.keymaps.copy_path = false
local state = {
  source_bufnr = collected.bufnr,
  view = collected,
  ui = runtime_ui,
  tab = "active",
  query = "",
  showing_help = false,
  expanded_key = nil,
  selected_key = nil,
  versions = {},
  source_error = nil,
  generation = 1,
  revision = 1,
  search_request = 0,
}
```

Before collection, call `window.current()`. If valid, focus it and return its exact `buf,win` without
collecting or altering controller state.

For a new controller, create `on_resize` and `on_error` closures that first require
`active_controller == controller`, `not controller.failed`, and a valid matching window. Inside one
protected initial-open transaction, call `render.setup_highlights()` and then call exactly:

```lua
local dashboard, created = window.open({
  source_bufnr = collected.bufnr,
  ui = runtime_ui,
  on_resize = function(instance)
    if active_controller == controller and controller.window == instance and not controller.failed then
      request_redraw(controller)
    end
  end,
  on_error = function(err)
    fail_once(controller, err)
  end,
})
```

A defensive `created=false` result focuses/returns that instance and performs no mapping, draw, resolver,
or controller replacement. For `created=true`, assign `controller.window`, install every UI-5 mapping,
perform initial render/draw, and invoke every deduplicated resolver through the buffered settlement barrier
from Step 7. Resolver callbacks remain buffered while startup is uncommitted. Only after every resolver
invocation returns successfully publish `active_controller=controller`, mark startup committed, and flush
each buffered completion once. Any failure clears controller identity, invalidates tokens, closes acquired window
resources, emits one ERROR notification, and returns `nil,nil` with original-error precedence. Normal
close clears active identity before `window:close()`; external retirement is detected by every callback
and by the next `open()`, which clears stale controller identity before creating a replacement.

- [ ] **Step 5: Implement render scheduling and selection tracking**

Store the most recent `muster.UiRender`. Before a state transition, map `window:cursor_line()` through
`output.row_by_line` and save its key; increment `state.revision` after each accepted mutation. Route the
initial draw and every later draw through one `draw_protected()` function:

```lua
local function draw_protected(controller)
  local ok, err = xpcall(function()
    local output = render.render(controller.state, controller.window:content_width())
    controller.window:draw(output, controller.state.selected_key)
    controller.output = output
  end, debug.traceback)
  if not ok then
    controller:fail_once(err)
  end
end
```

`fail_once()` atomically marks failed, clears active identity and `redraw_pending`, increments search
request/generation to invalidate callbacks, closes window resources, and emits one ERROR notification.
Every later callback no-ops.

Implement `request_redraw()` with an acceptance barrier. Set `redraw_pending=true` before `pcall(vim.schedule,
callback)`. A callback arriving before the scheduler returns records one buffered invocation and does not
draw. After return: if scheduling threw, discard the buffer, clear pending, and call `fail_once` once; if
it returned and a callback was buffered, execute exactly one draw; otherwise the later async callback
executes once. The callback first consumes/clears pending, so duplicate/late invocations no-op.
Callback-then-throw therefore draws zero and fails once. Normal async and accepted synchronous modes draw
exactly once. A resize callback uses the same barrier and never recollects or resolves versions.

Implement only against the complete prewritten failure/cursor specs. Any renderer/window draw failure
flows through `fail_once` after UI-4 has restored/retired its resources. Selection capture occurs before
each accepted mutation and the rendered selected identity or renderer anchor determines the final cursor.

- [ ] **Step 6: Install configured basic actions**

Expand each `muster.UiKeymap` value into zero or more mappings and install descriptions for:

- close;
- Active, All, and Issues;
- next and previous tab;
- details;
- help;
- search.

Use one transition helper that captures selected identity, applies a mutation, and only when the mutation
returns `changed=true` increments revision and requests one redraw:

- Active/All/Issues set the requested tab and clear help; same tab outside help is no-op.
- next/previous cycle `active -> all -> issues`, clear help, and always change.
- details acts only on the current entry row, toggles that key, and is otherwise no-op.
- help captures selection and opens/closes the separate child directly while preserving
  tab/query/expanded key and main revision/render bytes.
- close clears active identity, invalidates tokens, and closes immediately with no revision/redraw.

Each search action increments `search_request` and captures token plus generation. Invoke
`vim.ui.input({ prompt = ui.labels.search_prompt, default = state.query }, callback)` through a return
barrier. A pre-return callback is buffered. If invocation returns, settle that value once; if ordinary or
callback-then-throw occurs, discard any buffer, increment the token again, preserve controller/query/
revision, draw zero, and emit one WARN. A settled callback still requires active identity, valid matching
window, generation, newest token, and not-yet-settled. Nil cancellation and same query are no-op. Empty
string clears a nonempty query. A string of at most 256 bytes sets query and clears help through the
transition helper; over-limit/non-string values emit one WARN and do not mutate or redraw. Duplicate,
out-of-order, stale, and post-close callbacks no-op.

Expand string/list mappings into one callback per lhs and install no mapping for `false`. Enabled close
mappings always close; defaults are `q`/`<Esc>`, while explicit config may replace/disable them. Keep
runtime refresh/copy keymaps false, so neither action is mapped or advertised in UI-5.

- [ ] **Step 7: Resolve versions with close-safe callbacks**

Deduplicate found entries across Active then unseen Other identities. For each identity create a
not-settled record and invoke `version.resolve()` through a return barrier while controller startup remains
uncommitted. Capture controller identity and generation. A callback before return is buffered; after a
successful return it is eligible to settle once. Duplicate callbacks are ignored. If resolver throws,
discard its buffered callback, invalidate all resolver records, fail the initial open once, close resources,
and return `nil,nil`; callback-then-throw never mutates versions.

After every resolver invocation returns successfully, publish the active controller and flush buffered
callbacks. A live completion still requires matching active controller/generation, valid window, and
unsettled identity. It captures selection, stores one version, increments revision once, and requests one
redraw. Asynchronous/synchronous completion after commit behaves identically. Completion after direct or
external close, duplicate completion, or callback from a failed startup no-ops.

- [ ] **Step 8: Run direct and regression checks**

```bash
nix develop --command busted spec/overlay_spec.lua spec/ui_render_spec.lua spec/ui_window_spec.lua
nix develop --command busted spec/plugin_spec.lua spec/runner_spec.lua spec/automatic_spec.lua
nix develop --command stylua --check lua/muster/overlay.lua spec/overlay_spec.lua
nix develop --command selene lua/muster/overlay.lua spec/overlay_spec.lua
nix develop --command scripts/typecheck
```

Expected: all commands exit 0; safety sentinels remain unreachable.

- [ ] **Step 9: Commit UI-5**

```bash
git add lua/muster/overlay.lua spec/overlay_spec.lua
git commit -m "feat(overlay): add interactive dashboard"
```

**Acceptance:** Direct prewritten specs prove canonical single-controller open, exact UI-4 callbacks/
returns, hidden UI-6 actions, transactional initial setup/mappings/draw/resolvers, exact scheduler/search/
version settlement across async/sync/reject/invoke-then-throw/late/duplicate modes, per-action revision and
no-op semantics, cursor preservation/fallback, and active preload traps. Existing collection remains
unchanged and no reporting/provisioning module is required or invoked.

**Rollback:** Revert UI-5 to restore the old overlay while retaining unused UI modules.

---

### Task 6: Refresh, Copy, and Asynchronous Safety

**Slice ID:** `UI-6`

**Outcome:** Refresh safely recollects the original source buffer, copy respects the active register,
source invalidation is explicit, and stale callbacks cannot affect a newer generation or closed view.

**Non-goals:** UI-6 does not change collection/probe behavior, config/renderer/window interfaces, search
matching, reporting/enrichment/Mason authority, or add any mutating action beyond refresh probe and
allowlisted register copy.

**Prerequisites:** UI-5 is integrated and independently `CONFIRMED` through main commit `1d995cf`; the
controller settlement and render-revision contracts are available; full Busted baseline is 452 successes
with a clean worktree.

**Exclusive ownership:** One UI-6 writer exclusively owns `lua/muster/overlay.lua` and
`spec/overlay_spec.lua`. No concurrent writer or main-session edit may touch these paths until review
completes.

**Execution budget:** One writer, nine TDD steps, focused security/integration suites, one static-check
set, and at most three materially changed claim-relevant fix/reverify passes. No external mutation beyond
the test-isolated register writes required by acceptance.

**Stop conditions:** Stop UI-6 if refresh can probe a noncanonical/report buffer, if old generation/search/
version callbacks can settle, if copy can target a special register or unsafe/stale path, if no-provision
traps are weakened, or when the fix/reverify budget is exhausted.

**Files:**
- Modify: `lua/muster/overlay.lua`
- Modify: `spec/overlay_spec.lua`

**Interfaces:**
- Consumes: the UI-5 controller and render metadata.
- Produces: configured `refresh` and `copy_path` actions and complete generation semantics.

- [ ] **Step 1: Add failing refresh and generation specs**

Before production code, prove UI-6 restores actions from a fresh `vim.deepcopy(config.ui())` instead of
UI-5's forced-false runtime copy. Table-drive default, remapped string, list, and `false` refresh/copy
mappings. Assert installed callbacks and exact normal-footer/help hints use configured keys; every list
lhs invokes the same action; disabled actions have no mapping/hint; `config.ui()` remains unchanged.

Use an adapter whose probe result changes between calls and record every `probe`/`live` buffer ID. Change
focus to the dashboard before refresh. Table-drive exact refresh outcomes from a state containing tab,
query, `showing_help`, expanded key, selected identity, versions, source error, generation, revision, and
search request:

- Success always probes only the original canonical ID, increments generation/revision/search token by
  exactly one, immediately replaces view, clears versions/source error, preserves tab/query/help, keeps
  expanded/selected identities only when present, schedules one redraw, and starts current-generation
  resolvers. A later success clears any prior refresh error.
- Invalid/deleted source calls no collector, increments the three counters once, preserves last view,
  versions, tab/query/help/expanded/selection, sets one deterministic source error, and schedules one
  redraw. Repeated invalid refresh does not duplicate text but still has the exact counter deltas.
- Throwing `M.collect` and a returned `view.bufnr` mismatch are contained identically to invalid source,
  preserve the last snapshot/versions, never probe/substitute report buffer, expose one bounded error in
  Issues, and never escape the mapping callback.

Assert outstanding search prompts, old version records, and old scheduled redraws are invalidated at the
start of every refresh. Cursor identity remains when present and falls back to the renderer tab anchor
when removed.

- [ ] **Step 2: Add failing source-buffer invalidation specs**

Add refresh-generation settlement specs before RED:

- Start old-generation async version, search, and scheduled redraw callbacks; refresh; then invoke each old
  callback and prove zero state mutation, draw, notification, or pending-token consumption.
- For current-generation version resolution cover synchronous, asynchronous, ordinary throw,
  callback-then-throw, duplicate, post-close, and burst completions. Reuse UI-5's return barrier per
  identity and require successfully returned current-generation completion before settlement.
- On refresh resolver throw or callback-then-throw, discard buffered/identity records and enter
  `fail_once` exactly once; later callbacks are inert. Successful sync/async completions settle once.
- Bind every refresh redraw request to both the existing unique scheduler token and captured generation.
  An old-generation scheduled callback cannot clear/consume a current token. A burst of current-generation
  version completions plus the base refresh request produces exactly one current-generation draw.
- After direct/external close, all refresh/search/version/scheduler callbacks are inert.

- [ ] **Step 3: Add failing copy-path specs**

Stub `vim.fn.setreg` and `vim.notify` with protected restoration. Exhaust the allowed active-register
set: unnamed `"`, every `a-z`, `A-Z`, `0-9`, `+`, `*`, `-`, and `_`. Exhaust special/unsafe values `=`,
`:`, `/`, `.`, `%`, `#`, `~`, empty, multi-character, and non-string. Allowed members receive the exact
validated bytes; every rejection writes zero registers and attempts one protected WARN.

Path selection is exact: if `probe.path ~= nil`, validate that preferred value and refuse on any defect;
fall back to `realpath` only when `path` is absent. Cover non-string, empty, exact 4096-byte acceptance,
4097-byte rejection, every C0 U+0000-U+001F, DEL, every C1 U+0080-U+009F, and bidi U+061C, U+200E,
U+200F, U+202A-U+202E, U+2066-U+2069. Preserve valid Unicode/raw bytes unchanged.

Treat `setreg` as successful only when `pcall` succeeds and its return is numeric zero. Cover throw,
`-1`, `false`, and nil returns; each emits protected WARN and no INFO. INFO occurs only after confirmed
write. Throwing INFO/WARN notifications never escape the mapping callback or cause a second write.

Increment controller revision without drawing and assert stale `output.revision` refuses copy with WARN;
after matching render it succeeds. Copy command-like text into an allowlisted named register in isolated
Neovim and prove no command/expression executes. Assert source buffer unchanged. Extend active preload
traps through enabled refresh/copy and run controls proving the traps are active.

- [ ] **Step 4: Run the overlay spec and verify the missing-action failures**

```bash
nix develop --command busted spec/overlay_spec.lua
```

Expected: FAIL because refresh and copy mappings/actions are not implemented and callbacks have no
refresh generation barrier.

- [ ] **Step 5: Implement generation-bound version resolution**

Generalize UI-5's per-identity resolver return barrier as `resolve_versions(controller, generation)`.
Every record captures controller/generation and buffers pre-return callback. Ordinary throw and
callback-then-throw discard that record and call `fail_once` once; only a successfully returned invocation
may settle once. A completion additionally requires active controller, matching current generation, valid
window, and unsettled record. Duplicate/stale/post-close callbacks no-op.

At refresh start increment generation, revision, and `search_request` exactly once and invalidate all old
resolver/search records before collection. Bind `request_redraw(controller, generation)` tokens to the
captured generation as well as unique request identity, so old callbacks cannot clear newer pending work.
On successful collection clear versions immediately, schedule the base current-generation draw, and start
the new resolver set; completion increments revision only after all checks and coalesces into the same
current-generation pending draw.

- [ ] **Step 6: Implement refresh and source invalidation**

Remove UI-5's two forced-false assignments and derive each controller's runtime UI from a fresh full
`vim.deepcopy(config.ui())`. Install refresh/copy through the existing string/list/false mapping expansion;
renderer footer/help therefore use the same enabled config. Never mutate `config.ui()` snapshots.

Refresh first captures selection and invalidates old generation/search/resolver/redraw records with exact
counter deltas. Use only the canonical positive integer stored at open; never pass nil/0 or current/report
buffer. If valid, call `M.collect(source_bufnr)` through `pcall` and require `collected.bufnr` to equal the
canonical ID.

On valid matching success: replace view, clear versions/source error, preserve tab/query/help, retain
expanded/selected key only if present, schedule one generation-bound draw, and start current-generation
resolvers. On invalid source, throw, or mismatch: keep prior view and versions plus interaction state, set
one bounded deterministic `source_error`, schedule one draw, and return from the mapping callback without
throwing. Repeated failure updates counters but never duplicates the error. A later success clears it.

- [ ] **Step 7: Implement active-register path copy**

Require `controller.output.revision == controller.state.revision` before consulting current row metadata;
stale output gets protected WARN and zero writes. Select preferred `probe.path` whenever it is non-nil;
fall back to `probe.realpath` only when path is absent. Validate a non-empty string of at most 4096 bytes
against the exact prohibited C0/DEL/C1/bidi set. An invalid present path refuses copy without fallback.

Allow only register `"`, one ASCII letter, one ASCII digit, `+`, `*`, `-`, or `_`. Reject every other
value with protected WARN and zero writes. Call `vim.fn.setreg(register, value)` through `pcall` and accept
only numeric return zero. Throw/nonzero/false/nil results emit protected WARN. Call protected INFO only
after confirmed write. Notification failure is contained and never retries the sink. Copy action never
changes controller/source state or schedules redraw.

- [ ] **Step 8: Run direct, safety, and static checks**

```bash
nix develop --command busted spec/overlay_spec.lua spec/ui_render_spec.lua spec/ui_window_spec.lua
nix develop --command busted spec/plugin_spec.lua spec/runner_spec.lua spec/automatic_spec.lua spec/handoff_mason_spec.lua
nix develop --command stylua --check lua/muster/overlay.lua spec/overlay_spec.lua
nix develop --command selene lua/muster/overlay.lua spec/overlay_spec.lua
nix develop --command scripts/typecheck
nix develop --command busted
```

Expected: all commands exit 0; stale callbacks retain only current-generation values; preload traps stay
untouched; full suite has 0 failures and 0 errors.

- [ ] **Step 9: Commit UI-6**

```bash
git add lua/muster/overlay.lua spec/overlay_spec.lua
git commit -m "feat(overlay): add dashboard read-only actions"
```

**Acceptance:** Full config re-enables only configured refresh/copy mappings and shared hints without
mutation. Every refresh outcome uses the canonical source, has exact counter/snapshot/error semantics,
and binds resolver/scheduler/search callbacks to current generation. Exhaustive register/path/sink tests
prove only allowlisted inert registers receive confirmed validated raw writes, invalid preferred paths do
not fall back, notifications are contained, command text never executes, stale metadata refuses copy,
preload traps remain active, and cursor identity/fallback are direct.

**Rollback:** Revert UI-6; UI-5 remains a functioning dashboard without refresh/copy.

#### UI-6A Follow-up Gate: Real Dashboard Flow Evidence

**Outcome:** One named real-Neovim Busted example proves the complete dashboard interaction at wide and
compact dimensions before documentation claims it.

**Non-goals:** No production behavior, config, renderer, window, documentation, or authority change. If
the test exposes a runtime defect, stop and reopen UI-6 implementation/review rather than weakening the
assertion.

**Prerequisites:** UI-6 is integrated and independently `CONFIRMED` through main commit `9122d55`; full
suite is 489 successes; main is clean.

**Exclusive ownership:** One test-only UI-6A writer owns only `spec/overlay_spec.lua` until review and
verification complete.

**Execution budget:** One writer, one integration example, focused/full verification, one review, and at
most three materially changed fix/reverify passes.

**Stop conditions:** Stop if the real modules cannot complete the flow, if no-provision traps fire, if
source/cursor/extmark assertions fail, if production code is required without reopening UI-6 scope, or if
the budget is exhausted.

- [ ] **Step A1: Add one named real-Neovim flow example**

Add exactly `it("runs the complete dashboard flow at wide and compact widths", function() ... end)` to
`spec/overlay_spec.lua`. Use real `muster.overlay`, `muster.ui.render`, and `muster.ui.window`; only adapter,
version resolver, `vim.ui.input`, `setreg`, notification, authority modules, and an observation-only
wrapper around the real `render.render` may use protected test seams. The render wrapper must call the
real function unchanged and record only input/output revision metadata. For each initial width 120 and 50 with a fixed usable height:

1. create a source buffer with stable lines/filetype and open the real dashboard with backdrop disabled;
2. assert 120 uses the four-column heading and 50 uses compact physical/virtual layout with every extmark
   line/byte range valid;
3. invoke the actual buffer-local mappings through All, selected-row details, literal search, help, help
   return, refresh, and path copy; then while the dashboard remains open change columns from 120 to 50
   or from 50 to 120 and only then emit `VimResized`, before close and reopen;
4. after each redraw use `vim.wait` and assert visible state, selected tool identity/cursor or documented
   anchor fallback, stable window dimensions, and direct equality between the observation wrapper's latest
   `state.revision` and returned `output.revision`. Assert every expected redraw adds exactly one matching
   revision record and no no-op stage adds one. After resize assert the
   exact newly computed real-window geometry, opposite wide/compact layout, unchanged source/revision,
   preserved selection/anchor, and valid extmark line/byte ranges;
5. assert refresh reprobes only the original source, copy receives the expected raw path, source lines
   never change, and close/reopen leaves no old main/backdrop/buffer/augroup resource;
6. run active preload traps for runner/automatic/report/enrich/Mason handoff through the full flow and
   prove controls fire only when directly required.

Use protected cleanup to restore editor dimensions, modules, mappings, registers, notifications, source
buffers, windows, highlights, and all test seams after either success or assertion failure.

- [ ] **Step A2: Run the named focused example and full suite**

```bash
nix develop --command busted --filter=runs%s+the%s+complete%s+dashboard%s+flow%s+at%s+wide%s+and%s+compact%s+widths spec/overlay_spec.lua
nix develop --command stylua --check spec/overlay_spec.lua
nix develop --command selene spec/overlay_spec.lua
nix develop --command busted
```

Expected: the named command runs exactly one success; static checks exit zero; full suite adds exactly one
success with 0 failures/errors.

- [ ] **Step A3: Commit and independently review/verify the evidence**

```bash
git add spec/overlay_spec.lua
git commit -m "test(ui): cover complete dashboard flow"
```

Task review must return spec/quality pass, and a fresh verifier must independently run the named example
at both dimensions and return `CONFIRMED` before UI-7 can become READY.

**Acceptance:** A single identifiable committed example and selector prove the complete flow, both
initial layouts and real 120↔50 resize transitions, source integrity, cursor/anchor/revision behavior,
extmark validity, cleanup/reopen, and no-provision boundary without changing production code.

**Rollback:** Revert only the UI-6A test commit that changes `spec/overlay_spec.lua`; integrated UI-6
production and all prior confirmed slices remain unchanged.

---

### Supplemental Help Overlay Lifecycle

The reviewed Help overlay is a separate child lifecycle spanning `lua/muster/ui/help.lua`,
`lua/muster/overlay.lua`, `lua/muster/ui/render.lua`, `spec/ui_help_spec.lua`, `spec/overlay_spec.lua`, and
`spec/ui_render_spec.lua`.

- Help-only open captures the selected tool, sets `showing_help=true`, renders and opens the child directly,
  and preserves `state.revision`, main-buffer bytes, and the main draw/scheduler counts.
- Fixed child mappings and visible text are always exactly `q/<Esc>  close Help`. Configured dashboard
  mappings remain in full Help; configured close is labeled `close dashboard` and may be disabled or
  remapped without changing the fixed child controls.
- Help-only close sets `showing_help=false`, focuses the main window, and performs no revision increment,
  scheduled redraw, or main draw. Parent refresh, version settlement, and resize may redraw an open child
  with the current revision; resize recomputes the child at 80% of the resized parent.
- The Help module mirrors the main window's retained retirement model: module-local `active` and `retiring`,
  resource IDs cleared only after success or observed invalidity, idempotent two-pass cleanup, retirement
  drains from `current()` and `open()`, initiating-error precedence, and reopen blocked by persistent
  cleanup failure.
- Construction, draw, mapping, resize, child window/buffer close, parent close, and main-controller close
  have direct resource, augroup, namespace, focus, selection, and no-orphan assertions.
- The main chrome remains two centered header rows, centered tabs, and a centered stable default footer
  `/ Muster search:   ? Help`; active query text never changes the footer.

---

### Task 7: Documentation and Full Verification

**Slice ID:** `UI-7`

**Outcome:** Public docs, generated vimdoc, LuaDoc, and direct documentation specs describe the complete
UI contract; all static and runtime gates pass.

**Non-goals:** UI-7 does not change runtime behavior, tests outside documentation assertions, CI workflow,
dependencies, authority surfaces, release automation, tags, pushes, PRs, or publishing.

**Prerequisites:** UI-1 through UI-6A are integrated and independently `CONFIRMED` through main commit
`dda1265`; full Busted baseline is 490 successes; main worktree is clean.

**Exclusive ownership:** One UI-7 writer exclusively owns `README.md`, `lua/muster/init.lua`,
`spec/documentation_spec.lua`, and generated `doc/muster.txt`. All other source/spec files are run-only;
no concurrent writer or main-session edit may touch owned paths until review completes.

**Execution budget:** One writer, ten TDD/documentation/verification steps, one documentation RED/green
cycle, one complete static/runtime gate set, and at most three materially changed claim-relevant
fix/reverify passes. No external mutation.

**Stop conditions:** Stop UI-7 if README/vimdoc/runtime contracts diverge, panvimdoc is not reproducible,
a required CI-equivalent gate fails outside owned documentation changes, any authority-surface diff is
nonempty, the final worktree is dirty, or the fix/reverify budget is exhausted.

**Files:**
- Modify: `README.md`
- Modify: `lua/muster/init.lua:8-20`
- Modify: `spec/documentation_spec.lua`
- Regenerate: `doc/muster.txt`
- Run without modifying: all `spec/*.lua`

**Interfaces:**
- Consumes: the final public configuration and dashboard behavior from UI-1 through UI-6.
- Produces: user-facing installation/configuration/interaction documentation and final acceptance
evidence.

- [ ] **Step 1: Add failing documentation assertions**

Before documentation changes, add a canonical README code block marker and a spec helper that extracts
the complete `require("muster").setup({ ui = ... })` block, transforms the setup argument into a returned
Lua table, executes it in the test sandbox, and asserts `opts.ui` is exactly `config.ui()`. The generated
vimdoc must contain the corresponding `>lua` block; assert every nested table/key and non-empty default
literal appears there. Removing, renaming, or misdefaulting any icon, label, adapter label, column,
detail label, or keymap must fail.

For both README and generated vimdoc, assert exact contract text for:

- Active/All/Issues semantics and stable unfiltered counts;
- compact rows, details, literal normalized 256-byte search, generated help, refresh, copy, resize, and
  singleton close/reopen;
- geometry defaults 0.8/0.8/rounded/60 and ratio-versus-fixed behavior;
- raw keymap source at most 64 bytes, normalized `vim.keycode` lhs at most 50 bytes, semantic collision
  rejection, string/list/`false` mappings, and every default action key;
- plain/acyclic/dense containers; labels 128, icons 32, border char 16, highlight 128; exact C0/DEL/C1 and
  U+061C/U+200E/U+200F/U+202A-U+202E/U+2066-U+2069 policy; adapter-key exception;
- inert register allowlist `"`, `a-z`, `A-Z`, `0-9`, `+`, `*`, `-`, `_`; rejected special registers;
  preferred path validation with realpath fallback only when path absent; 4096/4097 boundary; stale
  revision refusal; numeric-zero-only `setreg` success; protected WARN/INFO; failed writes leave registers
  unchanged; command-like text is inert;
- all highlight links: `MusterNormal/NormalFloat`, `MusterBackdrop/Normal`, `MusterHeader/Title`, active and
  inactive tabs, five status groups, adapter, version, muted, detail key, and search match;
- dashboard inspection never requires runner/automatic/report/enrich/Mason handoff and never installs,
  removes, updates, or reconfigures a package.

Keep the existing README Lua-block syntax test. Add a positive LuaDoc test that extracts the commented
`lua` block from `lua/muster/init.lua`, strips the `---` prefixes, parses it with `loadstring`, and asserts
it contains `ui`, width/height/border/backdrop, nested icons/labels/keymaps, and a valid compact setup call.

- [ ] **Step 2: Run documentation specs and verify failure**

```bash
nix develop --command busted spec/documentation_spec.lua
```

Expected: FAIL because README and vimdoc do not describe the dashboard or UI options.

- [ ] **Step 3: Document dashboard behavior and configuration in README**

Add a `Dashboard UI` section after setup/usage documentation containing:

- the Active, All, and Issues definitions;
- compact rows and expanded details;
- bounded literal search, generated help, canonical-source refresh, and path copy restricted to the
  allowlisted inert registers `"`, `a-z`, `A-Z`, `0-9`, `+`, `*`, `-`, and `_`;
- rejected special registers, unsafe/oversized paths, stale render metadata, and protected `setreg`
  failure behavior;
- default `q` / `<Esc>` close behavior and explicit remap/disable semantics;
- the complete default `ui` table from the approved spec;
- plain-container, size/control, semantic-key-collision, and `false` keymap validation rules;
- every `Muster*` highlight group and its default link;
- a direct statement that dashboard interactions never install or enter Mason handoff.

Keep all README Lua blocks valid Lua.

- [ ] **Step 4: Update public LuaDoc and regenerate vimdoc**

Add a compact `ui` example to `lua/muster/init.lua` without duplicating the full README reference. Then
run:

```bash
nix develop --command scripts/generate-vimdoc
nix develop --command scripts/check-vimdoc
```

Expected: `doc/muster.txt` changes once during generation; the subsequent check exits 0 with no diff.

- [ ] **Step 5: Run focused integration behavior at wide and narrow sizes**

Run the exact UI-6A example by name without editing its owning spec:

```bash
nix develop --command busted --filter=runs%s+the%s+complete%s+dashboard%s+flow%s+at%s+wide%s+and%s+compact%s+widths spec/overlay_spec.lua
nix develop --command busted spec/config_spec.lua spec/ui_render_spec.lua spec/ui_window_spec.lua spec/overlay_spec.lua spec/documentation_spec.lua
```

Expected: the first command runs exactly one success proving
`open -> All -> details -> search -> help -> return -> refresh -> copy -> resize -> close -> reopen` at
120 and 50 columns, including source integrity, cursor/anchor, extmark, cleanup/reopen, and no-provision
assertions. The second focused command passes all public-config, renderer, window, controller, and
documentation specs without UI-7 modifying runtime specs.

- [ ] **Step 6: Run the complete static verification set**

Run the applicable local equivalents of every CI static/documentation gate:

```bash
nix flake check --all-systems --no-build
nix develop --command actionlint .github/workflows/ci.yml
nix develop --command scripts/test-nix-netrc-override
nix develop --command scripts/test-workflow-action-guard
nix develop --command scripts/test-vimdoc-gate
nix develop --command scripts/check-vimdoc
nix develop --command shellcheck scripts/check-vimdoc scripts/generate-vimdoc \
  scripts/test-vimdoc-gate scripts/test-workflow-action-guard scripts/test-workflow-whitespace \
  scripts/test-nix-netrc-override scripts/test-debug-call-cli scripts/typecheck
nix develop --command stylua --check lua plugin spec scripts/check-debug-calls.lua \
  scripts/debug_call_audit.lua scripts/test-debug-call-audit.lua
nix develop --command selene lua plugin spec scripts/check-debug-calls.lua \
  scripts/debug_call_audit.lua scripts/test-debug-call-audit.lua
nix develop --command scripts/typecheck
nix develop --command nvim --clean --headless -u NONE -i NONE -l scripts/test-debug-call-audit.lua
nix develop --command scripts/test-debug-call-cli
nix develop --command nvim --clean --headless -u NONE -i NONE -l scripts/check-debug-calls.lua lua plugin
nix develop --command scripts/test-workflow-whitespace
```

Verify Vim help in a temporary runtime path:

```bash
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/doc"
cp doc/muster.txt "$tmp/doc/"
TMP_RTP="$tmp" nix develop --command nvim --clean --headless -i NONE \
  --cmd 'set loadplugins' \
  --cmd 'execute "set runtimepath^=" .. fnameescape($TMP_RTP)' \
  -c 'lua local ok = pcall(function() vim.cmd("helptags " .. vim.fn.fnameescape(vim.env.TMP_RTP .. "/doc")); vim.cmd("help muster"); assert(vim.endswith(vim.api.nvim_buf_get_name(0), "/doc/muster.txt")) end); if ok then vim.cmd("qa!") else vim.cmd("cquit") end'
test ! -e doc/tags
```

Expected: every command exits 0; all systems evaluate; Selene has zero errors/warnings; LuaLS has no
problems; vimdoc regeneration is byte-clean; Vim help loads; no `doc/tags` or other artifact remains.

- [ ] **Step 7: Run the full Busted suite**

```bash
nix develop --command busted
```

Expected: all tests succeed with 0 failures and 0 errors.

- [ ] **Step 8: Inspect the final diff and safety boundaries**

```bash
git diff --check
git diff --stat b39befd..HEAD
git diff b39befd..HEAD -- \
  lua/muster/check.lua lua/muster/probe.lua lua/muster/host.lua lua/muster/source.lua \
  lua/muster/adapters lua/muster/version.lua lua/muster/enrich.lua lua/muster/providers \
  lua/muster/report.lua lua/muster/runner.lua lua/muster/automatic.lua \
  lua/muster/handoff/mason.lua lua/muster/mason_result.lua lua/muster/mason_source.lua
git status --short
```

Expected: whitespace check exits 0; authority-surface diff is empty; only the uncommitted UI-7
documentation changes remain before commit.

- [ ] **Step 9: Commit UI-7**

```bash
git add README.md lua/muster/init.lua spec/documentation_spec.lua doc/muster.txt
git commit -m "docs(ui): document muster dashboard"
```

- [ ] **Step 10: Re-run final-byte verification**

```bash
nix flake check --all-systems --no-build
nix develop --command actionlint .github/workflows/ci.yml
nix develop --command scripts/test-nix-netrc-override
nix develop --command scripts/test-workflow-action-guard
nix develop --command scripts/test-vimdoc-gate
nix develop --command scripts/check-vimdoc
nix develop --command shellcheck scripts/check-vimdoc scripts/generate-vimdoc \
  scripts/test-vimdoc-gate scripts/test-workflow-action-guard scripts/test-workflow-whitespace \
  scripts/test-nix-netrc-override scripts/test-debug-call-cli scripts/typecheck
nix develop --command stylua --check lua plugin spec scripts/check-debug-calls.lua \
  scripts/debug_call_audit.lua scripts/test-debug-call-audit.lua
nix develop --command selene lua plugin spec scripts/check-debug-calls.lua \
  scripts/debug_call_audit.lua scripts/test-debug-call-audit.lua
nix develop --command scripts/typecheck
nix develop --command nvim --clean --headless -u NONE -i NONE -l scripts/test-debug-call-audit.lua
nix develop --command scripts/test-debug-call-cli
nix develop --command nvim --clean --headless -u NONE -i NONE -l scripts/check-debug-calls.lua lua plugin
nix develop --command scripts/test-workflow-whitespace
nix develop --command busted --filter=runs%s+the%s+complete%s+dashboard%s+flow%s+at%s+wide%s+and%s+compact%s+widths spec/overlay_spec.lua
nix develop --command busted

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/doc"
cp doc/muster.txt "$tmp/doc/"
TMP_RTP="$tmp" nix develop --command nvim --clean --headless -i NONE \
  --cmd 'set loadplugins' \
  --cmd 'execute "set runtimepath^=" .. fnameescape($TMP_RTP)' \
  -c 'lua local ok = pcall(function() vim.cmd("helptags " .. vim.fn.fnameescape(vim.env.TMP_RTP .. "/doc")); vim.cmd("help muster"); assert(vim.endswith(vim.api.nvim_buf_get_name(0), "/doc/muster.txt")) end); if ok then vim.cmd("qa!") else vim.cmd("cquit") end'
test ! -e doc/tags

git diff --check
git diff b39befd..HEAD -- \
  lua/muster/check.lua lua/muster/probe.lua lua/muster/host.lua lua/muster/source.lua \
  lua/muster/adapters lua/muster/version.lua lua/muster/enrich.lua lua/muster/providers \
  lua/muster/report.lua lua/muster/runner.lua lua/muster/automatic.lua \
  lua/muster/handoff/mason.lua lua/muster/mason_result.lua lua/muster/mason_source.lua
git status --short
```

Expected: all final-byte gates exit 0, authority diff is empty, no generated artifact remains, and
`git status --short` prints nothing.

**Acceptance:** README, LuaDoc, and generated vimdoc match runtime behavior; all focused and full project
gates pass on the committed bytes; authority surfaces remain unchanged.

**Rollback:** Revert UI-7 to remove docs only, or revert UI-7 through UI-1 in reverse order to restore the
pre-dashboard repository.

## Final Execution Gate

Implementation is complete only when all slice acceptance statements hold, the final-byte verification
in UI-7 passes, the worktree is clean, and the read-only safety diff confirms no authority surface was
changed. Do not push, publish, tag, or release as part of this plan.
