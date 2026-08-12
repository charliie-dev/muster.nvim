---The startup notification.
---
---Problems only, and silent when there are none — which is why it can default to
---on. A plugin whose purpose is telling you about tools you had not noticed were
---missing cannot be opt-in and still do its job.

local check = require("muster.check")

local M = {}

---Statuses the startup notification reports on. `found` is deliberately absent:
---`:checkhealth muster` and `:Muster` show everything.
---
---`unverifiable` IS included, in its own section. "We could not tell" must never
---render identically to "it is fine" — that composition is the exact failure
---this plugin exists to prevent.
local REPORTED = { missing = true, unknown = true, broken = true, unverifiable = true }

local PROBLEM = { missing = true, unknown = true, broken = true }

local LABEL = {
	missing = "not on $PATH",
	unknown = "unrecognised name",
	broken = "config error",
	-- Not "from this buffer": most reasons here are not buffer-dependent, and
	-- naming a cause muster does not know sends the user to try another buffer.
	unverifiable = "could not be verified",
}

---@param entry muster.Entry
---@param advice muster.Advice
---@return string
local function advice_line(entry, advice)
	local subject = ("%s (%s)"):format(entry.name, entry.adapter)
	if not advice.package then
		return ("  advice %s: %s matched multiple packages; no package guessed"):format(subject, advice.provider)
	end
	if advice.action == "install" then
		if advice.provider == "mason" and advice.eligible == true then
			return ("  advice %s: will install %s via mason after this report"):format(subject, advice.package)
		elseif advice.provider == "mason" and advice.eligible == false then
			return ("  advice %s: will not install %s via mason — %s"):format(
				subject,
				advice.package,
				advice.reason or "not eligible"
			)
		elseif advice.command then
			return ("  advice %s: %s package %s (%s)"):format(subject, advice.provider, advice.package, advice.command)
		end
		return ("  advice %s: install %s via %s"):format(subject, advice.package, advice.provider)
	end
	return ("  advice %s: declare %s via %s"):format(subject, advice.package, advice.provider)
end

---@param result muster.Result
---@return string[]
function M.lines(result)
	local by_status = {}
	for _, entry in ipairs(result.entries) do
		local status = entry.probe and entry.probe.status
		if REPORTED[status] then
			local bucket = by_status[status] or {}
			-- The reason carries the truth: conform's verbatim message tells the
			-- user whether a name is a typo or a malformed config, and dropping
			-- it defeats the whole reason muster accepts that conflation.
			local reason = entry.probe and entry.probe.reason
			bucket[#bucket + 1] = ("%s (%s)%s"):format(entry.name, entry.adapter, reason and (" — " .. reason) or "")
			by_status[status] = bucket
		end
	end

	local lines = {}
	for _, status in ipairs({ "missing", "unknown", "broken", "unverifiable" }) do
		local bucket = by_status[status]
		if bucket then
			lines[#lines + 1] = ("  %s: %s"):format(LABEL[status], table.concat(bucket, ", "))
		end
	end
	for _, entry in ipairs(result.entries) do
		for _, advice in ipairs(entry.advice or {}) do
			lines[#lines + 1] = advice_line(entry, advice)
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

---Does this result contain anything the user must act on?
---
---Notes alone do not qualify. Mason's `PATH = "prepend"` is its default, so
---notifying on a note would mean a warning popup on every startup for every
---Mason user — and would break the "silent when nothing is wrong" promise that
---justifies defaulting the notification to on. Notes still appear in
---`:checkhealth muster`.
---@param result muster.Result
---@return boolean
function M.has_problems(result)
	for _, entry in ipairs(result.entries) do
		local status = entry.probe and entry.probe.status
		if REPORTED[status] then
			return true
		end
	end
	return #result.skipped > 0
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
	if not M.has_problems(result) then
		return false
	end

	local lines = M.lines(result)
	if #lines == 0 then
		return false
	end

	local counts = check.tally(result)
	local problems = 0
	for status in pairs(PROBLEM) do
		problems = problems + (counts[status] or 0)
	end

	-- Severity follows the worst skip: an adapter that crashed and a plugin
	-- that has not loaded yet must not read identically at the same level.
	local level = vim.log.levels.WARN
	local unchecked = 0
	for _, skip in ipairs(result.skipped) do
		unchecked = unchecked + (skip.count or 0)
		if skip.severity == "error" then
			level = vim.log.levels.ERROR
		end
	end

	local header
	if problems == 1 then
		header = "muster: 1 tool needs attention"
	elseif problems > 1 then
		header = ("muster: %d tools need attention"):format(problems)
	else
		-- Only skips and/or unverifiable entries: still worth saying, but not as
		-- a count of problems.
		header = "muster: some tools were not checked"
	end
	if unchecked > 0 then
		header = ("%s (%d unchecked)"):format(header, unchecked)
	end

	vim.notify(header .. "\n" .. table.concat(lines, "\n"), level, { title = "muster" })
	return true
end

return M
