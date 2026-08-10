---nvim-lint adapter.
---
---`lint.linters` is a metatable whose __index requires `lint.linters.<name>`,
---so an unknown name yields nil. Three shapes exist in the wild and all three
---are handled: a table with a string `cmd`, a table with a function `cmd`, and
---a module that IS a function (8 of 186 builtins), which `lookup_linter` calls
---before use.

local probe = require("muster.probe")

---@type muster.Adapter
local M = {
	id = "lint",
}

---@return boolean loaded
---@return string|nil reason
function M.available()
	return require("muster.host").status("lint", "lua/lint.lua")
end

---@param entry any
---@return string
function M.identity(entry)
	return tostring(entry)
end

---@param entry any
---@param _bufnr integer
---@return muster.Probe
function M.probe(entry, _bufnr)
	local name = M.identity(entry)
	local ok, linter = probe.guarded(function()
		return require("lint").linters[name]
	end)
	if not ok then
		return probe.broken(linter --[[@as string]])
	end
	if linter == nil then
		return probe.unknown("no lint.linters." .. name .. " module")
	end

	-- A module that is itself a function is resolved by calling it; that call
	-- is the subsystem's own lookup, so a raise here is `broken` too.
	if type(linter) == "function" then
		local called_ok, called = probe.guarded(linter)
		if not called_ok then
			return probe.broken(called --[[@as string]])
		end
		linter = called
	end

	if type(linter) ~= "table" then
		return probe.broken(("linter resolved to a %s, expected a table"):format(type(linter)))
	end
	if type(linter.cmd) == "function" then
		return probe.unverifiable("cmd is a function: the linter resolves it per run")
	end
	if type(linter.cmd) ~= "string" or linter.cmd == "" then
		-- A structurally invalid entry is a config error, not something we
		-- merely could not verify: routing it to `unverifiable` would file a
		-- broken linter under "nothing to worry about".
		return probe.broken(("linter table has no usable `cmd` (found %s)"):format(type(linter.cmd)))
	end
	return probe.resolve(linter.cmd)
end

---Linters configured for this buffer's filetype. Uses `_resolve_linter_by_ft`
---rather than indexing `linters_by_ft` directly, because nvim-lint resolves
---dotted compound filetypes there and a plain index misses those buffers.
---@param bufnr integer
---@return string[] entries
---@return string|nil err @A failed query must not render as "nothing configured".
function M.live(bufnr)
	local ok, names = pcall(function()
		local ft = vim.bo[bufnr].filetype
		return require("lint")._resolve_linter_by_ft(ft)
	end)
	if not ok then
		return {}, tostring(names)
	end
	return type(names) == "table" and names or {}, nil
end

return M
