---The adapter registry.
---
---Setup keys ARE adapter ids, so there is no mapping to get wrong and a
---third-party adapter is declared exactly like a built-in one.

local M = {}

---@type table<string, muster.Adapter>
local adapters = {}

M.BUILTIN = { "lsp", "conform", "lint", "dap", "none_ls" }

---@param id string
---@return boolean
function M.is_builtin(id)
	return vim.tbl_contains(M.BUILTIN, id)
end

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
---@type table<string, string>
local load_failures = {}

---@return table<string, string> failures @Adapter id -> the load error.
function M.load_builtins()
	local failures = vim.deepcopy(load_failures)
	for _, id in ipairs(M.BUILTIN) do
		if adapters[id] and not adapters[id].__muster_builtin then
			-- Someone else got here first. Silently yielding would mean every
			-- verdict for this subsystem came from foreign code while muster's
			-- own adapter never ran, and nothing said so.
			failures[id] = (
				"a third-party adapter is registered under this built-in id, "
				.. "so muster's own %q adapter was not loaded"
			):format(id)
		elseif not adapters[id] then
			-- Per id, not all-or-nothing: one broken module must not stop the
			-- other four from registering, and the caller needs to know which
			-- ones are missing rather than blaming every declared list.
			local ok, adapter = pcall(require, "muster.adapters." .. id)
			if not ok then
				-- Remember the ORIGINAL text. A second require of a module that
				-- raised returns Lua's "loop or previous error" sentinel, which
				-- names a require loop that does not exist and loses the cause.
				failures[id] = load_failures[id] or tostring(adapter)
				load_failures[id] = failures[id]
			else
				if type(adapter) == "table" then
					adapter.__muster_builtin = true
				end
				local registered, err = pcall(M.register, adapter)
				if not registered then
					failures[id] = load_failures[id] or tostring(err)
					load_failures[id] = failures[id]
				end
			end
		end
	end
	return failures
end

---Test seam: drop everything. Specs register fakes against a clean registry.
function M.reset()
	adapters = {}
	load_failures = {}
end

return M
