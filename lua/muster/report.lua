---The startup notification.
---
---Problems only, and silent when there are none — which is why it can default to
---on. A plugin whose purpose is telling you about tools you had not noticed were
---missing cannot be opt-in and still do its job.

local check = require("muster.check")

local M = {}

---Statuses the startup notification reports on. `found` is deliberately absent:
---`:checkhealth muster` and `:Muster` show everything.
local REPORTED = { missing = true, unknown = true, broken = true }

local LABEL = {
	missing = "not on $PATH",
	unknown = "unrecognised name",
	broken = "config error",
}

---@param result muster.Result
---@return string[]
function M.lines(result)
	local by_status = {}
	for _, entry in ipairs(result.entries) do
		if REPORTED[entry.probe.status] then
			local bucket = by_status[entry.probe.status] or {}
			bucket[#bucket + 1] = ("%s (%s)"):format(entry.name, entry.adapter)
			by_status[entry.probe.status] = bucket
		end
	end

	local lines = {}
	for _, status in ipairs({ "missing", "unknown", "broken" }) do
		local bucket = by_status[status]
		if bucket then
			lines[#lines + 1] = ("  %s: %s"):format(LABEL[status], table.concat(bucket, ", "))
		end
	end
	for _, skip in ipairs(result.skipped) do
		lines[#lines + 1] = ("  skipped %s: %s"):format(skip.adapter, skip.reason)
	end
	for _, note in ipairs(result.notes) do
		lines[#lines + 1] = "  note: " .. note
	end
	return lines
end

---Emit the one report for this check. Returns whether anything was shown, so a
---caller (and a spec) can tell silence from suppression.
---@param result muster.Result
---@return boolean notified
function M.emit(result)
	local config = require("muster.config").get()
	if not config or not config.notify_on_startup then
		return false
	end

	local lines = M.lines(result)
	if #lines == 0 then
		return false
	end

	local counts = check.tally(result)
	local problems = counts.missing + counts.unknown + counts.broken
	local header = problems > 0 and ("muster: %d tool%s need attention"):format(problems, problems == 1 and "" or "s")
		or "muster"

	vim.notify(header .. "\n" .. table.concat(lines, "\n"), vim.log.levels.WARN, { title = "muster" })
	return true
end

return M
