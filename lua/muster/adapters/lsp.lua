---LSP adapter.
---
---Known names come from `vim.lsp.config[name]`, which resolves rtp `lsp/` files
---and stored registrations exactly the way `vim.lsp.enable()` consumes them, and
---returns nil for a name nothing defines. It can also raise, when the `lsp/`
---file itself raises — that is `broken`, not `unknown`.

local probe = require("muster.probe")

---@type muster.Adapter
local M = {
	id = "lsp",
}

function M.available()
	return vim.lsp ~= nil and vim.lsp.config ~= nil
end

---@param entry any
---@return string
function M.identity(entry)
	return tostring(entry)
end

---A table `cmd` is argv; its first element is the binary. A function `cmd`
---resolves its own transport at launch time and cannot be probed.
---@param cmd any
---@return string|nil binary
---@return string|nil unverifiable_reason
local function binary_of(cmd)
	if type(cmd) == "table" then
		local first = cmd[1]
		return type(first) == "string" and first or nil, "cmd is a table with no string argv[0]"
	end
	if type(cmd) == "function" then
		return nil, "cmd is a function: the server resolves its own transport"
	end
	return nil, "no cmd"
end

---@param entry any
---@param _bufnr integer
---@return muster.Probe
function M.probe(entry, _bufnr)
	local name = M.identity(entry)
	if name == "*" then
		-- '*' is merged into every config at read time; it is not a server.
		return probe.unknown("'*' is the wildcard config, not a server name")
	end

	local ok, config = probe.guarded(function()
		return vim.lsp.config[name]
	end)
	if not ok then
		return probe.broken(config --[[@as string]])
	end
	if not config then
		return probe.unknown("no lsp/ config and no registration for this name")
	end

	local binary, reason = binary_of(config.cmd)
	if not binary then
		return probe.unverifiable(reason --[[@as string]])
	end
	return probe.resolve(binary)
end

---Clients attached to this buffer, normalised to the name strings `identity`
---and `probe` accept. The filter key must be NAMED: a positional `{ bufnr }`
---leaves `filter.bufnr` nil and returns every client in the session.
---@param bufnr integer
---@return string[]
function M.live(bufnr)
	local names = {}
	for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
		names[#names + 1] = client.name
	end
	return names
end

return M
