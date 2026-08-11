---Injectable dependencies, module-level rather than parameters on `check()`.
---
---Tier-4 version probing is deliberately unreachable from `check()` (it lives in
---the overlay module), so a seam hanging off `check(opts)` could not inject it.
---Everything that touches the outside world goes through here instead, and every
---caller reads `M.spawn` / `M.executable` at call time so a spec can swap them.

local M = {}

---Resolve an executable name against $PATH.
---@param name string
---@return string|nil @Absolute path, or nil when not found.
function M.executable(name)
	local path = vim.fn.exepath(name)
	return path ~= "" and path or nil
end

---Run a command and capture it. stdin is closed: a tool that waits on input
---would otherwise hang the caller, and several do (go-debug-adapter only exits
---on EOF). Both streams are captured because tools disagree about where a
---version belongs.
---@param result vim.SystemCompleted
---@return { code: integer, signal: integer, output: string, error?: string }
local function capture(result)
	return {
		code = result.code,
		signal = result.signal or 0,
		output = (result.stdout or "") .. "\n" .. (result.stderr or ""),
	}
end

---@param cmd string[]
---@param opts? { timeout_ms?: integer }
---@param callback? fun(result: { code: integer, signal: integer, output: string, error?: string })
---@return { code: integer, signal: integer, output: string, error?: string }|nil
function M.spawn(cmd, opts, callback)
	opts = opts or {}
	local system_opts = {
		stdin = false,
		text = true,
		timeout = opts.timeout_ms or 5000,
	}
	if callback then
		local completion_seen = false
		local delivered = false
		vim.system(cmd, system_opts, function(result)
			if completion_seen then
				return
			end
			completion_seen = true
			local captured = capture(result)
			local function deliver()
				if delivered then
					return
				end
				delivered = true
				callback(captured)
			end
			local scheduled, schedule_err = pcall(vim.schedule, deliver)
			if not scheduled then
				captured = {
					code = -1,
					signal = 0,
					output = "",
					error = "process completion scheduling failed: " .. tostring(schedule_err),
				}
				-- `vim.defer_fn` provides a separate event-loop bridge when the
				-- primary scheduler rejects. If both are unavailable there is no
				-- safe way to invoke arbitrary consumers from fast-event context.
				pcall(vim.defer_fn, deliver, 0)
			end
		end)
		return nil
	end
	return capture(vim.system(cmd, system_opts):wait())
end

return M
