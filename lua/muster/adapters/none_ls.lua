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

---@return boolean loaded
---@return string|nil reason
function M.available()
	return require("muster.host").status("null-ls", "lua/null-ls/init.lua")
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
			if type(command) == "string" and command ~= "" then
				-- Route through resolve so `binary` is a basename, as the
				-- registry key contract requires, rather than a raw path. Only a
				-- resolve that itself succeeded may be downgraded: stamping
				-- `missing` over a `broken` would discard a real config error,
				-- and stamping it over a `found` would tell the user a tool that
				-- IS on $PATH is not.
				local resolved = probe.resolve(command)
				if resolved.status ~= "missing" then
					-- The command may well be on $PATH; can_run() failed for some
					-- other reason of the source's own. Calling that "not on
					-- $PATH" would be a plain lie, so the verdict is reported as
					-- what it is: the source says it cannot run.
					return probe.broken(
						("the source's own can_run() reports it cannot run (command %q resolved to %s)"):format(
							command,
							resolved.path or resolved.status
						)
					)
				end
				resolved.reason = "the source's own can_run() reports it cannot run"
				return resolved
			end
			return probe.broken(
				("can_run() reports the source cannot run; its command is a %s, so muster cannot resolve it"):format(
					type(command)
				)
			)
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
---@return any[] entries
---@return string|nil err @A failed query must not render as "nothing configured".
function M.live(bufnr)
	local ok, sources = pcall(function()
		local ft = vim.bo[bufnr].filetype
		return require("null-ls.sources").get_available(ft)
	end)
	if not ok then
		return {}, tostring(sources)
	end
	return type(sources) == "table" and sources or {}, nil
end

---Every registered source, for the derived mode where the user gave no list.
---
---Returns the failure distinctly: a swallowed error here would be reported as
---"none-ls has no registered sources", sending the user to debug a config that
---is fine while muster's own read is what broke.
---@return boolean ok
---@return any[]|string sources_or_error
function M.registered()
	return pcall(function()
		return require("null-ls.sources").get_all()
	end)
end

return M
