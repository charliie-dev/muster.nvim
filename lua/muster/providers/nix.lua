---Nix advice from nix-index's machine-readable `nix-locate` output.

local env = require("muster.env")

local M = {}

---@param output string
---@return muster.Advice|nil
local function parse(output)
	local names = {}
	local uncertain = false
	for line in (output .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
		line = vim.trim(line)
		if line ~= "" then
			local indirect = line:match("^%((.+)%)$")
			if indirect or line:find("%s") then
				uncertain = true
			else
				names[line] = true
			end
		end
	end
	local packages = vim.tbl_keys(names)
	table.sort(packages)
	if #packages == 0 and not uncertain then
		return nil
	end
	if #packages == 1 and not uncertain then
		return { provider = "nix", action = "declare", package = packages[1] }
	end
	return { provider = "nix", action = "declare" }
end

---@param binaries string[]
---@param max_concurrency integer
---@param callback fun(advice: table<string, muster.Advice>, err?: string)
function M.collect(binaries, max_concurrency, callback)
	local executable_ok, executable = pcall(env.executable, "nix-locate")
	if not executable_ok then
		callback({}, "nix-locate executable lookup failed: " .. tostring(executable))
		return
	end
	if not executable or #binaries == 0 then
		callback({})
		return
	end

	local queue = vim.deepcopy(binaries)
	table.sort(queue)
	local limit = math.max(1, math.floor(max_concurrency or 4))
	local next_index = 1
	local active = 0
	local remaining = #queue
	local advice = {}
	local errors = {}
	local completed = false
	local pump

	local function finish()
		if completed or remaining ~= 0 then
			return
		end
		completed = true
		local messages = {}
		for _, binary in ipairs(queue) do
			if errors[binary] then
				messages[#messages + 1] = errors[binary]
			end
		end
		callback(advice, #messages > 0 and table.concat(messages, "; ") or nil)
	end

	local function finish_one(binary, result, spawn_err)
		active = active - 1
		remaining = remaining - 1
		if spawn_err then
			errors[binary] = ("nix-locate failed for %s: %s"):format(binary, spawn_err)
		elseif type(result) ~= "table" or result.code ~= 0 or (result.signal or 0) ~= 0 then
			errors[binary] = (result and result.error and ("nix-locate failed for %s: %s"):format(binary, result.error))
				or ("nix-locate failed for %s (exit %s, signal %s)"):format(
					binary,
					tostring(type(result) == "table" and result.code or "unknown"),
					tostring(type(result) == "table" and (result.signal or 0) or "unknown")
				)
		else
			advice[binary] = parse(result.output or "")
		end
		pump()
		finish()
	end

	local function start(binary)
		active = active + 1
		local returned = false
		local callback_seen = false
		local settled = false
		local buffered_result
		local function settle(result, spawn_err)
			if settled then
				return
			end
			settled = true
			finish_one(binary, result, spawn_err)
		end
		local function receive(result)
			if callback_seen then
				return
			end
			callback_seen = true
			if returned then
				settle(result)
			else
				buffered_result = result
			end
		end

		local ok, err = pcall(env.spawn, {
			executable,
			"--minimal",
			"--whole-name",
			"--type",
			"x",
			-- nix-locate patterns are literal unless `-r/--regex` is passed.
			"bin/" .. binary,
		}, { timeout_ms = 10000 }, receive)
		returned = true
		if not ok then
			settle(nil, tostring(err))
		elseif callback_seen then
			settle(buffered_result)
		end
	end

	pump = function()
		while active < limit and next_index <= #queue do
			local binary = queue[next_index]
			next_index = next_index + 1
			start(binary)
		end
	end

	pump()
end

return M
