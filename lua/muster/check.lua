---Probe the declared lists and build a `muster.Result`.
---
---This is the report path. It is spawn-free by construction: nothing here
---requires the overlay module, which is where tier-4 version probing lives.

local config = require("muster.config")
local host = require("muster.host")
local registry = require("muster.registry")

local M = {}

local STATUSES = { found = true, missing = true, unverifiable = true, unknown = true, broken = true }

---Mason puts its bin directory on $PATH inside `mason.setup()` and nowhere else.
---Probing before that reports every Mason-provided tool as missing — the exact
---false negative muster exists to prevent — so the hazard is detected and
---reported rather than silently producing wrong results.
---
---Presence is read from the runtimepath, not `package.loaded`: a Mason
---lazy-loaded on `cmd` or `LspAttach` is not in `package.loaded` at check time,
---which is precisely the case that produces the false negative. muster still
---does not force-load Mason.
---@param notes string[]
local function mason_notes(notes)
	if not host.installed("lua/mason/init.lua") then
		return
	end
	if not package.loaded["mason"] then
		notes[#notes + 1] = "mason.nvim is installed but not loaded yet, so its bin directory is not on $PATH. "
			.. "Mason-provided tools will be reported as missing. Run muster's check after mason.setup()."
		return
	end

	local ok, mason = pcall(require, "mason")
	if ok and type(mason) == "table" then
		if mason.has_setup == false then
			notes[#notes + 1] = "mason.nvim is loaded but has not been set up yet, so its bin directory is not "
				.. "on $PATH. Mason-provided tools will be reported as missing."
		elseif mason.has_setup == nil then
			-- Undocumented internal state: treat its absence as unknown rather
			-- than as healthy, so a rename cannot silently disable this guard.
			notes[#notes + 1] = "muster could not determine whether mason.nvim has been set up "
				.. "(mason.has_setup is absent); Mason-provided tools may be misreported."
		end
	end

	local ok_settings, settings = pcall(require, "mason.settings")
	local path_mode = ok_settings and type(settings) == "table" and vim.tbl_get(settings, "current", "PATH") or nil
	if path_mode == "prepend" then
		notes[#notes + 1] = 'mason.nvim is configured with PATH = "prepend", so its copies shadow system tools. '
			.. 'muster recommends PATH = "append" for system-first resolution.'
	elseif path_mode == "skip" then
		notes[#notes + 1] = 'mason.nvim is configured with PATH = "skip", so its bin directory is never on $PATH '
			.. "and muster cannot see Mason-installed tools at all. Every one of them will be reported as missing."
	elseif path_mode == nil then
		notes[#notes + 1] = "muster could not read mason.nvim's PATH setting; Mason-provided tools may be misreported."
	end
end

---Entries an adapter should probe.
---@param id string
---@param adapter muster.Adapter
---@return any[]|nil entries
---@return string|nil skip_reason
local function entries_for(id, adapter)
	local declared = config.list(id)
	if declared then
		if #declared == 0 then
			-- An empty list is not an all-clear: it is far more often a list
			-- built programmatically by something that returned nothing.
			return nil, "declared list is empty"
		end
		return declared, nil
	end
	-- Derived mode. Availability is checked FIRST: without it, an absent
	-- none-ls yields an empty read and muster would report "loaded but has no
	-- registered sources" about a plugin that is not installed.
	if id == "none_ls" and type(adapter.registered) == "function" and adapter.available() then
		local ok, sources = adapter.registered()
		if not ok then
			return nil, "none-ls is loaded but muster could not read its source registry: " .. tostring(sources)
		end
		if type(sources) ~= "table" or #sources == 0 then
			return nil, "none-ls is loaded but has no registered sources"
		end
		return sources, nil
	end
	return nil, nil
end

---Anything an adapter hands back is untrusted: a third-party `probe` is exactly
---the case the registry exists for, and an invalid return must be a loud bug
---report rather than a crash inside a scheduled callback.
---@param id string
---@param value any
---@return muster.Probe
local function validated(id, value)
	if type(value) ~= "table" or not STATUSES[value.status] then
		return {
			status = "broken",
			reason = ("adapter %q returned an invalid probe: %s"):format(id, vim.inspect(value)),
		}
	end
	return value
end

---@param result muster.Result
---@param id string
---@param adapter muster.Adapter
---@param entries any[]
---@param bufnr integer
---@param seen table<string, boolean>
local function probe_entries(result, id, adapter, entries, bufnr, seen)
	for _, entry in ipairs(entries) do
		local named, name = pcall(adapter.identity, entry)
		if not named then
			result.skipped[#result.skipped + 1] = { adapter = id, count = 1, reason = tostring(name) }
		else
			local key = id .. "\0" .. name
			if not seen[key] then
				seen[key] = true
				local ok, probe = pcall(adapter.probe, entry, bufnr)
				result.entries[#result.entries + 1] = {
					adapter = id,
					name = name,
					declared = true,
					probe = ok and validated(id, probe)
						or { status = "broken", reason = ("probe raised: %s"):format(tostring(probe)) },
					advice = {},
				}
			end
		end
	end
end

---@param bufnr? integer
---@return muster.Result
function M.run(bufnr)
	bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()

	---@type muster.Result
	local result = { entries = {}, skipped = {}, bufnr = bufnr, notes = {} }

	local loaded_ok, load_err = pcall(registry.load_builtins)
	if not loaded_ok then
		result.notes[#result.notes + 1] = ("muster could not load its built-in adapters: %s"):format(load_err)
	end
	mason_notes(result.notes)

	local seen = {}
	for id, adapter in pairs(registry.all()) do
		-- One bad adapter must cost one adapter's worth of results, not all of
		-- them: a raise here would otherwise destroy the whole report.
		local ok, err = pcall(function()
			local entries, skip_reason = entries_for(id, adapter)
			if not entries then
				if skip_reason then
					result.skipped[#result.skipped + 1] = { adapter = id, count = 0, reason = skip_reason }
				end
				return
			end
			local available, reason = adapter.available()
			if not available then
				-- A missing host plugin is never a typo: the names may be
				-- perfectly good, there is simply nothing to ask.
				result.skipped[#result.skipped + 1] = {
					adapter = id,
					count = #entries,
					reason = reason or "host plugin not loaded",
				}
				return
			end
			probe_entries(result, id, adapter, entries, bufnr, seen)
		end)
		if not ok then
			result.skipped[#result.skipped + 1] =
				{ adapter = id, count = 0, reason = ("adapter raised during the check: %s"):format(tostring(err)) }
		end
	end

	table.sort(result.entries, function(a, b)
		if a.adapter ~= b.adapter then
			return a.adapter < b.adapter
		end
		return a.name < b.name
	end)
	return result
end

---Count entries by status. Used by every presenter, so none of them has to
---re-derive it and they cannot disagree. Defensive about unrecognised statuses
---so no presenter can be crashed by data.
---@param result muster.Result
---@return table<string, integer>
function M.tally(result)
	local counts = { found = 0, missing = 0, unverifiable = 0, unknown = 0, broken = 0 }
	for _, entry in ipairs(result.entries) do
		local status = entry.probe and entry.probe.status
		if type(status) ~= "string" then
			status = "broken"
		end
		counts[status] = (counts[status] or 0) + 1
	end
	return counts
end

return M
