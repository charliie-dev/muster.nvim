---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")
local registry = require("muster.registry")

local function fake(id, opts)
	opts = opts or {}
	return {
		id = id,
		available = function()
			return opts.available ~= false, opts.available == false and "host not loaded" or nil
		end,
		identity = opts.identity or tostring,
		probe = opts.probe or function(entry, bufnr)
			return {
				status = "found",
				binary = tostring(entry),
				path = ("/buf/%d/%s"):format(bufnr, tostring(entry)),
				realpath = ("/buf/%d/%s"):format(bufnr, tostring(entry)),
				source = "system",
			}
		end,
		live = opts.live,
	}
end

local function with_adapters(adapters, opts, fn)
	registry.reset()
	for _, adapter in ipairs(adapters) do
		registry.register(adapter)
	end
	local saved = registry.load_builtins
	registry.load_builtins = function()
		return {}
	end
	config.setup(opts or {})
	package.loaded["muster.overlay"] = nil
	local overlay = require("muster.overlay")
	local ok, err = pcall(fn, overlay)
	registry.load_builtins = saved
	config.reset()
	registry.reset()
	package.loaded["muster.overlay"] = nil
	if not ok then
		error(err, 0)
	end
end

local function names(entries)
	return vim.tbl_map(function(entry)
		return entry.adapter .. "/" .. entry.name
	end, entries)
end

local function protect(body, cleanup)
	local body_ok, body_err = xpcall(body, debug.traceback)
	local cleanup_ok, cleanup_err = xpcall(cleanup, debug.traceback)
	if not body_ok then
		if not cleanup_ok then
			body_err = body_err .. "\ncleanup also failed:\n" .. cleanup_err
		end
		error(body_err, 0)
	end
	if not cleanup_ok then
		error(cleanup_err, 0)
	end
end

local function cleanup_all(...)
	local errors = {}
	for index = 1, select("#", ...) do
		local action = select(index, ...)
		local ok, err = xpcall(action, debug.traceback)
		if not ok then
			errors[#errors + 1] = err
		end
	end
	if #errors > 0 then
		error(table.concat(errors, "\ncleanup also failed:\n"), 0)
	end
end

local function close_overlay(win, report_buf, source_buf)
	cleanup_all(function()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, function()
		if report_buf and vim.api.nvim_buf_is_valid(report_buf) then
			vim.api.nvim_buf_delete(report_buf, { force = true })
		end
	end, function()
		if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
			vim.api.nvim_buf_delete(source_buf, { force = true })
		end
	end)
end

describe("overlay spec cleanup", function()
	it("runs cleanup even when the protected body fails", function()
		local cleaned = false
		local ok = pcall(function()
			protect(function()
				error("deliberate body failure")
			end, function()
				cleaned = true
			end)
		end)
		assert.is_false(ok)
		assert.is_true(cleaned)
	end)

	it("preserves the body error when cleanup also fails", function()
		local cleaned = false
		local ok, err = pcall(function()
			protect(function()
				error("deliberate body failure")
			end, function()
				cleanup_all(function()
					error("deliberate cleanup failure")
				end, function()
					cleaned = true
				end)
			end)
		end)
		local body_error = err:find("deliberate body failure", 1, true)
		local cleanup_error = err:find("deliberate cleanup failure", 1, true)
		assert.is_false(ok)
		assert.is_true(cleaned)
		assert.is_truthy(body_error)
		assert.is_truthy(cleanup_error)
		assert.is_true(body_error < cleanup_error)
	end)

	it("restores overridden modules and overlay resources after an assertion failure", function()
		with_adapters({ fake("a") }, { a = { "tool" } }, function(overlay)
			local version = require("muster.version")
			local saved_resolve = version.resolve
			local saved_runner = package.loaded["muster.runner"]
			local source_buf, report_buf, win
			version.resolve = function(_, callback)
				callback({ value = "1.0.0", tier = 4 })
			end
			package.loaded["muster.runner"] = { start = function() end }

			local ok, err = pcall(function()
				protect(function()
					source_buf = vim.api.nvim_create_buf(false, true)
					report_buf, win = overlay.open(source_buf)
					error("deliberate overlay assertion failure")
				end, function()
					cleanup_all(function()
						error("deliberate first cleanup failure")
					end, function()
						version.resolve = saved_resolve
					end, function()
						package.loaded["muster.runner"] = saved_runner
					end, function()
						close_overlay(win, report_buf, source_buf)
					end)
				end)
			end)

			local resolver_restored = version.resolve == saved_resolve
			local runner_restored = package.loaded["muster.runner"] == saved_runner
			local window_closed = not win or not vim.api.nvim_win_is_valid(win)
			local report_deleted = not report_buf or not vim.api.nvim_buf_is_valid(report_buf)
			local source_deleted = not source_buf or not vim.api.nvim_buf_is_valid(source_buf)
			-- Defensive cleanup keeps this spec isolated even if an assertion below fails.
			version.resolve = saved_resolve
			package.loaded["muster.runner"] = saved_runner
			pcall(close_overlay, win, report_buf, source_buf)

			assert.is_false(ok)
			assert.is_truthy(err:find("deliberate overlay assertion failure", 1, true))
			assert.is_truthy(err:find("deliberate first cleanup failure", 1, true))
			assert.is_true(resolver_restored)
			assert.is_true(runner_restored)
			assert.is_true(window_closed)
			assert.is_true(report_deleted)
			assert.is_true(source_deleted)
		end)
	end)
end)

describe("overlay.collect", function()
	it("re-probes declared and live entries against the invoking buffer", function()
		local probed = {}
		local bufnr = vim.api.nvim_get_current_buf()
		local adapter = fake("a", {
			live = function(actual)
				assert.equals(bufnr, actual)
				return { "live-only" }
			end,
			probe = function(entry, actual_bufnr)
				probed[entry] = actual_bufnr
				return {
					status = "found",
					binary = entry,
					path = "/bin/" .. entry,
					realpath = "/bin/" .. entry,
					source = "system",
				}
			end,
		})
		with_adapters({ adapter }, { a = { "declared" } }, function(overlay)
			local view = overlay.collect(bufnr)
			assert.equals(bufnr, view.bufnr)
			assert.same({ declared = bufnr, ["live-only"] = bufnr }, probed)
		end)
	end)

	it("merges a declared live identity with declared=true winning", function()
		local adapter = fake("a", {
			live = function()
				return { "shared", "discovered" }
			end,
		})
		with_adapters({ adapter }, { a = { "shared", "elsewhere" } }, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({ "a/discovered", "a/shared" }, names(view.active))
			assert.same({ "a/elsewhere" }, names(view.other))
			assert.is_false(view.active[1].declared)
			assert.same({}, view.active[1].advice)
			assert.is_true(view.active[2].declared)
		end)
	end)

	it("puts every declared entry below when an adapter omits live", function()
		with_adapters({ fake("third_party") }, { third_party = { "x" } }, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({}, view.active)
			assert.same({ "third_party/x" }, names(view.other))
		end)
	end)

	it("surfaces a failed live query instead of rendering it as empty", function()
		local adapter = fake("a", {
			live = function()
				return {}, "foreign API exploded"
			end,
		})
		with_adapters({ adapter }, { a = { "x" } }, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.equals(1, #view.diagnostics)
			assert.is_truthy(view.diagnostics[1]:find("foreign API exploded", 1, true))
		end)
	end)

	it("contains raised live queries and identities without losing healthy entries", function()
		local query_error = fake("query_error", {
			live = function()
				error("query exploded")
			end,
		})
		local identity_error = fake("identity_error", {
			live = function()
				return { "broken" }
			end,
			identity = function()
				error("identity exploded")
			end,
		})
		local healthy = fake("healthy", {
			live = function()
				return { "ok" }
			end,
		})
		with_adapters({ query_error, identity_error, healthy }, {}, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({ "healthy/ok" }, names(view.active))
			assert.equals(2, #view.diagnostics)
			assert.is_truthy(view.diagnostics[1]:find("identity exploded", 1, true))
			assert.is_truthy(view.diagnostics[2]:find("query exploded", 1, true))
		end)
	end)

	it("reports an empty live identity instead of creating a blank row", function()
		local adapter = fake("a", {
			live = function()
				return { "nameless" }
			end,
			identity = function()
				return ""
			end,
		})
		with_adapters({ adapter }, {}, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({}, view.active)
			assert.equals(1, #view.diagnostics)
			assert.is_truthy(view.diagnostics[1]:find("non-empty string", 1, true))
		end)
	end)

	it("reports a map-shaped live result instead of treating it as empty", function()
		local adapter = fake("a", {
			live = function()
				return { tool = true }
			end,
		})
		with_adapters({ adapter }, {}, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.equals(1, #view.diagnostics)
			assert.is_truthy(view.diagnostics[1]:find("expected a list", 1, true))
		end)
	end)

	it("contains an invalid discovered probe and preserves healthy adapters", function()
		local bad = fake("bad", {
			live = function()
				return { "broken" }
			end,
			probe = function()
				return { status = "found" }
			end,
		})
		local good = fake("good", {
			live = function()
				return { "ok" }
			end,
		})
		with_adapters({ bad, good }, {}, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({ "bad/broken", "good/ok" }, names(view.active))
			assert.equals("broken", view.active[1].probe.status)
			assert.equals("found", view.active[2].probe.status)
		end)
	end)
end)

local UI5_ACTIONS = {
	"close",
	"active",
	"all",
	"issues",
	"next_tab",
	"previous_tab",
	"details",
	"help",
	"search",
}

local function found_entry(adapter, name)
	return {
		adapter = adapter,
		name = name,
		declared = true,
		probe = {
			status = "found",
			binary = name,
			path = "/bin/" .. name,
			realpath = "/bin/" .. name,
			source = "system",
		},
		advice = {},
	}
end

local function dashboard_view(bufnr, entry_names)
	local active = {}
	for _, name in ipairs(entry_names or {}) do
		active[#active + 1] = found_entry("a", name)
	end
	return {
		bufnr = bufnr,
		filetype = "lua",
		active = active,
		other = {},
		diagnostics = {},
		notes = {},
	}
end

local function cleanup_report_buffers()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == "muster://report" then
			for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
				pcall(vim.api.nvim_win_close, winid, true)
			end
			pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		end
	end
end

local function with_controller(adapters, setup, options, body)
	options = options or {}
	with_adapters(adapters or {}, setup or {}, function(overlay)
		local render = require("muster.ui.render")
		local help = require("muster.ui.help")
		local window = require("muster.ui.window")
		local version = require("muster.version")
		local saved = {
			setup_highlights = render.setup_highlights,
			render = render.render,
			render_help = render.help,
			help_current = help.current,
			help_close = help.close,
			help_open = help.open,
			help_content_width = help.content_width,
			current = window.current,
			open = window.open,
			resolve = version.resolve,
			schedule = vim.schedule,
			input = vim.ui.input,
			notify = vim.notify,
			setreg = vim.fn.setreg,
			v = vim.v,
		}
		local real_render = render.render
		local harness = {
			events = {},
			mappings = {},
			notifications = {},
			scheduled = {},
			inputs = {},
			resolvers = {},
			draws = {},
			renders = {},
			open_options = {},
			setreg_calls = {},
			help_draws = {},
			help_open_options = {},
			help_close_calls = 0,
			help_resize_calls = 0,
			schedule_calls = 0,
			map_calls = 0,
			close_calls = 0,
			focus_calls = 0,
			schedule_mode = options.schedule_mode or "async",
		}
		local instance = {
			buf = options.report_buf or 901,
			win = options.report_win or 902,
			source_bufnr = options.instance_source or -1,
			ui = options.instance_ui or { sentinel = true },
			on_resize = options.instance_on_resize or function() end,
			on_error = options.instance_on_error or function() end,
			is_valid = options.instance_valid ~= false,
			cursor = 1,
		}
		harness.instance = instance
		local help_instance = {
			buf = 903,
			win = 904,
			is_valid = true,
		}
		harness.help_instance = help_instance

		function instance:valid()
			return self.is_valid
		end
		function instance:focus()
			harness.focus_calls = harness.focus_calls + 1
		end
		function instance:content_width()
			return options.width or 100
		end
		function instance:cursor_line()
			return self.cursor
		end
		function instance:draw(output, selected_key)
			harness.events[#harness.events + 1] = "draw"
			if options.draw_error then
				error(options.draw_error, 0)
			end
			harness.draws[#harness.draws + 1] = { output = output, selected_key = selected_key }
			harness.last_output = output
			local target = selected_key and output.line_by_key[selected_key]
				or output.anchors.body
				or output.anchors.tabs
				or output.anchors.title
				or 1
			self.cursor = target
		end
		function instance:map(lhs, callback, desc)
			harness.map_calls = harness.map_calls + 1
			harness.events[#harness.events + 1] = "map:" .. lhs
			if options.fail_map_at == harness.map_calls then
				error(options.map_error or ("mapping failed " .. lhs), 0)
			end
			harness.mappings[lhs] = { callback = callback, desc = desc }
		end
		function instance:close()
			harness.close_calls = harness.close_calls + 1
			self.is_valid = false
			if options.close_error then
				error(options.close_error, 0)
			end
		end

		function help_instance:valid()
			return self.is_valid
		end
		function help_instance:focus()
			harness.help_focus_calls = (harness.help_focus_calls or 0) + 1
		end
		function help_instance:resize()
			harness.help_resize_calls = harness.help_resize_calls + 1
		end
		function help_instance:draw(output)
			harness.help_draws[#harness.help_draws + 1] = output
			harness.help_output = output
		end
		function help_instance:close(notify)
			harness.help_close_calls = harness.help_close_calls + 1
			self.is_valid = false
			harness.help_current = nil
			if notify ~= false and self.on_close then
				self.on_close()
			end
		end

		render.setup_highlights = function()
			harness.events[#harness.events + 1] = "highlights"
			if options.highlight_error then
				error(options.highlight_error, 0)
			end
			if harness.setup_highlights_impl then
				return harness.setup_highlights_impl()
			end
		end
		render.render = function(state, width)
			harness.controller_state = state
			harness.events[#harness.events + 1] = "render"
			if options.render_error then
				error(options.render_error, 0)
			end
			harness.renders[#harness.renders + 1] = vim.deepcopy(state)
			local output = real_render(state, width)
			harness.last_output = output
			return output
		end
		render.help = function(state, width)
			harness.events[#harness.events + 1] = "render-help"
			local output = saved.render_help(state, width)
			harness.help_output = output
			return output
		end
		help.current = function()
			if harness.help_current_impl then
				return harness.help_current_impl()
			end
			return harness.help_current
		end
		help.content_width = function()
			return math.max(1, math.floor((options.width or 100) * 0.8))
		end
		help.close = function(notify)
			if harness.help_current then
				harness.help_current:close(notify)
			end
		end
		help.open = function(opts)
			harness.events[#harness.events + 1] = "help-open"
			harness.help_open_options[#harness.help_open_options + 1] = opts
			help_instance.is_valid = true
			help_instance.on_close = opts.on_close
			harness.help_current = help_instance
			help_instance:draw(opts.output)
			return help_instance, true
		end
		window.current = function()
			harness.events[#harness.events + 1] = "current"
			if harness.current_impl then
				return harness.current_impl()
			end
			return options.current
		end
		window.open = function(opts)
			harness.events[#harness.events + 1] = "open"
			harness.open_options[#harness.open_options + 1] = opts
			if options.open_error then
				error(options.open_error, 0)
			end
			if harness.open_impl then
				return harness.open_impl(opts)
			end
			return instance, options.created ~= false
		end
		version.resolve = function(entry, callback)
			harness.events[#harness.events + 1] = "resolve:" .. entry.adapter .. "/" .. entry.name
			harness.resolvers[#harness.resolvers + 1] = { entry = entry, callback = callback }
			if harness.resolve_impl then
				return harness.resolve_impl(entry, callback)
			end
		end
		vim.schedule = function(callback)
			harness.schedule_calls = harness.schedule_calls + 1
			if harness.schedule_impl then
				return harness.schedule_impl(callback, harness.schedule_calls)
			end
			local mode = harness.schedule_mode
			if mode == "sync" then
				callback()
			elseif mode == "throw" then
				error("schedule rejected", 0)
			elseif mode == "callback_throw" then
				callback()
				error("schedule rejected after callback", 0)
			elseif mode == "duplicate" then
				callback()
				callback()
			else
				harness.scheduled[#harness.scheduled + 1] = callback
			end
		end
		vim.ui.input = function(input_opts, callback)
			harness.inputs[#harness.inputs + 1] = { opts = input_opts, callback = callback }
			if harness.input_impl then
				return harness.input_impl(input_opts, callback)
			end
		end
		vim.notify = function(message, level, notify_opts)
			harness.notifications[#harness.notifications + 1] = {
				message = tostring(message),
				level = level,
				opts = notify_opts,
			}
			if harness.notify_impl then
				return harness.notify_impl(message, level, notify_opts)
			end
		end
		vim.fn.setreg = function(register, value)
			harness.setreg_calls[#harness.setreg_calls + 1] = { register = register, value = value }
			if harness.setreg_impl then
				return harness.setreg_impl(register, value)
			end
			return 0
		end

		function harness:flush()
			while #self.scheduled > 0 do
				local callback = table.remove(self.scheduled, 1)
				callback()
			end
		end
		function harness:invoke(lhs)
			local mapping = assert(self.mappings[lhs], "missing mapping " .. lhs)
			return mapping.callback()
		end
		function harness:close_help()
			local current = assert(self.help_current, "help is not open")
			current:close(true)
		end
		function harness:state()
			return self.renders[#self.renders]
		end
		function harness:set_cursor(key)
			self.instance.cursor = assert(self.last_output.line_by_key[key], "missing cursor key " .. key)
		end
		function harness:set_register(register)
			vim.v = { register = register }
		end

		local ok, err = xpcall(function()
			body(overlay, harness)
		end, debug.traceback)
		render.setup_highlights = saved.setup_highlights
		render.render = saved.render
		render.help = saved.render_help
		help.current = saved.help_current
		help.close = saved.help_close
		help.open = saved.help_open
		help.content_width = saved.help_content_width
		window.current = saved.current
		window.open = saved.open
		version.resolve = saved.resolve
		vim.schedule = saved.schedule
		vim.ui.input = saved.input
		vim.notify = saved.notify
		vim.fn.setreg = saved.setreg
		vim.v = saved.v
		cleanup_report_buffers()
		if not ok then
			error(err, 0)
		end
	end)
end

local function notification_count(harness, level)
	local count = 0
	for _, notification in ipairs(harness.notifications) do
		if notification.level == level then
			count = count + 1
		end
	end
	return count
end

local function all_disabled_keymaps()
	local keymaps = { refresh = false, copy_path = false }
	for _, action in ipairs(UI5_ACTIONS) do
		keymaps[action] = false
	end
	return keymaps
end

describe("overlay.open dashboard integration", function()
	it("opens the rendered dashboard with the public buffer and window returns", function()
		local adapter = fake("a", {
			live = function()
				return { "lua_ls" }
			end,
		})
		with_adapters({ adapter }, { a = { "lua_ls" } }, function(overlay)
			local version = require("muster.version")
			local saved_resolve = version.resolve
			local finish
			local source_buf, report_buf, win
			version.resolve = function(_, callback)
				finish = callback
			end
			protect(function()
				source_buf = vim.api.nvim_create_buf(false, true)
				vim.bo[source_buf].filetype = "lua"
				report_buf, win = overlay.open(source_buf)
				assert.is_true(vim.api.nvim_win_is_valid(win))
				assert.equals("muster", vim.bo[report_buf].filetype)
				local text = table.concat(vim.api.nvim_buf_get_lines(report_buf, 0, -1, false), "\n")
				assert.is_truthy(text:find("muster.nvim", 1, true))
				assert.is_truthy(text:find("Active", 1, true))
				assert.is_truthy(text:find("lua_ls", 1, true))
				finish({ value = "9.8.7", tier = 4 })
				vim.wait(100, function()
					return table
						.concat(vim.api.nvim_buf_get_lines(report_buf, 0, -1, false), "\n")
						:find("9.8.7", 1, true) ~= nil
				end)
			end, function()
				version.resolve = saved_resolve
				close_overlay(win, report_buf, source_buf)
			end)
		end)
	end)

	it("uses the real window singleton before collecting again", function()
		local collections = 0
		local adapter = fake("a", {
			live = function()
				collections = collections + 1
				return {}
			end,
		})
		with_adapters({ adapter }, {}, function(overlay)
			local first_source = vim.api.nvim_create_buf(false, true)
			local second_source = vim.api.nvim_create_buf(false, true)
			local source_win = vim.api.nvim_get_current_win()
			local report_buf, win
			protect(function()
				report_buf, win = overlay.open(first_source)
				assert.equals(1, collections)
				vim.api.nvim_set_current_win(source_win)
				vim.api.nvim_set_current_buf(second_source)
				local same_buf, same_win = overlay.open(second_source)
				assert.equals(report_buf, same_buf)
				assert.equals(win, same_win)
				assert.equals(1, collections)
				assert.equals(win, vim.api.nvim_get_current_win())
			end, function()
				close_overlay(win, report_buf, first_source)
				if vim.api.nvim_buf_is_valid(second_source) then
					vim.api.nvim_buf_delete(second_source, { force = true })
				end
			end)
		end)
	end)

	it("passes canonical source and an isolated UI copy through exact callbacks", function()
		local adapter_ids = {}
		local focus_target
		local adapter = fake("a", {
			live = function(bufnr)
				adapter_ids[#adapter_ids + 1] = bufnr
				if focus_target then
					vim.api.nvim_set_current_buf(focus_target)
				end
				return { "alpha" }
			end,
			probe = function(entry, bufnr)
				adapter_ids[#adapter_ids + 1] = bufnr
				return found_entry("a", entry).probe
			end,
		})
		with_controller({ adapter }, { a = { "alpha" } }, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			focus_target = vim.api.nvim_create_buf(false, true)
			local configured = config.ui()
			local report, win = overlay.open(source)
			assert.equals(harness.instance.buf, report)
			assert.equals(harness.instance.win, win)
			local opts = assert(harness.open_options[1])
			assert.equals(source, opts.source_bufnr)
			assert.equals(source, harness:state().source_bufnr)
			assert.equals(source, harness:state().view.bufnr)
			assert.is_function(opts.on_resize)
			assert.is_function(opts.on_error)
			assert.equals("r", opts.ui.keymaps.refresh)
			assert.equals("y", opts.ui.keymaps.copy_path)
			assert.is_not.equals(configured, opts.ui)
			assert.equals("r", configured.keymaps.refresh)
			assert.equals("y", configured.keymaps.copy_path)
			assert.equals("r", config.ui().keymaps.refresh)
			assert.equals("y", config.ui().keymaps.copy_path)
			assert.same({ source, source }, adapter_ids)
			assert.is_not.equals(focus_target, opts.source_bufnr)
			vim.api.nvim_buf_delete(source, { force = true })
			vim.api.nvim_buf_delete(focus_target, { force = true })
		end)
	end)

	for _, source_kind in ipairs({ "nil", "zero", "explicit" }) do
		it("canonicalizes " .. source_kind .. " before every adapter call", function()
			local seen = {}
			local adapter = fake("a", {
				live = function(bufnr)
					seen[#seen + 1] = bufnr
					return { "live" }
				end,
				probe = function(entry, bufnr)
					seen[#seen + 1] = bufnr
					return found_entry("a", entry).probe
				end,
			})
			with_controller({ adapter }, { a = { "declared" } }, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_set_current_buf(source)
				local argument
				if source_kind == "zero" then
					argument = 0
				elseif source_kind == "explicit" then
					argument = source
				end
				overlay.open(argument)
				assert.equals(source, harness.open_options[1].source_bufnr)
				assert.same({ source, source, source }, seen)
				vim.api.nvim_buf_delete(source, { force = true })
			end)
		end)
	end

	it("contains invalid sources before collection or window acquisition", function()
		local adapter_calls = 0
		local adapter = fake("a", {
			live = function()
				adapter_calls = adapter_calls + 1
				return {}
			end,
		})
		for _, invalid in ipairs({ "1", -1, 1.5, math.huge }) do
			with_controller({ adapter }, {}, {}, function(overlay, harness)
				local report, win = overlay.open(invalid)
				assert.is_nil(report)
				assert.is_nil(win)
				assert.equals(0, #harness.open_options)
				assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
			end)
		end
		assert.equals(0, adapter_calls)
	end)

	it("does not commit a controller until setup, mappings, draw, and resolvers succeed", function()
		local adapter = fake("a", {
			live = function()
				return { "alpha" }
			end,
		})
		with_controller({ adapter }, { a = { "alpha" } }, {}, function(overlay, harness)
			harness.resolve_impl = function(_, callback)
				harness.open_options[1].on_resize(harness.instance)
				callback({ value = "1.0.0", tier = 4 })
			end
			local report, win = overlay.open(vim.api.nvim_get_current_buf())
			assert.equals(harness.instance.buf, report)
			assert.equals(harness.instance.win, win)
			assert.equals("highlights", harness.events[2])
			assert.equals("open", harness.events[3])
			local draw_index = assert(vim.fn.index(harness.events, "draw")) + 1
			local resolve_index = assert(vim.fn.index(harness.events, "resolve:a/alpha")) + 1
			assert.is_true(draw_index < resolve_index)
			assert.equals(12, harness.map_calls)
			assert.equals(1, harness.schedule_calls)
			harness:flush()
			local draws = #harness.draws
			harness.open_options[1].on_resize(harness.instance)
			assert.equals(2, harness.schedule_calls)
			harness:flush()
			assert.equals(draws + 1, #harness.draws)
			harness.open_options[1].on_error("window callback failed")
			harness.open_options[1].on_error("duplicate failure")
			assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
			assert.equals(1, harness.close_calls)
			local schedules = harness.schedule_calls
			harness.open_options[1].on_resize(harness.instance)
			assert.equals(schedules, harness.schedule_calls)
		end)
	end)

	it("focuses a defensive created=false result without replacing its state", function()
		with_controller({}, {}, {
			created = false,
			instance_source = 77,
			instance_ui = { retained = true },
		}, function(overlay, harness)
			local old_resize = harness.instance.on_resize
			local old_error = harness.instance.on_error
			local report, win = overlay.open(vim.api.nvim_get_current_buf())
			assert.equals(harness.instance.buf, report)
			assert.equals(harness.instance.win, win)
			assert.equals(1, harness.focus_calls)
			assert.equals(77, harness.instance.source_bufnr)
			assert.same({ retained = true }, harness.instance.ui)
			assert.equals(old_resize, harness.instance.on_resize)
			assert.equals(old_error, harness.instance.on_error)
			assert.equals(0, harness.map_calls)
			assert.equals(0, #harness.draws)
			assert.equals(0, #harness.resolvers)
		end)
	end)

	it("shows configured refresh and copy mappings only in help without mutating overrides", function()
		local keymaps = {
			refresh = "RUNTIME_REFRESH",
			copy_path = { "RUNTIME_COPY", "RUNTIME_COPY_2" },
			help = "H",
		}
		with_controller({}, { ui = { keymaps = keymaps } }, { width = 500 }, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			assert.is_function(harness.mappings.RUNTIME_REFRESH.callback)
			assert.is_function(harness.mappings.RUNTIME_COPY.callback)
			assert.is_function(harness.mappings.RUNTIME_COPY_2.callback)
			assert.equals(harness.mappings.RUNTIME_COPY.callback, harness.mappings.RUNTIME_COPY_2.callback)
			local footer = harness.last_output.lines[harness.last_output.anchors.footer]
			assert.is_truthy(footer:find("/ Muster search:", 1, true))
			assert.is_truthy(footer:find("H Help", 1, true))
			assert.is_nil(footer:find("RUNTIME_REFRESH", 1, true))
			assert.is_nil(footer:find("RUNTIME_COPY", 1, true))
			harness:invoke("H")
			harness:flush()
			local help = table.concat(harness.help_output.lines, "\n")
			assert.is_truthy(help:find("RUNTIME_REFRESH  refresh", 1, true))
			assert.is_truthy(help:find("RUNTIME_COPY/RUNTIME_COPY_2  copy path", 1, true))
			assert.equals("RUNTIME_REFRESH", config.ui().keymaps.refresh)
			assert.same({ "RUNTIME_COPY", "RUNTIME_COPY_2" }, config.ui().keymaps.copy_path)
		end)
	end)
end)

describe("overlay dashboard mappings and transitions", function()
	for _, action in ipairs({ "refresh", "copy_path" }) do
		for _, form in ipairs({ "default", "string", "list", "false" }) do
			it(("installs and hints %s from %s form"):format(action, form), function()
				local keymaps
				local setup = { a = { "alpha" } }
				local first = action == "refresh" and "R" or "Y"
				local second = action == "refresh" and "<F6>" or "<F7>"
				local help = "?"
				local expected_keys = action == "refresh" and "r" or "y"
				if form ~= "default" then
					keymaps = all_disabled_keymaps()
					keymaps.help = "H"
					help = "H"
					keymaps[action] = form == "string" and first or form == "list" and { first, second } or false
					expected_keys = form == "list" and (first .. "/" .. second) or first
				end
				if keymaps then
					setup.ui = { keymaps = keymaps }
				end
				with_controller(
					{ fake("a", {
						live = function()
							return { "alpha" }
						end,
					}) },
					setup,
					{ width = 500 },
					function(overlay, harness)
						local source = vim.api.nvim_create_buf(false, true)
						local collections = 0
						local original_collect = overlay.collect
						overlay.collect = function(bufnr)
							collections = collections + 1
							return original_collect(bufnr)
						end
						overlay.open(source)
						local lhs = form == "default" and (action == "refresh" and "r" or "y") or first
						local normal = table.concat(harness.last_output.lines, "\n")
						assert.is_nil(normal:find(action == "refresh" and "refresh" or "copy path", 1, true))
						if form == "false" then
							assert.is_nil(harness.mappings[lhs])
						else
							assert.is_function(harness.mappings[lhs].callback)
							if action == "copy_path" then
								harness:set_cursor("a\0alpha")
								harness:set_register("a")
							end
							harness:invoke(lhs)
							if form == "list" then
								assert.equals(harness.mappings[first].callback, harness.mappings[second].callback)
								harness:invoke(second)
							end
							if action == "refresh" then
								assert.equals(form == "list" and 3 or 2, collections)
							else
								assert.equals(form == "list" and 2 or 1, #harness.setreg_calls)
							end
						end
						harness:invoke(help)
						harness:flush()
						local help_text = table.concat(harness.help_output.lines, "\n")
						if form == "false" then
							assert.is_nil(help_text:find(action == "refresh" and "refresh" or "copy path", 1, true))
						else
							assert.is_truthy(
								help_text:find(
									expected_keys .. "  " .. (action == "refresh" and "refresh" or "copy path"),
									1,
									true
								)
							)
						end
						local configured_action = keymaps and keymaps[action]
						if keymaps == nil then
							configured_action = action == "refresh" and "r" or "y"
						end
						assert.same(configured_action, config.ui().keymaps[action])
						vim.api.nvim_buf_delete(source, { force = true })
					end
				)
			end)
		end
	end

	for action_index, action in ipairs(UI5_ACTIONS) do
		for _, form in ipairs({ "string", "list", "false" }) do
			it(("installs %s from %s form"):format(action, form), function()
				local keymaps = all_disabled_keymaps()
				local first = ("g%d"):format(action_index)
				local second = ("z%d"):format(action_index)
				keymaps[action] = form == "string" and first or form == "list" and { first, second } or false
				with_controller({}, { ui = { keymaps = keymaps } }, {}, function(overlay, harness)
					overlay.open(vim.api.nvim_get_current_buf())
					if form == "false" then
						assert.equals(0, harness.map_calls)
						assert.is_nil(harness.mappings[first])
					else
						assert.is_function(harness.mappings[first].callback)
						assert.is_string(harness.mappings[first].desc)
						if form == "list" then
							assert.is_function(harness.mappings[second].callback)
						end
						harness:invoke(first)
						if action == "close" then
							assert.is_false(harness.instance.is_valid)
						end
					end
				end)
			end)
		end
	end

	it("uses both default close mappings and makes late callbacks inert", function()
		local adapter = fake("a", {
			live = function()
				return { "alpha" }
			end,
		})
		for _, lhs in ipairs({ "q", "<Esc>" }) do
			with_controller({ adapter }, { a = { "alpha" } }, {}, function(overlay, harness)
				overlay.open(vim.api.nvim_get_current_buf())
				local resolver = harness.resolvers[1].callback
				local resize = harness.open_options[1].on_resize
				local on_error = harness.open_options[1].on_error
				harness:invoke(lhs)
				harness:invoke(lhs)
				assert.equals(1, harness.close_calls)
				assert.equals(1, harness:state().revision)
				assert.equals(0, harness.schedule_calls)
				local draws = #harness.draws
				local notifications = #harness.notifications
				resolver({ value = "late", tier = 4 })
				resize(harness.instance)
				on_error("late window error")
				assert.equals(1, harness.close_calls)
				assert.equals(notifications, #harness.notifications)
				assert.equals(1, harness:state().revision)
				assert.equals(draws, #harness.draws)
				assert.equals(0, harness.schedule_calls)
			end)
		end
	end)

	it("table-drives tabs, details, help, revisions, selection, and no-ops", function()
		local adapter = fake("a", {
			live = function()
				return { "alpha", "beta" }
			end,
		})
		with_controller({ adapter }, { a = { "alpha", "beta" } }, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			local beta = "a\0beta"
			harness:set_cursor(beta)
			local function changed(lhs, expected, expected_selected)
				local before_revision = harness:state().revision
				local before_schedules = harness.schedule_calls
				harness:invoke(lhs)
				assert.equals(before_schedules + 1, harness.schedule_calls)
				harness:flush()
				local state = harness:state()
				assert.equals(before_revision + 1, state.revision)
				assert.equals(expected_selected, state.selected_key, lhs .. " selected state")
				for field, value in pairs(expected) do
					assert.equals(value, state[field])
				end
				assert.equals(expected_selected, harness.draws[#harness.draws].selected_key)
			end
			local function unchanged(lhs)
				local revision = harness:state().revision
				local schedules = harness.schedule_calls
				local draws = #harness.draws
				harness:invoke(lhs)
				assert.equals(revision, harness:state().revision)
				assert.equals(schedules, harness.schedule_calls)
				assert.equals(draws, #harness.draws)
			end

			unchanged("1")
			changed("2", { tab = "all", showing_help = false }, beta)
			changed("3", { tab = "issues", showing_help = false }, beta)
			changed("<Tab>", { tab = "active", showing_help = false }, nil)
			harness:set_cursor(beta)
			changed("<S-Tab>", { tab = "issues", showing_help = false }, beta)
			changed("1", { tab = "active", showing_help = false }, nil)
			harness:set_cursor(beta)
			changed("2", { tab = "all", showing_help = false }, beta)
			local before_revision = harness.controller_state.revision
			local before_schedules = harness.schedule_calls
			local before_draws = #harness.draws
			harness:invoke("?")
			assert.equals(before_revision, harness.controller_state.revision)
			assert.equals(before_schedules, harness.schedule_calls)
			assert.equals(before_draws, #harness.draws)
			assert.is_true(harness.controller_state.showing_help)
			assert.equals(beta, harness.controller_state.selected_key)
			assert.equals(harness.help_instance, harness.help_current)
			assert.is_truthy(table.concat(harness.help_output.lines, "\n"):find("Navigation", 1, true))
			harness:close_help()
			assert.equals(before_revision, harness.controller_state.revision)
			assert.equals(before_schedules, harness.schedule_calls)
			assert.equals(before_draws, #harness.draws)
			assert.is_false(harness.controller_state.showing_help)
			assert.equals(beta, harness.controller_state.selected_key)
			assert.equals(1, harness.focus_calls)
			assert.is_nil(harness.help_current)
			local query = harness.controller_state.query
			changed("3", { showing_help = false, query = query }, beta)

			harness:invoke("1")
			harness:flush()
			harness:set_cursor(beta)
			changed("<CR>", { expanded_key = beta }, beta)
			changed("<CR>", { expanded_key = nil }, beta)
			harness.instance.cursor = harness.last_output.anchors.footer
			unchanged("<CR>")
			harness:invoke("?")
			harness:flush()
			assert.equals(harness.help_instance, harness.help_current)
			harness:close_help()
			harness:flush()
		end)
	end)

	it("updates an open Help child on parent resize and version redraw without a Help-only main redraw", function()
		local adapter = fake("a", {
			live = function()
				return { "alpha" }
			end,
		})
		with_controller({ adapter }, { a = { "alpha" } }, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			local revision = harness.controller_state.revision
			local draws = #harness.draws
			harness:invoke("?")
			assert.equals(revision, harness.help_output.revision)
			assert.equals(draws, #harness.draws)

			harness.resolvers[1].callback({ value = "2.0.0", tier = 4 })
			harness.open_options[1].on_resize(harness.instance)
			assert.equals(1, #harness.scheduled)
			harness:flush()
			assert.equals(revision + 1, harness.controller_state.revision)
			assert.equals(draws + 1, #harness.draws)
			assert.equals(1, harness.help_resize_calls)
			assert.equals(revision + 1, harness.help_output.revision)
			assert.equals(revision + 1, harness.help_draws[#harness.help_draws].revision)
		end)
	end)

	it("does not reopen Help when retirement finalization closes state during a parent redraw", function()
		local adapter = fake("a", {
			live = function()
				return { "alpha" }
			end,
		})
		with_controller({ adapter }, { a = { "alpha" } }, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			harness:invoke("?")
			assert.equals(1, #harness.help_open_options)
			local revision = harness.controller_state.revision
			local schedules = harness.schedule_calls
			local draws = #harness.draws
			local finalized = false
			harness.help_current_impl = function()
				if not finalized then
					finalized = true
					harness.help_current = nil
					harness.help_open_options[1].on_close()
				end
				return nil
			end

			harness.resolvers[1].callback({ value = "2.0.0", tier = 4 })
			assert.equals(schedules + 1, harness.schedule_calls)
			harness:flush()
			assert.is_true(finalized)
			assert.is_false(harness.controller_state.showing_help)
			assert.equals(revision + 1, harness.controller_state.revision)
			assert.equals(draws + 1, #harness.draws)
			assert.equals(1, #harness.help_open_options)

			local settled_revision = harness.controller_state.revision
			local settled_schedules = harness.schedule_calls
			local settled_draws = #harness.draws
			harness.open_options[1].on_resize(harness.instance)
			harness:flush()
			assert.equals(settled_revision, harness.controller_state.revision)
			assert.equals(settled_schedules + 1, harness.schedule_calls)
			assert.equals(settled_draws + 1, #harness.draws)
			assert.equals(1, #harness.help_open_options)
		end)
	end)

	it("preserves selected identity across redraw and falls back when filtering removes it", function()
		local adapter = fake("a", {
			live = function()
				return { "alpha", "beta" }
			end,
		})
		with_controller({ adapter }, { a = { "alpha", "beta" } }, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			local beta = "a\0beta"
			harness:set_cursor(beta)
			harness:invoke("2")
			harness:flush()
			assert.equals(harness.last_output.line_by_key[beta], harness.instance.cursor)
			local selected = harness:state().selected_key
			harness.open_options[1].on_resize(harness.instance)
			harness:flush()
			assert.equals(selected, harness.draws[#harness.draws].selected_key)
			assert.equals(harness.last_output.line_by_key[beta], harness.instance.cursor)

			harness:invoke("/")
			harness.inputs[1].callback("alpha")
			harness:flush()
			assert.equals(beta, harness:state().selected_key)
			assert.is_nil(harness.last_output.line_by_key[beta])
			assert.equals(harness.last_output.anchors.body, harness.instance.cursor)
		end)
	end)
end)

describe("overlay dashboard search settlement", function()
	it("accepts, clears, cancels, rejects, deduplicates, and orders prompts exactly once", function()
		with_controller({}, {}, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			local function prompt(value)
				harness:invoke("/")
				local callback = harness.inputs[#harness.inputs].callback
				callback(value)
				return callback
			end
			local callback = prompt(string.rep("x", 256))
			callback("duplicate")
			assert.equals(1, harness.schedule_calls)
			harness:flush()
			assert.equals(string.rep("x", 256), harness:state().query)
			assert.equals(2, harness:state().revision)

			local revision = harness:state().revision
			prompt(string.rep("y", 257))
			prompt(nil)
			assert.equals(revision, harness:state().revision)
			assert.equals(1, notification_count(harness, vim.log.levels.WARN))

			prompt(42)
			assert.equals(2, notification_count(harness, vim.log.levels.WARN))
			prompt(harness:state().query)
			assert.equals(revision, harness:state().revision)

			prompt("")
			harness:flush()
			assert.equals("", harness:state().query)
			assert.equals(revision + 1, harness:state().revision)
			local cleared_revision = harness:state().revision
			prompt("")
			assert.equals(cleared_revision, harness:state().revision)

			harness:invoke("/")
			local older = harness.inputs[#harness.inputs].callback
			harness:invoke("/")
			local newer = harness.inputs[#harness.inputs].callback
			older("old")
			newer("new")
			harness:flush()
			assert.equals("new", harness:state().query)
			assert.equals(cleared_revision + 1, harness:state().revision)
		end)
	end)

	for _, case in ipairs({
		{ name = "synchronous success", mode = "sync", accepted = true },
		{ name = "ordinary throw", mode = "throw", warning = true },
		{ name = "callback then throw", mode = "callback_throw", warning = true },
	}) do
		it("settles " .. case.name .. " with the input return barrier", function()
			with_controller({}, {}, {}, function(overlay, harness)
				harness.input_impl = function(_, callback)
					if case.mode == "sync" then
						callback("accepted")
					elseif case.mode == "callback_throw" then
						callback("discarded")
						error("input failed after callback", 0)
					else
						error("input failed", 0)
					end
				end
				overlay.open(vim.api.nvim_get_current_buf())
				local draws = #harness.draws
				harness:invoke("/")
				if case.accepted then
					assert.equals(1, harness.schedule_calls)
					harness:flush()
					assert.equals("accepted", harness:state().query)
					assert.equals(draws + 1, #harness.draws)
					assert.equals(0, notification_count(harness, vim.log.levels.WARN))
				else
					assert.equals("", harness:state().query)
					assert.equals(1, harness:state().revision)
					assert.equals(draws, #harness.draws)
					assert.equals(0, harness.schedule_calls)
					assert.equals(1, notification_count(harness, vim.log.levels.WARN))
				end
			end)
		end)
	end

	it("discards completion after close", function()
		with_controller({}, {}, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			harness:invoke("/")
			local callback = harness.inputs[1].callback
			harness:invoke("q")
			callback("late")
			assert.equals(0, harness.schedule_calls)
			assert.equals(1, harness:state().revision)
		end)
	end)
end)

describe("overlay dashboard redraw scheduler", function()
	for _, case in ipairs({
		{ name = "accepted asynchronous", mode = "async", draw = true },
		{ name = "accepted synchronous", mode = "sync", draw = true },
		{ name = "duplicate synchronous callback", mode = "duplicate", draw = true },
		{ name = "rejection", mode = "throw", failure = true },
		{ name = "callback then throw", mode = "callback_throw", failure = true },
	}) do
		it("handles " .. case.name, function()
			with_controller({}, {}, { schedule_mode = case.mode }, function(overlay, harness)
				overlay.open(vim.api.nvim_get_current_buf())
				local draws = #harness.draws
				harness:invoke("2")
				if case.mode == "async" then
					assert.equals(draws, #harness.draws)
					harness:flush()
				end
				if case.draw then
					assert.equals(draws + 1, #harness.draws)
					assert.equals(0, notification_count(harness, vim.log.levels.ERROR))
					assert.equals(0, harness.close_calls)
				else
					assert.equals(draws, #harness.draws)
					assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
					assert.equals(1, harness.close_calls)
					local calls = harness.schedule_calls
					if #harness.scheduled > 0 then
						harness:flush()
					end
					assert.equals(calls, harness.schedule_calls)
				end
			end)
		end)
	end

	it("does not let a settled callback consume a newer pending redraw", function()
		with_controller({}, {}, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			local initial_draws = #harness.draws

			harness:invoke("2")
			local first = table.remove(harness.scheduled, 1)
			first()
			assert.equals(initial_draws + 1, #harness.draws)

			harness:invoke("3")
			local second = table.remove(harness.scheduled, 1)
			local before_stale = #harness.draws
			first()
			assert.equals(before_stale, #harness.draws)
			second()
			assert.equals(before_stale + 1, #harness.draws)
			assert.equals("issues", harness:state().tab)
			second()
			assert.equals(before_stale + 1, #harness.draws)
		end)
	end)

	it("makes an accepted asynchronous callback late-safe after close", function()
		with_controller({}, {}, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			local draws = #harness.draws
			harness:invoke("2")
			harness:invoke("q")
			harness:flush()
			assert.equals(draws, #harness.draws)
			assert.equals(1, harness.close_calls)
		end)
	end)
end)

describe("overlay dashboard versions", function()
	local duplicate_view = {
		bufnr = 1,
		filetype = "lua",
		active = { found_entry("a", "alpha"), found_entry("a", "beta") },
		other = { found_entry("a", "alpha"), found_entry("a", "gamma") },
		diagnostics = {},
		notes = {},
	}

	it("deduplicates found identities in Active then All order", function()
		with_controller({}, {}, {}, function(overlay, harness)
			overlay.collect = function(bufnr)
				local view = vim.deepcopy(duplicate_view)
				view.bufnr = bufnr
				return view
			end
			overlay.open(vim.api.nvim_get_current_buf())
			assert.same(
				{ "alpha", "beta", "gamma" },
				vim.tbl_map(function(call)
					return call.entry.name
				end, harness.resolvers)
			)
		end)
	end)

	for _, case in ipairs({
		{ name = "synchronous success", mode = "sync", accepted = true },
		{ name = "asynchronous success", mode = "async", accepted = true },
		{ name = "duplicate completion", mode = "duplicate", accepted = true },
		{ name = "ordinary resolver throw", mode = "throw", failure = true },
		{ name = "callback then throw", mode = "callback_throw", failure = true },
	}) do
		it("settles " .. case.name .. " exactly once", function()
			with_controller({}, {}, {}, function(overlay, harness)
				overlay.collect = function(bufnr)
					return {
						bufnr = bufnr,
						filetype = "lua",
						active = { found_entry("a", "alpha") },
						other = {},
						diagnostics = {},
						notes = {},
					}
				end
				local callback
				harness.resolve_impl = function(_, resolve_callback)
					callback = resolve_callback
					if case.mode == "sync" then
						resolve_callback({ value = "1.0.0", tier = 4 })
					elseif case.mode == "duplicate" then
						resolve_callback({ value = "1.0.0", tier = 4 })
						resolve_callback({ value = "2.0.0", tier = 4 })
					elseif case.mode == "throw" then
						error("resolver failed", 0)
					elseif case.mode == "callback_throw" then
						resolve_callback({ value = "discarded", tier = 4 })
						error("resolver failed after callback", 0)
					end
				end
				local report, win = overlay.open(vim.api.nvim_get_current_buf())
				if case.failure then
					assert.is_nil(report)
					assert.is_nil(win)
					assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
					assert.equals(1, harness.close_calls)
					assert.equals(0, harness.schedule_calls)
					callback({ value = "late", tier = 4 })
					assert.equals(0, harness.schedule_calls)
				else
					if case.mode == "async" then
						callback({ value = "1.0.0", tier = 4 })
						callback({ value = "duplicate", tier = 4 })
					end
					assert.equals(1, harness.schedule_calls)
					harness:flush()
					assert.equals("1.0.0", harness:state().versions["a\0alpha"].value)
					assert.equals(2, harness:state().revision)
					assert.equals(2, #harness.draws)
				end
			end)
		end)
	end

	for _, close_kind in ipairs({ "direct", "external" }) do
		it("ignores completion after " .. close_kind .. " close", function()
			with_controller({}, {}, {}, function(overlay, harness)
				overlay.collect = function(bufnr)
					return {
						bufnr = bufnr,
						filetype = "lua",
						active = { found_entry("a", "alpha") },
						other = {},
						diagnostics = {},
						notes = {},
					}
				end
				overlay.open(vim.api.nvim_get_current_buf())
				local callback = harness.resolvers[1].callback
				if close_kind == "direct" then
					harness:invoke("q")
				else
					harness.instance.is_valid = false
				end
				callback({ value = "late", tier = 4 })
				assert.equals(0, harness.schedule_calls)
				assert.equals(1, harness:state().revision)
			end)
		end)
	end

	it("captures selected identity before a live version completion", function()
		local adapter = fake("a", {
			live = function()
				return { "alpha", "beta" }
			end,
		})
		with_controller({ adapter }, { a = { "alpha", "beta" } }, {}, function(overlay, harness)
			overlay.open(vim.api.nvim_get_current_buf())
			local beta = "a\0beta"
			harness:set_cursor(beta)
			local alpha_callback
			for _, resolver in ipairs(harness.resolvers) do
				if resolver.entry.name == "alpha" then
					alpha_callback = resolver.callback
				end
			end
			alpha_callback({ value = "3.0.0", tier = 4 })
			harness:flush()
			assert.equals(beta, harness:state().selected_key)
			assert.equals(beta, harness.draws[#harness.draws].selected_key)
			assert.equals(harness.last_output.line_by_key[beta], harness.instance.cursor)
		end)
	end)
end)

describe("overlay dashboard refresh generations", function()
	it("keeps only the active resolver generation while old callbacks remain inert", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, { "alpha" })
			end
			overlay.open(source)

			local function controller_for(callback)
				for index = 1, 20 do
					local _, value = debug.getupvalue(callback, index)
					if type(value) == "table" and type(value.controller) == "table" and value.generation ~= nil then
						return value.controller
					end
				end
			end

			local first_callback = harness.resolvers[1].callback
			local controller = assert(controller_for(first_callback), "resolver controller upvalue missing")
			assert.equals(1, #controller.resolvers)
			local old_callbacks = { first_callback }
			for _ = 1, 4 do
				harness:invoke("r")
				assert.equals(1, #controller.resolvers)
				local schedules = harness.schedule_calls
				local draws = #harness.draws
				for _, callback in ipairs(old_callbacks) do
					callback({ value = "stale", tier = 4 })
				end
				assert.equals(schedules, harness.schedule_calls)
				assert.equals(draws, #harness.draws)
				harness:flush()
				old_callbacks[#old_callbacks + 1] = harness.resolvers[#harness.resolvers].callback
			end
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	it("recollects only the canonical source and invalidates every old callback before replacing state", function()
		local seen = {}
		local round = 0
		local adapter = fake("a", {
			live = function(bufnr)
				seen[#seen + 1] = { kind = "live", bufnr = bufnr }
				return round == 0 and { "alpha", "beta" } or { "alpha", "gamma" }
			end,
			probe = function(entry, bufnr)
				seen[#seen + 1] = { kind = "probe", bufnr = bufnr }
				return found_entry("a", entry).probe
			end,
		})
		with_controller({ adapter }, { a = { "alpha" } }, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			local dashboard = vim.api.nvim_create_buf(false, true)
			overlay.open(source)
			local settled_resolver
			local pending_resolver
			for _, resolver in ipairs(harness.resolvers) do
				if resolver.entry.name == "alpha" then
					settled_resolver = resolver.callback
				elseif resolver.entry.name == "beta" then
					pending_resolver = resolver.callback
				end
			end
			settled_resolver({ value = "old", tier = 4 })
			harness:flush()
			harness:invoke("2")
			harness:flush()
			harness:set_cursor("a\0alpha")
			harness:invoke("<CR>")
			harness:flush()
			harness:invoke("/")
			local accepted_search = harness.inputs[#harness.inputs].callback
			accepted_search("a")
			harness:flush()
			harness:set_cursor("a\0alpha")
			harness:invoke("?")
			assert.equals(0, #harness.scheduled)
			harness:invoke("/")
			local old_search = harness.inputs[#harness.inputs].callback
			local before = vim.deepcopy(harness.controller_state)
			local before_draws = #harness.draws
			local before_schedules = harness.schedule_calls
			local before_resolvers = #harness.resolvers
			round = 1
			vim.api.nvim_set_current_buf(dashboard)
			harness:invoke("r")
			assert.equals(before_schedules + 1, harness.schedule_calls)
			assert.equals(before_resolvers + 2, #harness.resolvers)
			local current_redraw = assert(table.remove(harness.scheduled, 1))

			pending_resolver({ value = "stale", tier = 4 })
			old_search("stale")
			assert.equals(before_draws, #harness.draws)
			current_redraw()
			local state = harness:state()
			assert.equals(source, state.source_bufnr)
			assert.equals(source, state.view.bufnr)
			assert.same({ "a/alpha", "a/gamma" }, names(state.view.active))
			assert.same({}, state.versions)
			assert.equals("all", state.tab)
			assert.equals("a", state.query)
			assert.is_true(state.showing_help)
			assert.equals("a\0alpha", state.expanded_key)
			assert.equals("a\0alpha", state.selected_key)
			assert.is_nil(state.source_error)
			assert.equals(before.generation + 1, state.generation)
			assert.equals(before.revision + 1, state.revision)
			assert.equals(before.search_request + 1, state.search_request)
			assert.equals(before_draws + 1, #harness.draws)
			for _, call in ipairs(seen) do
				assert.equals(source, call.bufnr, call.kind)
			end
			vim.api.nvim_buf_delete(source, { force = true })
			vim.api.nvim_buf_delete(dashboard, { force = true })
		end)
	end)

	for _, case in ipairs({
		{
			name = "deleted source",
			error = "dashboard source buffer is no longer valid",
			prepare = function(source)
				vim.api.nvim_buf_delete(source, { force = true })
			end,
		},
		{
			name = "collector throw",
			error = "dashboard refresh failed while collecting source buffer",
			collect = function()
				error("untrusted collector detail", 0)
			end,
		},
		{
			name = "collector source mismatch",
			error = "dashboard refresh returned a different source buffer",
			collect = function(source)
				return dashboard_view(source + 1, { "replacement" })
			end,
		},
	}) do
		it("contains " .. case.name .. " and preserves the initialized snapshot exactly", function()
			with_controller({}, {}, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				local resolver_callbacks = {}
				overlay.collect = function(bufnr)
					return dashboard_view(bufnr, { "alpha", "beta" })
				end
				harness.resolve_impl = function(entry, callback)
					resolver_callbacks[entry.name] = callback
				end
				overlay.open(source)
				resolver_callbacks.alpha({ value = "old", tier = 4 })
				harness:flush()
				harness:invoke("2")
				harness:flush()
				harness:set_cursor("a\0beta")
				harness:invoke("<CR>")
				harness:flush()
				harness:invoke("/")
				harness.inputs[#harness.inputs].callback("alpha")
				harness:invoke("?")
				harness:flush()

				harness.controller_state.source_error = "prior source error"
				harness.open_options[1].on_resize(harness.instance)
				harness:flush()
				local before = vim.deepcopy(harness:state())
				assert.equals("alpha", before.query)
				assert.is_true(before.showing_help)
				assert.equals("a\0beta", before.expanded_key)
				assert.equals("a\0beta", before.selected_key)
				assert.equals("old", before.versions["a\0alpha"].value)
				assert.equals("prior source error", before.source_error)
				assert.is_not.equals(case.error, before.source_error)

				harness:invoke("/")
				local old_search = harness.inputs[#harness.inputs].callback
				harness.open_options[1].on_resize(harness.instance)
				local old_redraw = assert(table.remove(harness.scheduled, 1))
				local old_resolver = resolver_callbacks.beta
				local collect_calls = 0
				overlay.collect = function(bufnr)
					collect_calls = collect_calls + 1
					return case.collect(bufnr)
				end
				if case.prepare then
					case.prepare(source)
				end
				assert.is_true(pcall(function()
					harness:invoke("r")
				end))
				local current_redraw = assert(table.remove(harness.scheduled, 1))
				local draws = #harness.draws
				local notifications = #harness.notifications
				local schedules = harness.schedule_calls
				old_resolver({ value = "stale", tier = 4 })
				old_search("stale")
				old_redraw()
				assert.equals(draws, #harness.draws)
				assert.equals(notifications, #harness.notifications)
				assert.equals(schedules, harness.schedule_calls)
				assert.equals(0, #harness.scheduled)
				current_redraw()

				local first = vim.deepcopy(harness:state())
				assert.equals(case.prepare and 0 or 1, collect_calls)
				assert.same(before.view, first.view)
				assert.same(before.versions, first.versions)
				assert.equals(before.tab, first.tab)
				assert.equals(before.query, first.query)
				assert.equals(before.showing_help, first.showing_help)
				assert.equals(before.expanded_key, first.expanded_key)
				assert.equals(before.selected_key, first.selected_key)
				assert.equals(case.error, first.source_error)
				assert.equals(before.generation + 1, first.generation)
				assert.equals(before.revision + 1, first.revision)
				assert.equals(before.search_request + 2, first.search_request)

				harness:invoke("r")
				harness:flush()
				local second = harness:state()
				assert.equals(first.generation + 1, second.generation)
				assert.equals(first.revision + 1, second.revision)
				assert.equals(first.search_request + 1, second.search_request)
				assert.equals(case.error, second.source_error)
				if vim.api.nvim_buf_is_valid(source) then
					vim.api.nvim_buf_delete(source, { force = true })
				end
			end)
		end)
	end

	it("clears a prior refresh error and applies identity cursor retention or tab-anchor fallback", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			local names_now = { "alpha", "beta" }
			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, names_now)
			end
			overlay.open(source)
			harness:set_cursor("a\0beta")
			harness:invoke("<CR>")
			harness:flush()
			overlay.collect = function()
				error("failed", 0)
			end
			harness:invoke("r")
			harness:flush()
			assert.is_string(harness:state().source_error)

			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, names_now)
			end
			harness:set_cursor("a\0beta")
			harness:invoke("r")
			harness:flush()
			assert.is_nil(harness:state().source_error)
			assert.equals("a\0beta", harness:state().selected_key)
			assert.equals("a\0beta", harness:state().expanded_key)
			assert.equals(harness.last_output.line_by_key["a\0beta"], harness.instance.cursor)

			harness:invoke("?")
			harness:flush()
			harness.resolve_impl = function(_, callback)
				callback({ value = "sync", tier = 4 })
			end
			harness:invoke("r")
			harness:flush()
			assert.is_true(harness:state().showing_help)
			assert.equals("a\0beta", harness:state().selected_key)
			assert.equals("a\0beta", harness:state().expanded_key)
			harness:invoke("?")
			harness:flush()

			names_now = { "alpha" }
			harness:set_cursor("a\0beta")
			harness:invoke("r")
			harness:flush()
			assert.is_nil(harness:state().selected_key)
			assert.is_nil(harness:state().expanded_key)
			assert.equals(harness.last_output.anchors.body, harness.instance.cursor)
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	it("does not restore a removed selection from stale output during synchronous settlement", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, { "alpha", "beta" })
			end
			overlay.open(source)
			harness:set_cursor("a\0beta")
			harness:invoke("<CR>")
			harness:flush()
			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, { "alpha" })
			end
			harness.resolve_impl = function(_, callback)
				callback({ value = "sync", tier = 4 })
			end
			harness:invoke("r")
			harness:flush()
			assert.is_nil(harness:state().selected_key)
			assert.is_nil(harness:state().expanded_key)
			assert.equals(harness.last_output.anchors.body, harness.instance.cursor)
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	for _, case in ipairs({
		{ name = "synchronous", mode = "sync", accepted = true },
		{ name = "asynchronous", mode = "async", accepted = true },
		{ name = "duplicate", mode = "duplicate", accepted = true },
		{ name = "ordinary throw", mode = "throw", failure = true },
		{ name = "callback then throw", mode = "callback_throw", failure = true },
	}) do
		it("settles current-generation " .. case.name .. " refresh resolution once", function()
			with_controller({}, {}, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				overlay.collect = function(bufnr)
					return dashboard_view(bufnr, {})
				end
				overlay.open(source)
				overlay.collect = function(bufnr)
					return dashboard_view(bufnr, { "alpha" })
				end
				local callback
				harness.resolve_impl = function(_, resolver_callback)
					callback = resolver_callback
					if case.mode == "sync" then
						resolver_callback({ value = "1.0.0", tier = 4 })
					elseif case.mode == "duplicate" then
						resolver_callback({ value = "1.0.0", tier = 4 })
						resolver_callback({ value = "discarded", tier = 4 })
					elseif case.mode == "throw" then
						error("resolver failed", 0)
					elseif case.mode == "callback_throw" then
						resolver_callback({ value = "discarded", tier = 4 })
						error("resolver failed after callback", 0)
					end
				end
				local ok = pcall(function()
					harness:invoke("r")
				end)
				assert.is_true(ok)
				if case.failure then
					assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
					assert.equals(1, harness.close_calls)
					local calls = harness.schedule_calls
					callback({ value = "late", tier = 4 })
					assert.equals(calls, harness.schedule_calls)
				else
					if case.mode == "async" then
						callback({ value = "1.0.0", tier = 4 })
						callback({ value = "discarded", tier = 4 })
					end
					assert.equals(1, harness.schedule_calls)
					harness:flush()
					assert.equals("1.0.0", harness:state().versions["a\0alpha"].value)
					assert.equals(3, harness:state().revision)
					assert.equals(2, #harness.draws)
				end
				vim.api.nvim_buf_delete(source, { force = true })
			end)
		end)
	end

	for _, mode in ipairs({ "throw", "callback_throw" }) do
		it("starts no resolver when the base refresh redraw scheduler " .. mode .. "s", function()
			with_controller({}, {}, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				overlay.collect = function(bufnr)
					return dashboard_view(bufnr, { "alpha" })
				end
				overlay.open(source)
				local old_resolver = harness.resolvers[1].callback
				harness:invoke("/")
				local old_search = harness.inputs[1].callback
				harness.open_options[1].on_resize(harness.instance)
				local old_redraw = assert(table.remove(harness.scheduled, 1))
				local resolvers = #harness.resolvers
				local state = vim.deepcopy(harness:state())
				overlay.collect = function(bufnr)
					return dashboard_view(bufnr, { "beta" })
				end
				harness.schedule_mode = mode
				assert.is_true(pcall(function()
					harness:invoke("r")
				end))
				assert.equals(resolvers, #harness.resolvers)
				assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
				assert.equals(1, harness.close_calls)
				local schedules = harness.schedule_calls
				local draws = #harness.draws
				local notifications = #harness.notifications
				old_resolver({ value = "late", tier = 4 })
				old_search("late")
				old_redraw()
				assert.same(state, harness:state())
				assert.equals(schedules, harness.schedule_calls)
				assert.equals(draws, #harness.draws)
				assert.equals(notifications, #harness.notifications)
				vim.api.nvim_buf_delete(source, { force = true })
			end)
		end)
	end

	it("stops starting resolvers when the first synchronous settlement fails its redraw", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, {})
			end
			overlay.open(source)
			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, { "alpha", "beta" })
			end
			local first_callback
			harness.resolve_impl = function(entry, callback)
				if entry.name == "alpha" then
					first_callback = callback
				end
				callback({ value = entry.name, tier = 4 })
			end
			harness.schedule_impl = function(callback, call)
				if call == 1 then
					callback()
					return
				end
				error("settlement redraw rejected", 0)
			end
			assert.is_true(pcall(function()
				harness:invoke("r")
			end))
			assert.same(
				{ "alpha" },
				vim.tbl_map(function(resolver)
					return resolver.entry.name
				end, harness.resolvers)
			)
			assert.equals(2, harness.schedule_calls)
			assert.equals(2, #harness.draws)
			assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
			assert.equals(1, harness.close_calls)
			local schedules = harness.schedule_calls
			first_callback({ value = "late", tier = 4 })
			assert.equals(schedules, harness.schedule_calls)
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	it("coalesces a burst of current completions with the base refresh draw", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, {})
			end
			overlay.open(source)
			overlay.collect = function(bufnr)
				return dashboard_view(bufnr, { "alpha", "beta", "gamma" })
			end
			harness:invoke("r")
			for _, resolver in ipairs(harness.resolvers) do
				resolver.callback({ value = resolver.entry.name, tier = 4 })
			end
			assert.equals(1, harness.schedule_calls)
			harness:flush()
			assert.equals(2, #harness.draws)
			assert.equals(5, harness:state().revision)
			assert.equals("alpha", harness:state().versions["a\0alpha"].value)
			assert.equals("beta", harness:state().versions["a\0beta"].value)
			assert.equals("gamma", harness:state().versions["a\0gamma"].value)
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	for _, close_kind in ipairs({ "direct", "external" }) do
		it("makes every refresh callback inert after " .. close_kind .. " close", function()
			with_controller({}, {}, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				overlay.collect = function(bufnr)
					return dashboard_view(bufnr, {})
				end
				overlay.open(source)
				overlay.collect = function(bufnr)
					return dashboard_view(bufnr, { "alpha" })
				end
				harness:invoke("r")
				local resolver = harness.resolvers[1].callback
				local scheduled = assert(table.remove(harness.scheduled, 1))
				harness:invoke("/")
				local input = harness.inputs[1].callback
				if close_kind == "direct" then
					harness:invoke("q")
				else
					harness.instance.is_valid = false
				end
				local state = vim.deepcopy(harness:state())
				local draws = #harness.draws
				local notifications = #harness.notifications
				resolver({ value = "late", tier = 4 })
				input("late")
				scheduled()
				assert.same(state, harness:state())
				assert.equals(draws, #harness.draws)
				assert.equals(notifications, #harness.notifications)
				vim.api.nvim_buf_delete(source, { force = true })
			end)
		end)
	end
end)

describe("overlay dashboard copy path", function()
	local function open_copy_entry(overlay, harness, source, probe)
		overlay.collect = function(bufnr)
			local entry = found_entry("a", "alpha")
			entry.probe = probe
			local view = dashboard_view(bufnr, {})
			view.active = { entry }
			return view
		end
		overlay.open(source)
		harness:set_cursor("a\0alpha")
	end

	it("allows exactly the exhaustive active-register set and writes validated bytes unchanged", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			local path = "/tmp/日本語/\255raw"
			open_copy_entry(overlay, harness, source, {
				status = "found",
				binary = "alpha",
				path = path,
				realpath = "/fallback",
				source = "system",
			})
			local allowed = { '"', "+", "*", "-", "_" }
			for byte = string.byte("a"), string.byte("z") do
				allowed[#allowed + 1] = string.char(byte)
			end
			for byte = string.byte("A"), string.byte("Z") do
				allowed[#allowed + 1] = string.char(byte)
			end
			for byte = string.byte("0"), string.byte("9") do
				allowed[#allowed + 1] = string.char(byte)
			end
			for _, register in ipairs(allowed) do
				harness:set_register(register)
				harness:invoke("y")
			end
			assert.equals(#allowed, #harness.setreg_calls)
			assert.equals(#allowed, notification_count(harness, vim.log.levels.INFO))
			for index, register in ipairs(allowed) do
				assert.same({ register = register, value = path }, harness.setreg_calls[index])
			end
			assert.equals(source, harness:state().source_bufnr)
			assert.equals(1, harness:state().revision)
			assert.equals(1, #harness.draws)
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	it("rejects every special, malformed, and non-string active register with one protected warning", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			open_copy_entry(overlay, harness, source, found_entry("a", "alpha").probe)
			local rejected = { "=", ":", "/", ".", "%", "#", "~", "", "aa", 1, false, {}, vim.NIL }
			for _, register in ipairs(rejected) do
				harness:set_register(register)
				local ok = pcall(function()
					harness:invoke("y")
				end)
				assert.is_true(ok)
			end
			harness:set_register(nil)
			assert.is_true(pcall(function()
				harness:invoke("y")
			end))
			assert.equals(0, #harness.setreg_calls)
			assert.equals(#rejected + 1, notification_count(harness, vim.log.levels.WARN))
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	it("prefers present path, falls back only when absent, and enforces every path boundary", function()
		local rejected = { 1, false, "", string.rep("x", 4097) }
		for codepoint = 0x00, 0x1F do
			rejected[#rejected + 1] = "/tmp/" .. string.char(codepoint)
		end
		rejected[#rejected + 1] = "/tmp/" .. string.char(0x7F)
		for codepoint = 0x80, 0x9F do
			rejected[#rejected + 1] = "/tmp/" .. vim.fn.nr2char(codepoint)
		end
		for _, codepoint in ipairs({
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
		}) do
			rejected[#rejected + 1] = "/tmp/" .. vim.fn.nr2char(codepoint)
		end
		for index, path in ipairs(rejected) do
			with_controller({}, {}, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				open_copy_entry(overlay, harness, source, {
					status = "found",
					binary = "alpha",
					path = path,
					realpath = "/safe/fallback",
					source = "system",
				})
				harness:set_register("a")
				harness:invoke("y")
				assert.equals(0, #harness.setreg_calls, ("rejected path fixture %d"):format(index))
				assert.equals(1, notification_count(harness, vim.log.levels.WARN))
				vim.api.nvim_buf_delete(source, { force = true })
			end)
		end

		for _, case in ipairs({
			{ path = string.rep("x", 4096), realpath = "/fallback", expected = string.rep("x", 4096) },
			{ path = "/preferred", realpath = "/fallback", expected = "/preferred" },
			{ realpath = "/fallback", expected = "/fallback" },
		}) do
			with_controller({}, {}, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				open_copy_entry(
					overlay,
					harness,
					source,
					vim.tbl_extend("force", {
						status = "found",
						binary = "alpha",
						source = "system",
					}, case)
				)
				harness:set_register("a")
				harness:invoke("y")
				assert.same({ register = "a", value = case.expected }, harness.setreg_calls[1])
				assert.equals(1, notification_count(harness, vim.log.levels.INFO))
				vim.api.nvim_buf_delete(source, { force = true })
			end)
		end
	end)

	for _, case in ipairs({
		{ name = "throw", result = "throw" },
		{ name = "negative", result = -1 },
		{ name = "false", result = false },
		{ name = "nil", result = nil },
	}) do
		it("contains setreg " .. case.name .. " without reporting success", function()
			with_controller({}, {}, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				open_copy_entry(overlay, harness, source, found_entry("a", "alpha").probe)
				harness:set_register("a")
				harness.setreg_impl = function()
					if case.result == "throw" then
						error("sink failed", 0)
					end
					return case.result
				end
				assert.is_true(pcall(function()
					harness:invoke("y")
				end))
				assert.equals(1, #harness.setreg_calls)
				assert.equals(1, notification_count(harness, vim.log.levels.WARN))
				assert.equals(0, notification_count(harness, vim.log.levels.INFO))
				vim.api.nvim_buf_delete(source, { force = true })
			end)
		end)
	end

	it("contains throwing success and warning notifications without retrying the sink", function()
		for _, sink_result in ipairs({ 0, -1 }) do
			with_controller({}, {}, {}, function(overlay, harness)
				local source = vim.api.nvim_create_buf(false, true)
				open_copy_entry(overlay, harness, source, found_entry("a", "alpha").probe)
				harness:set_register("a")
				harness.setreg_impl = function()
					return sink_result
				end
				harness.notify_impl = function()
					error("notification failed", 0)
				end
				assert.is_true(pcall(function()
					harness:invoke("y")
				end))
				assert.equals(1, #harness.setreg_calls)
				assert.equals(1, #harness.notifications)
				vim.api.nvim_buf_delete(source, { force = true })
			end)
		end
	end)

	it("refuses stale rendered metadata and succeeds after the matching revision is drawn", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			open_copy_entry(overlay, harness, source, found_entry("a", "alpha").probe)
			harness:set_register("a")
			harness:set_cursor("a\0alpha")
			harness:invoke("2")
			harness:invoke("y")
			assert.equals(0, #harness.setreg_calls)
			assert.equals(1, notification_count(harness, vim.log.levels.WARN))
			harness:flush()
			harness:set_cursor("a\0alpha")
			harness:invoke("y")
			assert.equals(1, #harness.setreg_calls)
			assert.equals(1, notification_count(harness, vim.log.levels.INFO))
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	it("copies path bytes from revisioned render metadata after the retained probe mutates", function()
		with_controller({}, {}, {}, function(overlay, harness)
			local source = vim.api.nvim_create_buf(false, true)
			local probe = {
				status = "found",
				binary = "alpha",
				path = "/rendered/path",
				realpath = "/rendered/realpath",
				source = "system",
			}
			open_copy_entry(overlay, harness, source, probe)
			probe.path = "/mutated/path"
			probe.realpath = "/mutated/realpath"
			harness:set_register("a")
			harness:invoke("y")
			assert.same({ register = "a", value = "/rendered/path" }, harness.setreg_calls[1])
			assert.equals(1, notification_count(harness, vim.log.levels.INFO))
			vim.api.nvim_buf_delete(source, { force = true })
		end)
	end)

	it("copies command-like text to a named register without executing or changing the source", function()
		local command = ":lua vim.g.muster_copy_executed = true"
		local adapter = fake("a", {
			live = function()
				return { "alpha" }
			end,
			probe = function()
				return {
					status = "found",
					binary = "alpha",
					path = command,
					realpath = command,
					source = "system",
				}
			end,
		})
		with_adapters({ adapter }, { a = { "alpha" } }, function(overlay)
			local source = vim.api.nvim_create_buf(false, true)
			local report, win
			local saved_register = vim.fn.getreg("a", 1, true)
			local saved_register_type = vim.fn.getregtype("a")
			protect(function()
				vim.api.nvim_buf_set_lines(source, 0, -1, false, { "unchanged" })
				report, win = overlay.open(source)
				vim.g.muster_copy_executed = nil
				vim.wait(100)
				local entry_line
				for index, line in ipairs(vim.api.nvim_buf_get_lines(report, 0, -1, false)) do
					if line:find("alpha", 1, true) then
						entry_line = index
						break
					end
				end
				vim.api.nvim_win_set_cursor(win, { assert(entry_line), 0 })
				vim.api.nvim_set_current_win(win)
				vim.cmd.normal({ args = { '"ay' }, bang = false })
				assert.equals(command, vim.fn.getreg("a"))
				assert.is_nil(vim.g.muster_copy_executed)
				assert.same({ "unchanged" }, vim.api.nvim_buf_get_lines(source, 0, -1, false))
			end, function()
				vim.fn.setreg("a", saved_register, saved_register_type)
				vim.g.muster_copy_executed = nil
				close_overlay(win, report, source)
			end)
		end)
	end)
end)

describe("overlay dashboard initial transaction", function()
	local cases = {
		{ name = "highlight setup", options = { highlight_error = "highlight failed" } },
		{ name = "window open", options = { open_error = "window failed" } },
		{ name = "initial render", options = { render_error = "render failed" } },
		{ name = "initial draw", options = { draw_error = "draw failed" } },
	}
	for index = 1, 12 do
		cases[#cases + 1] = {
			name = "mapping " .. index,
			options = { fail_map_at = index, map_error = "mapping failed " .. index },
		}
	end

	for _, case in ipairs(cases) do
		it("rolls back " .. case.name .. " with inert callbacks", function()
			with_controller({}, {}, case.options, function(overlay, harness)
				local report, win = overlay.open(vim.api.nvim_get_current_buf())
				assert.is_nil(report)
				assert.is_nil(win)
				assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
				assert.is_truthy(harness.notifications[1].message:find("failed", 1, true))
				if #harness.open_options > 0 then
					local schedules = harness.schedule_calls
					harness.open_options[1].on_resize(harness.instance)
					harness.open_options[1].on_error("late callback")
					assert.equals(schedules, harness.schedule_calls)
					assert.equals(1, notification_count(harness, vim.log.levels.ERROR))
				end
				if case.name ~= "highlight setup" and case.name ~= "window open" then
					assert.is_false(harness.instance.is_valid)
					assert.equals(1, harness.close_calls)
				end
			end)
		end)
	end

	it("preserves the initiating error when cleanup also throws", function()
		with_controller({}, {}, {
			fail_map_at = 1,
			map_error = "original mapping error",
			close_error = "secondary cleanup error",
		}, function(overlay, harness)
			local report, win = overlay.open(vim.api.nvim_get_current_buf())
			assert.is_nil(report)
			assert.is_nil(win)
			assert.equals(1, #harness.notifications)
			assert.is_truthy(harness.notifications[1].message:find("original mapping error", 1, true))
			assert.is_nil(harness.notifications[1].message:find("secondary cleanup error", 1, true))
		end)
	end)
end)

describe("overlay dashboard authority boundary", function()
	it("never bare-requires reporting or provisioning through any UI-5 interaction", function()
		local blocked = {
			"muster.runner",
			"muster.automatic",
			"muster.report",
			"muster.enrich",
			"muster.handoff.mason",
		}
		local saved_loaded, saved_preload, tripped = {}, {}, {}
		for _, name in ipairs(blocked) do
			saved_loaded[name] = package.loaded[name]
			saved_preload[name] = package.preload[name]
			package.loaded[name] = nil
			package.preload[name] = function()
				tripped[name] = true
				error("forbidden dashboard require: " .. name)
			end
		end

		local adapter = fake("a", {
			live = function()
				return { "alpha" }
			end,
		})
		local version = require("muster.version")
		local window = require("muster.ui.window")
		local saved_resolve = version.resolve
		local saved_open = window.open
		local saved_input = vim.ui.input
		local version_callback
		local input_callback
		local open_opts
		local source, report, win
		local ok, err = xpcall(function()
			with_adapters({ adapter }, { a = { "alpha" } }, function(overlay)
				version.resolve = function(_, callback)
					version_callback = callback
				end
				window.open = function(opts)
					open_opts = opts
					return saved_open(opts)
				end
				vim.ui.input = function(_, callback)
					input_callback = callback
				end
				source = vim.api.nvim_create_buf(false, true)
				report, win = overlay.open(source)
				local mappings = vim.api.nvim_buf_get_keymap(report, "n")
				local close_callbacks = {}
				for _, mapping in ipairs(mappings) do
					if mapping.desc == "Close Muster dashboard" then
						close_callbacks[#close_callbacks + 1] = mapping.callback
					else
						mapping.callback()
					end
				end
				assert.is_function(input_callback)
				input_callback("alpha")
				version_callback({ value = "1.2.3", tier = 4 })
				open_opts.on_resize(window.current())
				vim.wait(50)
				assert.same({}, tripped)
				close_callbacks[1]()
				report, win = overlay.open(source)
				local reopened = vim.api.nvim_buf_get_keymap(report, "n")
				for _, mapping in ipairs(reopened) do
					if mapping.desc == "Close Muster dashboard" then
						mapping.callback()
						break
					end
				end
				assert.same({}, tripped)
			end)
			for _, name in ipairs(blocked) do
				local required = pcall(require, name)
				assert.is_false(required)
				assert.is_true(tripped[name])
			end
		end, debug.traceback)
		version.resolve = saved_resolve
		window.open = saved_open
		vim.ui.input = saved_input
		for _, name in ipairs(blocked) do
			package.loaded[name] = saved_loaded[name]
			package.preload[name] = saved_preload[name]
		end
		pcall(close_overlay, win, report, source)
		if not ok then
			error(err, 0)
		end
	end)
end)

describe("overlay complete dashboard integration", function()
	it("runs the complete dashboard flow at wide and compact widths", function()
		local blocked = {
			"muster.runner",
			"muster.automatic",
			"muster.report",
			"muster.enrich",
			"muster.handoff.mason",
		}
		local highlight_names = {
			"MusterNormal",
			"MusterBackdrop",
			"MusterHeader",
			"MusterTabActive",
			"MusterTabInactive",
			"MusterStatusFound",
			"MusterStatusMissing",
			"MusterStatusBroken",
			"MusterStatusUnknown",
			"MusterStatusUnverifiable",
			"MusterAdapter",
			"MusterVersion",
			"MusterMuted",
			"MusterDetailKey",
			"MusterSearchMatch",
		}
		local source_lines = { "local dashboard_source = true", "return dashboard_source" }
		local long_tool = "extraordinarily_long_dashboard_tool"
		local namespace = vim.api.nvim_create_namespace("muster_ui")
		local ui_render = require("muster.ui.render")
		local ui_help = require("muster.ui.help")
		local ui_window = require("muster.ui.window")
		local version = require("muster.version")
		local saved = {
			columns = vim.o.columns,
			lines = vim.o.lines,
			cmdheight = vim.o.cmdheight,
			current_win = vim.api.nvim_get_current_win(),
			current_buf = vim.api.nvim_get_current_buf(),
			render = ui_render.render,
			resolve = version.resolve,
			input = vim.ui.input,
			notify = vim.notify,
			setreg = vim.fn.setreg,
			register = vim.fn.getreg('"', 1, true),
			register_type = vim.fn.getregtype('"'),
			loaded = {},
			preload = {},
			highlights = {},
		}
		local baseline = { wins = {}, bufs = {} }
		local sources = {}
		local resources = {}
		local notifications = {}
		local setreg_calls = {}
		local adapter_calls = {}
		local version_calls = {}
		local render_records = {}
		local asserted_render_records = 0
		local input_values = {}
		local tripped = {}
		local phase = "setup"
		local current_source

		for _, winid in ipairs(vim.api.nvim_list_wins()) do
			baseline.wins[winid] = true
		end
		for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				baseline.bufs[bufnr] = true
			end
		end
		for _, name in ipairs(highlight_names) do
			saved.highlights[name] = vim.api.nvim_get_hl(0, { name = name, link = true })
		end
		saved.highlight_group_exists = pcall(vim.api.nvim_get_autocmds, { group = "muster_ui_highlights" })
		for _, name in ipairs(blocked) do
			saved.loaded[name] = package.loaded[name]
			saved.preload[name] = package.preload[name]
		end

		local function text(bufnr)
			return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		end

		local function wrapped_text(bufnr)
			return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)):gsub("%s", "")
		end

		local function find_line(bufnr, needle)
			for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
				if line:find(needle, 1, true) then
					return index
				end
			end
		end

		local function heading_line(bufnr)
			for index, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
				if line:match("^%s*STATUS%s+TOOL%s+TYPE%s+VERSION%s*$") then
					return index
				end
			end
		end

		local function invoke_mapping(bufnr, desc)
			for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
				if mapping.desc == desc then
					assert.is_function(mapping.callback, "mapping has no Lua callback: " .. desc)
					mapping.callback()
					return
				end
			end
			error("missing buffer-local mapping: " .. desc, 0)
		end

		local function attach_redraw_counter(bufnr)
			local tracker = { count = 0 }
			assert.is_true(vim.api.nvim_buf_attach(bufnr, false, {
				on_lines = function()
					tracker.count = tracker.count + 1
				end,
			}))
			return tracker
		end

		local function wait_for_redraw(tracker, previous, label)
			assert.is_true(
				vim.wait(1000, function()
					return tracker.count > previous
				end, 10),
				"dashboard redraw timed out: " .. label
			)
		end

		local function assert_geometry(winid, editor_width)
			local expected_width = math.floor(editor_width * 0.8)
			local win_config = vim.api.nvim_win_get_config(winid)
			assert.equals(expected_width, vim.api.nvim_win_get_width(winid))
			assert.equals(20, vim.api.nvim_win_get_height(winid))
			assert.equals(expected_width, win_config.width)
			assert.equals(20, win_config.height)
			assert.equals(math.floor((editor_width - expected_width - 2) / 2), win_config.col)
			assert.equals(8, win_config.row)
			assert.same({ "╭", "─", "╮", "│", "╯", "─", "╰", "│" }, win_config.border)
			assert.equals("editor", win_config.relative)
		end

		local function assert_extmarks_valid(bufnr)
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			local marks = vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
			assert.is_true(#marks > 0)
			for _, mark in ipairs(marks) do
				local line = mark[2]
				local col = mark[3]
				local details = mark[4]
				assert.is_true(line >= 0 and line < #lines, "extmark line outside report")
				assert.is_true(col >= 0 and col <= #lines[line + 1], "extmark column outside report")
				if details.end_col ~= nil then
					assert.is_true(details.end_col >= col, "extmark end precedes start")
					assert.is_true(details.end_col <= #lines[line + 1], "extmark end outside report")
				end
			end
			return marks
		end

		local function expected_table_margin(width)
			local available = math.max(0, math.floor((width - 2) / 2))
			local preferred = math.min(32, math.max(8, math.floor(width * 0.2)))
			return math.min(available, preferred)
		end

		local function assert_table_margins(line, width)
			local margin = expected_table_margin(width)
			assert.equals(margin, #line - #line:gsub("^ +", ""))
			assert.equals(margin, width - vim.fn.strdisplaywidth(line))
		end

		local function assert_compact_layout(bufnr)
			assert.is_nil(heading_line(bufnr))
			local winid = vim.fn.bufwinid(bufnr)
			assert.is_true(winid > 0)
			local width = vim.api.nvim_win_get_width(winid)
			local physical = false
			for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
				if line:find("integration", 1, true) then
					physical = true
					assert_table_margins(line, width)
				end
			end
			assert.is_true(physical, "compact physical metadata line missing")
		end

		local function assert_layout(bufnr, editor_width)
			if editor_width == 120 then
				local heading = assert(heading_line(bufnr), "wide four-column heading missing")
				local line = vim.api.nvim_buf_get_lines(bufnr, heading - 1, heading, false)[1]
				local winid = vim.fn.bufwinid(bufnr)
				assert.is_true(winid > 0)
				local width = vim.api.nvim_win_get_width(winid)
				assert_table_margins(line, width)
			else
				assert_compact_layout(bufnr)
			end
		end

		local function assert_centered(line, width)
			local content = line:gsub("^ +", "")
			assert.equals(math.floor((width - vim.fn.strdisplaywidth(content)) / 2), #line - #content)
		end

		local function assert_chrome(report, winid)
			local lines = vim.api.nvim_buf_get_lines(report, 0, -1, false)
			local width = vim.api.nvim_win_get_width(winid)
			assert.equals("muster.nvim", vim.trim(lines[1]))
			assert.is_truthy(lines[2]:find("  •  buf ", 1, true))
			assert_centered(lines[1], width)
			assert_centered(lines[2], width)

			local tab_lines = {}
			for _, pill in ipairs({ "[ Active (", "[ All (", "[ Issues (" }) do
				local found
				for index, line in ipairs(lines) do
					if line:find(pill, 1, true) then
						found = index
						break
					end
				end
				assert.is_number(found, "missing tab pill " .. pill)
				tab_lines[found] = true
			end
			for line in pairs(tab_lines) do
				assert_centered(lines[line], width)
			end

			local footer = lines[#lines]
			assert.is_truthy(footer:find("/ Muster search:", 1, true))
			assert.is_truthy(footer:find("? Help", 1, true))
			for _, hidden in ipairs({ "close", "refresh", "copy path", "Active tab", "details" }) do
				assert.is_nil(footer:find(hidden, 1, true), "footer includes nonessential hint " .. hidden)
			end
			assert.is_true(vim.fn.strdisplaywidth(footer) <= width)
			assert_centered(footer, width)
			assert.is_nil(footer:find("…", 1, true))
		end

		local function assert_source_unchanged(source)
			assert.same(source_lines, vim.api.nvim_buf_get_lines(source, 0, -1, false))
			assert.equals("lua", vim.bo[source].filetype)
		end

		local function assert_render_records(expected)
			assert.equals(asserted_render_records + expected, #render_records)
			for index = asserted_render_records + 1, #render_records do
				assert.equals(render_records[index].input, render_records[index].output)
			end
			asserted_render_records = #render_records
		end

		local function assert_stage(report, winid, editor_width, source, expected_renders)
			assert_render_records(expected_renders == nil and 1 or expected_renders)
			assert.is_true(vim.api.nvim_buf_is_valid(report))
			assert.is_true(vim.api.nvim_win_is_valid(winid))
			assert_geometry(winid, editor_width)
			assert_extmarks_valid(report)
			assert_chrome(report, winid)
			assert_source_unchanged(source)
			assert.same({}, tripped)
		end

		local function assert_selected(report, winid, name)
			assert.equals(
				assert(find_line(report, name), "selected row missing: " .. name),
				vim.api.nvim_win_get_cursor(winid)[1]
			)
		end

		local function assert_anchor(report, winid, editor_width, compact_text)
			local expected = editor_width == 120 and heading_line(report) or find_line(report, compact_text)
			assert.equals(assert(expected, "dashboard anchor missing"), vim.api.nvim_win_get_cursor(winid)[1])
		end

		local function assert_adapter_slice(start_index, source, expected_phase)
			local probes = 0
			local live = 0
			for index = start_index + 1, #adapter_calls do
				local call = adapter_calls[index]
				assert.equals(source, call.bufnr)
				assert.equals(expected_phase, call.phase)
				if call.kind == "probe" then
					probes = probes + 1
				else
					live = live + 1
				end
			end
			assert.equals(3, probes)
			assert.equals(1, live)
		end

		local function remember_resources(instance)
			local ids = {
				win = instance.win,
				buf = instance.buf,
				backdrop_win = instance.backdrop_win,
				backdrop_buf = instance.backdrop_buf,
				augroup = instance.augroup,
			}
			resources[#resources + 1] = ids
			assert.is_nil(ids.backdrop_win)
			assert.is_nil(ids.backdrop_buf)
			return ids
		end

		local function assert_retired(ids)
			assert.is_false(ids.win and vim.api.nvim_win_is_valid(ids.win) or false)
			assert.is_false(ids.buf and vim.api.nvim_buf_is_valid(ids.buf) or false)
			assert.is_false(ids.backdrop_win and vim.api.nvim_win_is_valid(ids.backdrop_win) or false)
			assert.is_false(ids.backdrop_buf and vim.api.nvim_buf_is_valid(ids.backdrop_buf) or false)
			assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = ids.augroup }))
			assert.is_nil(ui_window.current())
		end

		local function close_dashboard(report, ids)
			invoke_mapping(report, "Close Muster dashboard")
			assert.is_true(vim.wait(1000, function()
				return not vim.api.nvim_buf_is_valid(ids.buf) and not vim.api.nvim_win_is_valid(ids.win)
			end, 10))
			assert_render_records(0)
			assert_retired(ids)
		end

		local adapter = fake("integration_adapter", {
			live = function(bufnr)
				adapter_calls[#adapter_calls + 1] = { kind = "live", bufnr = bufnr, phase = phase }
				return { "alpha", "beta", long_tool }
			end,
			probe = function(entry, bufnr)
				adapter_calls[#adapter_calls + 1] = { kind = "probe", bufnr = bufnr, phase = phase }
				return {
					status = "found",
					binary = entry,
					path = ("/raw/dashboard/%d/%s"):format(bufnr, entry),
					realpath = ("/resolved/dashboard/%d/%s"):format(bufnr, entry),
					source = "system",
				}
			end,
		})

		local function run_flow(overlay, initial_width)
			local resized_width = initial_width == 120 and 50 or 120
			vim.o.columns = initial_width
			vim.o.lines = 40
			vim.o.cmdheight = 1
			local source = vim.api.nvim_create_buf(false, true)
			sources[#sources + 1] = source
			vim.api.nvim_buf_set_lines(source, 0, -1, false, source_lines)
			vim.bo[source].filetype = "lua"
			current_source = source
			phase = "open"
			input_values = { "beta", "" }
			local calls_before_open = #adapter_calls
			local versions_before_open = #version_calls
			local report, winid = overlay.open(source)
			assert.is_number(report)
			assert.is_number(winid)
			local first = remember_resources(assert(ui_window.current()))
			assert_stage(report, winid, initial_width, source)
			local tracker = attach_redraw_counter(report)
			assert.is_true(
				vim.wait(1000, function()
					return text(report):find("9.", 1, true) ~= nil
				end, 10),
				"initial versions did not render:\n" .. text(report)
			)
			assert_adapter_slice(calls_before_open, source, "open")
			assert.equals(versions_before_open + 3, #version_calls)
			assert_stage(report, winid, initial_width, source)
			assert_layout(report, initial_width)
			assert_anchor(report, winid, initial_width, "alpha")

			local redraw = tracker.count
			invoke_mapping(report, "Show All tools")
			wait_for_redraw(tracker, redraw, "All")
			assert.is_truthy(text(report):find("extraordinarily_lon", 1, true))
			assert_stage(report, winid, initial_width, source)
			assert_layout(report, initial_width)
			if initial_width == 120 then
				assert_anchor(report, winid, initial_width, "alpha")
			else
				assert_selected(report, winid, "alpha")
			end

			vim.api.nvim_win_set_cursor(winid, { assert(find_line(report, "beta")), 0 })
			redraw = tracker.count
			invoke_mapping(report, "Toggle Muster details")
			wait_for_redraw(tracker, redraw, "details")
			local beta_path = ("/raw/dashboard/%d/beta"):format(source)
			assert.is_truthy(wrapped_text(report):find(beta_path, 1, true))
			assert_stage(report, winid, initial_width, source)
			assert_selected(report, winid, "beta")

			redraw = tracker.count
			invoke_mapping(report, "Toggle Muster details")
			wait_for_redraw(tracker, redraw, "details collapse")
			assert.is_nil(wrapped_text(report):find(beta_path, 1, true))
			assert_stage(report, winid, initial_width, source)
			assert_selected(report, winid, "beta")

			redraw = tracker.count
			invoke_mapping(report, "Search Muster tools")
			wait_for_redraw(tracker, redraw, "literal search")
			assert.is_truthy(text(report):find("beta", 1, true))
			assert.is_nil(text(report):find(long_tool, 1, true))
			assert_stage(report, winid, initial_width, source)
			assert_selected(report, winid, "beta")

			redraw = tracker.count
			invoke_mapping(report, "Show Muster help")
			local help_instance = assert(ui_help.current(), "help overlay did not open")
			assert.equals(redraw, tracker.count)
			assert.is_truthy(text(help_instance.buf):find("Navigation", 1, true))
			assert.is_nil(text(report):find("Navigation", 1, true))
			assert.equals(
				math.floor(vim.api.nvim_win_get_width(winid) * 0.8),
				vim.api.nvim_win_get_width(help_instance.win)
			)
			assert.equals(
				math.floor(vim.api.nvim_win_get_height(winid) * 0.8),
				vim.api.nvim_win_get_height(help_instance.win)
			)
			assert_stage(report, winid, initial_width, source, 0)

			vim.o.columns = resized_width
			vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
			wait_for_redraw(tracker, redraw, "help parent resize")
			assert.equals(
				math.floor(vim.api.nvim_win_get_width(winid) * 0.8),
				vim.api.nvim_win_get_width(help_instance.win)
			)
			assert.equals(
				math.floor(vim.api.nvim_win_get_height(winid) * 0.8),
				vim.api.nvim_win_get_height(help_instance.win)
			)
			assert_stage(report, winid, resized_width, source)
			vim.o.columns = initial_width
			redraw = tracker.count
			vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
			wait_for_redraw(tracker, redraw, "help parent restore")
			assert_stage(report, winid, initial_width, source)

			redraw = tracker.count
			invoke_mapping(help_instance.buf, "Close Muster help")
			assert.equals(redraw, tracker.count)
			assert.is_nil(ui_help.current())
			assert.is_truthy(text(report):find("beta", 1, true))
			assert_stage(report, winid, initial_width, source, 0)
			assert_selected(report, winid, "beta")

			redraw = tracker.count
			invoke_mapping(report, "Search Muster tools")
			wait_for_redraw(tracker, redraw, "search clear")
			assert.is_truthy(text(report):find("extraordinarily_lon", 1, true))
			assert_stage(report, winid, initial_width, source)
			assert_layout(report, initial_width)
			assert_selected(report, winid, "beta")
			vim.api.nvim_win_set_cursor(winid, { assert(find_line(report, "beta")), 0 })

			phase = "refresh"
			local calls_before_refresh = #adapter_calls
			local versions_before_refresh = #version_calls
			redraw = tracker.count
			invoke_mapping(report, "Refresh Muster dashboard")
			wait_for_redraw(tracker, redraw, "refresh")
			assert_adapter_slice(calls_before_refresh, source, "refresh")
			assert.equals(versions_before_refresh + 3, #version_calls)
			assert_stage(report, winid, initial_width, source)
			assert_selected(report, winid, "beta")

			local copies_before = #setreg_calls
			invoke_mapping(report, "Copy Muster path")
			assert.same(
				{ register = '"', value = ("/raw/dashboard/%d/beta"):format(source) },
				setreg_calls[#setreg_calls]
			)
			assert.equals(copies_before + 1, #setreg_calls)
			assert_stage(report, winid, initial_width, source, 0)
			assert_selected(report, winid, "beta")

			local calls_before_resize = #adapter_calls
			local versions_before_resize = #version_calls
			redraw = tracker.count
			vim.o.columns = resized_width
			vim.api.nvim_exec_autocmds("VimResized", { modeline = false })
			wait_for_redraw(tracker, redraw, "VimResized")
			assert.equals(calls_before_resize, #adapter_calls)
			assert.equals(versions_before_resize, #version_calls)
			assert_stage(report, winid, resized_width, source)
			assert_layout(report, resized_width)
			assert_selected(report, winid, "beta")

			copies_before = #setreg_calls
			invoke_mapping(report, "Copy Muster path")
			assert.same(
				{ register = '"', value = ("/raw/dashboard/%d/beta"):format(source) },
				setreg_calls[#setreg_calls]
			)
			assert.equals(copies_before + 1, #setreg_calls)
			assert_stage(report, winid, resized_width, source, 0)
			close_dashboard(report, first)

			phase = "reopen"
			local calls_before_reopen = #adapter_calls
			local versions_before_reopen = #version_calls
			report, winid = overlay.open(source)
			local reopened = remember_resources(assert(ui_window.current()))
			assert_stage(report, winid, resized_width, source)
			tracker = attach_redraw_counter(report)
			assert.is_true(
				vim.wait(1000, function()
					return text(report):find("9.", 1, true) ~= nil
				end, 10),
				"reopened versions did not render:\n" .. text(report)
			)
			assert_adapter_slice(calls_before_reopen, source, "reopen")
			assert.equals(versions_before_reopen + 3, #version_calls)
			assert_stage(report, winid, resized_width, source)
			assert_layout(report, resized_width)
			assert_anchor(report, winid, resized_width, "alpha")
			close_dashboard(report, reopened)
			assert_source_unchanged(source)
			vim.api.nvim_buf_delete(source, { force = true })
			assert.is_false(vim.api.nvim_buf_is_valid(source))
		end

		protect(function()
			for _, name in ipairs(blocked) do
				package.loaded[name] = nil
				package.preload[name] = function()
					tripped[name] = true
					error("forbidden dashboard require: " .. name, 0)
				end
			end
			ui_render.render = function(state, width)
				local output = saved.render(state, width)
				render_records[#render_records + 1] = { input = state.revision, output = output.revision }
				return output
			end
			version.resolve = function(entry, callback)
				version_calls[#version_calls + 1] = { name = entry.name, source = current_source, phase = phase }
				callback({ value = "9.8.7", tier = 4 })
			end
			vim.ui.input = function(opts, callback)
				assert.equals("Muster search: ", opts.prompt)
				assert.is_true(#input_values > 0)
				callback(table.remove(input_values, 1))
			end
			vim.notify = function(message, level, opts)
				notifications[#notifications + 1] = { message = message, level = level, opts = opts }
			end
			vim.fn.setreg = function(register, value)
				setreg_calls[#setreg_calls + 1] = { register = register, value = value }
				return 0
			end

			with_adapters({ adapter }, {
				integration_adapter = { "alpha", "beta", long_tool },
				ui = { height = 20, backdrop = 100 },
			}, function(overlay)
				run_flow(overlay, 120)
				run_flow(overlay, 50)
			end)

			for _, notification in ipairs(notifications) do
				assert.is_true(notification.level ~= vim.log.levels.ERROR and notification.level ~= vim.log.levels.WARN)
			end
			assert.equals(4, #setreg_calls)
			assert.same({}, tripped)
			for _, name in ipairs(blocked) do
				assert.is_false(pcall(require, name))
				assert.is_true(tripped[name])
			end
			for _, winid in ipairs(vim.api.nvim_list_wins()) do
				assert.is_true(baseline.wins[winid] == true, "window leaked: " .. winid)
			end
			for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_valid(bufnr) then
					assert.is_true(baseline.bufs[bufnr] == true, "buffer leaked: " .. bufnr)
				end
			end
		end, function()
			cleanup_all(function()
				ui_render.render = saved.render
				version.resolve = saved.resolve
				vim.ui.input = saved.input
				vim.notify = saved.notify
				vim.fn.setreg = saved.setreg
			end, function()
				for _, name in ipairs(blocked) do
					package.loaded[name] = saved.loaded[name]
					package.preload[name] = saved.preload[name]
				end
			end, function()
				for _ = 1, 3 do
					local ok, current = pcall(ui_help.current)
					if ok and current then
						pcall(current.close, current, false)
					end
				end
				for _ = 1, 3 do
					local ok, current = pcall(ui_window.current)
					if ok and current then
						pcall(current.close, current)
					end
				end
				for _, ids in ipairs(resources) do
					if ids.win and vim.api.nvim_win_is_valid(ids.win) then
						pcall(vim.api.nvim_win_close, ids.win, true)
					end
					if ids.backdrop_win and vim.api.nvim_win_is_valid(ids.backdrop_win) then
						pcall(vim.api.nvim_win_close, ids.backdrop_win, true)
					end
					if ids.buf and vim.api.nvim_buf_is_valid(ids.buf) then
						pcall(vim.api.nvim_buf_delete, ids.buf, { force = true })
					end
					if ids.backdrop_buf and vim.api.nvim_buf_is_valid(ids.backdrop_buf) then
						pcall(vim.api.nvim_buf_delete, ids.backdrop_buf, { force = true })
					end
					if ids.augroup then
						pcall(vim.api.nvim_del_augroup_by_id, ids.augroup)
					end
				end
			end, function()
				if vim.api.nvim_win_is_valid(saved.current_win) then
					vim.api.nvim_set_current_win(saved.current_win)
					if vim.api.nvim_buf_is_valid(saved.current_buf) then
						vim.api.nvim_set_current_buf(saved.current_buf)
					end
				end
				for _, source in ipairs(sources) do
					if vim.api.nvim_buf_is_valid(source) then
						pcall(vim.api.nvim_buf_delete, source, { force = true })
					end
				end
			end, function()
				saved.setreg('"', saved.register, saved.register_type)
			end, function()
				vim.o.columns = saved.columns
				vim.o.lines = saved.lines
				vim.o.cmdheight = saved.cmdheight
			end, function()
				for _, name in ipairs(highlight_names) do
					vim.api.nvim_set_hl(0, name, saved.highlights[name])
				end
				if not saved.highlight_group_exists then
					pcall(vim.api.nvim_del_augroup_by_name, "muster_ui_highlights")
				end
			end)
		end)
	end)
end)
