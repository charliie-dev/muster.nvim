---Runs the internal automatic pipeline exactly once per configured session.

local M = {}

local ran = false

---@return boolean
function M.has_run()
	return ran
end

function M.start()
	if ran or not require("muster.config").get() then
		return
	end

	local function failed(err)
		pcall(
			vim.notify,
			("muster: the startup check failed: %s"):format(tostring(err)),
			vim.log.levels.ERROR,
			{ title = "muster" }
		)
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
		local ok, err = pcall(require("muster.automatic").run)
		if not ok then
			failed(err)
		end
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

---Test seam.
function M.reset()
	ran = false
end

return M
