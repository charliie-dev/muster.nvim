---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")
local window = require("muster.ui.window")

local saved_api = {}
local saved_fn = {}
local original_options
local original_normal
local instances = {}

local function patch_api(name, replacement)
	if saved_api[name] == nil then
		saved_api[name] = vim.api[name]
	end
	vim.api[name] = replacement
end

local function patch_fn(name, replacement)
	if saved_fn[name] == nil then
		saved_fn[name] = vim.fn[name]
	end
	vim.fn[name] = replacement
end

local function restore_patches()
	for name, value in pairs(saved_api) do
		vim.api[name] = value
	end
	for name, value in pairs(saved_fn) do
		vim.fn[name] = value
	end
	saved_api = {}
	saved_fn = {}
end

local function ui(overrides)
	config.reset()
	config.setup({ ui = overrides or {} })
	return vim.deepcopy(config.ui())
end

local function opts(overrides)
	overrides = overrides or {}
	return {
		source_bufnr = overrides.source_bufnr or vim.api.nvim_get_current_buf(),
		ui = overrides.ui or ui(),
		on_resize = overrides.on_resize or function() end,
		on_error = overrides.on_error or function(err)
			error(err, 0)
		end,
	}
end

local function open(overrides)
	local instance, created = window.open(opts(overrides))
	instances[#instances + 1] = instance
	return instance, created
end

local function is_valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function assert_retired(instance)
	assert.is_nil(window.current())
	assert.is_false(is_valid_win(instance.win))
	assert.is_false(is_valid_win(instance.backdrop_win))
	assert.is_false(is_valid_buf(instance.buf))
	assert.is_false(is_valid_buf(instance.backdrop_buf))
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

local function resource_ids(instance)
	return {
		win = instance.win,
		backdrop_win = instance.backdrop_win,
		buf = instance.buf,
		backdrop_buf = instance.backdrop_buf,
		augroup = instance.augroup,
	}
end

local function assert_resource_ids_invalid(ids)
	assert.is_false(is_valid_win(ids.win))
	assert.is_false(is_valid_win(ids.backdrop_win))
	assert.is_false(is_valid_buf(ids.buf))
	assert.is_false(is_valid_buf(ids.backdrop_buf))
end

local function assert_augroup_invalid(group)
	local ok = pcall(vim.api.nvim_get_autocmds, { group = group })
	assert.is_false(ok, "augroup remains valid: " .. group)
end

local function output(line_by_key, anchors)
	local lines = {}
	for index = 1, 60 do
		lines[index] = ("line %02d %s"):format(index, string.rep("x", 100))
	end
	return {
		lines = lines,
		extmarks = {
			{ line = 0, col = 0, opts = { end_col = 4, hl_group = "MusterHeader" } },
			{ line = 1, col = 5, opts = { end_col = 9, hl_group = "MusterMuted" } },
		},
		virtual_text = {
			{ line = 2, chunks = { { "right", "MusterAdapter" } }, pos = "right_align" },
			{ line = 3, chunks = { { "tail", "MusterMuted" } } },
		},
		row_by_line = {},
		line_by_key = line_by_key or { selected = 30 },
		anchors = anchors or { title = 1, tabs = 3, body = 5 },
		revision = 1,
	}
end

local function autocmd_count(group)
	local ok, commands = pcall(vim.api.nvim_get_autocmds, { group = group })
	return ok and #commands or 0
end

local function close_all()
	restore_patches()
	for _ = 1, 4 do
		local ok, current = pcall(window.current)
		if ok and current then
			pcall(current.close, current)
		end
		for _, instance in ipairs(instances) do
			pcall(instance.close, instance)
		end
	end
	instances = {}
end

local function with_open_spy(callback)
	local calls = {}
	local real = vim.api.nvim_open_win
	patch_api("nvim_open_win", function(buf, enter, win_config)
		calls[#calls + 1] = { buf = buf, enter = enter, config = vim.deepcopy(win_config) }
		return real(buf, enter, win_config)
	end)
	local result = callback(calls)
	restore_patches()
	return result
end

local function assert_main_options(instance)
	assert.equals("nofile", vim.bo[instance.buf].buftype)
	assert.equals("wipe", vim.bo[instance.buf].bufhidden)
	assert.is_false(vim.bo[instance.buf].swapfile)
	assert.is_false(vim.bo[instance.buf].modifiable)
	assert.is_false(vim.bo[instance.buf].buflisted)
	assert.equals(-1, vim.bo[instance.buf].undolevels)
	assert.equals(0, vim.bo[instance.buf].textwidth)
	assert.equals("muster", vim.bo[instance.buf].filetype)
	assert.is_false(vim.wo[instance.win].number)
	assert.is_false(vim.wo[instance.win].relativenumber)
	assert.is_false(vim.wo[instance.win].wrap)
	assert.is_false(vim.wo[instance.win].spell)
	assert.is_false(vim.wo[instance.win].foldenable)
	assert.equals("no", vim.wo[instance.win].signcolumn)
	assert.equals("", vim.wo[instance.win].colorcolumn)
	assert.is_true(vim.wo[instance.win].cursorline)
	assert.equals("Normal:MusterNormal", vim.wo[instance.win].winhighlight)
end

local function assert_backdrop_options(instance, blend)
	assert.equals("nofile", vim.bo[instance.backdrop_buf].buftype)
	assert.equals("wipe", vim.bo[instance.backdrop_buf].bufhidden)
	assert.is_false(vim.bo[instance.backdrop_buf].swapfile)
	assert.is_false(vim.bo[instance.backdrop_buf].buflisted)
	assert.equals("muster_backdrop", vim.bo[instance.backdrop_buf].filetype)
	assert.equals(blend, vim.wo[instance.backdrop_win].winblend)
	assert.equals("Normal:MusterBackdrop", vim.wo[instance.backdrop_win].winhighlight)
end

local function find_call(calls, zindex)
	for _, call in ipairs(calls) do
		if call.config.zindex == zindex then
			return call
		end
	end
end

local function fail_api(name, predicate, message)
	local real = vim.api[name]
	local count = 0
	patch_api(name, function(...)
		count = count + 1
		if predicate(count, ...) then
			error(message, 0)
		end
		return real(...)
	end)
end

local function install_construction_failpoint(case, captured)
	local create_buf = vim.api.nvim_create_buf
	local create_buf_calls = 0
	patch_api("nvim_create_buf", function(...)
		create_buf_calls = create_buf_calls + 1
		if case.stage == "buffer" and create_buf_calls == case.index then
			error("construction failed: " .. case.name, 0)
		end
		local buf = create_buf(...)
		captured.buffers[#captured.buffers + 1] = buf
		return buf
	end)

	local set_option = vim.api.nvim_set_option_value
	local option_failed = false
	patch_api("nvim_set_option_value", function(name, value, scope)
		local target
		if case.stage == "buffer_options" then
			target = captured.buffers[case.index]
		elseif case.stage == "window_options" then
			target = captured.windows[case.index]
		end
		local matches = case.stage == "buffer_options" and target ~= nil and scope.buf == target
			or case.stage == "window_options" and target ~= nil and scope.win == target
		if matches and not option_failed then
			option_failed = true
			captured.failed_option_scope = vim.deepcopy(scope)
			error("construction failed: " .. case.name, 0)
		end
		return set_option(name, value, scope)
	end)

	local open_win = vim.api.nvim_open_win
	local open_win_calls = 0
	patch_api("nvim_open_win", function(...)
		open_win_calls = open_win_calls + 1
		if case.stage == "window" and open_win_calls == case.index then
			error("construction failed: " .. case.name, 0)
		end
		local win = open_win(...)
		captured.windows[#captured.windows + 1] = win
		return win
	end)

	local create_augroup = vim.api.nvim_create_augroup
	patch_api("nvim_create_augroup", function(...)
		if case.stage == "augroup" then
			error("construction failed: " .. case.name, 0)
		end
		local group = create_augroup(...)
		captured.augroup = group
		return group
	end)

	local create_autocmd = vim.api.nvim_create_autocmd
	local autocmd_calls = 0
	patch_api("nvim_create_autocmd", function(...)
		autocmd_calls = autocmd_calls + 1
		if case.stage == "autocmd" and autocmd_calls == case.index then
			error("construction failed: " .. case.name, 0)
		end
		local autocmd = create_autocmd(...)
		captured.autocmds[#captured.autocmds + 1] = autocmd
		return autocmd
	end)
end

local function exec_resize()
	return pcall(vim.api.nvim_exec_autocmds, "VimResized", { modeline = false })
end

local function with_option_values(values, callback)
	local real_options = vim.o
	vim.o = setmetatable({}, {
		__index = function(_, key)
			if values[key] ~= nil then
				return values[key]
			end
			return real_options[key]
		end,
		__newindex = function(_, key, value)
			real_options[key] = value
		end,
	})
	local ok, err = pcall(callback)
	vim.o = real_options
	if not ok then
		error(err, 0)
	end
end

describe("muster.ui.window", function()
	before_each(function()
		original_options = {
			columns = vim.o.columns,
			lines = vim.o.lines,
			cmdheight = vim.o.cmdheight,
			termguicolors = vim.o.termguicolors,
		}
		original_normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
		vim.o.termguicolors = true
		vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x101010 })
	end)

	after_each(function()
		close_all()
		vim.o.columns = original_options.columns
		vim.o.lines = original_options.lines
		vim.o.cmdheight = original_options.cmdheight
		vim.o.termguicolors = original_options.termguicolors
		vim.api.nvim_set_hl(0, "Normal", original_normal)
		config.reset()
	end)

	it("uses the exact geometry, configs, and owned options", function()
		local cases = {
			{
				columns = 120,
				lines = 40,
				cmdheight = 1,
				width = 0.8,
				height = 0.8,
				border = "rounded",
				expected = { width = 96, height = 31, col = 11, row = 3, border = "rounded" },
			},
			{
				columns = 120,
				lines = 40,
				cmdheight = 1,
				width = 0.8,
				height = 0.8,
				border = "none",
				expected = { width = 96, height = 31, col = 12, row = 4, border = "none" },
			},
			{
				columns = 120,
				lines = 40,
				cmdheight = 1,
				width = 40,
				height = 10,
				border = "rounded",
				expected = { width = 40, height = 10, col = 39, row = 13, border = "rounded" },
			},
			{
				columns = 120,
				lines = 40,
				cmdheight = 2,
				width = 0.8,
				height = 0.8,
				border = "rounded",
				expected = { width = 96, height = 30, col = 11, row = 3, border = "rounded" },
			},
			{
				columns = 2,
				lines = 3,
				cmdheight = 2,
				width = 100,
				height = 100,
				border = "rounded",
				expected = { width = 2, height = 1, col = 0, row = 0, border = "none" },
			},
		}
		for _, case in ipairs(cases) do
			close_all()
			if case.columns > 2 then
				vim.o.columns = case.columns
				vim.o.lines = case.lines
				vim.o.cmdheight = case.cmdheight
			end
			-- Headless Nvim clamps the screen height; the proxy covers the contracted 2x3 viewport.
			with_option_values(case, function()
				with_open_spy(function(calls)
					local instance = open({
						ui = ui({
							width = case.width,
							height = case.height,
							border = case.border,
						}),
					})
					local main = assert(find_call(calls, 50), "missing main open")
					assert.same(
						vim.tbl_extend("force", {
							relative = "editor",
							style = "minimal",
							focusable = true,
							zindex = 50,
						}, case.expected),
						main.config
					)
					assert_main_options(instance)
				end)
			end)
		end
	end)

	it("creates the exact backdrop only when all eligibility checks pass", function()
		vim.o.columns = 120
		vim.o.lines = 40
		vim.o.cmdheight = 2
		with_open_spy(function(calls)
			local instance = open({ ui = ui({ backdrop = 37 }) })
			local backdrop = assert(find_call(calls, 49), "missing backdrop open")
			assert.same({
				relative = "editor",
				row = 0,
				col = 0,
				width = 120,
				height = 38,
				style = "minimal",
				border = "none",
				focusable = false,
				zindex = 49,
			}, backdrop.config)
			assert_backdrop_options(instance, 37)
		end)

		local omissions = {
			{
				name = "blend 100",
				prepare = function() end,
				ui = { backdrop = 100 },
			},
			{
				name = "termguicolors disabled",
				prepare = function()
					vim.o.termguicolors = false
				end,
				ui = { backdrop = 37 },
			},
			{
				name = "Normal background absent",
				prepare = function()
					vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff })
				end,
				ui = { backdrop = 37 },
			},
			{
				name = "non-integer Normal background",
				prepare = function()
					patch_api("nvim_get_hl", function()
						return { bg = 1.5 }
					end)
				end,
				ui = { backdrop = 37 },
			},
			{
				name = "highlight inspection failure",
				prepare = function()
					patch_api("nvim_get_hl", function()
						error("highlight inspection failed", 0)
					end)
				end,
				ui = { backdrop = 37 },
			},
		}
		for _, case in ipairs(omissions) do
			close_all()
			vim.o.termguicolors = true
			vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x101010 })
			case.prepare()
			with_open_spy(function(calls)
				local instance = open({ ui = ui(case.ui) })
				assert.is_nil(instance.backdrop_win, case.name)
				assert.is_nil(instance.backdrop_buf, case.name)
				assert.is_nil(find_call(calls, 49), case.name)
			end)
		end
	end)

	it("draws every exact copied mark once and restores scroll with selected identity", function()
		local instance = open({ ui = ui({ backdrop = 100 }) })
		vim.api.nvim_win_call(instance.win, function()
			vim.api.nvim_buf_set_option(instance.buf, "modifiable", true)
			vim.api.nvim_buf_set_lines(instance.buf, 0, -1, false, output().lines)
			vim.api.nvim_buf_set_option(instance.buf, "modifiable", false)
			vim.fn.winrestview({ lnum = 20, col = 0, topline = 10, leftcol = 7 })
		end)
		local rendered = output({ selected = 30 })
		local set_lines_calls = 0
		local real_set_lines = vim.api.nvim_buf_set_lines
		patch_api("nvim_buf_set_lines", function(...)
			set_lines_calls = set_lines_calls + 1
			return real_set_lines(...)
		end)
		local extmark_calls = {}
		local real_set_extmark = vim.api.nvim_buf_set_extmark
		patch_api("nvim_buf_set_extmark", function(buf, ns, line, col, mark_opts)
			extmark_calls[#extmark_calls + 1] = {
				buf = buf,
				ns = ns,
				line = line,
				col = col,
				opts = vim.deepcopy(mark_opts),
				opts_ref = mark_opts,
			}
			return real_set_extmark(buf, ns, line, col, mark_opts)
		end)
		instance:draw(rendered, "selected")
		restore_patches()

		assert.equals(1, set_lines_calls)
		assert.is_false(vim.bo[instance.buf].modifiable)
		local namespace = vim.api.nvim_create_namespace("muster_ui")
		local expected = {
			{
				buf = instance.buf,
				ns = namespace,
				line = 0,
				col = 0,
				opts = { end_col = 4, hl_group = "MusterHeader" },
			},
			{
				buf = instance.buf,
				ns = namespace,
				line = 1,
				col = 5,
				opts = { end_col = 9, hl_group = "MusterMuted" },
			},
			{
				buf = instance.buf,
				ns = namespace,
				line = 2,
				col = 0,
				opts = {
					virt_text = { { "right", "MusterAdapter" } },
					virt_text_pos = "right_align",
				},
			},
			{
				buf = instance.buf,
				ns = namespace,
				line = 3,
				col = 0,
				opts = {
					virt_text = { { "tail", "MusterMuted" } },
					virt_text_pos = "eol",
				},
			},
		}
		local captured = {}
		for _, call in ipairs(extmark_calls) do
			captured[#captured + 1] = {
				buf = call.buf,
				ns = call.ns,
				line = call.line,
				col = call.col,
				opts = call.opts,
			}
		end
		assert.same(expected, captured)
		assert.is_true(extmark_calls[1].opts_ref ~= rendered.extmarks[1].opts)
		assert.is_true(extmark_calls[2].opts_ref ~= rendered.extmarks[2].opts)
		for index, call_index in ipairs({ 3, 4 }) do
			local source_chunks = rendered.virtual_text[index].chunks
			local passed_chunks = extmark_calls[call_index].opts_ref.virt_text
			assert.is_true(passed_chunks ~= source_chunks)
			for chunk_index, source_chunk in ipairs(source_chunks) do
				assert.is_true(passed_chunks[chunk_index] ~= source_chunk)
			end
		end

		rendered.extmarks[1].opts.end_col = 1
		rendered.extmarks[1].opts.hl_group = "Changed"
		rendered.extmarks[2].opts.end_col = 6
		rendered.virtual_text[1].chunks[1][1] = "changed"
		rendered.virtual_text[1].chunks[1][2] = "Changed"
		rendered.virtual_text[2].chunks[1][1] = "changed tail"
		rendered.virtual_text[2].chunks[1][2] = "Changed tail"
		assert.same(expected, captured)
		assert.same(expected[3].opts, extmark_calls[3].opts_ref)
		assert.same(expected[4].opts, extmark_calls[4].opts_ref)

		local stored = vim.api.nvim_buf_get_extmarks(instance.buf, namespace, 0, -1, { details = true })
		local stored_projection = {}
		for index, mark in ipairs(stored) do
			local details = mark[4]
			local mark_opts
			if index <= 2 then
				mark_opts = { end_col = details.end_col, hl_group = details.hl_group }
			else
				mark_opts = { virt_text = details.virt_text, virt_text_pos = details.virt_text_pos }
			end
			stored_projection[#stored_projection + 1] = {
				buf = instance.buf,
				ns = namespace,
				line = mark[2],
				col = mark[3],
				opts = mark_opts,
			}
		end
		assert.same(expected, stored_projection)

		local view = vim.api.nvim_win_call(instance.win, vim.fn.winsaveview)
		assert.equals(30, view.lnum)
		assert.equals(0, view.col)
		assert.equals(10, view.topline)
		assert.equals(7, view.leftcol)

		vim.api.nvim_win_call(instance.win, function()
			vim.fn.winrestview({ lnum = 30, col = 0, topline = 12, leftcol = 9 })
		end)
		instance:draw(output({ selected = 42 }), "selected")
		view = vim.api.nvim_win_call(instance.win, vim.fn.winsaveview)
		assert.equals(42, view.lnum)
		assert.equals(12, view.topline)
		assert.equals(9, view.leftcol)
	end)

	it("uses body, tabs, title, then line one as exact draw cursor fallbacks", function()
		local cases = {
			{ anchors = { title = 1, tabs = 3, body = 5 }, expected = 5 },
			{ anchors = { title = 1, tabs = 3 }, expected = 3 },
			{ anchors = { title = 2 }, expected = 2 },
			{ anchors = {}, expected = 1 },
		}
		for _, case in ipairs(cases) do
			close_all()
			local instance = open({ ui = ui({ backdrop = 100 }) })
			instance:draw(output({}, case.anchors), "removed")
			assert.equals(case.expected, instance:cursor_line())
		end
	end)

	it("retires on every draw failpoint, restores modifiable, and preserves the initiating error", function()
		local cases = {
			{
				name = "capture nvim_win_call",
				api = "nvim_win_call",
				predicate = function(count)
					return count == 1
				end,
			},
			{
				name = "winsaveview",
				fn = "winsaveview",
			},
			{
				name = "modifiable true",
				api = "nvim_set_option_value",
				predicate = function(_, name, value)
					return name == "modifiable" and value == true
				end,
			},
			{
				name = "set lines",
				api = "nvim_buf_set_lines",
				predicate = function()
					return true
				end,
			},
			{
				name = "modifiable false",
				api = "nvim_set_option_value",
				predicate = function(_, name, value)
					return name == "modifiable" and value == false
				end,
			},
			{
				name = "namespace clear",
				api = "nvim_buf_clear_namespace",
				predicate = function()
					return true
				end,
			},
			{
				name = "first highlight",
				api = "nvim_buf_set_extmark",
				predicate = function(count)
					return count == 1
				end,
			},
			{
				name = "second highlight",
				api = "nvim_buf_set_extmark",
				predicate = function(count)
					return count == 2
				end,
			},
			{
				name = "first virtual text",
				api = "nvim_buf_set_extmark",
				predicate = function(count)
					return count == 3
				end,
			},
			{
				name = "second virtual text",
				api = "nvim_buf_set_extmark",
				predicate = function(count)
					return count == 4
				end,
			},
			{ name = "winrestview", fn = "winrestview" },
			{
				name = "restore nvim_win_call",
				api = "nvim_win_call",
				predicate = function(count)
					return count == 2
				end,
			},
		}
		for _, case in ipairs(cases) do
			close_all()
			local instance = open({ ui = ui({ backdrop = 100 }) })
			local message = "draw fail: " .. case.name
			if case.api then
				fail_api(case.api, case.predicate, message)
			else
				patch_fn(case.fn, function()
					error(message, 0)
				end)
			end
			local ok, err = pcall(instance.draw, instance, output(), "selected")
			restore_patches()
			assert.is_false(ok, case.name)
			assert.is_truthy(tostring(err):find(message, 1, true), case.name)
			assert.is_false(is_valid_buf(instance.buf) and vim.bo[instance.buf].modifiable, case.name)
			assert_retired(instance)
		end
	end)

	it("retires transactionally when a later mapping fails and reopens cleanly", function()
		local instance = open({ ui = ui({ backdrop = 100 }) })
		instance:map("a", function() end, "first")
		local real_set = vim.keymap.set
		local calls = 0
		vim.keymap.set = function(...)
			calls = calls + 1
			if calls == 2 then
				error("second mapping failed", 0)
			end
			return real_set(...)
		end
		instance:map("b", function() end, "second")
		local ok, err = pcall(instance.map, instance, "c", function() end, "third")
		vim.keymap.set = real_set
		assert.is_false(ok)
		assert.is_truthy(tostring(err):find("second mapping failed", 1, true))
		assert_retired(instance)
		local reopened = open({ ui = ui({ backdrop = 100 }) })
		reopened:map("a", function() end, "first")
		reopened:map("b", function() end, "second")
		reopened:map("c", function() end, "third")
		assert.equals(3, #vim.api.nvim_buf_get_keymap(reopened.buf, "n"))
	end)

	it("relayouts main then backdrop, reapplies options, and calls resize once", function()
		vim.o.columns = 100
		vim.o.lines = 30
		vim.o.cmdheight = 1
		local resized = 0
		local instance
		instance = open({
			ui = ui({ width = 0.5, height = 0.5, border = "rounded", backdrop = 25 }),
			on_resize = function(value)
				assert.equals(instance, value)
				resized = resized + 1
			end,
		})
		vim.wo[instance.win].wrap = true
		vim.wo[instance.backdrop_win].winblend = 0
		vim.o.columns = 120
		vim.o.lines = 40
		vim.o.cmdheight = 2
		local order = {}
		local real_config = vim.api.nvim_win_set_config
		patch_api("nvim_win_set_config", function(win, win_config)
			order[#order + 1] = win
			return real_config(win, win_config)
		end)
		assert.is_true(exec_resize())
		restore_patches()
		assert.same({ instance.win, instance.backdrop_win }, order)
		assert.equals(1, resized)
		assert.equals(60, instance:content_width())
		assert_main_options(instance)
		assert_backdrop_options(instance, 25)
		local main = vim.api.nvim_win_get_config(instance.win)
		assert.equals(60, main.width)
		assert.equals(19, main.height)
		assert.equals(29, main.col)
		assert.equals(8, main.row)
		local backdrop = vim.api.nvim_win_get_config(instance.backdrop_win)
		assert.equals(120, backdrop.width)
		assert.equals(38, backdrop.height)
	end)

	it("contains every resize failure, retires once, and reports the original error once", function()
		local cases = {
			{
				name = "geometry",
				install = function(instance)
					instance.ui.width = {}
				end,
			},
			{
				name = "main config",
				install = function(instance)
					fail_api("nvim_win_set_config", function(_, win)
						return win == instance.win
					end, "main config failed")
				end,
			},
			{
				name = "backdrop config",
				install = function(instance)
					fail_api("nvim_win_set_config", function(_, win)
						return win == instance.backdrop_win
					end, "backdrop config failed")
				end,
			},
			{
				name = "main option",
				install = function(instance)
					fail_api("nvim_set_option_value", function(_, name, _, scope)
						return name == "number" and scope.win == instance.win
					end, "main option failed")
				end,
			},
			{
				name = "backdrop option",
				install = function(instance)
					fail_api("nvim_set_option_value", function(_, name, _, scope)
						return name == "winblend" and scope.win == instance.backdrop_win
					end, "backdrop option failed")
				end,
			},
			{
				name = "callback",
				callback = function()
					error("resize callback failed", 0)
				end,
				install = function() end,
			},
		}
		for _, case in ipairs(cases) do
			close_all()
			local errors = {}
			local instance = open({
				ui = ui({ backdrop = 25 }),
				on_resize = case.callback or function() end,
				on_error = function(err)
					errors[#errors + 1] = tostring(err)
					error("on_error must be contained", 0)
				end,
			})
			case.install(instance)
			local ok = exec_resize()
			restore_patches()
			assert.is_true(ok, case.name)
			assert.equals(1, #errors, case.name)
			local expected = case.name == "geometry" and "compare" or "failed"
			assert.is_truthy(errors[1]:find(expected, 1, true), case.name)
			assert_retired(instance)
		end
	end)

	it("no-ops resize while closing or invalid", function()
		local resized = 0
		local instance = open({
			ui = ui({ backdrop = 100 }),
			on_resize = function()
				resized = resized + 1
			end,
		})
		vim.api.nvim_win_close(instance.win, true)
		assert.is_true(exec_resize())
		assert.equals(0, resized)
		assert_retired(instance)
	end)

	it("returns and focuses the unchanged singleton without acquiring resources", function()
		local first_opts = opts({ source_bufnr = 17, ui = ui({ backdrop = 100 }) })
		local instance, created = window.open(first_opts)
		instances[#instances + 1] = instance
		assert.is_true(created)
		local before = snapshot()
		local second_opts = opts({ source_bufnr = 29, ui = ui({ width = 0.5, backdrop = 100 }) })
		local same, second_created = window.open(second_opts)
		assert.equals(instance, same)
		assert.is_false(second_created)
		assert.equals(17, same.source_bufnr)
		assert.equals(first_opts.ui, same.ui)
		assert.equals(instance.win, vim.api.nvim_get_current_win())
		assert_snapshot(before)
		assert.equals(instance, window.current())
		assert.is_true(instance:valid())
	end)

	it("scopes lifecycle events and every owned close ordering retires exactly once", function()
		local instance = open({ ui = ui({ backdrop = 25 }) })
		local other_buf = vim.api.nvim_create_buf(false, true)
		local other_win = vim.api.nvim_open_win(other_buf, false, {
			relative = "editor",
			row = 0,
			col = 0,
			width = 1,
			height = 1,
			style = "minimal",
		})
		vim.api.nvim_exec_autocmds("WinClosed", { pattern = tostring(other_win), modeline = false })
		for _, event in ipairs({ "BufHidden", "BufDelete", "BufWipeout" }) do
			vim.api.nvim_exec_autocmds(event, { buffer = other_buf, modeline = false })
		end
		assert.equals(instance, window.current())
		assert.is_true(instance:valid())
		vim.api.nvim_win_close(other_win, true)
		vim.api.nvim_buf_delete(other_buf, { force = true })

		local triggers = {
			function(value)
				vim.api.nvim_exec_autocmds("WinClosed", { pattern = tostring(value.win), modeline = false })
			end,
			function(value)
				vim.api.nvim_exec_autocmds("BufHidden", { buffer = value.buf, modeline = false })
			end,
			function(value)
				vim.api.nvim_exec_autocmds("BufDelete", { buffer = value.buf, modeline = false })
			end,
			function(value)
				vim.api.nvim_exec_autocmds("BufWipeout", { buffer = value.buf, modeline = false })
			end,
			function(value)
				vim.api.nvim_win_close(value.win, true)
			end,
			function(value)
				vim.api.nvim_buf_delete(value.buf, { force = true })
			end,
		}
		instance:close()
		for _, trigger in ipairs(triggers) do
			local value = open({ ui = ui({ backdrop = 25 }) })
			trigger(value)
			assert_retired(value)
			local reopened = open({ ui = ui({ backdrop = 25 }) })
			assert.is_true(reopened:valid())
			reopened:close()
		end
	end)

	it("best-effort retires invalid active resources and never focuses backdrop", function()
		local instance = open({ ui = ui({ backdrop = 25 }) })
		vim.api.nvim_win_close(instance.win, true)
		assert.is_nil(window.current())
		assert_retired(instance)
		local reopened = open({ ui = ui({ backdrop = 25 }) })
		reopened:focus()
		assert.equals(reopened.win, vim.api.nvim_get_current_win())
		assert.is_not.equals(reopened.backdrop_win, vim.api.nvim_get_current_win())
	end)

	it("publishes active only after every construction stage succeeds", function()
		local cases = {
			{ name = "first buffer", stage = "buffer", index = 1 },
			{ name = "main buffer options", stage = "buffer_options", index = 1 },
			{ name = "second buffer", stage = "buffer", index = 2 },
			{ name = "backdrop buffer options", stage = "buffer_options", index = 2 },
			{ name = "first window", stage = "window", index = 1 },
			{ name = "backdrop window options", stage = "window_options", index = 1 },
			{ name = "second window", stage = "window", index = 2 },
			{ name = "main window options", stage = "window_options", index = 2 },
			{ name = "augroup", stage = "augroup" },
		}
		for index = 1, 5 do
			cases[#cases + 1] = { name = "autocmd " .. index, stage = "autocmd", index = index }
		end
		for _, case in ipairs(cases) do
			close_all()
			local before = snapshot()
			local captured = { buffers = {}, windows = {}, autocmds = {} }
			install_construction_failpoint(case, captured)
			local ok, err = pcall(window.open, opts({ ui = ui({ backdrop = 25 }) }))
			restore_patches()
			assert.is_false(ok, case.name)
			assert.is_truthy(tostring(err):find("construction failed", 1, true), case.name)
			if case.name == "backdrop buffer options" then
				assert.equals(captured.buffers[2], captured.failed_option_scope.buf)
			end
			for _, win in ipairs(captured.windows) do
				assert.is_false(vim.api.nvim_win_is_valid(win), case.name)
			end
			for _, buf in ipairs(captured.buffers) do
				assert.is_false(vim.api.nvim_buf_is_valid(buf), case.name)
			end
			if captured.augroup then
				assert_augroup_invalid(captured.augroup)
			end
			for _, autocmd in ipairs(captured.autocmds) do
				assert.same({}, vim.api.nvim_get_autocmds({ id = autocmd }), case.name)
			end
			assert_snapshot(before)
			assert.is_nil(window.current(), case.name)
		end
		local instance, created = open({ ui = ui({ backdrop = 25 }) })
		assert.is_true(created)
		assert.equals(instance, window.current())
		assert.is_true(instance:valid())
		assert.equals(5, autocmd_count(instance.augroup))
	end)

	it("retries retained cleanup from close, current, and open before proceeding", function()
		for _, entry in ipairs({ "close", "current", "open" }) do
			close_all()
			local instance = open({ ui = ui({ backdrop = 100 }) })
			local group = instance.augroup
			local real_delete = vim.api.nvim_del_augroup_by_id
			patch_api("nvim_del_augroup_by_id", function(id)
				if id == group then
					error("retirement blocked", 0)
				end
				return real_delete(id)
			end)
			local ok, err = pcall(instance.close, instance)
			assert.is_false(ok, entry)
			assert.is_truthy(tostring(err):find("retirement blocked", 1, true), entry)
			restore_patches()
			if entry == "close" then
				instance:close()
				assert.is_nil(window.current())
			elseif entry == "current" then
				assert.is_nil(window.current())
			else
				local reopened, created = open({ ui = ui({ backdrop = 100 }) })
				assert.is_true(created)
				assert.is_true(reopened:valid())
			end
			assert.equals(0, autocmd_count(group))
		end
	end)

	it("blocks current and open behind persistent retirement without creating or focusing", function()
		local instance = open({ ui = ui({ backdrop = 100 }) })
		local group = instance.augroup
		local before = snapshot()
		local real_delete = vim.api.nvim_del_augroup_by_id
		patch_api("nvim_del_augroup_by_id", function(id)
			if id == group then
				error("persistent retirement failure", 0)
			end
			return real_delete(id)
		end)
		assert.has_error(function()
			instance:close()
		end, "persistent retirement failure")
		local unfocused_win = vim.api.nvim_get_current_win()
		assert.has_error(window.current, "persistent retirement failure")
		assert.has_error(function()
			window.open(opts({ ui = ui({ backdrop = 100 }) }))
		end, "persistent retirement failure")
		assert.equals(unfocused_win, vim.api.nvim_get_current_win())
		assert_snapshot(before)
		restore_patches()
		assert.is_nil(window.current())
		local reopened, created = open({ ui = ui({ backdrop = 100 }) })
		assert.is_true(created)
		assert.is_true(reopened:valid())
	end)

	it("bounds one-shot retirement to a failed first pass and successful second pass", function()
		local instance = open({ ui = ui({ backdrop = 25 }) })
		local ids = resource_ids(instance)
		local autocmds = vim.api.nvim_get_autocmds({ group = ids.augroup })
		local delete_augroup = vim.api.nvim_del_augroup_by_id
		local attempts = {}
		patch_api("nvim_del_augroup_by_id", function(group)
			if group == ids.augroup then
				if #attempts == 0 then
					attempts[1] = "failed"
					error("one-shot augroup", 0)
				elseif #attempts == 1 then
					attempts[2] = "succeeded"
					return delete_augroup(group)
				end
				error("third cleanup attempt", 0)
			end
			return delete_augroup(group)
		end)

		local ok, err = pcall(instance.close, instance)
		assert.is_false(ok)
		assert.is_truthy(tostring(err):find("one%-shot augroup"))
		assert.same({ "failed", "succeeded" }, attempts)
		assert_resource_ids_invalid(ids)
		assert_augroup_invalid(ids.augroup)
		for _, autocmd in ipairs(autocmds) do
			assert.same({}, vim.api.nvim_get_autocmds({ id = autocmd.id }))
		end
		assert.equals(2, #attempts, "cleanup exceeded two passes before singleton access")
		assert.is_nil(window.current())
		assert.equals(2, #attempts, "current triggered a third cleanup attempt")
		restore_patches()
	end)

	it("retries every one-shot cleanup effect and reports the first cleanup error", function()
		local cases = {
			{ name = "namespace", api = "nvim_buf_clear_namespace" },
			{ name = "augroup", api = "nvim_del_augroup_by_id" },
			{ name = "window", api = "nvim_win_close" },
			{ name = "modifiable", api = "nvim_set_option_value" },
			{ name = "buffer", api = "nvim_buf_delete" },
		}
		for _, case in ipairs(cases) do
			close_all()
			local instance = open({ ui = ui({ backdrop = 25 }) })
			local group = instance.augroup
			local ids = resource_ids(instance)
			instance:map("x", function() end, "cleanup mapping")
			instance:draw(output(), "selected")
			if case.api == "nvim_set_option_value" or case.api == "nvim_buf_delete" then
				vim.bo[instance.buf].bufhidden = "hide"
				vim.bo[instance.backdrop_buf].bufhidden = "hide"
			end
			local real = vim.api[case.api]
			local failed = false
			patch_api(case.api, function(...)
				if not failed then
					failed = true
					error("one-shot " .. case.name, 0)
				end
				return real(...)
			end)
			local ok, err = pcall(instance.close, instance)
			restore_patches()
			assert.is_false(ok, case.name)
			assert.is_truthy(tostring(err):find("one%-shot " .. case.name), case.name)
			assert_resource_ids_invalid(ids)
			assert_augroup_invalid(group)
			assert.is_nil(window.current())
		end
	end)

	it("preserves an initiating failure over cleanup errors", function()
		local instance = open({ ui = ui({ backdrop = 100 }) })
		fail_api("nvim_buf_set_lines", function()
			return true
		end, "initiating draw failure")
		local real_delete = vim.api.nvim_del_augroup_by_id
		patch_api("nvim_del_augroup_by_id", function(id)
			if id == instance.augroup then
				error("cleanup failure", 0)
			end
			return real_delete(id)
		end)
		local ok, err = pcall(instance.draw, instance, output(), "selected")
		assert.is_false(ok)
		assert.is_truthy(tostring(err):find("initiating draw failure", 1, true))
		assert.is_nil(tostring(err):find("cleanup failure", 1, true))
		restore_patches()
		instance:close()
		assert_retired(instance)
	end)
end)
