# muster.nvim

Call the roll on the tools your Neovim config declares.

You tell muster which LSP servers, formatters, linters, DAP adapters, and none-ls
sources your configuration expects. It reports whether they are available,
where found executables came from, and which known providers may supply missing
ones.

muster requires Neovim 0.12 or newer. It is read-only by default: inspection
never installs, removes, or reconfigures anything. The only provisioning path is
an explicit `mason_install_fallback = true` opt-in on the automatic startup run.

## Installation

### Read-only mode

With lazy.nvim, muster can load on the first `BufReadPost`/`BufNewFile` event or
when `:Muster` is invoked. Lazy loads the dependencies before the plugin on
either trigger. Each dependency below is expected to have its own `opts` or
`config` that requires and configures the host module before muster's setup
runs; a bare repository dependency may not make that adapter available.

```lua
return {
  "charliie-dev/muster.nvim",
  event = { "BufReadPost", "BufNewFile" },
  cmd = "Muster",
  dependencies = {
    "neovim/nvim-lspconfig",
    "stevearc/conform.nvim",
    "mfussenegger/nvim-lint",
    "mfussenegger/nvim-dap",
  },
  opts = {
    lsp = {
      "lua_ls",
      { name = "jsonls", command = "vscode-json-language-server" },
      { name = "yamlls", command = "yaml-language-server" },
    },
    conform = { "stylua" },
    nvim_lint = {
      "selene",
      { name = "oxlint", command = "oxlint" },
    },
    dap = { "codelldb" },
    mason_install_fallback = false,
    notify_on_startup = true,
  },
}
```

### Optional Mason mode

Load and set up Mason as a dependency before muster on either the buffer-event
or `:Muster` trigger. Append Mason's bin directory to the PATH environment
variable. As in read-only mode, the listed host dependencies must have their own
`opts` or `config` that finishes host setup before muster runs.

```lua
return {
{
  "mason-org/mason.nvim",
  cmd = { "Mason", "MasonInstall", "MasonUninstall", "MasonUpdate" },
  opts = {
    PATH = "append",
  },
},
{
  "charliie-dev/muster.nvim",
  event = { "BufReadPost", "BufNewFile" },
  cmd = "Muster",
  dependencies = {
    "mason-org/mason.nvim",
    "neovim/nvim-lspconfig",
    "stevearc/conform.nvim",
    "mfussenegger/nvim-lint",
    "mfussenegger/nvim-dap",
  },
  opts = {
    lsp = {
      "lua_ls",
      { name = "jsonls", command = "vscode-json-language-server" },
      { name = "yamlls", command = "yaml-language-server" },
    },
    conform = { "stylua" },
    nvim_lint = {
      "selene",
      { name = "oxlint", command = "oxlint" },
    },
    dap = { "codelldb" },
    mason_install_fallback = true,
    notify_on_startup = true,
  },
},
}
```

Append mode keeps system-provided tools first while leaving Mason-installed
tools discoverable. Prepend mode puts Mason first. Skip mode leaves Mason's bin
directory off the PATH environment variable.

## Configuration

A full lazy.nvim spec can declare every built-in adapter and both options. Its
config callback runs after the dependencies when either the buffer event or the
`:Muster` command triggers the plugin:

```lua
return {
  "charliie-dev/muster.nvim",
  event = { "BufReadPost", "BufNewFile" },
  cmd = "Muster",
  dependencies = {
    "neovim/nvim-lspconfig",
    "stevearc/conform.nvim",
    "mfussenegger/nvim-lint",
    "mfussenegger/nvim-dap",
    "nvimtools/none-ls.nvim",
  },
  config = function()
    local null_ls = require("null-ls")
    require("muster").setup({
      lsp = {
        "lua_ls",
        { name = "jsonls", command = "vscode-json-language-server" },
        { name = "yamlls", command = "yaml-language-server" },
      },
      conform = { "stylua", "prettierd" },
      nvim_lint = {
        "selene",
        { name = "oxlint", command = "oxlint" },
      },
      dap = { "codelldb" },
      none_ls = {
        null_ls.builtins.formatting.stylua,
      },
      mason_install_fallback = false, -- default; true permits Mason installs
      notify_on_startup = true,       -- default; silent when nothing needs attention
    })
  end,
}
```

Use the names and entries accepted by each host plugin. If the `none_ls` key is
omitted, muster reads the registered none-ls sources after `null-ls.setup()`.
All other lists are explicit; muster does not infer them from filetype mappings.

LSP entries accept either a server name or an exact
`{ name = "server", command = "executable" }` map. A string declaration looks
up `vim.lsp.config[name]` and probes its static command. If that catalog command
is a function, muster does not invoke it and the entry is `unverifiable`. A table
declaration keeps `name` as the server identity but makes its explicit `command`
authoritative for PATH probing, provider advice, and Mason package mapping:

```lua
local lsp = {
  "lua_ls",
  { name = "jsonls", command = "vscode-json-language-server" },
  { name = "yamlls", command = "yaml-language-server" },
}
```

The explicit command must be a bare executable name, not a path, argument list,
or shell command. A readable `vim.lsp.config[name]` catalog entry is still
mandatory: the declaration supplies a probe prerequisite, not a new LSP server
configuration. In particular, function-form catalog commands such as `jsonls`
and `yamlls` may later select a project-local executable or another root-specific
transport. Finding the declared global command does not prove which transport
the LSP function will launch. muster never invokes the function, changes the
catalog entry, or enables the server.

`nvim_lint` entries accept a linter name or an exact `{ name, command }` map.
The string form uses the command in nvim-lint's linter definition; a
function-form command is `unverifiable` because muster does not invoke it. The
explicit form probes the named bare executable instead:

```lua
local nvim_lint = {
  "selene",
  { name = "oxlint", command = "oxlint" },
}
```

The named `lint.linters[name]` catalog entry must exist in both forms. An
explicit command is only a probe prerequisite; it neither defines the linter nor
proves the project-aware command nvim-lint will later choose. With
`mason_install_fallback = false`, a missing explicit command receives advice
only. With `true`, it is eligible for Mason installation. For a linter such as
oxlint that may select `node_modules/.bin/oxlint` per project, opting in can
therefore install a duplicate global tool even though nvim-lint would use the
project-local copy.

Conform declarations remain string-only formatter names. If local integration
settings call these lists `formatter_deps` and `linter_deps`, pass the former to
`conform` and the latter to `nvim_lint`; those setting names are not muster setup
keys.

The DAP setup key remains `dap`. Muster's built-in example declares only
`codelldb`, whose registered nvim-dap adapter exposes a tool executable.
`dap-go` and `dap-python` are language-plugin-owned integrations, not Muster
adapters or install declarations. Project-aware choices such as a user-approved
`uv` environment, `.env` interpreter, or ambient Python belong in that local
nvim-dap integration. Muster does not choose, approve, or provision them.

The removed `install` option is always rejected, including `install = false`.
The old `lint` setup key is also a rejected tombstone, including empty or false
values; rename it to `nvim_lint`. Use `mason_install_fallback = false` for
read-only operation or `true` for the single installation-capable automatic
path.

Third-party integrations use the same adapter interface and setup key. Register
them inside the lazy config callback before calling setup:

```lua
return {
  "charliie-dev/muster.nvim",
  event = { "BufReadPost", "BufNewFile" },
  cmd = "Muster",
  config = function()
    local muster = require("muster")
    muster.register({
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
    muster.setup({
      guard = { { name = "example" } },
    })
  end,
}
```

Adapter ids must be unique. An unregistered setup key is reported as a
configuration error rather than ignored.

## Using muster

### Commands and startup notification

- `:Muster` opens a fresh report for the current buffer. Its first section shows
  tools live in that buffer; the second shows all other declared tools.
- `:checkhealth muster` synchronously checks configuration and declared tools.
- When a lazy.nvim example is loaded by the first buffer event, the automatic
  check runs once after a UI attaches; `VimEnter` is the fallback when the plugin
  was already loaded, including in a headless session. If `:Muster` first loads
  and configures the plugin after `VimEnter`, setup schedules a separate
  automatic run. The command remains read-only, but that later automatic run can
  perform fallback installation when `mason_install_fallback = true`. The
  summary can notify about missing, unknown, broken, or unverifiable tools and
  skipped host plugins. It omits found tools and is silent when nothing needs
  attention. Set `notify_on_startup = false` to disable only this summary. Mason
  install lifecycle INFO/WARN/ERROR notifications remain enabled when
  installation authority is opted in.

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
| Auto (fallback `false`) | Yes | Read-only | No |
| Auto (fallback `true`) | Yes | Yes | **Yes** |

Only the automatic run with `mason_install_fallback = true` has provisioning
authority. It requires Mason to be loaded, `mason.setup()` to have run, and the
Mason registry to refresh successfully. muster does not force-load Mason. A
missing prerequisite or refresh failure degrades to reporting without
installation.

The opted-in order is probe, registry refresh, enrichment, hand-off preparation,
reporting, then install dispatch. Reporting completes before any install is
dispatched. muster uses Mason's generic package installer; it does not call a
mason-lspconfig install shortcut, run `:MasonInstall`, or directly enable an LSP
server. LSP activation remains the user's or mason-lspconfig's policy.

Each dispatched package produces an INFO start notification. Terminal
notifications and `:checkhealth muster` use the same result severity: only
`completed/found/full` is INFO, `completed/found/partial` is WARN, and every
other terminal result is ERROR. Automatic-run degradation is WARN; an automatic
or safe-context bridge failure is ERROR. These lifecycle notifications and
installation authority are independent of `notify_on_startup`; disabling the
startup summary suppresses neither.

Installation results have three independent axes:

- `outcome` is lifecycle progress: `planned`, `dispatched`, `verifying`,
  `completed`, `failed`, or `unknown`. `completed` means the installer callback
  returned success and the verification phase reached a terminal result,
  including when a verification safe-context bridge could not run or the
  verification deadline expired; by itself it is not success.
- `availability` is the post-install executable probe: `not_checked`, `found`,
  `missing`, `unverifiable`, `unknown`, or `broken`.
- `attestation` is the integrity proof: `not_checked`, `full`, `partial`, or
  `failed`. Reasons on availability and attestation remain independent.

These are all legal result shapes; malformed or stale combinations fail closed
to `unknown/not_checked/not_checked`:

```text
outcome | availability | attestation | level | detail
planned | not_checked | not_checked | INFO | none; internal state
dispatched | not_checked | not_checked | INFO | none; internal state
verifying | not_checked | not_checked | INFO | none; internal state
failed | not_checked | not_checked | ERROR | operation error; rejected contract or failed installer callback
unknown | not_checked | not_checked | ERROR | operation error; dispatch, handle, or deadline outcome unknown
completed | found | full | INFO | none; only verified success
completed | found | partial | WARN | attestation reason; npm install or supported Windows partial case
completed | found | failed | ERROR | attestation reason; receipt or integrity proof failed
completed | missing | failed | ERROR | both reasons; expected executable missing
completed | unverifiable | failed | ERROR | both reasons; executable cannot be safely probed
completed | unknown | failed | ERROR | both reasons; host lookup could not resolve executable
completed | broken | failed | ERROR | both reasons; executable probing broke
completed | not_checked | failed | ERROR | both reasons; availability was not checked
```

### Examples <!-- -->

- A successful npm callback with every executable found and every proof except
  the compiler-policy proof records `completed/found/partial` and WARN.
- A failed callback records `failed/not_checked/not_checked` and ERROR.
- A successful callback with a missing executable records
  `completed/missing/failed` and ERROR; a receipt mismatch with a found
  executable records `completed/found/failed` and ERROR.
- On Windows, only a FULL-policy compiler with the exact supported `.cmd`
  receipt and containment proofs can record `completed/found/partial`; Windows
  plus a PARTIAL compiler fails attestation.

Successfully installed packages are retained after partial or failed
attestation. Muster never automatically rolls them back, uninstalls them, or
cleans them up. One package's result does not change another package's result,
and no result path enables an LSP server.

## Known limits

- muster itself never force-loads host plugins. The lazy.nvim examples ask Lazy
  to load the host specs first, but those specs must still run their own setup
  and require their main modules. Conform, nvim-lint, DAP, and none-ls are skipped as
  "host plugin not loaded" until that happens. LSP is the exception: its adapter
  uses Neovim's built-in `vim.lsp.config`, so an absent catalog server is
  `unknown` rather than a skipped host, even when an explicit command was given.
- DAP has no external name catalog. Mason hand-off works only when an adapter's
  command is the actual tool binary; wrappers such as a Python interpreter may
  not map to a useful package.
- LSP string declarations cannot safely inspect function-form catalog commands
  and report `unverifiable`. An explicit `{ name, command }` declaration can
  verify a bare executable prerequisite without invoking the function, but it
  cannot prove the root-specific transport the function later launches.
- Full Mason attestation is limited to this exact compiler allowlist: cargo,
  composer, gem, golang, luarocks, nuget, and opam. The `npm`, `pypi`, `github`,
  `mason`, `generic`, and `openvsx` compiler types can reach only partial
  attestation on non-Windows when every other proof passes. An `unknown` or
  future compiler type fails attestation. The jsonls and yamlls declarations
  above are npm-backed examples, so a successful callback with found binaries
  can reach `completed/found/partial`, not verified success.
- Mason's runtime fingerprint detects on-disk Mason Lua source drift from the
  pinned implementation. This is a trusted-process check: the running Neovim
  process and in-memory Lua functions are trusted. It does not claim to defend
  against same-process code monkeypatching functions during installation.
- Windows cannot reach full attestation. A FULL-policy compiler can reach
  partial only with the supported exact `.cmd` receipt key and target, package
  containment, stable compiler/fingerprint evidence, Mason source, and Mason-bin
  path proofs. A PARTIAL or unknown compiler fails attestation. The installed
  package is retained and no LSP is enabled.
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
