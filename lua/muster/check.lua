---Probe the declared lists and build a `muster.Result`.
---
---This is the report path. It is spawn-free by construction: nothing here
---requires the overlay module, which is where tier-4 version probing lives.

local config = require("muster.config")
local host = require("muster.host")
local registry = require("muster.registry")

local M = {}

local STATUSES = { found = true, missing = true, unverifiable = true, unknown = true, broken = true }
local SOURCES = { mason = true, nix = true, mise = true, brew = true, system = true, unknown = true }

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
---@return string|nil severity
local function entries_for(id, adapter)
	local declared = config.list(id)
	if declared then
		if #declared == 0 then
			if next(declared) ~= nil then
				-- A map, not a list. `#t` is 0 for it, so calling this "empty"
				-- would be three false statements at once: the list is not
				-- empty, its entries were not counted, and tools WERE declared.
				local keys = vim.tbl_keys(declared)
				table.sort(keys, function(a, b)
					return tostring(a) < tostring(b)
				end)
				return nil,
					("declared list is a map, not a list; muster reads the array part, so %s %s ignored"):format(
						table.concat(vim.tbl_map(vim.inspect, keys), ", "),
						#keys == 1 and "was" or "were"
					)
			end
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
			-- muster's own read failed and the whole derived list went unread.
			-- That is an error about muster, not a warning about the user's
			-- config, and it must not read like "conform hasn't loaded yet".
			return nil,
				"none-ls is loaded but muster could not read its source registry: " .. tostring(sources),
				"error"
		end
		if type(sources) ~= "table" then
			-- Structurally wrong is not the same as empty: telling the user
			-- they registered no sources sends them to audit a list that is fine.
			return nil,
				("none-ls's get_all() returned a %s, not a list of sources; muster cannot read it"):format(
					type(sources)
				),
				"error"
		end
		if #sources == 0 then
			return nil, "none-ls is loaded but has no registered sources", "warn"
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
	local function invalid(why)
		return {
			status = "broken",
			reason = ("adapter %q returned an invalid probe (%s): %s"):format(id, why, vim.inspect(value)),
		}
	end
	if type(value) ~= "table" or not STATUSES[value.status] then
		return invalid("unrecognised status")
	end
	-- The requiredness rules are enforced HERE or nowhere: a third-party probe
	-- is exactly the path they drift through, and a `found` with no path renders
	-- as a green tick for something that was never verified.
	local function present(v)
		return type(v) == "string" and v ~= ""
	end
	if value.status == "found" then
		if not (present(value.binary) and present(value.path) and present(value.source)) then
			return invalid("found without binary, path and source")
		end
		if not SOURCES[value.source] then
			return invalid(("unrecognised source %q"):format(tostring(value.source)))
		end
	elseif value.status == "missing" then
		-- `binary` is the Mason registry key the hand-off will need.
		if not present(value.binary) then
			return invalid("missing without a binary")
		end
	elseif not present(value.reason) then
		return invalid(("%s without a reason"):format(value.status))
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
		if named and type(name) ~= "string" then
			-- Not merely cosmetic: a non-string name flows into the dedupe key
			-- and into the final sort, where comparing it raises OUTSIDE any
			-- per-adapter guard and destroys every adapter's results.
			named, name = false, ("identity() returned a %s, expected a string"):format(type(name))
		end
		if not named then
			result.skipped[#result.skipped + 1] =
				{ adapter = id, count = 1, severity = "error", reason = tostring(name) }
		else
			local key = id .. "\0" .. name
			if seen[key] then
				-- Dropping a duplicate silently would hide a second, possibly
				-- broken, definition of the same tool -- and in none-ls derived
				-- mode the user never wrote the list, so could not notice.
				result.skipped[#result.skipped + 1] = {
					adapter = id,
					count = 1,
					severity = "warn",
					reason = ("a further entry shares the identity %q and was not probed"):format(name),
				}
			else
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

	local loaded_ok, failures = pcall(registry.load_builtins)
	if loaded_ok and type(failures) == "table" then
		for id, err in pairs(failures) do
			-- Only the adapters that actually failed. Blaming every declared
			-- list would assert that fully-probed tools went unchecked.
			local list = config.list(id)
			result.skipped[#result.skipped + 1] = {
				adapter = id,
				count = type(list) == "table" and #list or 0,
				severity = "error",
				reason = ("muster could not load its %q adapter: %s"):format(id, err),
			}
		end
	elseif not loaded_ok then
		-- A note alone would be silent: notes never notify, and with no adapters
		-- registered there are no entries and no skips either, so a total
		-- failure to load would produce a completely empty, clean-looking
		-- report. Every declared list is accounted for instead.
		result.skipped[#result.skipped + 1] = {
			adapter = "muster",
			count = 0,
			severity = "error",
			reason = ("muster could not load its built-in adapters: %s"):format(tostring(failures)),
		}
	end

	-- A rejected setup() must be visible on every surface, not only in the
	-- one-shot notification at setup time: `check()` is public API, and there a
	-- discarded config would otherwise be indistinguishable from an empty one.
	local config_err = config.error()
	if config_err then
		result.skipped[#result.skipped + 1] = {
			adapter = "muster",
			count = 0,
			severity = "error",
			reason = ("your setup() call was rejected, so only defaults are in effect: %s"):format(config_err),
		}
	end
	mason_notes(result.notes)

	local seen = {}
	for id, adapter in pairs(registry.all()) do
		-- One bad adapter must cost one adapter's worth of results, not all of
		-- them: a raise here would otherwise destroy the whole report.
		local ok, err = pcall(function()
			local entries, skip_reason, severity = entries_for(id, adapter)
			if not entries then
				if skip_reason then
					local list = config.list(id)
					result.skipped[#result.skipped + 1] = {
						adapter = id,
						count = type(list) == "table" and #list or 0,
						severity = severity or "warn",
						reason = skip_reason,
					}
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
					severity = "warn",
					reason = reason or "host plugin not loaded",
				}
				return
			end
			probe_entries(result, id, adapter, entries, bufnr, seen)
		end)
		if not ok then
			-- The real count matters: `health` must not render "0 entries
			-- unchecked" at info level for an adapter that crashed with three
			-- declared tools behind it.
			local list = config.list(id)
			result.skipped[#result.skipped + 1] = {
				adapter = id,
				count = type(list) == "table" and #list or 0,
				severity = "error",
				reason = ("adapter raised during the check: %s"):format(tostring(err)),
			}
		end
	end

	-- A declared key with no adapter behind it is never visited by the loop
	-- above, so without this it produces no entry, no skip and total silence --
	-- a clean Result indistinguishable from a passing one.
	for key in pairs(config.get() or {}) do
		local list = config.list(key)
		-- A declared BUILTIN key is never a typo, and its absence from the
		-- registry is already reported above with the real load error. Without
		-- this the adapter is skipped twice, its unchecked count is doubled, and
		-- the second line calls a correct setup key a typo.
		if type(list) == "table" and not registry.get(key) and not registry.is_builtin(key) then
			result.skipped[#result.skipped + 1] = {
				adapter = key,
				count = #list,
				severity = "error",
				reason = "no adapter is registered for this setup key "
					.. "(a typo, or the plugin providing it has not registered yet)",
			}
		end
	end

	-- Every name reaching here is a validated string, but the sort is the one
	-- statement outside the per-adapter guards, so it is protected too: a raise
	-- here would discard the whole report.
	local sorted, sort_err = pcall(table.sort, result.entries, function(a, b)
		if a.adapter ~= b.adapter then
			return a.adapter < b.adapter
		end
		return a.name < b.name
	end)
	if not sorted then
		-- Reaching here means the comparator saw data the validators were
		-- supposed to make impossible; row order is cosmetic but the bug is not.
		result.notes[#result.notes + 1] = ("muster could not sort its results: %s"):format(tostring(sort_err))
	end
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
