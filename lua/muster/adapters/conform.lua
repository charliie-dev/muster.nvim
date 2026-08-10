---conform.nvim adapter.
---
---Uses `get_formatter_info`, which is public and documented, rather than the
---`@private` `get_formatter_config`. It also resolves function-form commands
---itself against the given buffer, so the probe-time evaluation comes free.

local probe = require("muster.probe")

---@type muster.Adapter
local M = {
	id = "conform",
}

---@return boolean loaded
---@return string|nil reason
function M.available()
	return require("muster.host").status("conform", "lua/conform/init.lua")
end

---@param entry any
---@return string
function M.identity(entry)
	return tostring(entry)
end

---@param entry any
---@param bufnr integer
---@return muster.Probe
function M.probe(entry, bufnr)
	local name = M.identity(entry)
	local ok, info = probe.guarded(function()
		return require("conform").get_formatter_info(name, bufnr)
	end)
	if not ok then
		return probe.broken(info --[[@as string]])
	end

	-- conform conflates "unknown name" with "malformed config" into `error`.
	-- Separating them would mean matching its message text, which is brittle, so
	-- muster reports `unknown` and carries the message verbatim: it tells the
	-- user which one it is, and muster never parses it.
	if info.error then
		return probe.unknown(info.available_msg or "unknown formatter")
	end

	if type(info.command) ~= "string" or info.command == "" then
		return probe.unverifiable("formatter has no external command")
	end

	-- A Lua-format formatter (`format = function`, e.g. trim_whitespace,
	-- injected) runs in-process and spawns nothing — but `get_formatter_info`
	-- reports `command = <the formatter's own name>` for those, so probing it
	-- would report a false `missing`, or a false `found` if some unrelated
	-- binary happens to share the name. The info API cannot express the
	-- distinction, so the formatter's definition is consulted for `format`.
	if info.command == name then
		local is_lua, config_err = M.is_lua_format(name, bufnr)
		if config_err then
			-- The user's own config function raised. Reporting "not on $PATH"
			-- would send them to install a binary that is beside the point.
			return probe.broken(("the conform config for %q raised: %s"):format(name, config_err))
		end
		if is_lua then
			return probe.unverifiable("formatter runs in-process: no external tool to be missing")
		end
	end
	return probe.resolve(info.command)
end

---Does this formatter format in Lua rather than by spawning a command?
---
---Checks the user override first (it wins in conform's own resolution) and then
---the builtin module. Deliberately avoids `get_formatter_config`, which is
---`@private`; a require of the builtin module is a stable public path.
---@param name string
---@param bufnr integer
---@return boolean is_lua_format
---@return string|nil err @The user's config raised; not the same as "no".
function M.is_lua_format(name, bufnr)
	local ok, conform = pcall(require, "conform")
	if ok then
		local override = conform.formatters and conform.formatters[name]
		if type(override) == "function" then
			local called_ok, called = pcall(override, bufnr)
			if not called_ok then
				return false, tostring(called)
			end
			override = called
		end
		if type(override) == "table" and type(override.format) == "function" then
			return true
		end
	end
	local mod_ok, mod = pcall(require, "conform.formatters." .. name)
	if not mod_ok then
		-- A module that exists but raises on load is a broken config; one that
		-- simply is not there is not. `require` reports both, so distinguish.
		local missing = tostring(mod):find("module '" .. vim.pesc("conform.formatters." .. name) .. "' not found")
		return false, (not missing) and tostring(mod) or nil
	end
	return type(mod) == "table" and type(mod.format) == "function"
end

---Formatters CONFIGURED for this buffer. `list_formatters` cannot be used here:
---it routes through `resolve_formatters`, which inserts only `if info.available`,
---so a formatter configured for the buffer whose binary is missing would never
---appear — exactly the row the overlay most needs to show.
---@param bufnr integer
---@return string[] entries
---@return string|nil err @A failed query must not render as "nothing configured".
function M.live(bufnr)
	local ok, names = pcall(function()
		return require("conform").list_formatters_for_buffer(bufnr)
	end)
	if not ok then
		return {}, tostring(names)
	end
	return type(names) == "table" and names or {}, nil
end

return M
