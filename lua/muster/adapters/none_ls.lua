---none-ls.nvim adapter.
---
---The only adapter whose entries are objects rather than name strings, which is
---why `identity()` exists at all. none-ls's own `validate_and_transform`
---requires `name` to be a string, defaulting to "anonymous source"; muster
---rejects an entry whose identity is not a usable string rather than reporting
---several sources under one key.

local probe = require("muster.probe")

---@type muster.Adapter
local M = {
	id = "none_ls",
}

---@return boolean
function M.available()
	return pcall(require, "null-ls")
end

---@param entry any
---@return string
function M.identity(entry)
	if type(entry) == "string" then
		return entry
	end
	if type(entry) == "table" and type(entry.name) == "string" and entry.name ~= "" then
		return entry.name
	end
	error("muster: none-ls source has no usable `name` to identify it by", 0)
end

---@param entry any
---@param _bufnr integer
---@return muster.Probe
function M.probe(entry, _bufnr)
	if type(entry) ~= "table" then
		return probe.unverifiable("source is not a table: nothing to inspect")
	end

	local opts = type(entry.generator) == "table" and entry.generator.opts or nil
	local command = type(opts) == "table" and opts.command or nil

	-- `can_run` is authoritative when present; it is the source's own answer.
	-- A negative answer settles the matter. A positive one does not skip the
	-- $PATH probe: `found` must carry a path and a source, and only locating the
	-- command can supply them.
	if type(entry.can_run) == "function" then
		local ok, runnable = probe.guarded(entry.can_run)
		if not ok then
			return probe.broken(runnable --[[@as string]])
		end
		if not runnable then
			return {
				status = "missing",
				binary = type(command) == "string" and command or nil,
				reason = "the source's own can_run() reports it cannot run",
			}
		end
		if type(command) ~= "string" or command == "" then
			-- Runs in-process; there is no external tool to be missing.
			return probe.unverifiable("can_run() passed; source has no external command")
		end
	end

	if type(command) == "function" then
		return probe.unverifiable("command is a function: the source resolves it per run")
	end
	if type(command) ~= "string" or command == "" then
		return probe.unverifiable("source declares no external command")
	end
	return probe.resolve(command)
end

---Sources registered and matching this buffer's filetype. Note that none-ls's
---"available" means registered-and-matching; it does NOT check that the command
---exists, so every result still goes through `probe`.
---@param bufnr integer
---@return any[]
function M.live(bufnr)
	local ok, sources = pcall(function()
		local ft = vim.bo[bufnr].filetype
		return require("null-ls.sources").get_available(ft)
	end)
	return ok and sources or {}
end

---Every registered source, for the derived mode where the user gave no list.
---@return any[]
function M.registered()
	local ok, sources = pcall(function()
		return require("null-ls.sources").get_all()
	end)
	return ok and sources or {}
end

return M
