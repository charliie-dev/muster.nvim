---Configuration.
---
---Setup keys ARE adapter ids, so a third-party adapter is declared exactly like
---a built-in one and there is no mapping to get wrong. Only types are validated
---here; unknown-key detection lives in `health.lua`, where upstream's guide puts
---it to keep it off the hot path.

local M = {}

---Reserved keys that are options rather than adapter tool lists.
---`install` remains reserved so the removed option cannot become an adapter id.
local OPTIONS = { install = true, mason_install_fallback = true, notify_on_startup = true }

local defaults = {
	mason_install_fallback = false,
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

local function valid_lsp_name(value)
	return type(value) == "string"
		and #value <= 128
		and value ~= "*"
		and value:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") ~= nil
end

local function valid_lsp_command(value)
	return type(value) == "string" and #value <= 255 and value:match("^[A-Za-z0-9][A-Za-z0-9_.+-]*$") ~= nil
end

local function validate_lsp(entries)
	local declarations = {}
	for index, entry in ipairs(entries) do
		local name
		local command
		local kind = type(entry)
		if kind == "string" then
			name = entry
			if not valid_lsp_name(name) then
				error(("lsp[%d]: expected a valid LSP server name"):format(index), 0)
			end
		elseif kind == "table" then
			if getmetatable(entry) ~= nil then
				error(("lsp[%d]: expected a plain { name, command } map without a metatable"):format(index), 0)
			end
			for key in pairs(entry) do
				if key ~= "name" and key ~= "command" then
					error(
						("lsp[%d]: unexpected key %s; expected exactly name and command"):format(
							index,
							vim.inspect(key)
						),
						0
					)
				end
			end
			if entry.name == nil or entry.command == nil then
				error(("lsp[%d]: expected exactly { name, command }"):format(index), 0)
			end
			name = entry.name
			command = entry.command
			if not valid_lsp_name(name) then
				error(("lsp[%d].name: expected a valid LSP server name"):format(index), 0)
			end
			if not valid_lsp_command(command) then
				error(("lsp[%d].command: expected a bare executable name"):format(index), 0)
			end
		else
			error(("lsp[%d]: expected a server name or { name, command } map"):format(index), 0)
		end

		local previous = declarations[name]
		if previous and (previous.kind ~= kind or previous.command ~= command) then
			error(("lsp: conflicting declarations for %q"):format(name), 0)
		end
		declarations[name] = { kind = kind, command = command }
	end
end

---@param opts table
local function validate(opts)
	vim.validate("opts", opts, "table")
	if rawget(opts, "install") ~= nil then
		error("muster: `install` was removed; use `mason_install_fallback = true` to permit Mason installs", 0)
	end
	vim.validate("mason_install_fallback", opts.mason_install_fallback, "boolean", true)
	vim.validate("notify_on_startup", opts.notify_on_startup, "boolean", true)
	for key, value in pairs(opts) do
		if not OPTIONS[key] then
			-- A list, specifically. `{ lua_ls = { ... } }` is a natural thing to
			-- write and `#t` reports it as empty, so accepting it quietly would
			-- mean silently checking nothing.
			vim.validate(key, value, function(v)
				return v == nil or vim.islist(v)
			end, true, "a list of tool entries (got a map?)")
			if key == "lsp" and value ~= nil then
				validate_lsp(value)
			end
		end
	end
end

local function snapshot_list(id, entries)
	local copy = {}
	for index, entry in ipairs(entries) do
		if id == "lsp" and type(entry) == "table" then
			copy[index] = { name = entry.name, command = entry.command }
		else
			copy[index] = entry
		end
	end
	return copy
end

local function snapshot(config)
	local copy = {}
	for key, value in pairs(config) do
		if OPTIONS[key] then
			copy[key] = value
		elseif value ~= nil then
			copy[key] = snapshot_list(key, value)
		end
	end
	return copy
end

---@param opts? muster.SetupOpts
function M.setup(opts)
	local candidate = opts == nil and {} or opts
	local ok, err = pcall(validate, candidate)
	if ok then
		setup_error = nil
		current = vim.tbl_extend("force", snapshot(defaults), snapshot(candidate))
	else
		-- Keep a usable config rather than leaving `current` nil: a nil config
		-- means "setup was never called", which is a different and misleading
		-- statement. The rejection is recorded and surfaced instead.
		setup_error = tostring(err)
		current = snapshot(defaults)
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
	return current and snapshot(current) or nil
end

---@return string|nil
function M.error()
	return setup_error
end

---@param id string
---@return boolean
function M.is_option(id)
	return OPTIONS[id] == true
end

---The declared list for one adapter, or nil when the key was absent.
---@param id string
---@return any[]|nil
function M.list(id)
	if not current or OPTIONS[id] then
		return nil
	end
	return current[id] and snapshot_list(id, current[id]) or nil
end

---Test seam.
function M.reset()
	current = nil
	setup_error = nil
end

return M
