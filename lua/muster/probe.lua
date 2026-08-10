---Probe constructors.
---
---Every adapter funnels into these so the five statuses are produced in exactly
---one place, and so the requiredness rules in `muster.Probe` cannot drift: a
---`found` probe always carries `path` and `source`, and every non-`found` status
---that needs a `reason` gets one.

local source = require("muster.source")

local M = {}

---@param reason string
---@return muster.Probe
function M.unknown(reason)
	return { status = "unknown", reason = reason }
end

---@param reason string
---@return muster.Probe
function M.broken(reason)
	return { status = "broken", reason = reason }
end

---A command the subsystem resolves for itself (a function-form command, an
---adapter factory). Its existence proves nothing about availability, and it must
---never be reported as a typo.
---@param reason string
---@return muster.Probe
function M.unverifiable(reason)
	return { status = "unverifiable", reason = reason }
end

---The one place `found` and `missing` are decided.
---
---`command` is whatever the subsystem declared, which is not always a bare name:
---configs written as `command = vim.fn.exepath("codelldb")` hand over an absolute
---path. Lookup uses the command as given, but `binary` is always reduced to the
---basename, because `binary` doubles as the Mason registry key and an absolute
---path is not one.
---@param command string
---@return muster.Probe
function M.resolve(command)
	if type(command) ~= "string" or command == "" then
		return M.unverifiable("no command to probe")
	end
	local binary = vim.fs.basename(command)
	if binary == "" then
		-- "/usr/bin/git/" or "/": a degenerate registry key, and nothing a
		-- $PATH lookup could ever satisfy.
		return M.broken(("command %q has no executable name"):format(command))
	end
	local located = source.locate(command)
	if not located then
		return { status = "missing", binary = binary }
	end
	return {
		status = "found",
		binary = binary,
		path = located.path,
		realpath = located.realpath,
		source = located.source,
		reason = located.reason,
	}
end

---Run an adapter's own lookup, converting a raise into `broken` rather than
---letting it escape. `broken` is defined uniformly as "the pcall around the
---subsystem's lookup failed" — never inferred by matching error text.
---@generic T
---@param fn fun(): T
---@return boolean ok
---@return T|string value_or_error
function M.guarded(fn)
	local ok, value = pcall(fn)
	if not ok then
		return false, type(value) == "string" and value or vim.inspect(value)
	end
	return true, value
end

return M
