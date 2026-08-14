---The adapter registry.
---
---Setup keys ARE adapter ids, so there is no mapping to get wrong and a
---third-party adapter is declared exactly like a built-in one.

local M = {}

---@type table<string, muster.Adapter>
local adapters = {}

M.BUILTIN = { "lsp", "conform", "nvim_lint", "dap", "none_ls" }

---@param id string
---@return boolean
function M.is_builtin(id)
	return vim.tbl_contains(M.BUILTIN, id)
end

local function validate_id(id, builtin)
	if type(id) ~= "string" or id == "" or #id > 128 or id:find("[%z\1-\31\127]") then
		error("adapter.id: expected a non-empty printable string of at most 128 bytes", 0)
	end
	if require("muster.config").is_option(id) then
		error(("adapter.id: %q is reserved and cannot be registered"):format(id), 0)
	end
	if M.is_builtin(id) and not builtin then
		error(("adapter.id: %q is reserved for muster's built-in adapter"):format(id), 0)
	end
end

---@param adapter muster.Adapter
---@param builtin boolean
local function validate(adapter, builtin)
	vim.validate("adapter", adapter, "table")
	vim.validate("adapter.id", adapter.id, "string")
	validate_id(adapter.id, builtin)
	vim.validate("adapter.available", adapter.available, "function")
	vim.validate("adapter.identity", adapter.identity, "function")
	vim.validate("adapter.probe", adapter.probe, "function")
	vim.validate("adapter.live", adapter.live, "function", true)
end

---@param adapter muster.Adapter
---@param builtin boolean
local function register(adapter, builtin)
	local ok, err = pcall(validate, adapter, builtin)
	if not ok then
		error(("muster: invalid adapter: %s"):format(err), 3)
	end
	if adapters[adapter.id] then
		error(("muster: adapter %q is already registered"):format(adapter.id), 3)
	end
	if builtin then
		adapter.__muster_builtin = true
	end
	adapters[adapter.id] = adapter
end

---Register a third-party adapter. Re-registering an id is an error rather than
---a silent overwrite, and built-in/reserved ids cannot be preempted.
---@param adapter muster.Adapter
function M.register(adapter)
	register(adapter, false)
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
			elseif type(adapter) ~= "table" or adapter.id ~= id then
				failures[id] = load_failures[id]
					or ("built-in module %q returned the wrong adapter id"):format("muster.adapters." .. id)
				load_failures[id] = failures[id]
			else
				local registered, err = pcall(register, adapter, true)
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
