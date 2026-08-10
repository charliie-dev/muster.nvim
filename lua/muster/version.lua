---Overlay-only version resolution.
---
---Found entries use a cheap source-specific tier first, then fall through to a
---single generic process probe. Non-found entries never spawn and never enter
---the cache. The cache key uses the executable's unresolved path because every
---mise shim may share one realpath.

local env = require("muster.env")

local M = {}

---@type table<string, muster.Version>
local cache = {}
---@type table<string, fun(version: muster.Version)[]>
local pending = {}

local FLAGS = { "--version", "version", "-version" }

---@param path string
---@return string|nil
local function mtime(path)
	local stat = vim.uv.fs_stat(path)
	if not stat or stat.mtime == nil then
		return nil
	end
	if type(stat.mtime) == "table" then
		return ("%s:%s"):format(tostring(stat.mtime.sec), tostring(stat.mtime.nsec))
	end
	return tostring(stat.mtime)
end

---@param line string
---@return string|nil
local function token(line)
	local trimmed = vim.trim(line)
	local lower = trimmed:lower()
	if lower:match("^usage[%s:]") then
		return nil
	end
	if trimmed:match("^%d%d%d%d[/%-]%d%d[/%-]%d%d[%sT]") then
		return nil
	end

	local last
	local from = 1
	while true do
		local first, final = trimmed:find("%d+%.%d+[%d%.]*", from)
		if not first then
			break
		end
		last = trimmed:sub(first, final):gsub("%.$", "")
		if first > 1 and trimmed:sub(first - 1, first - 1):lower() == "v" then
			last = trimmed:sub(first - 1, final):gsub("%.$", "")
		end
		from = final + 1
	end
	return last
end

---@param output string
---@return string|nil
local function output_version(output)
	for line in (output .. "\n"):gmatch("([^\r\n]*)[\r\n]") do
		local value = token(line)
		if value then
			return value
		end
	end
	return nil
end

---@param binary string
---@return string|nil
local function mason_version(binary)
	local ok_registry, registry = pcall(require, "mason-registry")
	if not ok_registry or type(registry) ~= "table" or type(registry.get_all_packages) ~= "function" then
		return nil
	end
	local ok_packages, packages = pcall(registry.get_all_packages)
	if not ok_packages or type(packages) ~= "table" then
		return nil
	end
	for _, pkg in ipairs(packages) do
		local bins = type(pkg.spec) == "table" and pkg.spec.bin or nil
		if type(bins) == "table" and bins[binary] ~= nil and type(pkg.get_installed_version) == "function" then
			local ok_version, value = pcall(pkg.get_installed_version, pkg)
			if ok_version and type(value) == "string" and value ~= "" then
				return value
			end
		end
	end
	return nil
end

---@param path string|nil
---@return string|nil
local function nix_version(path)
	if not path then
		return nil
	end
	local store_name = path:match("^/nix/store/[^/]+")
	return store_name and token(store_name) or nil
end

---@param realpath string|nil
---@return string|nil
local function mise_version(realpath)
	if not realpath then
		return nil
	end
	local value = realpath:match("/installs/[^/]+/([^/]+)/")
	if value and value:find("%d+%.%d+") then
		return value
	end
	return nil
end

---@param binary string
---@param callback fun(version: muster.Version)
local function spawn_version(binary, callback)
	local index = 1
	local saw_success = false

	local function attempt()
		local flag = FLAGS[index]
		if not flag then
			callback({
				tier = 4,
				reason = saw_success and "no version-shaped output" or "spawn failed",
			})
			return
		end
		index = index + 1
		local ok = pcall(env.spawn, { binary, flag }, { timeout_ms = 5000 }, function(result)
			if result.code == 0 then
				saw_success = true
				local value = output_version(result.output or "")
				if value then
					callback({ value = value, tier = 4 })
					return
				end
			end
			attempt()
		end)
		if not ok then
			attempt()
		end
	end

	attempt()
end

---@param source muster.Source
---@return 1|2|3|4
local function tier_for(source)
	if source == "mason" then
		return 1
	elseif source == "nix" then
		return 2
	elseif source == "mise" then
		return 3
	end
	return 4
end

---@param entry muster.Entry
---@param callback fun(version: muster.Version)
function M.resolve(entry, callback)
	local probe = entry.probe or {}
	if probe.status ~= "found" then
		callback({ tier = 4, reason = "status is " .. tostring(probe.status) })
		return
	end

	local stamp = mtime(probe.path)
	local key = stamp and (probe.path .. "\0" .. stamp) or nil
	if key and cache[key] then
		callback(cache[key])
		return
	end
	if key and pending[key] then
		pending[key][#pending[key] + 1] = callback
		return
	end
	if key then
		pending[key] = { callback }
	end

	local function finish(version)
		if key then
			cache[key] = version
			local callbacks = pending[key] or {}
			pending[key] = nil
			for _, waiting in ipairs(callbacks) do
				waiting(version)
			end
		else
			callback(version)
		end
	end

	local tier = tier_for(probe.source)
	local value
	if tier == 1 then
		value = mason_version(probe.binary)
	elseif tier == 2 then
		value = nix_version(probe.realpath)
	elseif tier == 3 then
		value = mise_version(probe.realpath)
	end
	if value then
		finish({ value = value, tier = tier })
		return
	end
	spawn_version(probe.path, finish)
end

return M
