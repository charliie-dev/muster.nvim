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

---Set when a `setup()` call was rejected. Distinguishing "never called" from
---"called and rejected" matters: without it the health check tells a user who
---did call setup that they did not, sending them to fix the one thing that is
---not wrong.
---@type string|nil
local setup_error = nil

---@param opts table
local function validate(opts)
	vim.validate("opts", opts, "table")
	vim.validate("install", opts.install, function(v)
		return v == nil or v == false or v == "mason"
	end, true, "false or 'mason'")
	vim.validate("notify_on_startup", opts.notify_on_startup, "boolean", true)
	for key, value in pairs(opts) do
		if not M.OPTIONS[key] then
			-- A list, specifically. `{ lua_ls = { ... } }` is a natural thing to
			-- write and `#t` reports it as empty, so accepting it quietly would
			-- mean silently checking nothing.
			vim.validate(key, value, function(v)
				return v == nil or vim.islist(v)
			end, true, "a list of tool entries (got a map?)")
		end
	end
end

---@param opts? table
function M.setup(opts)
	opts = opts or {}
	local ok, err = pcall(validate, opts)
	if ok then
		setup_error = nil
		current = vim.tbl_extend("force", vim.deepcopy(defaults), opts)
	else
		-- Keep a usable config rather than leaving `current` nil: a nil config
		-- means "setup was never called", which is a different and misleading
		-- statement. The rejection is recorded and surfaced instead.
		setup_error = tostring(err)
		current = vim.deepcopy(defaults)
		vim.notify(
			("muster: your configuration was rejected, so only defaults are in effect: %s"):format(err),
			vim.log.levels.ERROR,
			{ title = "muster" }
		)
	end
end

---nil until `setup()` runs. The automatic check reads this to decide whether to
---run at all: without a call there is nothing declared, and the derived none-ls
---mode would otherwise notify a user who never configured muster.
---@return muster.Config|nil
function M.get()
	return current
end

---@return string|nil
function M.error()
	return setup_error
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
	setup_error = nil
end

return M
