---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")
local help = require("muster.ui.help")
local render = require("muster.ui.render")

local saved_api = {}
local saved_keymap_set
local parents = {}
local instances = {}

local function patch_api(name, replacement)
	if saved_api[name] == nil then
		saved_api[name] = vim.api[name]
	end
	vim.api[name] = replacement
end

local function patch_keymap_set(replacement)
	if saved_keymap_set == nil then
		saved_keymap_set = vim.keymap.set
	end
	vim.keymap.set = replacement
end

local function restore_patches()
	for name, value in pairs(saved_api) do
		vim.api[name] = value
	end
	if saved_keymap_set ~= nil then
		vim.keymap.set = saved_keymap_set
	end
	saved_api = {}
	saved_keymap_set = nil
end

local function parent(width, height)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "one", "two", "three" })
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		row = 0,
		col = 0,
		width = width,
		height = height,
		style = "minimal",
	})
	vim.api.nvim_win_set_cursor(win, { 2, 0 })
	parents[#parents + 1] = { buf = buf, win = win }
	return win
end

local function output(revision)
	return {
		lines = { "Help", "  q/<Esc>  close Help" },
		extmarks = {
			{ line = 1, col = 2, opts = { end_col = 9, hl_group = "MusterDetailKey" } },
		},
		virtual_text = {},
		row_by_line = {},
		line_by_key = {},
		anchors = { help = 1 },
		revision = revision or 1,
	}
end

local function open(parent_win, overrides)
	overrides = overrides or {}
	local instance, created = help.open({
		parent_win = parent_win,
		ui = overrides.ui or config.ui(),
		output = overrides.output or output(),
		on_close = overrides.on_close or function() end,
	})
	instances[#instances + 1] = instance
	return instance, created
end

local function is_valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function autocmd_count(group)
	local ok, commands = pcall(vim.api.nvim_get_autocmds, { group = group })
	return ok and #commands or 0
end

local function assert_augroup_invalid(group)
	assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = group }), "augroup remains valid")
end

local function snapshot()
	local wins = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		wins[win] = true
	end
	local bufs = {}
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			bufs[buf] = true
		end
	end
	return { wins = wins, bufs = bufs }
end

local function assert_snapshot(before)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		assert.is_true(before.wins[win] == true, "window leaked: " .. win)
	end
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			assert.is_true(before.bufs[buf] == true, "buffer leaked: " .. buf)
		end
	end
end

local function close_all()
	restore_patches()
	for _ = 1, 4 do
		local ok, current = pcall(help.current)
		if ok and current then
			pcall(current.close, current, false)
		end
		for _, instance in ipairs(instances) do
			pcall(instance.close, instance, false)
		end
	end
	instances = {}
	for _, item in ipairs(parents) do
		if is_valid_win(item.win) then
			pcall(vim.api.nvim_win_close, item.win, true)
		end
		if is_valid_buf(item.buf) then
			pcall(vim.api.nvim_buf_delete, item.buf, { force = true })
		end
	end
	parents = {}
end

local function fail_api(name, predicate, message)
	local real = vim.api[name]
	local calls = 0
	patch_api(name, function(...)
		calls = calls + 1
		if predicate(calls, ...) then
			error(message, 0)
		end
		return real(...)
	end)
end

local function close_mapping(instance, lhs)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(instance.buf, "n")) do
		if mapping.lhs == lhs then
			return mapping.callback
		end
	end
end

local function block_owned_cleanup(instance, message)
	local attempts = { namespace = 0, augroup = 0, window = 0, buffer = 0 }
	local clear_namespace = vim.api.nvim_buf_clear_namespace
	patch_api("nvim_buf_clear_namespace", function(buf, ...)
		if buf == instance.buf then
			attempts.namespace = attempts.namespace + 1
			error(message, 0)
		end
		return clear_namespace(buf, ...)
	end)
	local delete_augroup = vim.api.nvim_del_augroup_by_id
	patch_api("nvim_del_augroup_by_id", function(group)
		if group == instance.augroup then
			attempts.augroup = attempts.augroup + 1
			error(message, 0)
		end
		return delete_augroup(group)
	end)
	local close_win = vim.api.nvim_win_close
	patch_api("nvim_win_close", function(win, ...)
		if win == instance.win then
			attempts.window = attempts.window + 1
			error(message, 0)
		end
		return close_win(win, ...)
	end)
	local delete_buf = vim.api.nvim_buf_delete
	patch_api("nvim_buf_delete", function(buf, ...)
		if buf == instance.buf then
			attempts.buffer = attempts.buffer + 1
			error(message, 0)
		end
		return delete_buf(buf, ...)
	end)
	return attempts
end

local function help_state()
	return {
		view = { bufnr = 1, filetype = "lua", active = {}, other = {}, diagnostics = {}, notes = {} },
		ui = config.ui(),
		tab = "active",
		query = "",
		showing_help = true,
		expanded_key = nil,
		versions = {},
		source_error = nil,
		revision = 4,
	}
end

describe("muster.ui.help", function()
	before_each(function()
		close_all()
		config.reset()
		config.setup({})
	end)

	after_each(function()
		close_all()
		config.reset()
	end)

	it("opens centered above the parent at eighty percent with exact owned resources", function()
		local parent_win = parent(80, 20)
		local before_cursor = vim.api.nvim_win_get_cursor(parent_win)
		assert.equals(64, help.content_width(parent_win, config.ui()))
		local closed = 0
		local instance, created = open(parent_win, {
			on_close = function()
				closed = closed + 1
			end,
		})
		assert.is_true(created)
		assert.equals(instance, help.current())
		local geometry = vim.api.nvim_win_get_config(instance.win)
		assert.equals("win", geometry.relative)
		assert.equals(parent_win, geometry.win)
		assert.equals(1, geometry.row)
		assert.equals(7, geometry.col)
		assert.equals(64, geometry.width)
		assert.equals(16, geometry.height)
		assert.equals(60, geometry.zindex)
		assert.equals("muster-help", vim.bo[instance.buf].filetype)
		assert.is_false(vim.bo[instance.buf].modifiable)
		assert.same(output().lines, vim.api.nvim_buf_get_lines(instance.buf, 0, -1, false))
		assert.same(before_cursor, vim.api.nvim_win_get_cursor(parent_win))
		assert.equals(5, autocmd_count(instance.augroup))
		local namespace = vim.api.nvim_create_namespace("muster_ui_help")
		assert.equals(1, #vim.api.nvim_buf_get_extmarks(instance.buf, namespace, 0, -1, {}))
		assert.equals(0, closed)

		local ids = { win = instance.win, buf = instance.buf, augroup = instance.augroup }
		instance:close(true)
		assert.equals(1, closed)
		assert.equals(parent_win, vim.api.nvim_get_current_win())
		assert.same(before_cursor, vim.api.nvim_win_get_cursor(parent_win))
		assert.is_false(is_valid_win(ids.win))
		assert.is_false(is_valid_buf(ids.buf))
		assert_augroup_invalid(ids.augroup)
		assert.is_nil(help.current())
	end)

	it("always installs and visibly renders fixed q and escape close Help controls", function()
		config.setup({ ui = { keymaps = { close = false, help = "H" } } })
		local parent_win = parent(80, 20)
		local rendered = render.help(help_state(), help.content_width(parent_win, config.ui()))
		assert.is_truthy(table.concat(rendered.lines, "\n"):find("q/<Esc>  close Help", 1, true))
		assert.is_nil(table.concat(rendered.lines, "\n"):find("close dashboard", 1, true))
		local closed = 0
		local instance = open(parent_win, {
			output = rendered,
			on_close = function()
				closed = closed + 1
			end,
		})
		assert.is_function(close_mapping(instance, "q"))
		assert.is_function(close_mapping(instance, "<Esc>"))
		assert.is_truthy(
			table
				.concat(vim.api.nvim_buf_get_lines(instance.buf, 0, -1, false), "\n")
				:find("q/<Esc>  close Help", 1, true)
		)
		close_mapping(instance, "q")()
		assert.equals(1, closed)
	end)

	it("keeps configured dashboard close in full Help without changing fixed child controls", function()
		config.setup({ ui = { keymaps = { close = "X", help = "H" } } })
		local parent_win = parent(80, 20)
		local rendered = render.help(help_state(), help.content_width(parent_win, config.ui()))
		local text = table.concat(rendered.lines, "\n")
		assert.is_truthy(text:find("q/<Esc>  close Help", 1, true))
		assert.is_truthy(text:find("X  close dashboard", 1, true))
		local instance = open(parent_win, { output = rendered })
		assert.is_function(close_mapping(instance, "q"))
		assert.is_function(close_mapping(instance, "<Esc>"))
		assert.is_nil(close_mapping(instance, "X"))
	end)

	it("relayouts to eighty percent after parent resize", function()
		local parent_win = parent(80, 20)
		local instance = open(parent_win)
		vim.api.nvim_win_set_config(parent_win, {
			relative = "editor",
			row = 0,
			col = 0,
			width = 50,
			height = 10,
		})
		instance:resize()
		instance:draw(output(5))
		local geometry = vim.api.nvim_win_get_config(instance.win)
		assert.equals(40, geometry.width)
		assert.equals(8, geometry.height)
		assert.equals(4, geometry.col)
		assert.equals(0, geometry.row)
		assert.same(output(5).lines, vim.api.nvim_buf_get_lines(instance.buf, 0, -1, false))
	end)

	it("retires on external child window, child buffer, and parent close", function()
		local triggers = {
			function(instance)
				vim.api.nvim_win_close(instance.win, true)
			end,
			function(instance)
				vim.api.nvim_buf_delete(instance.buf, { force = true })
			end,
			function(_, parent_win)
				vim.api.nvim_win_close(parent_win, true)
			end,
		}
		for _, trigger in ipairs(triggers) do
			close_all()
			local parent_win = parent(80, 20)
			local closed = 0
			local instance = open(parent_win, {
				on_close = function()
					closed = closed + 1
				end,
			})
			local ids = { win = instance.win, buf = instance.buf, augroup = instance.augroup }
			trigger(instance, parent_win)
			assert.is_true(vim.wait(1000, function()
				return pcall(help.current) and help.current() == nil
			end, 10))
			assert.is_false(is_valid_win(ids.win))
			assert.is_false(is_valid_buf(ids.buf))
			assert_augroup_invalid(ids.augroup)
			assert.equals(trigger == triggers[3] and 0 or 1, closed)
		end
	end)

	it("publishes active only after construction, mappings, and draw succeed", function()
		local cases = {
			{ name = "buffer", api = "nvim_create_buf" },
			{ name = "buffer option", api = "nvim_set_option_value", match = "buf" },
			{ name = "window", api = "nvim_open_win" },
			{ name = "window option", api = "nvim_set_option_value", match = "win" },
			{ name = "augroup", api = "nvim_create_augroup" },
			{ name = "autocmd", api = "nvim_create_autocmd" },
			{ name = "mapping", mapping = true },
			{ name = "draw", api = "nvim_buf_set_lines" },
		}
		for _, case in ipairs(cases) do
			close_all()
			local parent_win = parent(80, 20)
			local before = snapshot()
			if case.mapping then
				patch_keymap_set(function()
					error("construction failed: " .. case.name, 0)
				end)
			else
				fail_api(case.api, function(_, _, _, scope)
					return case.match == nil or scope and scope[case.match] ~= nil
				end, "construction failed: " .. case.name)
			end
			local ok, err = pcall(open, parent_win)
			restore_patches()
			assert.is_false(ok, case.name)
			assert.is_truthy(tostring(err):find("construction failed", 1, true), case.name)
			assert_snapshot(before)
			assert.is_nil(help.current(), case.name)
		end
	end)

	it("retires on draw and resize failures while preserving the initiating error", function()
		local cases = {
			{ name = "draw", method = "draw", api = "nvim_buf_set_extmark" },
			{ name = "resize config", method = "resize", api = "nvim_win_set_config" },
			{ name = "resize option", method = "resize", api = "nvim_set_option_value" },
		}
		for _, case in ipairs(cases) do
			close_all()
			local parent_win = parent(80, 20)
			local instance = open(parent_win)
			local ids = { win = instance.win, buf = instance.buf, augroup = instance.augroup }
			fail_api(case.api, function(_, name, _, scope)
				if case.name == "resize option" then
					return name == "number" and scope and scope.win == instance.win
				end
				return true
			end, "initiating " .. case.name .. " failure")
			local ok, err = pcall(instance[case.method], instance, output(2))
			restore_patches()
			assert.is_false(ok, case.name)
			assert.is_truthy(tostring(err):find("initiating " .. case.name .. " failure", 1, true), case.name)
			assert.is_false(is_valid_win(ids.win))
			assert.is_false(is_valid_buf(ids.buf))
			assert_augroup_invalid(ids.augroup)
			assert.is_nil(help.current())
		end
	end)

	for _, case in ipairs({
		{ lhs = "q", drain = "current" },
		{ lhs = "<Esc>", drain = "open" },
	}) do
		it(
			("delivers retained %s close intent exactly once from a later %s drain"):format(case.lhs, case.drain),
			function()
				local parent_win = parent(80, 20)
				local state = { showing_help = true, revision = 7, schedules = 0, draws = 0 }
				local callbacks = 0
				local instance = open(parent_win, {
					on_close = function()
						callbacks = callbacks + 1
						state.showing_help = false
					end,
				})
				local ids = { win = instance.win, buf = instance.buf, augroup = instance.augroup }
				local attempts = block_owned_cleanup(instance, "retained user close")
				local ok, err = pcall(close_mapping(instance, case.lhs))
				assert.is_false(ok)
				assert.is_truthy(tostring(err):find("retained user close", 1, true))
				assert.is_true(instance.close_notification_pending)
				assert.is_false(instance.close_notification_delivered)
				assert.equals(0, callbacks)
				assert.equals(ids.win, instance.win)
				assert.equals(ids.buf, instance.buf)
				assert.equals(ids.augroup, instance.augroup)
				assert.is_true(is_valid_win(ids.win))
				assert.is_true(is_valid_buf(ids.buf))
				assert.same({ namespace = 2, augroup = 2, window = 2, buffer = 2 }, attempts)
				restore_patches()

				if case.drain == "current" then
					assert.is_nil(help.current())
				else
					local reopened, created = help.open({
						parent_win = parent_win,
						ui = config.ui(),
						output = output(),
						on_close = function()
							error("draining open must not acquire a replacement", 0)
						end,
					})
					assert.is_nil(reopened)
					assert.is_false(created)
				end
				assert.equals(parent_win, vim.api.nvim_get_current_win())
				assert.equals(1, callbacks)
				assert.is_false(state.showing_help)
				assert.equals(7, state.revision)
				assert.equals(0, state.schedules)
				assert.equals(0, state.draws)
				assert.is_false(instance.close_notification_pending)
				assert.is_true(instance.close_notification_delivered)
				assert.is_nil(help.current())
				assert.equals(1, callbacks)
				assert.is_false(is_valid_win(ids.win))
				assert.is_false(is_valid_buf(ids.buf))
				assert_augroup_invalid(ids.augroup)
			end
		)
	end

	for _, cancellation in ipairs({ "parent", "main" }) do
		it("keeps persistent user intent pending and lets " .. cancellation .. " close cancel it", function()
			local parent_win = parent(80, 20)
			local callbacks = 0
			local instance = open(parent_win, {
				on_close = function()
					callbacks = callbacks + 1
				end,
			})
			block_owned_cleanup(instance, "persistent user close")
			local ok = pcall(close_mapping(instance, "q"))
			assert.is_false(ok)
			assert.is_true(instance.close_notification_pending)
			assert.is_false(instance.close_notification_delivered)
			assert.equals(0, callbacks)
			assert.has_error(help.current, "persistent user close")
			assert.has_error(function()
				help.open({
					parent_win = parent_win,
					ui = config.ui(),
					output = output(),
					on_close = function() end,
				})
			end, "persistent user close")
			assert.is_true(instance.close_notification_pending)
			if cancellation == "parent" then
				vim.api.nvim_win_close(parent_win, true)
			else
				assert.has_error(function()
					help.close(false)
				end, "persistent user close")
			end
			assert.is_false(instance.close_notification_pending)
			assert.is_false(instance.close_notification_delivered)
			assert.equals(0, callbacks)
			restore_patches()
			assert.is_nil(help.current())
			assert.equals(0, callbacks)
		end)
	end

	it("retries retained one-shot cleanup from close current and open", function()
		for _, entry in ipairs({ "close", "current", "open" }) do
			close_all()
			local parent_win = parent(80, 20)
			local instance = open(parent_win)
			local group = instance.augroup
			local real = vim.api.nvim_del_augroup_by_id
			local failed = false
			patch_api("nvim_del_augroup_by_id", function(id)
				if id == group and not failed then
					failed = true
					error("one-shot retirement failure", 0)
				end
				return real(id)
			end)
			local ok, err = pcall(instance.close, instance, false)
			assert.is_false(ok, entry)
			assert.is_truthy(tostring(err):find("one%-shot retirement failure"), entry)
			restore_patches()
			if entry == "close" then
				instance:close(false)
			elseif entry == "current" then
				assert.is_nil(help.current())
			else
				local reopened, created = open(parent_win)
				assert.is_true(created)
				assert.is_true(reopened:valid())
			end
			assert_augroup_invalid(group)
		end
	end)

	it("bounds cleanup to two passes and reports the first one-shot failure", function()
		local parent_win = parent(80, 20)
		local instance = open(parent_win)
		local group = instance.augroup
		local real = vim.api.nvim_del_augroup_by_id
		local attempts = 0
		patch_api("nvim_del_augroup_by_id", function(id)
			if id == group then
				attempts = attempts + 1
				if attempts == 1 then
					error("first cleanup pass failed", 0)
				elseif attempts > 2 then
					error("third cleanup pass", 0)
				end
			end
			return real(id)
		end)
		local ok, err = pcall(instance.close, instance, false)
		assert.is_false(ok)
		assert.is_truthy(tostring(err):find("first cleanup pass failed", 1, true))
		assert.equals(2, attempts)
		assert.is_nil(help.current())
		assert.equals(2, attempts)
	end)

	it("blocks current and reopen behind persistent retained cleanup", function()
		local parent_win = parent(80, 20)
		local instance = open(parent_win)
		local group = instance.augroup
		local before = snapshot()
		local real = vim.api.nvim_del_augroup_by_id
		patch_api("nvim_del_augroup_by_id", function(id)
			if id == group then
				error("persistent retirement failure", 0)
			end
			return real(id)
		end)
		assert.has_error(function()
			instance:close(false)
		end, "persistent retirement failure")
		local focused = vim.api.nvim_get_current_win()
		assert.has_error(help.current, "persistent retirement failure")
		assert.has_error(function()
			help.open({
				parent_win = parent_win,
				ui = config.ui(),
				output = output(),
				on_close = function() end,
			})
		end, "persistent retirement failure")
		assert.equals(focused, vim.api.nvim_get_current_win())
		assert_snapshot(before)
		restore_patches()
		assert.is_nil(help.current())
	end)

	it("preserves an initiating draw error over persistent cleanup errors", function()
		local parent_win = parent(80, 20)
		local instance = open(parent_win)
		fail_api("nvim_buf_set_lines", function()
			return true
		end, "initiating draw failure")
		local real = vim.api.nvim_del_augroup_by_id
		local group = instance.augroup
		patch_api("nvim_del_augroup_by_id", function(id)
			if id == group then
				error("cleanup failure", 0)
			end
			return real(id)
		end)
		local ok, err = pcall(instance.draw, instance, output(3))
		assert.is_false(ok)
		assert.is_truthy(tostring(err):find("initiating draw failure", 1, true))
		assert.is_nil(tostring(err):find("cleanup failure", 1, true))
	end)
end)
