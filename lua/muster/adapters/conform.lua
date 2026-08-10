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

---@return boolean
function M.available()
	return pcall(require, "conform")
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

	-- A Lua-format formatter has no command at all; nothing to probe.
	if type(info.command) ~= "string" or info.command == "" then
		return probe.unverifiable("formatter has no external command")
	end
	return probe.resolve(info.command)
end

---Formatters CONFIGURED for this buffer. `list_formatters` cannot be used here:
---it routes through `resolve_formatters`, which inserts only `if info.available`,
---so a formatter configured for the buffer whose binary is missing would never
---appear — exactly the row the overlay most needs to show.
---@param bufnr integer
---@return string[]
function M.live(bufnr)
	local ok, names = pcall(function()
		return require("conform").list_formatters_for_buffer(bufnr)
	end)
	return ok and names or {}
end

return M
