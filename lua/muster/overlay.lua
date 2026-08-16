---The `:Muster` floating report.
---
---Each invocation probes the buffer it was opened from, then asks every loaded
---adapter for entries live in that same buffer. It calls the pure probe path
---directly: opening this read-only surface emits no startup report and cannot
---enter a provisioning hand-off.

local check = require("muster.check")
local registry = require("muster.registry")

local M = {}

local function key(entry)
	return entry.adapter .. "\0" .. entry.name
end

local function sort_entries(entries)
	table.sort(entries, function(a, b)
		if a.adapter ~= b.adapter then
			return a.adapter < b.adapter
		end
		return a.name < b.name
	end)
end

---@class muster.OverlayView
---@field bufnr integer
---@field filetype string
---@field active muster.Entry[]
---@field other muster.Entry[]
---@field diagnostics string[]
---@field notes string[]

---@param view muster.OverlayView
---@param diagnostic string
local function add_diagnostic(view, diagnostic)
	view.diagnostics[#view.diagnostics + 1] = diagnostic
end

---@param id string
---@param adapter muster.Adapter
---@param raw any
---@param name string
---@param bufnr integer
---@return muster.Entry
local function probe_discovered(id, adapter, raw, name, bufnr)
	local probed, probe = pcall(adapter.probe, raw, bufnr)
	return {
		adapter = id,
		name = name,
		declared = false,
		probe = probed and check.validate_probe(id, probe) or {
			status = "broken",
			reason = ("probe raised: %s"):format(tostring(probe)),
		},
		advice = {},
	}
end

---@param view muster.OverlayView
---@param declared table<string, muster.Entry>
---@param active table<string, boolean>
---@param id string
---@param adapter muster.Adapter
---@param raw any
local function collect_live_entry(view, declared, active, id, adapter, raw)
	local named, name = pcall(adapter.identity, raw)
	if not named or type(name) ~= "string" or name == "" then
		local reason
		if not named then
			reason = tostring(name)
		elseif name == "" then
			reason = "expected a non-empty string, got an empty string"
		else
			reason = "expected a string, got " .. type(name)
		end
		add_diagnostic(view, ("%s live identity failed: %s"):format(id, reason))
		return
	end

	local entry_key = id .. "\0" .. name
	if active[entry_key] then
		return
	end

	local entry = declared[entry_key] or probe_discovered(id, adapter, raw, name, view.bufnr)
	active[entry_key] = true
	view.active[#view.active + 1] = entry
end

---@param view muster.OverlayView
---@param declared table<string, muster.Entry>
---@param active table<string, boolean>
---@param id string
---@param adapter muster.Adapter
local function collect_live(view, declared, active, id, adapter)
	if type(adapter.live) ~= "function" then
		return
	end

	local available_ok, available = pcall(adapter.available)
	if not available_ok or not available then
		return
	end

	local live_ok, entries, live_err = pcall(adapter.live, view.bufnr)
	if not live_ok then
		add_diagnostic(view, ("%s live query failed: %s"):format(id, entries))
		return
	end
	if type(entries) ~= "table" or not vim.islist(entries) then
		add_diagnostic(view, ("%s live query returned a %s, expected a list"):format(id, type(entries)))
		return
	end
	if live_err then
		add_diagnostic(view, ("%s live query failed: %s"):format(id, tostring(live_err)))
	end

	for _, raw in ipairs(entries) do
		collect_live_entry(view, declared, active, id, adapter, raw)
	end
end

---@param bufnr? integer
---@return muster.OverlayView
function M.collect(bufnr)
	bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
	local result = check.run(bufnr)
	local view = {
		bufnr = bufnr,
		filetype = vim.bo[bufnr].filetype,
		active = {},
		other = {},
		diagnostics = {},
		notes = result.notes,
	}

	local declared = {}
	for _, entry in ipairs(result.entries) do
		declared[key(entry)] = entry
	end
	for _, skip in ipairs(result.skipped) do
		add_diagnostic(view, ("%s: %s"):format(skip.adapter, skip.reason))
	end

	local active = {}
	for id, adapter in pairs(registry.all()) do
		collect_live(view, declared, active, id, adapter)
	end

	for _, entry in ipairs(result.entries) do
		if not active[key(entry)] then
			view.other[#view.other + 1] = entry
		end
	end
	sort_entries(view.active)
	sort_entries(view.other)
	table.sort(view.diagnostics)
	return view
end

local config = require("muster.config")
local render = require("muster.ui.render")
local help = require("muster.ui.help")
local version = require("muster.version")
local window = require("muster.ui.window")

local active_controller

local TABS = { "active", "all", "issues" }
local ACTIONS = {
	{ name = "close", desc = "Close Muster dashboard" },
	{ name = "active", desc = "Show Active tools" },
	{ name = "all", desc = "Show All tools" },
	{ name = "issues", desc = "Show Muster issues" },
	{ name = "next_tab", desc = "Show next Muster tab" },
	{ name = "previous_tab", desc = "Show previous Muster tab" },
	{ name = "details", desc = "Toggle Muster details" },
	{ name = "help", desc = "Show Muster help" },
	{ name = "search", desc = "Search Muster tools" },
	{ name = "refresh", desc = "Refresh Muster dashboard" },
	{ name = "copy_path", desc = "Copy Muster path" },
}

local function notify(message, level)
	pcall(vim.notify, "muster: " .. tostring(message), level, { title = "muster" })
end

local function invalidate_async(controller)
	controller.state.search_request = controller.state.search_request + 1
	controller.state.generation = controller.state.generation + 1
	controller.redraw_pending = false
	for _, record in ipairs(controller.resolvers) do
		record.valid = false
		record.has_buffered = false
		record.buffered = nil
	end
	controller.resolvers = {}
end

local function invalidate(controller)
	invalidate_async(controller)
	controller.startup_committed = false
end

local function close_help_window()
	help.close(false)
end

local function retire(controller)
	local ok, err = pcall(close_help_window)
	if active_controller == controller then
		active_controller = nil
	end
	invalidate(controller)
	controller.closed = true
	if not ok then
		return err
	end
end

local function instance_valid(controller)
	if controller.window == nil then
		return false
	end
	local ok, valid = pcall(controller.window.valid, controller.window)
	return ok and valid == true
end

local function live(controller)
	if
		active_controller ~= controller
		or controller.failed
		or controller.closed
		or not controller.startup_committed
	then
		return false
	end
	if instance_valid(controller) then
		return true
	end
	local err = retire(controller)
	if err ~= nil then
		controller.failed = true
		notify(err, vim.log.levels.ERROR)
	end
	return false
end

local function generation_live(controller, generation)
	return generation == controller.state.generation and live(controller)
end

local function resolution_active(controller, generation)
	if generation ~= controller.state.generation or controller.failed or controller.closed then
		return false
	end
	if controller.startup_committed then
		return live(controller)
	end
	return instance_valid(controller)
end

local function fail_once(controller, err)
	if controller.failed or controller.closed then
		return
	end
	if controller.startup_committed and active_controller ~= controller then
		return
	end
	controller.failed = true
	if active_controller == controller then
		active_controller = nil
	end
	invalidate(controller)
	pcall(close_help_window)
	if controller.window ~= nil then
		pcall(controller.window.close, controller.window)
	end
	notify(err, vim.log.levels.ERROR)
end

local function capture_selection(controller)
	if controller.state.showing_help then
		return true
	end
	local selected
	if controller.output ~= nil then
		local ok, line = pcall(controller.window.cursor_line, controller.window)
		if not ok then
			fail_once(controller, line)
			return false
		end
		local row = controller.output.row_by_line[line]
		if row ~= nil and row.kind == "entry" then
			selected = row.key
		end
	end
	controller.state.selected_key = selected
	return true
end

local toggle_help

local function finish_help_close(controller)
	if not controller.state.showing_help then
		return
	end
	controller.state.showing_help = false
	if not live(controller) then
		return
	end
	local ok, err = pcall(controller.window.focus, controller.window)
	if not ok then
		fail_once(controller, err)
	end
end

local function draw_protected(controller)
	if controller.failed or controller.window == nil then
		return false
	end
	local ok, err = xpcall(function()
		local output = render.render(controller.state, controller.window:content_width())
		controller.window:draw(output, controller.state.selected_key)
		controller.output = output
		if controller.state.showing_help then
			local help_output =
				render.help(controller.state, help.content_width(controller.window.win, controller.state.ui))
			local current = help.current()
			if current then
				current:resize()
				current:draw(help_output)
			elseif controller.state.showing_help then
				help.open({
					parent_win = controller.window.win,
					ui = controller.state.ui,
					output = help_output,
					on_close = function()
						finish_help_close(controller)
					end,
				})
			end
		else
			close_help_window()
		end
	end, debug.traceback)
	if not ok then
		fail_once(controller, err)
		return false
	end
	return true
end

local function request_redraw(controller, generation)
	if not generation_live(controller, generation) then
		return false
	end
	if controller.redraw_pending then
		return true
	end
	local token = {}
	controller.redraw_pending = token
	local returned = false
	local buffered = false
	local settled = false
	local function execute()
		if settled then
			return
		end
		settled = true
		if generation ~= controller.state.generation or controller.redraw_pending ~= token then
			return
		end
		controller.redraw_pending = false
		if live(controller) then
			draw_protected(controller)
		end
	end
	local function callback()
		if settled then
			return
		end
		if not returned then
			buffered = true
			return
		end
		execute()
	end
	local ok, err = pcall(vim.schedule, callback)
	if not ok then
		settled = true
		if generation == controller.state.generation and controller.redraw_pending == token then
			controller.redraw_pending = false
		end
		fail_once(controller, err)
		return false
	end
	returned = true
	if buffered then
		execute()
	end
	return generation_live(controller, generation)
end

local function transition(controller, changed, mutate)
	if not changed or not live(controller) then
		return false
	end
	if not capture_selection(controller) then
		return false
	end
	mutate()
	controller.state.revision = controller.state.revision + 1
	request_redraw(controller, controller.state.generation)
	return true
end

local function close_controller(controller)
	if active_controller ~= controller or controller.failed or controller.closed then
		return
	end
	local first_error = retire(controller)
	local ok, err = pcall(controller.window.close, controller.window)
	if not ok and first_error == nil then
		first_error = err
	end
	if first_error ~= nil then
		controller.failed = true
		notify(first_error, vim.log.levels.ERROR)
	end
end

local function select_tab(controller, tab)
	local changed = controller.state.tab ~= tab or controller.state.showing_help
	transition(controller, changed, function()
		controller.state.tab = tab
		controller.state.showing_help = false
	end)
end

local function cycle_tab(controller, delta)
	if not live(controller) then
		return
	end
	local current = 1
	for index, tab in ipairs(TABS) do
		if tab == controller.state.tab then
			current = index
			break
		end
	end
	local target = ((current - 1 + delta) % #TABS) + 1
	transition(controller, true, function()
		controller.state.tab = TABS[target]
		controller.state.showing_help = false
	end)
end

local function current_row(controller)
	if not live(controller) or controller.output == nil then
		return nil
	end
	local ok, line = pcall(controller.window.cursor_line, controller.window)
	if not ok then
		fail_once(controller, line)
		return nil
	end
	return controller.output.row_by_line[line]
end

local function current_entry_key(controller)
	local row = current_row(controller)
	if row ~= nil and row.kind == "entry" then
		return row.key
	end
end

local function toggle_details(controller)
	local entry_key = current_entry_key(controller)
	if entry_key == nil then
		return
	end
	transition(controller, true, function()
		if controller.state.expanded_key == entry_key then
			controller.state.expanded_key = nil
		else
			controller.state.expanded_key = entry_key
		end
	end)
end

toggle_help = function(controller)
	if not live(controller) then
		return
	end
	if controller.state.showing_help then
		local ok, err = xpcall(function()
			local current = help.current()
			if current then
				current:close(true)
			else
				finish_help_close(controller)
			end
		end, debug.traceback)
		if not ok then
			fail_once(controller, err)
		end
		return
	end
	if not capture_selection(controller) then
		return
	end
	controller.state.showing_help = true
	local ok, err = xpcall(function()
		local help_output =
			render.help(controller.state, help.content_width(controller.window.win, controller.state.ui))
		help.open({
			parent_win = controller.window.win,
			ui = controller.state.ui,
			output = help_output,
			on_close = function()
				finish_help_close(controller)
			end,
		})
	end, debug.traceback)
	if not ok then
		controller.state.showing_help = false
		fail_once(controller, err)
	end
end

local function search(controller)
	if not live(controller) then
		return
	end
	controller.state.search_request = controller.state.search_request + 1
	local token = controller.state.search_request
	local generation = controller.state.generation
	local returned = false
	local settled = false
	local has_buffered = false
	local buffered

	local function settle(value)
		if settled then
			return
		end
		settled = true
		if
			not live(controller)
			or generation ~= controller.state.generation
			or token ~= controller.state.search_request
		then
			return
		end
		if value == nil then
			return
		end
		if type(value) ~= "string" or #value > 256 then
			notify("search query must be a string of at most 256 bytes", vim.log.levels.WARN)
			return
		end
		if value == controller.state.query then
			return
		end
		transition(controller, true, function()
			controller.state.query = value
			controller.state.showing_help = false
		end)
	end

	local function callback(value)
		if settled then
			return
		end
		if not returned then
			if not has_buffered then
				has_buffered = true
				buffered = value
			end
			return
		end
		settle(value)
	end

	local ok, err = pcall(vim.ui.input, {
		prompt = controller.state.ui.labels.search_prompt,
		default = controller.state.query,
	}, callback)
	if not ok then
		settled = true
		if controller.state.search_request == token then
			controller.state.search_request = token + 1
		end
		notify(err, vim.log.levels.WARN)
		return
	end
	returned = true
	if has_buffered then
		settle(buffered)
	end
end

local refresh
local copy_path

local function action_callbacks(controller)
	return {
		close = function()
			close_controller(controller)
		end,
		active = function()
			select_tab(controller, "active")
		end,
		all = function()
			select_tab(controller, "all")
		end,
		issues = function()
			select_tab(controller, "issues")
		end,
		next_tab = function()
			cycle_tab(controller, 1)
		end,
		previous_tab = function()
			cycle_tab(controller, -1)
		end,
		details = function()
			toggle_details(controller)
		end,
		help = function()
			toggle_help(controller)
		end,
		search = function()
			search(controller)
		end,
		refresh = function()
			refresh(controller)
		end,
		copy_path = function()
			copy_path(controller)
		end,
	}
end

local function mappings(value)
	if value == false then
		return {}
	end
	if type(value) == "table" then
		return value
	end
	return { value }
end

local function install_mappings(controller)
	local callbacks = action_callbacks(controller)
	for _, action in ipairs(ACTIONS) do
		for _, lhs in ipairs(mappings(controller.state.ui.keymaps[action.name])) do
			controller.window:map(lhs, callbacks[action.name], action.desc)
		end
	end
end

local function view_has_key(view, entry_key)
	for _, entries in ipairs({ view.active, view.other }) do
		for _, entry in ipairs(entries) do
			if key(entry) == entry_key then
				return true
			end
		end
	end
	return false
end

local function capture_settlement_selection(controller)
	if controller.output == nil or controller.output.revision ~= controller.state.revision then
		return true
	end
	local ok, line = pcall(controller.window.cursor_line, controller.window)
	if not ok then
		fail_once(controller, line)
		return false
	end
	local row = controller.output.row_by_line[line]
	if row ~= nil and row.kind == "entry" and view_has_key(controller.state.view, row.key) then
		controller.state.selected_key = row.key
	end
	return true
end

local function settle_version(controller, record, resolved)
	if record.settled or not record.valid or not record.returned then
		return
	end
	record.settled = true
	if record.controller ~= controller or record.generation ~= controller.state.generation or not live(controller) then
		return
	end
	if not capture_settlement_selection(controller) then
		return
	end
	controller.state.versions[record.key] = resolved
	controller.state.revision = controller.state.revision + 1
	request_redraw(controller, record.generation)
end

local function flush_resolver(controller, record)
	if not record.has_buffered then
		return
	end
	local resolved = record.buffered
	record.has_buffered = false
	record.buffered = nil
	settle_version(controller, record, resolved)
end

local function invoke_resolver(controller, generation, entry)
	local record = {
		controller = controller,
		key = key(entry),
		generation = generation,
		valid = true,
		settled = false,
		returned = false,
		has_buffered = false,
	}
	controller.resolvers[#controller.resolvers + 1] = record
	local function callback(resolved)
		if record.settled or not record.valid then
			return
		end
		if not record.returned or not controller.startup_committed then
			if not record.has_buffered then
				record.has_buffered = true
				record.buffered = resolved
			end
			return
		end
		settle_version(controller, record, resolved)
	end
	local ok, err = xpcall(function()
		version.resolve(entry, callback)
	end, debug.traceback)
	if not ok then
		record.valid = false
		record.has_buffered = false
		record.buffered = nil
		return false, err
	end
	record.returned = true
	if controller.startup_committed then
		flush_resolver(controller, record)
	end
	return true
end

local function resolve_versions(controller, generation)
	if not resolution_active(controller, generation) then
		return false
	end
	local seen = {}
	for _, entries in ipairs({ controller.state.view.active, controller.state.view.other }) do
		for _, entry in ipairs(entries) do
			local entry_key = key(entry)
			if entry.probe.status == "found" and not seen[entry_key] then
				if not resolution_active(controller, generation) then
					return false
				end
				seen[entry_key] = true
				local ok, err = invoke_resolver(controller, generation, entry)
				if not ok then
					for _, record in ipairs(controller.resolvers) do
						if record.generation == generation then
							record.valid = false
							record.has_buffered = false
							record.buffered = nil
						end
					end
					fail_once(controller, err)
					return false
				end
				if not resolution_active(controller, generation) then
					return false
				end
			end
		end
	end
	return true
end

local function flush_resolvers(controller)
	for _, record in ipairs(controller.resolvers) do
		flush_resolver(controller, record)
	end
end

local function valid_source(source_bufnr)
	if type(source_bufnr) ~= "number" or source_bufnr ~= source_bufnr or source_bufnr <= 0 or source_bufnr % 1 ~= 0 then
		return false
	end
	local ok, valid = pcall(vim.api.nvim_buf_is_valid, source_bufnr)
	return ok and valid == true
end

local function capture_refresh_selection(controller)
	if controller.output == nil then
		return true
	end
	local ok, line = pcall(controller.window.cursor_line, controller.window)
	if not ok then
		fail_once(controller, line)
		return false
	end
	local row = controller.output.row_by_line[line]
	if row ~= nil and row.kind == "entry" then
		controller.state.selected_key = row.key
	end
	return true
end

local function view_keys(view)
	local present = {}
	for _, entries in ipairs({ view.active, view.other }) do
		for _, entry in ipairs(entries) do
			present[key(entry)] = true
		end
	end
	return present
end

refresh = function(controller)
	if not live(controller) or not capture_refresh_selection(controller) then
		return
	end

	invalidate_async(controller)
	controller.state.revision = controller.state.revision + 1
	local generation = controller.state.generation
	local source_bufnr = controller.state.source_bufnr

	if not valid_source(source_bufnr) then
		controller.state.source_error = "dashboard source buffer is no longer valid"
		request_redraw(controller, generation)
		return
	end

	local ok, collected = pcall(M.collect, source_bufnr)
	if not ok then
		controller.state.source_error = "dashboard refresh failed while collecting source buffer"
		request_redraw(controller, generation)
		return
	end
	if type(collected) ~= "table" or collected.bufnr ~= source_bufnr then
		controller.state.source_error = "dashboard refresh returned a different source buffer"
		request_redraw(controller, generation)
		return
	end

	local present = view_keys(collected)
	controller.state.view = collected
	controller.state.versions = {}
	controller.state.source_error = nil
	if not present[controller.state.expanded_key] then
		controller.state.expanded_key = nil
	end
	if not present[controller.state.selected_key] then
		controller.state.selected_key = nil
	end
	if not request_redraw(controller, generation) or not generation_live(controller, generation) then
		return
	end
	resolve_versions(controller, generation)
end

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

local function valid_copy_path(value)
	if type(value) ~= "string" or value == "" or #value > 4096 or value:find("[%z\1-\31\127]") then
		return false
	end
	for codepoint = 0x80, 0x9F do
		if value:find(vim.fn.nr2char(codepoint), 1, true) then
			return false
		end
	end
	for _, codepoint in ipairs(BIDI_CONTROLS) do
		if value:find(vim.fn.nr2char(codepoint), 1, true) then
			return false
		end
	end
	return true
end

local function valid_register(register)
	return type(register) == "string" and (register == '"' or register:match("^[A-Za-z0-9+*_-]$") ~= nil)
end

copy_path = function(controller)
	if not live(controller) then
		return
	end
	if controller.output == nil or controller.output.revision ~= controller.state.revision then
		notify("cannot copy path from stale dashboard output", vim.log.levels.WARN)
		return
	end
	local row = current_row(controller)
	local probe = row and row.kind == "entry" and row.entry and row.entry.probe or nil
	if type(probe) ~= "table" then
		notify("no tool path is selected", vim.log.levels.WARN)
		return
	end
	local value
	if probe.path ~= nil then
		value = probe.path
	else
		value = probe.realpath
	end
	if not valid_copy_path(value) then
		notify("selected tool path is not safe to copy", vim.log.levels.WARN)
		return
	end
	local register = vim.v.register
	if not valid_register(register) then
		notify("active register is not allowed for path copy", vim.log.levels.WARN)
		return
	end
	local ok, result = pcall(vim.fn.setreg, register, value)
	if not ok or type(result) ~= "number" or result ~= 0 then
		notify("failed to copy selected tool path", vim.log.levels.WARN)
		return
	end
	notify("copied selected tool path", vim.log.levels.INFO)
end

local function current_dashboard()
	local ok, current = pcall(window.current)
	if not ok then
		notify(current, vim.log.levels.ERROR)
		return nil, true
	end
	if current == nil then
		if active_controller ~= nil then
			local err = retire(active_controller)
			if err ~= nil then
				notify(err, vim.log.levels.ERROR)
				return nil, true
			end
		end
		return nil, false
	end
	local focused, focus_err = pcall(current.focus, current)
	if not focused then
		notify(focus_err, vim.log.levels.ERROR)
		return nil, true
	end
	return current, false
end

---@param source_bufnr? integer
---@return integer? report_bufnr
---@return integer? winid
function M.open(source_bufnr)
	local current, current_failed = current_dashboard()
	if current_failed then
		return nil, nil
	end
	if current ~= nil then
		return current.buf, current.win
	end

	local canonical = source_bufnr
	if canonical == nil or canonical == 0 then
		canonical = vim.api.nvim_get_current_buf()
	end
	if not valid_source(canonical) then
		notify("cannot open dashboard for an invalid source buffer", vim.log.levels.ERROR)
		return nil, nil
	end

	local collected = M.collect(canonical)
	local runtime_ui = vim.deepcopy(config.ui())
	local controller = {
		state = {
			source_bufnr = canonical,
			view = collected,
			ui = runtime_ui,
			tab = "active",
			query = "",
			showing_help = false,
			expanded_key = nil,
			selected_key = nil,
			versions = {},
			source_error = nil,
			generation = 1,
			revision = 1,
			search_request = 0,
		},
		resolvers = {},
		redraw_pending = false,
		startup_committed = false,
		failed = false,
		closed = false,
	}

	local existing
	local ok, err = xpcall(function()
		render.setup_highlights()
		local dashboard, created = window.open({
			source_bufnr = canonical,
			ui = runtime_ui,
			on_resize = function(instance)
				if active_controller == controller and controller.window == instance and live(controller) then
					request_redraw(controller, controller.state.generation)
				end
			end,
			on_error = function(callback_err)
				fail_once(controller, callback_err)
			end,
		})
		if not created then
			dashboard:focus()
			existing = dashboard
			return
		end
		controller.window = dashboard
		install_mappings(controller)
		if not draw_protected(controller) then
			return
		end
		resolve_versions(controller, controller.state.generation)
		if controller.failed then
			return
		end
		active_controller = controller
		controller.startup_committed = true
		flush_resolvers(controller)
	end, debug.traceback)

	if existing ~= nil then
		return existing.buf, existing.win
	end
	if not ok then
		fail_once(controller, err)
	end
	if controller.failed then
		return nil, nil
	end
	return controller.window.buf, controller.window.win
end

return M
