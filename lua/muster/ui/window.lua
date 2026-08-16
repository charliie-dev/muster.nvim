local M = {}

local namespace = vim.api.nvim_create_namespace("muster_ui")

---@type muster.UiWindow|nil
local active
---@type muster.UiWindow|nil
local retiring

local MAIN_BUFFER_OPTIONS = {
	buftype = "nofile",
	bufhidden = "wipe",
	swapfile = false,
	modifiable = false,
	buflisted = false,
	undolevels = -1,
	textwidth = 0,
	filetype = "muster",
}

local BACKDROP_BUFFER_OPTIONS = {
	buftype = "nofile",
	bufhidden = "wipe",
	swapfile = false,
	buflisted = false,
	filetype = "muster_backdrop",
}

local MAIN_WINDOW_OPTIONS = {
	number = false,
	relativenumber = false,
	wrap = false,
	spell = false,
	foldenable = false,
	signcolumn = "no",
	colorcolumn = "",
	cursorline = true,
	winhighlight = "Normal:MusterNormal",
}

local function backdrop_window_options(blend)
	return {
		winblend = blend,
		winhighlight = "Normal:MusterBackdrop",
	}
end

local function set_options(scope, id, options)
	for name, value in pairs(options) do
		vim.api.nvim_set_option_value(name, value, { [scope] = id })
	end
end

local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(value, maximum))
end

local function backdrop_eligible(ui)
	if ui.backdrop >= 100 or not vim.o.termguicolors then
		return false
	end
	local ok, normal = pcall(vim.api.nvim_get_hl, 0, { name = "Normal" })
	return ok and type(normal.bg) == "number" and normal.bg % 1 == 0
end

local function geometry(ui)
	local columns = vim.o.columns
	local usable_lines = math.max(1, vim.o.lines - vim.o.cmdheight)
	local border = ui.border
	local border_cells = 0
	if border ~= "none" and columns >= 3 and usable_lines >= 3 then
		border_cells = 2
	else
		border = "none"
	end

	local requested_width = ui.width <= 1 and math.floor(columns * ui.width) or math.floor(ui.width)
	local requested_height = ui.height <= 1 and math.floor(usable_lines * ui.height) or math.floor(ui.height)
	local content_width = clamp(requested_width, 1, columns - border_cells)
	local content_height = clamp(requested_height, 1, usable_lines - border_cells)
	local col = math.max(0, math.floor((columns - content_width - border_cells) / 2))
	local row = math.max(0, math.floor((usable_lines - content_height - border_cells) / 2))

	return {
		relative = "editor",
		style = "minimal",
		focusable = true,
		zindex = 50,
		width = content_width,
		height = content_height,
		row = row,
		col = col,
		border = border,
	},
		{
			relative = "editor",
			row = 0,
			col = 0,
			width = columns,
			height = usable_lines,
			style = "minimal",
			border = "none",
			focusable = false,
			zindex = 49,
		},
		backdrop_eligible(ui)
end

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function remember_error(first, ok, err)
	if not ok and first == nil then
		return err
	end
	return first
end

local function reconcile(instance)
	if instance.win ~= nil and not valid_win(instance.win) then
		instance.win = nil
	end
	if instance.backdrop_win ~= nil and not valid_win(instance.backdrop_win) then
		instance.backdrop_win = nil
	end
	if instance.buf ~= nil and not valid_buf(instance.buf) then
		instance.buf = nil
	end
	if instance.backdrop_buf ~= nil and not valid_buf(instance.backdrop_buf) then
		instance.backdrop_buf = nil
	end
	if instance.buf == nil and instance.backdrop_buf == nil then
		instance.namespace_dirty = false
	end
end

local function cleanup_pass(instance)
	local first_error

	if instance.namespace_dirty then
		local cleared = true
		for _, field in ipairs({ "buf", "backdrop_buf" }) do
			local buf = instance[field]
			if valid_buf(buf) then
				local ok, err = pcall(vim.api.nvim_buf_clear_namespace, buf, namespace, 0, -1)
				first_error = remember_error(first_error, ok, err)
				cleared = cleared and ok
			end
		end
		if cleared then
			instance.namespace_dirty = false
		end
	end

	if instance.augroup ~= nil then
		local ok, err = pcall(vim.api.nvim_del_augroup_by_id, instance.augroup)
		first_error = remember_error(first_error, ok, err)
		if ok then
			instance.augroup = nil
		end
	end

	for _, field in ipairs({ "win", "backdrop_win" }) do
		local win = instance[field]
		if valid_win(win) then
			local ok, err = pcall(vim.api.nvim_win_close, win, true)
			first_error = remember_error(first_error, ok, err)
			if ok then
				instance[field] = nil
			end
		else
			instance[field] = nil
		end
	end

	for _, field in ipairs({ "buf", "backdrop_buf" }) do
		local buf = instance[field]
		if valid_buf(buf) then
			local ok_modifiable, modifiable_err =
				pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = buf })
			first_error = remember_error(first_error, ok_modifiable, modifiable_err)
			local ok, err = pcall(vim.api.nvim_buf_delete, buf, { force = true })
			first_error = remember_error(first_error, ok, err)
			if ok then
				instance[field] = nil
			end
		else
			instance[field] = nil
		end
	end

	reconcile(instance)
	return first_error
end

local function resources_gone(instance)
	return instance.augroup == nil
		and instance.win == nil
		and instance.backdrop_win == nil
		and instance.buf == nil
		and instance.backdrop_buf == nil
		and not instance.namespace_dirty
end

local function cleanup(instance)
	if instance.cleanup_running then
		return
	end
	instance.cleanup_running = true
	instance.closing = true
	if active == instance then
		active = nil
	end
	retiring = instance

	local first_error
	for _ = 1, 2 do
		local pass_error = cleanup_pass(instance)
		first_error = first_error or pass_error
	end
	instance.cleanup_running = false

	if resources_gone(instance) then
		if retiring == instance then
			retiring = nil
		end
		instance.closed = true
	end
	return first_error
end

local function raise_after_cleanup(instance, initiating_error)
	cleanup(instance)
	error(initiating_error, 0)
end

local function drain_retiring()
	if retiring == nil then
		return
	end
	local instance = retiring
	local err = cleanup(instance)
	if err ~= nil then
		error(err, 0)
	end
	if retiring ~= nil then
		error("muster.ui.window: retirement incomplete", 0)
	end
end

local function instance_valid(instance)
	if instance.closing or instance.closed then
		return false
	end
	if not valid_buf(instance.buf) or not valid_win(instance.win) then
		return false
	end
	if instance.backdrop_buf ~= nil or instance.backdrop_win ~= nil then
		return valid_buf(instance.backdrop_buf) and valid_win(instance.backdrop_win)
	end
	return true
end

local methods = {}
methods.__index = methods

function methods:valid()
	return instance_valid(self)
end

function methods:focus()
	vim.api.nvim_set_current_win(self.win)
end

function methods:content_width()
	return vim.api.nvim_win_get_width(self.win)
end

function methods:cursor_line()
	return vim.api.nvim_win_get_cursor(self.win)[1]
end

function methods:draw(output, selected_key)
	local saved_view
	local initiating_error
	local ok, err = pcall(function()
		saved_view = vim.api.nvim_win_call(self.win, vim.fn.winsaveview)
		vim.api.nvim_set_option_value("modifiable", true, { buf = self.buf })
		vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, output.lines)
	end)
	if not ok then
		initiating_error = err
	end

	local modifiable_ok, modifiable_err = pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = self.buf })
	if initiating_error == nil and not modifiable_ok then
		initiating_error = modifiable_err
	end

	if initiating_error == nil then
		local draw_ok, draw_err = pcall(function()
			vim.api.nvim_buf_clear_namespace(self.buf, namespace, 0, -1)
			self.namespace_dirty = true
			for _, mark in ipairs(output.extmarks) do
				vim.api.nvim_buf_set_extmark(self.buf, namespace, mark.line, mark.col, vim.deepcopy(mark.opts))
			end
			for _, item in ipairs(output.virtual_text) do
				vim.api.nvim_buf_set_extmark(self.buf, namespace, item.line, 0, {
					virt_text = vim.deepcopy(item.chunks),
					virt_text_pos = item.pos or "eol",
				})
			end
			local target = selected_key and output.line_by_key[selected_key]
				or output.anchors.body
				or output.anchors.tabs
				or output.anchors.title
				or 1
			saved_view.lnum = target
			saved_view.col = 0
			vim.api.nvim_win_call(self.win, function()
				vim.fn.winrestview(saved_view)
			end)
		end)
		if not draw_ok then
			initiating_error = draw_err
		end
	end

	if initiating_error ~= nil then
		raise_after_cleanup(self, initiating_error)
	end
end

function methods:map(lhs, callback, desc)
	local ok, err = pcall(vim.keymap.set, "n", lhs, callback, {
		buffer = self.buf,
		nowait = true,
		silent = true,
		desc = desc,
	})
	if not ok then
		raise_after_cleanup(self, err)
	end
end

function methods:close()
	if self.closed and retiring ~= self then
		return
	end
	local err = cleanup(self)
	if err ~= nil then
		error(err, 0)
	end
end

local function resize(instance)
	local main_config, backdrop_config = geometry(instance.ui)
	vim.api.nvim_win_set_config(instance.win, main_config)
	if instance.backdrop_win ~= nil then
		vim.api.nvim_win_set_config(instance.backdrop_win, backdrop_config)
	end
	set_options("win", instance.win, MAIN_WINDOW_OPTIONS)
	if instance.backdrop_win ~= nil then
		set_options("win", instance.backdrop_win, backdrop_window_options(instance.ui.backdrop))
	end
	instance.on_resize(instance)
end

local function resize_callback(instance)
	if active ~= instance or instance.closing or not instance_valid(instance) then
		return
	end
	local ok, err = pcall(resize, instance)
	if ok then
		return
	end
	cleanup(instance)
	pcall(instance.on_error, err)
end

local function lifecycle_callback(instance)
	if active ~= instance or instance.closing then
		return
	end
	pcall(cleanup, instance)
end

local function create_autocmds(instance)
	vim.api.nvim_create_autocmd("VimResized", {
		group = instance.augroup,
		callback = function()
			resize_callback(instance)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = instance.augroup,
		pattern = tostring(instance.win),
		callback = function()
			lifecycle_callback(instance)
		end,
	})
	for _, event in ipairs({ "BufHidden", "BufDelete", "BufWipeout" }) do
		vim.api.nvim_create_autocmd(event, {
			group = instance.augroup,
			buffer = instance.buf,
			callback = function()
				lifecycle_callback(instance)
			end,
		})
	end
end

local function acquire(opts)
	local main_config, backdrop_config, use_backdrop = geometry(opts.ui)
	local instance = setmetatable({
		source_bufnr = opts.source_bufnr,
		ui = opts.ui,
		on_resize = opts.on_resize,
		on_error = opts.on_error,
		closing = false,
		closed = false,
		cleanup_running = false,
		namespace_dirty = false,
	}, methods)

	local ok, err = pcall(function()
		instance.buf = vim.api.nvim_create_buf(false, true)
		set_options("buf", instance.buf, MAIN_BUFFER_OPTIONS)

		if use_backdrop then
			instance.backdrop_buf = vim.api.nvim_create_buf(false, true)
			set_options("buf", instance.backdrop_buf, BACKDROP_BUFFER_OPTIONS)
			instance.backdrop_win = vim.api.nvim_open_win(instance.backdrop_buf, false, backdrop_config)
			set_options("win", instance.backdrop_win, backdrop_window_options(opts.ui.backdrop))
		end

		instance.win = vim.api.nvim_open_win(instance.buf, true, main_config)
		set_options("win", instance.win, MAIN_WINDOW_OPTIONS)
		instance.augroup = vim.api.nvim_create_augroup("muster_ui_window_" .. instance.buf, { clear = true })
		create_autocmds(instance)
	end)
	if not ok then
		raise_after_cleanup(instance, err)
	end
	return instance
end

function M.current()
	drain_retiring()
	if active == nil then
		return nil
	end
	if instance_valid(active) then
		return active
	end
	local invalid = active
	local err = cleanup(invalid)
	if err ~= nil then
		error(err, 0)
	end
	return nil
end

---@param opts muster.UiWindowOpenOpts
---@return muster.UiWindow window
---@return boolean created
function M.open(opts)
	drain_retiring()
	local current = M.current()
	if current ~= nil then
		current:focus()
		return current, false
	end
	local instance = acquire(opts)
	active = instance
	return instance, true
end

if false then
	---@type muster.UiWindowOpenOpts
	local typecheck_opts = {
		source_bufnr = 1,
		ui = require("muster.config").ui(),
		on_resize = function(window)
			window:valid()
		end,
		on_error = function(_) end,
	}
	local current = M.current()
	if current then
		current:valid()
		current:focus()
		current:content_width()
		current:cursor_line()
		---@type muster.UiRender
		local rendered
		current:draw(rendered, "key")
		current:map("q", function() end, "close")
		current:close()
	end
	local opened, created = M.open(typecheck_opts)
	typecheck_opts.on_resize(opened)
	typecheck_opts.on_error(created)
end

return M
