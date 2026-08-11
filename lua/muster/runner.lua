---Runs the automatic check exactly once per session.
---
---Two entry points reach here and either may come first: the `VimEnter`
---autocmd, and `setup()` itself. `event = "VeryLazy"` -- the most common
---lazy.nvim idiom -- fires strictly after `VimEnter`, so an autocmd alone would
---leave a correctly configured muster having never probed anything, while
---`:checkhealth` would report it healthy and mask that.

local M = {}

local ran = false

---Whether the automatic check has run this session. `health.lua` reports it, so
---a dead startup pass is visible instead of being masked by an on-demand probe.
---@return boolean
function M.has_run()
	return ran
end

---Run the check and emit the one report, unless it already happened or nothing
---was ever configured.
function M.start()
	if ran then
		return
	end
	if not require("muster.config").get() then
		-- No setup() call: nothing is declared, so the automatic check does not
		-- run at all. :Muster and :checkhealth still work on demand.
		return
	end
	ran = true
	local function failed(err)
		-- If the notification backend itself is broken, there is no reliable
		-- secondary UI channel; containment is the only honest guarantee.
		local notified, notify_err = pcall(
			vim.notify,
			("muster: the startup check failed: %s"):format(err),
			vim.log.levels.ERROR,
			{ title = "muster" }
		)
		return notified, notify_err
	end

	local cancelled = false
	local started = false
	local reported = false
	local schedule_returned = false
	local buffered_result
	local function emit(result)
		if cancelled or reported then
			return
		end
		reported = true
		local emitted, emit_err = pcall(require("muster.report").emit, result)
		if not emitted then
			failed(emit_err)
		end
	end
	local function complete(result)
		if cancelled or reported or buffered_result then
			return
		end
		if not schedule_returned then
			buffered_result = result
			return
		end
		emit(result)
	end
	local function run()
		if started then
			return
		end
		started = true
		local ok, err = pcall(require("muster").check, nil, complete)
		if not ok then
			failed(err)
		end
	end

	local run_requested = false
	local function scheduled_run()
		if not schedule_returned then
			run_requested = true
			return
		end
		run()
	end
	local scheduled, schedule_err = pcall(vim.schedule, scheduled_run)
	schedule_returned = true
	if not scheduled then
		cancelled = true
		buffered_result = nil
		failed(schedule_err)
	else
		if run_requested then
			run()
		end
		if buffered_result then
			emit(buffered_result)
		end
	end
end

---Test seam.
function M.reset()
	ran = false
end

return M
