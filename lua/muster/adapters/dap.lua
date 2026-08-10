---nvim-dap adapter.
---
---DAP never returns `unknown`. `dap.adapters` starts empty and is populated
---entirely by the user, so there is no external catalogue to typo against —
---whatever name is registered IS the name. That is a category difference from
---the other four, not a missing feature.

local probe = require("muster.probe")

---@type muster.Adapter
local M = {
	id = "dap",
}

---@return boolean loaded
---@return string|nil reason
function M.available()
	return require("muster.host").status("dap", "lua/dap.lua")
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
	local ok, adapter = probe.guarded(function()
		return require("dap").adapters[name]
	end)
	if not ok then
		return probe.broken(adapter --[[@as string]])
	end
	if adapter == nil then
		-- Not `unknown`: nothing external defines DAP adapter names, so this is
		-- "you have not registered it yet", which is unverifiable, not a typo.
		return probe.unverifiable("no dap.adapters." .. name .. " registered")
	end

	-- An adapter factory resolves per session, asynchronously, via a callback.
	if type(adapter) == "function" then
		return probe.unverifiable("adapter is a factory function: it resolves per session")
	end
	if type(adapter) ~= "table" then
		return probe.broken(("adapter is a %s, expected a table or function"):format(type(adapter)))
	end

	-- Executable adapters carry `command`; server adapters carry it under
	-- `executable`, and may have none at all when attaching to a running server.
	local command = adapter.command
	if command == nil and type(adapter.executable) == "table" then
		command = adapter.executable.command
	end
	if command == nil then
		return probe.unverifiable("server adapter with no local executable (remote attach)")
	end
	return probe.resolve(command)
end

---Adapter types referenced by this filetype's configurations, normalised to the
---type strings `identity`/`probe` accept. Configurations supplied at runtime
---through `dap.providers.configs` (launch.json) are not in the static table, so
---this undercounts; documented rather than worked around.
---@param bufnr integer
---@return string[] entries
---@return string|nil err @A failed query must not render as "nothing configured".
function M.live(bufnr)
	local ok, types = pcall(function()
		local ft = vim.bo[bufnr].filetype
		local configs = require("dap").configurations[ft] or {}
		local seen, out = {}, {}
		for _, config in ipairs(configs) do
			local kind = config.type
			if type(kind) == "string" and not seen[kind] then
				seen[kind] = true
				out[#out + 1] = kind
			end
		end
		return out
	end)
	if not ok then
		return {}, tostring(types)
	end
	return type(types) == "table" and types or {}, nil
end

return M
