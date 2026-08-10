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
---@return { code: integer, output: string }
local function capture(result)
	return {
		code = result.code,
		output = (result.stdout or "") .. "\n" .. (result.stderr or ""),
	}
end

---@param cmd string[]
---@param opts? { timeout_ms?: integer }
---@param callback? fun(result: { code: integer, output: string })
---@return { code: integer, output: string }|nil
function M.spawn(cmd, opts, callback)
	opts = opts or {}
	local system_opts = {
		stdin = false,
		text = true,
		timeout = opts.timeout_ms or 5000,
	}
	if callback then
		vim.system(cmd, system_opts, function(result)
			callback(capture(result))
		end)
		return nil
	end
	return capture(vim.system(cmd, system_opts):wait())
end

return M
