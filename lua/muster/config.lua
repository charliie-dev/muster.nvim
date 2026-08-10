---Configuration.
---
---Setup keys ARE adapter ids, so a third-party adapter is declared exactly like
---a built-in one and there is no mapping to get wrong. Only types are validated
---here; unknown-key detection lives in `health.lua`, where upstream's guide puts
---it to keep it off the hot path.

local M = {}

---Reserved keys that are options rather than adapter tool lists.
M.OPTIONS = { install = true, notify_on_startup = true }

---@class muster.Config
---@field install false|'"mason"'
---@field notify_on_startup boolean
---@field [string] any[]  Tool lists, keyed by adapter id.
local defaults = {
	install = false,
	notify_on_startup = true,
}

---@type muster.Config|nil
local current = nil

---@param opts table
local function validate(opts)
	vim.validate("opts", opts, "table")
	vim.validate("install", opts.install, function(v)
		return v == nil or v == false or v == "mason"
	end, true, "false or 'mason'")
	vim.validate("notify_on_startup", opts.notify_on_startup, "boolean", true)
	for key, value in pairs(opts) do
		if not M.OPTIONS[key] then
			vim.validate(key, value, "table", true)
		end
	end
end

---@param opts? table
function M.setup(opts)
	opts = opts or {}
	local ok, err = pcall(validate, opts)
	if not ok then
		vim.notify(("muster: invalid configuration: %s"):format(err), vim.log.levels.ERROR)
		return
	end
	current = vim.tbl_extend("force", vim.deepcopy(defaults), opts)
end

---nil until `setup()` runs. The automatic check reads this to decide whether to
---run at all: without a call there is nothing declared, and the derived none-ls
---mode would otherwise notify a user who never configured muster.
---@return muster.Config|nil
function M.get()
	return current
end

---The declared list for one adapter, or nil when the key was absent.
---@param id string
---@return any[]|nil
function M.list(id)
	if not current or M.OPTIONS[id] then
		return nil
	end
	return current[id]
end

---Test seam.
function M.reset()
	current = nil
end

return M
