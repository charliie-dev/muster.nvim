---The adapter registry.
---
---Setup keys ARE adapter ids, so there is no mapping to get wrong and a
---third-party adapter is declared exactly like a built-in one.

local M = {}

---@type table<string, muster.Adapter>
local adapters = {}

local BUILTIN = { "lsp", "conform", "lint", "dap", "none_ls" }

---@param adapter muster.Adapter
local function validate(adapter)
	vim.validate("adapter", adapter, "table")
	vim.validate("adapter.id", adapter.id, "string")
	vim.validate("adapter.available", adapter.available, "function")
	vim.validate("adapter.identity", adapter.identity, "function")
	vim.validate("adapter.probe", adapter.probe, "function")
	vim.validate("adapter.live", adapter.live, "function", true)
end

---Register an adapter. Re-registering an id is an error rather than a silent
---overwrite: two plugins fighting over "conform" should be loud.
---@param adapter muster.Adapter
function M.register(adapter)
	local ok, err = pcall(validate, adapter)
	if not ok then
		error(("muster: invalid adapter: %s"):format(err), 2)
	end
	if adapters[adapter.id] then
		error(("muster: adapter %q is already registered"):format(adapter.id), 2)
	end
	adapters[adapter.id] = adapter
end

---@param id string
---@return muster.Adapter|nil
function M.get(id)
	return adapters[id]
end

---@return table<string, muster.Adapter>
function M.all()
	return adapters
end

---Load the built-in adapters once. Kept lazy so `plugin/muster.lua` can stay
---free of requires: nothing here runs until the first check.
function M.load_builtins()
	for _, id in ipairs(BUILTIN) do
		if not adapters[id] then
			M.register(require("muster.adapters." .. id))
		end
	end
end

---Test seam: drop everything. Specs register fakes against a clean registry.
function M.reset()
	adapters = {}
end

return M
