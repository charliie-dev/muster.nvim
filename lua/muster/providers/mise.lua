---mise advice from the machine-readable first column of `mise registry`.

local env = require("muster.env")

local M = {}

local BACKENDS = {
	aqua = true,
	asdf = true,
	cargo = true,
	conda = true,
	core = true,
	gem = true,
	github = true,
	gitlab = true,
	go = true,
	http = true,
	npm = true,
	pipx = true,
	spm = true,
	vfox = true,
}

---@param text string
---@return boolean
local function has_backend(text)
	for token in text:gmatch("%S+") do
		local backend, value = token:match("^([%w_-]+):(.+)$")
		if backend and BACKENDS[backend] and value ~= "" and not value:match("^//") then
			return true
		end
	end
	return false
end

---@param binaries string[]
---@param output string
---@return table<string, muster.Advice>
local function parse(binaries, output)
	local requested = {}
	for _, binary in ipairs(binaries) do
		requested[binary] = true
	end
	local found = {}
	for line in (output .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
		local name, backends = line:match("^([^%s]+)%s+(.+)$")
		if name and requested[name] and has_backend(backends) then
			found[name] = true
		end
	end
	local advice = {}
	for _, binary in ipairs(binaries) do
		if found[binary] then
			advice[binary] = { provider = "mise", action = "declare", package = binary }
		end
	end
	return advice
end

---@param binaries string[]
---@param callback fun(advice: table<string, muster.Advice>, err?: string)
function M.collect(binaries, callback)
	local executable_ok, executable = pcall(env.executable, "mise")
	if not executable_ok then
		callback({}, "mise executable lookup failed: " .. tostring(executable))
		return
	end
	if not executable or #binaries == 0 then
		callback({})
		return
	end

	local returned = false
	local callback_seen = false
	local settled = false
	local buffered_result
	local function settle(result, spawn_err)
		if settled then
			return
		end
		settled = true
		if spawn_err then
			callback({}, "mise registry failed: " .. spawn_err)
		elseif type(result) ~= "table" or result.code ~= 0 or (result.signal or 0) ~= 0 then
			local failure = result and result.error
				or ("mise registry failed (exit %s, signal %s)"):format(
					tostring(type(result) == "table" and result.code or "unknown"),
					tostring(type(result) == "table" and (result.signal or 0) or "unknown")
				)
			callback({}, failure)
		else
			callback(parse(binaries, result.output or ""))
		end
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

	local ok, err = pcall(env.spawn, { executable, "registry" }, { timeout_ms = 10000 }, receive)
	returned = true
	if not ok then
		settle(nil, tostring(err))
	elseif callback_seen then
		settle(buffered_result)
	end
end

return M
