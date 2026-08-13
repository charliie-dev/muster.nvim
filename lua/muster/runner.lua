---Runs the internal automatic pipeline exactly once per configured session.

local M = {}

local ran = false

---@param err any
local function failed(err)
	pcall(
		vim.notify,
		("muster: the startup check failed: %s"):format(tostring(err)),
		vim.log.levels.ERROR,
		{ title = "muster" }
	)
end

---@return boolean
function M.has_run()
	return ran
end

---@param immediate? boolean Already executing from an accepted safe-context bridge.
function M.start(immediate)
	if ran or not require("muster.config").get() then
		return
	end

	local started = false
	local schedule_returned = false
	local requested = false
	local cancelled = false
	local function run()
		if started or cancelled then
			return
		end
		started = true
		local ok, err = pcall(function()
			require("muster.automatic").run()
		end)
		if not ok then
			failed(err)
		end
	end
	if immediate then
		ran = true
		run()
		return
	end

	local function scheduled()
		if schedule_returned then
			run()
		else
			requested = true
		end
	end
	local ok, err = pcall(vim.schedule, scheduled)
	schedule_returned = true
	if not ok then
		cancelled = true
		failed(err)
		return
	end
	-- Scheduling acceptance is the point at which this session has an automatic
	-- run. Rejected invoke-then-throw schedulers must remain retryable.
	ran = true
	if requested then
		run()
	end
end

---Defer startup until after VimEnter while containing scheduler failures.
function M.defer_start()
	local started = false
	local function start_once()
		if started then
			return
		end
		started = true
		local ok, err = pcall(M.start, true)
		if not ok then
			failed(err)
		end
	end

	local schedule_returned = false
	local requested = false
	local function scheduled()
		if schedule_returned then
			start_once()
		else
			requested = true
		end
	end
	local ok = pcall(vim.schedule, scheduled)
	schedule_returned = true
	if ok then
		if requested then
			start_once()
		end
		return
	end

	local defer_returned = false
	requested = false
	local function deferred()
		if defer_returned then
			start_once()
		else
			requested = true
		end
	end
	ok = pcall(vim.defer_fn, deferred, 0)
	defer_returned = true
	if ok then
		if requested then
			start_once()
		end
		return
	end

	start_once()
end

---Test seam.
function M.reset()
	ran = false
end

return M
