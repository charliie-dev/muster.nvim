# muster.nvim

Call the roll on the tools your Neovim config declares.

You tell muster which LSP servers, formatters, linters, DAP adapters, and none-ls
sources your configuration expects. It reports whether they are available,
where found executables came from, and which known providers may supply missing
ones.

muster requires Neovim 0.12 or newer. It is read-only by default: inspection
never installs, removes, or reconfigures anything. The only provisioning path is
an explicit `install = "mason"` opt-in on the automatic startup run.

## Installation

### Read-only mode

With the lazy.nvim plugin manager, the options table below is passed to muster's
setup function:

```lua
{
  "charliie-dev/muster.nvim",
  lazy = false,
  opts = {
    lsp = { "lua_ls", "gopls" },
    conform = { "stylua" },
    lint = { "selene" },
    dap = { "codelldb" },
  },
}
```

### Optional Mason mode

Load and set up Mason before muster. Append Mason's bin directory to the PATH environment variable.

```lua
{
  "mason-org/mason.nvim",
  lazy = false,
  opts = {
    PATH = "append",
  },
},
{
  "charliie-dev/muster.nvim",
  lazy = false,
  dependencies = { "mason-org/mason.nvim" },
  opts = {
    lsp = { "lua_ls", "gopls" },
    conform = { "stylua" },
    lint = { "selene" },
    dap = { "codelldb" },
    install = "mason",
  },
}
```

Append mode keeps system-provided tools first while leaving Mason-installed
tools discoverable. Prepend mode puts Mason first. Skip mode leaves Mason's bin
directory off the PATH environment variable.

## Configuration

A full setup can declare every built-in adapter and both options:

```lua
local null_ls = require("null-ls")
require("muster").setup({
  lsp = { "lua_ls", "gopls" },
  conform = { "stylua", "prettierd" },
  lint = { "selene" },
  dap = { "codelldb" },
  none_ls = {
    null_ls.builtins.formatting.stylua,
  },
  install = false,          -- false (default) or "mason"
  notify_on_startup = true, -- default; silent when nothing needs attention
})
```

Use the names and entries accepted by each host plugin. If the `none_ls` key is
omitted, muster reads the registered none-ls sources after `null-ls.setup()`.
All other lists are explicit; muster does not infer them from filetype mappings.

Third-party integrations use the same adapter interface and setup key:

```lua
require("muster").register({
  id = "guard",
  available = function()
    return true
  end,
  identity = function(entry)
    return entry.name
  end,
  probe = function(entry, bufnr)
    -- Return a muster.Probe for this entry and buffer.
  end,
  live = function(bufnr)
    -- Optional: return entries active in this buffer.
    return {}
  end,
})
require("muster").setup({
  guard = { { name = "example" } },
})
```

Adapter ids must be unique. An unregistered setup key is reported as a
configuration error rather than ignored.

## Using muster

### Commands and startup notification

- `:Muster` opens a fresh report for the current buffer. Its first section shows
  tools live in that buffer; the second shows all other declared tools.
- `:checkhealth muster` synchronously checks configuration and declared tools.
- After `VimEnter`, the automatic check can notify about missing, unknown,
  broken, or unverifiable tools and skipped host plugins. It omits found tools
  and is silent when nothing needs attention. Set
  `notify_on_startup = false` to disable only this notification.

Both commands are inspection surfaces: they do not run provider enrichment,
refresh Mason, or install anything.

### Lua API

Probe synchronously when raw availability is enough:

```lua
local result = require("muster").probe(0)
```

Check asynchronously when provider advice is wanted:

```lua
require("muster").check(0, function(result)
  -- Called once, after all read-only provider lookups have settled.
end)
```

`probe` and `check` emit no report and never hand tools to Mason. Their Result
contains declared entries, skipped adapters, the probed buffer number, and
notes. Each entry records its adapter, name, declared status, probe, and advice.

### Reading results

Probe status has five values:

| Status | Meaning |
| --- | --- |
| `found` | The executable resolved on `PATH`; its path and source are shown. |
| `missing` | A string command did not resolve; available provider advice is shown. |
| `unverifiable` | No safe external-tool verdict is available, such as for a function-form command or buffer-dependent predicate. |
| `unknown` | The host subsystem could not resolve or validate the entry. |
| `broken` | Host lookup, predicate, or command structure failed. |

For `unverifiable`, `unknown`, and `broken`, the recorded reason is authoritative.

Found executables are classified as `mason`, `nix`, `mise`, `brew`, `system`, or
`unknown` from their resolved paths. Source labels are hints, and every overlay
row keeps the path visible.

Advice is best effort and only enriches declared missing tools. It may identify
a Mason package, a nixpkgs attribute, or a mise backend from those providers'
machine-readable data. No unique match means no package is guessed. A tool that
is live in the current buffer but was never declared is display-only: it appears
in `:Muster`, receives no advice, and is never eligible for installation.

`:Muster` deliberately compares two different sets. **ACTIVE IN THIS BUFFER** is
queried from every registered adapter that implements `live`, including all five
built-ins, and can include undeclared tools. **EVERYTHING ELSE** contains
declared tools that are not live there. The command re-probes on every opening,
because formatter commands and other predicates can depend on the buffer.

## Installation authority

| Surface | Probe | Advice | Install |
| --- | --- | --- | --- |
| `:Muster` | Current buffer | None | No |
| `:checkhealth muster` | Current buffer | None | No |
| `probe()` | Synchronous | None | No |
| `check()` | Asynchronous | Read-only | No |
| Auto (`install = false`) | Yes | Read-only | No |
| Auto (`install = "mason"`) | Yes | Yes | **Yes** |

Only the automatic run with `install = "mason"` has provisioning authority. It
requires Mason to be loaded, `mason.setup()` to have run, and the Mason registry
to refresh successfully. muster does not force-load Mason. A missing prerequisite
or refresh failure degrades to reporting without installation.

The opted-in order is probe, registry refresh, enrichment, hand-off preparation,
reporting, then install dispatch. The reporting step completes before any install
is dispatched. Deliberately suppressing the startup notification does not suppress
installation when `install = "mason"` was explicitly opted in. Each package is
handled best-effort: platform support, registry state, or installation can still
fail, and one failure does not turn the reporting step into a success claim.
muster never automatically uninstalls or cleans up packages.

## Known limits

- Lazy host plugins are not force-loaded. Until a host plugin loads, its declared
  entries are skipped as "host plugin not loaded" rather than called typos.
- DAP has no external name catalog. Mason hand-off works only when an adapter's
  command is the actual tool binary; wrappers such as a Python interpreter may
  not map to a useful package.
- Function-form commands can depend on a real buffer. When muster cannot resolve
  one safely, it reports `unverifiable`, not `missing`.
- Overlay version probing is best effort. Its generic fallback tries
  `--version`, `version`, and `-version` only when `:Muster` is opened. It can
  miss date-only versions, and a tool's version command can have side effects.
- Source classification is path-prefix based. `/usr/local` can be labeled
  Homebrew when `HOMEBREW_PREFIX` is unset, and mise shim versions can remain
  cached until the shim changes; use the displayed path as the ground truth.

## Development

The pinned development shell contains Neovim, Busted, panvimdoc, the linters,
and LuaLS:

```sh
nix develop
nix develop --command busted
nix develop --command stylua --check lua plugin spec
nix develop --command selene lua plugin spec
nix develop --command scripts/typecheck
```

`README.md` is the sole handwritten user guide. Vim help is checked in at
`doc/muster.txt` and must never be edited directly. Regenerate it after every
README change:

```sh
nix develop --command scripts/generate-vimdoc
```

## License

muster.nvim is released under the [MIT License](LICENSE).
