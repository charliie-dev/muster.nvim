---`:checkhealth muster`.
---
---Shows everything, including `found`. Renders no versions: version resolution
---lives in the overlay module, which this file does not require, so the
---report path stays spawn-free.
---
---Unknown-key detection lives here rather than in `setup()`, following
---`:h lua-plugin-config` — it is the kind of check worth doing thoroughly and
---not worth doing on every startup.

local M = {}

local ICON = {
	found = "ok",
	missing = "error",
	unknown = "error",
	broken = "error",
	unverifiable = "info",
}

---@param entry muster.Entry
---@return string
local function describe(entry)
	local probe = entry.probe
	if probe.status == "found" then
		-- `reason` on a found probe explains a `source` of "unknown" (the errno
		-- from fs_realpath). It was being captured and rendered nowhere.
		return ("%s (%s): %s — %s%s"):format(
			entry.name,
			entry.adapter,
			probe.source,
			probe.path,
			probe.reason and ("  (" .. probe.reason .. ")") or ""
		)
	end
	return ("%s (%s): %s%s"):format(
		entry.name,
		entry.adapter,
		probe.status,
		probe.reason and (" — " .. probe.reason) or ""
	)
end

---Keys in setup() that match no registered adapter and are not options. Cheap to
---get wrong, and a typo here silently means "that list is never checked".
---@return string[]
local function unknown_keys()
	local config = require("muster.config").get()
	if not config then
		return {}
	end
	local registry = require("muster.registry")
	-- A failure here must degrade the page, not abort it: this runs before the
	-- rest of the health output.
	pcall(registry.load_builtins)
	local options = require("muster.config").OPTIONS
	local unknown = {}
	for key in pairs(config) do
		-- A builtin id whose module failed to load is unregistered but is NOT a
		-- typo: saying so would send the user to fix a line that is correct.
		if not options[key] and not registry.get(key) and not registry.is_builtin(key) then
			unknown[#unknown + 1] = key
		end
	end
	table.sort(unknown)
	return unknown
end

function M.check()
	vim.health.start("muster")

	local config_mod = require("muster.config")
	-- `or {}`: removing the early return for the no-setup case left every
	-- statement below dereferencing a nil config, turning a green page over
	-- missing tools into a traceback over the same missing tools.
	local raw_config = config_mod.get()
	local config = raw_config or {}
	local setup_err = config_mod.error()
	if setup_err then
		-- Distinct from "never called": telling a user who did call setup that
		-- they did not sends them to fix the one thing that is not wrong.
		vim.health.error(("setup() was called but rejected, so only defaults are in effect: %s"):format(setup_err))
	elseif not raw_config then
		-- Only the AUTOMATIC check is suppressed without setup(); an on-demand
		-- health check was explicitly asked for, and returning here rendered a
		-- green page over tools muster's own check() could see were missing.
		vim.health.info("setup() has not been called, so the automatic startup check does not run")
	end

	if not require("muster.runner").has_run() then
		vim.health.warn(
			"the automatic startup check has not run this session. "
				.. "If muster is lazy-loaded, make sure setup() is called (an on-demand :checkhealth "
				.. "does not substitute for it)."
		)
	end

	for _, key in ipairs(unknown_keys()) do
		vim.health.error(("setup key %q matches no registered adapter"):format(key))
	end

	if config.install == "mason" then
		vim.health.info(
			'install = "mason" is enabled: only the automatic startup run may refresh or install; '
				.. "this health check is read-only"
		)
	end

	-- Health must not load the automatic pipeline. If the runner loaded it earlier,
	-- its pure-Lua terminal state is safe to inspect on either configuration path.
	local automatic = package.loaded["muster.automatic"]
	if type(automatic) == "table" and type(automatic.status) == "function" then
		local ok, status = pcall(automatic.status)
		if ok and type(status) == "table" then
			if status.state == "bridge_failed" then
				vim.health.error(
					"the automatic Mason run could not cross a safe-context bridge: "
						.. tostring(status.reason or "unknown failure")
				)
			elseif status.state == "failed" then
				vim.health.error("the automatic startup run failed: " .. tostring(status.reason or "unknown failure"))
			end
		end
	end

	local result = require("muster.check").run()
	for _, note in ipairs(result.notes) do
		vim.health.warn(note)
	end
	for _, skip in ipairs(result.skipped) do
		-- Severity follows the KIND of skip, not the count. An adapter that
		-- raised is an error even with nothing declared behind it; rendering it
		-- as info produced a clean-looking health page over a crash.
		local level = skip.severity or (skip.count > 0 and "warn" or "info")
		vim.health[level](("%s: %s (%d entries unchecked)"):format(skip.adapter, skip.reason, skip.count))
	end

	-- Derived from the CONFIG, not from the result: `#entries == 0` also happens
	-- when every declared tool was skipped, and "no tools declared" would then
	-- contradict the skip lines immediately above it.
	local declared = 0
	for key in pairs(config) do
		local list = config_mod.list(key)
		if type(list) == "table" then
			declared = declared + #list
		end
	end
	-- Derived entries have no config key, so they are a SECOND population, not
	-- an alternative one. `max` would hide declared-but-skipped tools: three
	-- unchecked conform tools plus six derived sources must read as nine, not six.
	for _, entry in ipairs(result.entries) do
		if config_mod.list(entry.adapter) == nil then
			declared = declared + 1
		end
	end

	if declared == 0 and #result.entries == 0 and #result.skipped == 0 then
		vim.health.info("no tools declared")
		return
	end
	if #result.entries == 0 then
		vim.health.warn(("%d tools declared, none probed — see the skips above"):format(declared))
		return
	end
	vim.health.info(("%d tools declared, %d probed"):format(declared, #result.entries))
	for _, entry in ipairs(result.entries) do
		local level = ICON[entry.probe.status] or "info"
		if entry.probe.status == "found" and entry.probe.source == "unknown" then
			level = "warn"
		end
		vim.health[level](describe(entry))
	end
end

return M
