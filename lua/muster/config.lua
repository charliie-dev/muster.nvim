---Configuration.
---
---Setup keys ARE adapter ids, so a third-party adapter is declared exactly like
---a built-in one and there is no mapping to get wrong. Only types are validated
---here; unknown-key detection lives in `health.lua`, where upstream's guide puts
---it to keep it off the hot path.

local M = {}

---Reserved keys that are options rather than adapter tool lists.
---Removed public keys remain reserved so they cannot become adapter ids.
local OPTIONS = {
	install = true,
	lint = true,
	mason_install_fallback = true,
	notify_on_startup = true,
	ui = true,
}

local defaults = {
	mason_install_fallback = false,
	notify_on_startup = true,
	ui = {
		width = 0.8,
		height = 0.8,
		border = "rounded",
		backdrop = 60,
		icons = {
			found = "●",
			missing = "○",
			unknown = "?",
			broken = "×",
			unverifiable = "!",
			pending = "…",
			discovered = "*",
			expanded = "▾",
			collapsed = "▸",
		},
		labels = {
			title = "muster.nvim",
			tabs = { active = "Active", all = "All", issues = "Issues" },
			adapters = {
				lsp = "LSP",
				conform = "Formatter",
				nvim_lint = "Linter",
				dap = "DAP",
				none_ls = "none-ls",
			},
			columns = { status = "STATUS", tool = "TOOL", adapter = "TYPE", version = "VERSION" },
			details = {
				source = "source",
				executable = "executable",
				path = "path",
				realpath = "realpath",
				reason = "reason",
				advice = "advice",
			},
			empty = "No tools found.",
			no_matches = "No matching tools.",
			no_issues = "No issues found.",
			search_prompt = "Muster search: ",
			help = "Help",
		},
		keymaps = {
			close = { "q", "<Esc>" },
			active = "1",
			all = "2",
			issues = "3",
			next_tab = "<Tab>",
			previous_tab = "<S-Tab>",
			details = "<CR>",
			search = "/",
			help = "?",
			refresh = "r",
			copy_path = "y",
		},
	},
}

local STRUCTURAL_UI_PATHS = {
	icons = true,
	labels = true,
	["labels.tabs"] = true,
	["labels.adapters"] = true,
	["labels.columns"] = true,
	["labels.details"] = true,
	keymaps = true,
}

local UI_KEYS =
	{ width = true, height = true, border = true, backdrop = true, icons = true, labels = true, keymaps = true }
local ICON_KEYS = {
	found = true,
	missing = true,
	unknown = true,
	broken = true,
	unverifiable = true,
	pending = true,
	discovered = true,
	expanded = true,
	collapsed = true,
}
local LABEL_KEYS = {
	title = true,
	tabs = true,
	adapters = true,
	columns = true,
	details = true,
	empty = true,
	no_matches = true,
	no_issues = true,
	search_prompt = true,
	help = true,
}
local TAB_KEYS = { active = true, all = true, issues = true }
local COLUMN_KEYS = { status = true, tool = true, adapter = true, version = true }
local DETAIL_KEYS = {
	source = true,
	executable = true,
	path = true,
	realpath = true,
	reason = true,
	advice = true,
}
local KEYMAP_KEYS = {
	close = true,
	active = true,
	all = true,
	issues = true,
	next_tab = true,
	previous_tab = true,
	details = true,
	search = true,
	help = true,
	refresh = true,
	copy_path = true,
}
local BORDER_NAMES = { none = true, single = true, double = true, rounded = true, solid = true, shadow = true }
local BIDI_CONTROLS = {
	0x061C,
	0x200E,
	0x200F,
	0x202A,
	0x202B,
	0x202C,
	0x202D,
	0x202E,
	0x2066,
	0x2067,
	0x2068,
	0x2069,
}

---@type muster.Config|nil
local current = nil

---Set when a `setup()` call was rejected. Distinguishing "never called" from
---"called and rejected" matters: without it the health check tells a user who
---did call setup that they did not, sending them to fix the one thing that is
---not wrong.
---@type string|nil
local setup_error = nil

local function valid_name(value)
	return type(value) == "string"
		and #value <= 128
		and value ~= "*"
		and value:match("^[A-Za-z0-9][A-Za-z0-9_.-]*$") ~= nil
end

local function valid_command(value)
	return type(value) == "string" and #value <= 255 and value:match("^[A-Za-z0-9][A-Za-z0-9_.+-]*$") ~= nil
end

local function validate_declarations(id, label, entries)
	if getmetatable(entries) ~= nil then
		error(("%s: expected a plain list without a metatable"):format(id), 0)
	end
	local declarations = {}
	for index, entry in ipairs(entries) do
		local name
		local command
		local kind = type(entry)
		if kind == "string" then
			name = entry
			if not valid_name(name) then
				error(("%s[%d]: expected a valid %s name"):format(id, index, label), 0)
			end
		elseif kind == "table" then
			if getmetatable(entry) ~= nil then
				error(("%s[%d]: expected a plain { name, command } map without a metatable"):format(id, index), 0)
			end
			for key in pairs(entry) do
				if key ~= "name" and key ~= "command" then
					error(
						("%s[%d]: unexpected key %s; expected exactly name and command"):format(
							id,
							index,
							vim.inspect(key)
						),
						0
					)
				end
			end
			if entry.name == nil or entry.command == nil then
				error(("%s[%d]: expected exactly { name, command }"):format(id, index), 0)
			end
			name = entry.name
			command = entry.command
			if not valid_name(name) then
				error(("%s[%d].name: expected a valid %s name"):format(id, index, label), 0)
			end
			if not valid_command(command) then
				error(("%s[%d].command: expected a bare executable name"):format(id, index), 0)
			end
		else
			error(("%s[%d]: expected a name or { name, command } map"):format(id, index), 0)
		end

		local previous = declarations[name]
		if previous and (previous.kind ~= kind or previous.command ~= command) then
			error(("%s: conflicting declarations for %q"):format(id, name), 0)
		end
		declarations[name] = { kind = kind, command = command }
	end
end

local function validate_conform(entries)
	if getmetatable(entries) ~= nil then
		error("conform: expected a plain list without a metatable", 0)
	end
	for index, entry in ipairs(entries) do
		if type(entry) ~= "string" or entry == "" or #entry > 128 or entry:find("[%z\1-\31\127]") then
			error(("conform[%d]: expected a non-empty printable formatter name of at most 128 bytes"):format(index), 0)
		end
	end
end

local function ui_error(path, message)
	error(("ui.%s: %s"):format(path, message), 0)
end

local function enter_plain_table(value, path, visiting)
	if type(value) ~= "table" then
		ui_error(path, "expected a table")
	end
	if getmetatable(value) ~= nil then
		ui_error(path, "expected a plain table without a metatable")
	end
	if visiting[value] then
		ui_error(path, "cyclic tables are not allowed")
	end
	visiting[value] = true
end

local function validate_map_keys(value, path, allowed)
	for key in pairs(value) do
		if type(key) ~= "string" or not allowed[key] then
			ui_error(path, ("unexpected key %s"):format(vim.inspect(key)))
		end
	end
end

local function dense_list_length(value, path, visiting)
	enter_plain_table(value, path, visiting)
	local count = 0
	local maximum = 0
	for key in pairs(value) do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			ui_error(path, "expected a dense list")
		end
		count = count + 1
		maximum = math.max(maximum, key)
	end
	if count ~= maximum then
		ui_error(path, "expected a dense list")
	end
	return count
end

local function has_prohibited_ui_text(value)
	if value:find("[%z\1-\31\127]") then
		return true
	end
	for codepoint = 0x80, 0x9F do
		if value:find(vim.fn.nr2char(codepoint), 1, true) then
			return true
		end
	end
	for _, codepoint in ipairs(BIDI_CONTROLS) do
		if value:find(vim.fn.nr2char(codepoint), 1, true) then
			return true
		end
	end
	return false
end

local function validate_ui_text(value, path, limit, allow_empty)
	if
		type(value) ~= "string"
		or #value > limit
		or (not allow_empty and value == "")
		or has_prohibited_ui_text(value)
	then
		ui_error(
			path,
			("expected %sprintable text of at most %d bytes"):format(allow_empty and "" or "non-empty ", limit)
		)
	end
end

local function validate_adapter_id(value, path)
	if type(value) ~= "string" or value == "" or #value > 128 or value:find("[%z\1-\31\127]") then
		ui_error(path, "expected a non-empty adapter id of at most 128 bytes without C0 or DEL controls")
	end
end

local function validate_text_map(value, path, allowed, limit, visiting)
	enter_plain_table(value, path, visiting)
	validate_map_keys(value, path, allowed)
	for key, text in pairs(value) do
		validate_ui_text(text, path .. "." .. key, limit, true)
	end
	visiting[value] = nil
end

local function validate_adapter_labels(value, visiting)
	local path = "labels.adapters"
	enter_plain_table(value, path, visiting)
	for key, text in pairs(value) do
		validate_adapter_id(key, path)
		validate_ui_text(text, path .. " value", 128, true)
	end
	visiting[value] = nil
end

local function validate_labels(value, visiting)
	local path = "labels"
	enter_plain_table(value, path, visiting)
	validate_map_keys(value, path, LABEL_KEYS)
	for _, key in ipairs({ "title", "empty", "no_matches", "no_issues", "search_prompt", "help" }) do
		if value[key] ~= nil then
			validate_ui_text(value[key], path .. "." .. key, 128, true)
		end
	end
	if value.tabs ~= nil then
		validate_text_map(value.tabs, "labels.tabs", TAB_KEYS, 128, visiting)
	end
	if value.adapters ~= nil then
		validate_adapter_labels(value.adapters, visiting)
	end
	if value.columns ~= nil then
		validate_text_map(value.columns, "labels.columns", COLUMN_KEYS, 128, visiting)
	end
	if value.details ~= nil then
		validate_text_map(value.details, "labels.details", DETAIL_KEYS, 128, visiting)
	end
	visiting[value] = nil
end

local function validate_border_character(value, path)
	validate_ui_text(value, path, 16, true)
	local ok, width = pcall(vim.fn.strdisplaywidth, value)
	if not ok or width > 1 then
		ui_error(path, "expected a border character with display width at most one")
	end
end

local function validate_border(value, visiting)
	if type(value) == "string" then
		if not BORDER_NAMES[value] then
			ui_error("border", "expected a supported border name")
		end
		return
	end
	local length = dense_list_length(value, "border", visiting)
	if length ~= 8 then
		ui_error("border", "expected exactly eight parts")
	end
	for index = 1, length do
		local part = value[index]
		local path = ("border[%d]"):format(index)
		if type(part) == "string" then
			validate_border_character(part, path)
		elseif type(part) == "table" then
			local tuple_length = dense_list_length(part, path, visiting)
			if tuple_length ~= 2 then
				ui_error(path, "expected exactly { character, highlight }")
			end
			validate_border_character(part[1], path .. "[1]")
			validate_ui_text(part[2], path .. "[2]", 128, false)
			visiting[part] = nil
		else
			ui_error(path, "expected a character or { character, highlight }")
		end
	end
	visiting[value] = nil
end

local function add_keymap_lhs(lhs, path, seen)
	validate_ui_text(lhs, path, 64, false)
	local normalized = vim.keycode(lhs)
	if #normalized == 0 or #normalized > 50 then
		ui_error(path, "expected a normalized mapping of 1 to 50 bytes")
	end
	if seen[normalized] then
		ui_error(path, ("conflicts with %s"):format(seen[normalized]))
	end
	seen[normalized] = path
end

local function validate_keymaps(value, visiting)
	local path = "keymaps"
	enter_plain_table(value, path, visiting)
	validate_map_keys(value, path, KEYMAP_KEYS)
	local seen = {}
	for key, mapping in pairs(value) do
		local mapping_path = path .. "." .. key
		if mapping ~= false then
			if type(mapping) == "string" then
				add_keymap_lhs(mapping, mapping_path, seen)
			elseif type(mapping) == "table" then
				local length = dense_list_length(mapping, mapping_path, visiting)
				if length == 0 then
					ui_error(mapping_path, "expected a non-empty mapping list")
				end
				for index = 1, length do
					add_keymap_lhs(mapping[index], ("%s[%d]"):format(mapping_path, index), seen)
				end
				visiting[mapping] = nil
			else
				ui_error(mapping_path, "expected a mapping string, list, or false")
			end
		end
	end
	visiting[value] = nil
end

local function valid_dimension(value)
	return type(value) == "number" and value > 0 and value == value and value ~= math.huge
end

local function validate_ui(value)
	if value == nil then
		return
	end
	local visiting = {}
	enter_plain_table(value, "root", visiting)
	validate_map_keys(value, "root", UI_KEYS)
	if value.width ~= nil and not valid_dimension(value.width) then
		ui_error("width", "expected a positive finite number")
	end
	if value.height ~= nil and not valid_dimension(value.height) then
		ui_error("height", "expected a positive finite number")
	end
	if value.backdrop ~= nil then
		local backdrop = value.backdrop
		if type(backdrop) ~= "number" or backdrop % 1 ~= 0 or backdrop < 0 or backdrop > 100 then
			ui_error("backdrop", "expected an integer from 0 through 100")
		end
	end
	if value.border ~= nil then
		validate_border(value.border, visiting)
	end
	if value.icons ~= nil then
		validate_text_map(value.icons, "icons", ICON_KEYS, 32, visiting)
	end
	if value.labels ~= nil then
		validate_labels(value.labels, visiting)
	end
	if value.keymaps ~= nil then
		validate_keymaps(value.keymaps, visiting)
	end
	visiting[value] = nil
end

---@param opts table
local function validate(opts)
	vim.validate("opts", opts, "table")
	if rawget(opts, "install") ~= nil then
		error("muster: `install` was removed; use `mason_install_fallback = true` to permit Mason installs", 0)
	end
	if rawget(opts, "lint") ~= nil then
		error("muster: `lint` was renamed; use the `nvim_lint` setup key", 0)
	end
	vim.validate("mason_install_fallback", opts.mason_install_fallback, "boolean", true)
	vim.validate("notify_on_startup", opts.notify_on_startup, "boolean", true)
	validate_ui(opts.ui)
	for key, value in pairs(opts) do
		if not OPTIONS[key] then
			-- A list, specifically. `{ lua_ls = { ... } }` is a natural thing to
			-- write and `#t` reports it as empty, so accepting it quietly would
			-- mean silently checking nothing.
			vim.validate(key, value, function(v)
				return v == nil or vim.islist(v)
			end, true, "a list of tool entries (got a map?)")
			if key == "lsp" and value ~= nil then
				validate_declarations("lsp", "LSP server", value)
			elseif key == "nvim_lint" and value ~= nil then
				validate_declarations("nvim_lint", "nvim-lint linter", value)
			elseif key == "conform" and value ~= nil then
				validate_conform(value)
			end
		end
	end
end

local function snapshot_list(id, entries)
	local copy = {}
	for index, entry in ipairs(entries) do
		if (id == "lsp" or id == "nvim_lint") and type(entry) == "table" then
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
		if key == "ui" then
			copy[key] = vim.deepcopy(value)
		elseif OPTIONS[key] then
			copy[key] = value
		elseif value ~= nil then
			copy[key] = snapshot_list(key, value)
		end
	end
	return copy
end

local function merge_ui_map(base, override, path)
	local result = vim.deepcopy(base)
	for key, value in pairs(override or {}) do
		local child = path == "" and key or (path .. "." .. key)
		if STRUCTURAL_UI_PATHS[child] then
			result[key] = merge_ui_map(result[key], value, child)
		else
			result[key] = vim.deepcopy(value)
		end
	end
	return result
end

---@param opts? muster.SetupOpts
---@return table
local function setup_candidate(opts)
	if opts == nil then
		return {}
	end
	return opts
end

---@param opts? muster.SetupOpts
function M.setup(opts)
	local candidate = setup_candidate(opts)
	local ok, result = pcall(function()
		validate(candidate)
		local base = snapshot(defaults)
		local candidate_copy = snapshot(candidate)
		base.ui = merge_ui_map(defaults.ui, candidate.ui or {}, "")
		validate_keymaps(base.ui.keymaps, {})
		candidate_copy.ui = nil
		return vim.tbl_extend("force", base, candidate_copy)
	end)
	if ok then
		setup_error = nil
		current = result
	else
		-- Keep a usable config rather than leaving `current` nil: a nil config
		-- means "setup was never called", which is a different and misleading
		-- statement. The rejection is recorded and surfaced instead.
		setup_error = tostring(result)
		current = snapshot(defaults)
		vim.notify(
			("muster: your configuration was rejected, so only defaults are in effect: %s"):format(result),
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

---@return muster.UiConfig
function M.ui()
	return vim.deepcopy((current or defaults).ui)
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
