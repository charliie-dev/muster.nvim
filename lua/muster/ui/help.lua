local M = {}

local namespace = vim.api.nvim_create_namespace("muster_ui_help")

---@type muster.UiHelp|nil
local active
---@type muster.UiHelp|nil
local retiring

local BUFFER_OPTIONS = {
	buftype = "nofile",
	bufhidden = "wipe",
	swapfile = false,
	modifiable = false,
	buflisted = false,
	undolevels = -1,
	filetype = "muster-help",
}

local WINDOW_OPTIONS = {
	number = false,
	relativenumber = false,
	wrap = false,
	spell = false,
	foldenable = false,
	signcolumn = "no",
	colorcolumn = "",
	cursorline = false,
	winhighlight = "Normal:MusterNormal",
}

local function set_options(scope, id, options)
	for name, value in pairs(options) do
		vim.api.nvim_set_option_value(name, value, { [scope] = id })
	end
end

local function valid_win(win)
	return win ~= nil and vim.api.nvim_win_is_valid(win)
end

local function valid_buf(buf)
	return buf ~= nil and vim.api.nvim_buf_is_valid(buf)
end

local function geometry(parent_win, ui)
	local parent_width = vim.api.nvim_win_get_width(parent_win)
	local parent_height = vim.api.nvim_win_get_height(parent_win)
	local border = ui.border
	local border_cells = 0
	if border ~= "none" and parent_width >= 3 and parent_height >= 3 then
		border_cells = 2
	else
		border = "none"
	end
	local max_width = math.max(1, parent_width - border_cells)
	local max_height = math.max(1, parent_height - border_cells)
	local width = math.max(1, math.min(math.floor(parent_width * 0.8), max_width))
	local height = math.max(1, math.min(math.floor(parent_height * 0.8), max_height))
	return {
		relative = "win",
		win = parent_win,
		row = math.max(0, math.floor((parent_height - height - border_cells) / 2)),
		col = math.max(0, math.floor((parent_width - width - border_cells) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = border,
		focusable = true,
		zindex = 60,
	}
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
	if instance.buf ~= nil and not valid_buf(instance.buf) then
		instance.buf = nil
	end
	if instance.buf == nil then
		instance.namespace_dirty = false
	end
end

local function cleanup_pass(instance)
	local first_error

	if instance.namespace_dirty then
		if valid_buf(instance.buf) then
			local ok, err = pcall(vim.api.nvim_buf_clear_namespace, instance.buf, namespace, 0, -1)
			first_error = remember_error(first_error, ok, err)
			if ok then
				instance.namespace_dirty = false
			end
		else
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

	if valid_win(instance.win) then
		local ok, err = pcall(vim.api.nvim_win_close, instance.win, true)
		first_error = remember_error(first_error, ok, err)
		if ok then
			instance.win = nil
		end
	else
		instance.win = nil
	end

	if valid_buf(instance.buf) then
		local modifiable_ok, modifiable_err =
			pcall(vim.api.nvim_set_option_value, "modifiable", false, { buf = instance.buf })
		first_error = remember_error(first_error, modifiable_ok, modifiable_err)
		local ok, err = pcall(vim.api.nvim_buf_delete, instance.buf, { force = true })
		first_error = remember_error(first_error, ok, err)
		if ok then
			instance.buf = nil
		end
	else
		instance.buf = nil
	end

	reconcile(instance)
	return first_error
end

local function resources_gone(instance)
	return instance.augroup == nil and instance.win == nil and instance.buf == nil and not instance.namespace_dirty
end

local function finalize_retirement(instance)
	if not resources_gone(instance) then
		return nil, false
	end
	if retiring == instance then
		retiring = nil
	end
	instance.closed = true
	if not instance.close_notification_pending or instance.close_notification_delivered then
		return nil, false
	end

	instance.close_notification_pending = false
	instance.close_notification_delivered = true
	local first_error
	if valid_win(instance.parent_win) then
		local ok, err = pcall(vim.api.nvim_set_current_win, instance.parent_win)
		first_error = remember_error(first_error, ok, err)
	end
	local ok, err = pcall(instance.on_close)
	first_error = remember_error(first_error, ok, err)
	return first_error, true
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

	local finalize_error, delivered = finalize_retirement(instance)
	first_error = first_error or finalize_error
	return first_error, delivered
end

local function raise_after_cleanup(instance, initiating_error)
	cleanup(instance)
	error(initiating_error, 0)
end

local function drain_retiring()
	if retiring == nil then
		return false
	end
	local instance = retiring
	local err, delivered = cleanup(instance)
	if err ~= nil then
		error(err, 0)
	end
	if retiring ~= nil then
		error("muster.ui.help: retirement incomplete", 0)
	end
	return delivered
end

local function instance_valid(instance)
	return not instance.closing
		and not instance.closed
		and valid_win(instance.parent_win)
		and valid_win(instance.win)
		and valid_buf(instance.buf)
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

function methods:draw(output)
	local initiating_error
	local ok, err = pcall(function()
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
		local marks_ok, marks_err = pcall(function()
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
		end)
		if not marks_ok then
			initiating_error = marks_err
		end
	end

	if initiating_error ~= nil then
		raise_after_cleanup(self, initiating_error)
	end
end

function methods:resize()
	local ok, err = pcall(function()
		vim.api.nvim_win_set_config(self.win, geometry(self.parent_win, self.ui))
		set_options("win", self.win, WINDOW_OPTIONS)
	end)
	if not ok then
		raise_after_cleanup(self, err)
	end
end

function methods:close(notify)
	if self.closed and retiring ~= self then
		return
	end
	if notify == false then
		self.close_notification_pending = false
	elseif not self.close_notification_delivered then
		self.close_notification_pending = true
	end
	local err = cleanup(self)
	if err ~= nil then
		error(err, 0)
	end
end

local function lifecycle_close(instance, notify)
	if notify == false then
		if active == instance or retiring == instance then
			pcall(instance.close, instance, false)
		end
		return
	end
	if active ~= instance or instance.closing then
		return
	end
	pcall(instance.close, instance, true)
end

local function create_autocmds(instance)
	vim.api.nvim_create_autocmd("WinClosed", {
		group = instance.augroup,
		pattern = tostring(instance.parent_win),
		callback = function()
			lifecycle_close(instance, false)
		end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = instance.augroup,
		pattern = tostring(instance.win),
		callback = function()
			lifecycle_close(instance, true)
		end,
	})
	for _, event in ipairs({ "BufHidden", "BufDelete", "BufWipeout" }) do
		vim.api.nvim_create_autocmd(event, {
			group = instance.augroup,
			buffer = instance.buf,
			callback = function()
				lifecycle_close(instance, true)
			end,
		})
	end
end

local function acquire(opts)
	local instance = setmetatable({
		parent_win = opts.parent_win,
		ui = opts.ui,
		on_close = opts.on_close,
		closing = false,
		closed = false,
		cleanup_running = false,
		namespace_dirty = false,
		close_notification_pending = false,
		close_notification_delivered = false,
	}, methods)

	local ok, err = pcall(function()
		instance.buf = vim.api.nvim_create_buf(false, true)
		set_options("buf", instance.buf, BUFFER_OPTIONS)
		instance.win = vim.api.nvim_open_win(instance.buf, true, geometry(instance.parent_win, instance.ui))
		set_options("win", instance.win, WINDOW_OPTIONS)
		instance.augroup = vim.api.nvim_create_augroup("muster_ui_help_" .. instance.buf, { clear = true })
		create_autocmds(instance)
		for _, lhs in ipairs({ "q", "<Esc>" }) do
			vim.keymap.set("n", lhs, function()
				instance:close(true)
			end, { buffer = instance.buf, nowait = true, silent = true, desc = "Close Muster help" })
		end
		instance:draw(opts.output)
	end)
	if not ok then
		raise_after_cleanup(instance, err)
	end
	return instance
end

function M.content_width(parent_win, ui)
	return geometry(parent_win, ui).width
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

function M.close(notify)
	local instance = retiring or active
	if instance then
		instance:close(notify)
	end
end

---@param opts muster.UiHelpOpenOpts
---@return muster.UiHelp? help
---@return boolean created
function M.open(opts)
	if drain_retiring() then
		return nil, false
	end
	local current = M.current()
	if current ~= nil then
		current:focus()
		return current, false
	end
	local instance = acquire(opts)
	active = instance
	return instance, true
end

return M
