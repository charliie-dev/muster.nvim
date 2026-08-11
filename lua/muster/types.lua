---Type definitions for muster.nvim. This module is documentation only: it holds
---no runtime state and exports an empty table, so requiring it is free.
---
---See DESIGN.md for the reasoning behind each field.

---How a declared tool resolved.
---@alias muster.Status
---| '"found"'        # executable resolved
---| '"missing"'      # string command, not on $PATH
---| '"unverifiable"' # function-form command, or a predicate needing a real buffer
---| '"unknown"'      # the subsystem does not recognise this name
---| '"broken"'       # the subsystem's own lookup failed: it raised, or it
---                    # returned a structurally invalid config

---Where a found executable came from. `unknown` means `found` but `fs_realpath`
---failed — never the fallback for an unrecognised prefix, which is `system`.
---@alias muster.Source '"mason"'|'"nix"'|'"mise"'|'"brew"'|'"system"'|'"unknown"'

---@class muster.Probe
---@field status muster.Status
---@field binary? string    Executable NAME: the $PATH target and the Mason registry key.
---@field path? string      As resolved on $PATH; required when status == "found".
---@field realpath? string  Symlinks followed; present when "found" and fs_realpath succeeded.
---@field source? muster.Source Required when status == "found".
---@field reason? string    Required for "unverifiable", "unknown" and "broken".

---One subsystem, adapted to a single interface.
---@class muster.Adapter
---@field id string
---@field available fun(): boolean, string|nil Is the host plugin loaded? The
---  second return is why not — "installed but not loaded yet" and "not
---  installed" are different things and must not read alike.
---@field identity fun(entry: any): string Stable per-adapter report/dedupe key.
---@field probe fun(entry: any, bufnr: integer): muster.Probe
---@field live? fun(bufnr: integer): any[], string|nil Entries live for this
---  buffer, in the shape this adapter's own `identity`/`probe` accept, plus an
---  error when the query itself failed. Omitting `live` is a stated degradation;
---  a `live` that FAILED is not the same thing and must not render alike.
---  Overlay only.

---@class muster.Advice
---@field provider '"mason"'|'"nix"'|'"mise"'
---@field action '"install"'|'"declare"'
---@field package? string Only for one unique machine-readable package match.
---@field command? string Only when the provider has a real, unambiguous command.

---@class muster.Entry
---@field adapter string      Adapter id; with `name` this is the dedupe key.
---@field name string         From `adapter.identity(entry)`.
---@field declared boolean    false = discovered live, never named in setup().
---@field probe muster.Probe
---@field advice muster.Advice[] Empty in raw `probe()` results and whenever
---  `declared == false`; complete when async `check()` invokes its callback.

---@class muster.Skip
---@field adapter string
---@field count integer  How many declared entries went unchecked.
---@field severity "info"|"warn"|"error" Follows the KIND of skip, not the count:
---  an adapter that raised is an error even with nothing declared behind it.
---@field reason string

---The public result. Its shape is covered by the compatibility promise.
---@class muster.Result
---@field entries muster.Entry[] Declared entries only.
---@field skipped muster.Skip[]
---@field bufnr integer         The buffer probes were resolved against.
---@field notes string[]        Environment warnings, e.g. Mason's PATH mode.

---Overlay-only. NOT part of muster.Result and carries no compatibility promise.
---@class muster.Version
---@field value? string   nil when unresolved; the column renders "—".
---@field tier 1|2|3|4
---@field reason? string  Why it is nil.

return {}
