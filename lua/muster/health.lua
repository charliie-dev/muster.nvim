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
		return ("%s (%s): %s — %s"):format(entry.name, entry.adapter, probe.source, probe.path)
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
	registry.load_builtins()
	local options = require("muster.config").OPTIONS
	local unknown = {}
	for key in pairs(config) do
		if not options[key] and not registry.get(key) then
			unknown[#unknown + 1] = key
		end
	end
	table.sort(unknown)
	return unknown
end

function M.check()
	vim.health.start("muster")

	local config_mod = require("muster.config")
	local config = config_mod.get()
	local setup_err = config_mod.error()
	if setup_err then
		-- Distinct from "never called": telling a user who did call setup that
		-- they did not sends them to fix the one thing that is not wrong.
		vim.health.error(("setup() was called but rejected, so no tools are checked: %s"):format(setup_err))
	elseif not config then
		vim.health.info("setup() has not been called; the automatic check does not run")
		return
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

	local result = require("muster.check").run()
	for _, note in ipairs(result.notes) do
		vim.health.warn(note)
	end
	for _, skip in ipairs(result.skipped) do
		-- A skip that hides declared entries is a warning, not trivia: those
		-- tools went unchecked.
		local level = skip.count > 0 and "warn" or "info"
		vim.health[level](("%s: %s (%d entries unchecked)"):format(skip.adapter, skip.reason, skip.count))
	end

	if #result.entries == 0 then
		vim.health.info("no tools declared")
		return
	end
	for _, entry in ipairs(result.entries) do
		local level = ICON[entry.probe.status] or "info"
		vim.health[level](describe(entry))
	end
end

return M
