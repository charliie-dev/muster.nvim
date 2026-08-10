---Probe the declared lists and build a `muster.Result`.
---
---This is the report path. It is spawn-free by construction: nothing here
---requires the overlay module, which is where tier-4 version probing lives.

local config = require("muster.config")
local registry = require("muster.registry")

local M = {}

---Mason puts its bin directory on $PATH inside `mason.setup()` and nowhere else.
---Probing before that reports every Mason-provided tool as missing — the exact
---false negative muster exists to prevent — so the hazard is detected and
---reported rather than silently producing wrong results. muster does not
---force-load Mason.
---@param notes string[]
local function mason_notes(notes)
	if not package.loaded["mason"] then
		return
	end
	local ok, mason = pcall(require, "mason")
	if not ok or type(mason) ~= "table" then
		return
	end
	if mason.has_setup == false then
		notes[#notes + 1] = "mason.nvim is loaded but has not been set up yet; "
			.. "Mason-provided tools may be reported as missing. Run muster's check after mason.setup()."
	end
	local ok_settings, settings = pcall(require, "mason.settings")
	if ok_settings and type(settings) == "table" and vim.tbl_get(settings, "current", "PATH") == "prepend" then
		notes[#notes + 1] = 'mason.nvim is configured with PATH = "prepend", so its copies shadow system tools. '
			.. 'muster recommends PATH = "append" for system-first resolution.'
	end
end

---Entries an adapter should probe, and whether they count as declared.
---
---A key present in `setup()` always wins. The one fallback is none-ls, whose
---entries are source objects the user already wrote once for `null_ls.setup()`;
---reading them back is not deriving a different config, so they stay
---`declared = true`.
---@param id string
---@param adapter muster.Adapter
---@return any[]|nil entries
---@return string|nil skip_reason
local function entries_for(id, adapter)
	local declared = config.list(id)
	if declared then
		return declared, nil
	end
	-- Derived mode. Availability is checked FIRST: without it, an absent
	-- none-ls yields an empty `registered()` and muster would report "loaded but
	-- has no registered sources" about a plugin that is not installed.
	if id == "none_ls" and type(adapter.registered) == "function" and adapter.available() then
		local sources = adapter.registered()
		if #sources == 0 then
			-- Loaded with nothing registered is a skip, not an empty pass: an
			-- empty pass would read as "all clear".
			return nil, "none-ls is loaded but has no registered sources"
		end
		return sources, nil
	end
	return nil, nil
end

---@param bufnr? integer
---@return muster.Result
function M.run(bufnr)
	bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
	registry.load_builtins()

	---@type muster.Result
	local result = { entries = {}, skipped = {}, bufnr = bufnr, notes = {} }
	mason_notes(result.notes)

	local seen = {}
	for id, adapter in pairs(registry.all()) do
		local entries, skip_reason = entries_for(id, adapter)

		if entries and not adapter.available() then
			-- A missing host plugin is never a typo: the names may be perfectly
			-- good, there is simply nothing to ask.
			result.skipped[#result.skipped + 1] = { adapter = id, count = #entries, reason = "host plugin not loaded" }
		elseif entries then
			for _, entry in ipairs(entries) do
				local ok, name = pcall(adapter.identity, entry)
				if not ok then
					result.skipped[#result.skipped + 1] = { adapter = id, count = 1, reason = tostring(name) }
				else
					local key = id .. "\0" .. name
					if not seen[key] then
						seen[key] = true
						local probed_ok, probe = pcall(adapter.probe, entry, bufnr)
						result.entries[#result.entries + 1] = {
							adapter = id,
							name = name,
							declared = true,
							probe = probed_ok and probe or { status = "broken", reason = tostring(probe) },
							advice = {},
						}
					end
				end
			end
		elseif skip_reason then
			result.skipped[#result.skipped + 1] = { adapter = id, count = 0, reason = skip_reason }
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
---re-derive it and they cannot disagree.
---@param result muster.Result
---@return table<muster.Status, integer>
function M.tally(result)
	local counts = { found = 0, missing = 0, unverifiable = 0, unknown = 0, broken = 0 }
	for _, entry in ipairs(result.entries) do
		counts[entry.probe.status] = (counts[entry.probe.status] or 0) + 1
	end
	return counts
end

return M
