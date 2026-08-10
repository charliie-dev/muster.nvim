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
	vim.schedule(function()
		local ok, err = pcall(function()
			require("muster.report").emit(require("muster.check").run())
		end)
		if not ok then
			-- A raise inside vim.schedule would otherwise reach the user as an
			-- unbranded traceback competing with the dashboard, or not at all.
			vim.notify(("muster: the startup check failed: %s"):format(err), vim.log.levels.ERROR, { title = "muster" })
		end
	end)
end

---Test seam.
function M.reset()
	ran = false
end

return M
