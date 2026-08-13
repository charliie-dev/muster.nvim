---The `:Muster` floating report.
---
---Each invocation probes the buffer it was opened from, then asks every loaded
---adapter for entries live in that same buffer. It calls the pure probe path
---directly: opening this read-only surface emits no startup report and cannot
---enter a provisioning hand-off.

local check = require("muster.check")
local registry = require("muster.registry")

local M = {}

local function key(entry)
	return entry.adapter .. "\0" .. entry.name
end

local function sort_entries(entries)
	table.sort(entries, function(a, b)
		if a.adapter ~= b.adapter then
			return a.adapter < b.adapter
		end
		return a.name < b.name
	end)
end

---@class muster.OverlayView
---@field bufnr integer
---@field filetype string
---@field active muster.Entry[]
---@field other muster.Entry[]
---@field diagnostics string[]
---@field notes string[]

---@param view muster.OverlayView
---@param diagnostic string
local function add_diagnostic(view, diagnostic)
	view.diagnostics[#view.diagnostics + 1] = diagnostic
end

---@param id string
---@param adapter muster.Adapter
---@param raw any
---@param name string
---@param bufnr integer
---@return muster.Entry
local function probe_discovered(id, adapter, raw, name, bufnr)
	local probed, probe = pcall(adapter.probe, raw, bufnr)
	return {
		adapter = id,
		name = name,
		declared = false,
		probe = probed and check.validate_probe(id, probe) or {
			status = "broken",
			reason = ("probe raised: %s"):format(tostring(probe)),
		},
		advice = {},
	}
end

---@param view muster.OverlayView
---@param declared table<string, muster.Entry>
---@param active table<string, boolean>
---@param id string
---@param adapter muster.Adapter
---@param raw any
local function collect_live_entry(view, declared, active, id, adapter, raw)
	local named, name = pcall(adapter.identity, raw)
	if not named or type(name) ~= "string" or name == "" then
		local reason
		if not named then
			reason = tostring(name)
		elseif name == "" then
			reason = "expected a non-empty string, got an empty string"
		else
			reason = "expected a string, got " .. type(name)
		end
		add_diagnostic(view, ("%s live identity failed: %s"):format(id, reason))
		return
	end

	local entry_key = id .. "\0" .. name
	if active[entry_key] then
		return
	end

	local entry = declared[entry_key] or probe_discovered(id, adapter, raw, name, view.bufnr)
	active[entry_key] = true
	view.active[#view.active + 1] = entry
end

---@param view muster.OverlayView
---@param declared table<string, muster.Entry>
---@param active table<string, boolean>
---@param id string
---@param adapter muster.Adapter
local function collect_live(view, declared, active, id, adapter)
	if type(adapter.live) ~= "function" then
		return
	end

	local available_ok, available = pcall(adapter.available)
	if not available_ok or not available then
		return
	end

	local live_ok, entries, live_err = pcall(adapter.live, view.bufnr)
	if not live_ok then
		add_diagnostic(view, ("%s live query failed: %s"):format(id, entries))
		return
	end
	if type(entries) ~= "table" or not vim.islist(entries) then
		add_diagnostic(view, ("%s live query returned a %s, expected a list"):format(id, type(entries)))
		return
	end
	if live_err then
		add_diagnostic(view, ("%s live query failed: %s"):format(id, tostring(live_err)))
	end

	for _, raw in ipairs(entries) do
		collect_live_entry(view, declared, active, id, adapter, raw)
	end
end

---@param bufnr? integer
---@return muster.OverlayView
function M.collect(bufnr)
	bufnr = (bufnr and bufnr ~= 0) and bufnr or vim.api.nvim_get_current_buf()
	local result = check.run(bufnr)
	local view = {
		bufnr = bufnr,
		filetype = vim.bo[bufnr].filetype,
		active = {},
		other = {},
		diagnostics = {},
		notes = result.notes,
	}

	local declared = {}
	for _, entry in ipairs(result.entries) do
		declared[key(entry)] = entry
	end
	for _, skip in ipairs(result.skipped) do
		add_diagnostic(view, ("%s: %s"):format(skip.adapter, skip.reason))
	end

	local active = {}
	for id, adapter in pairs(registry.all()) do
		collect_live(view, declared, active, id, adapter)
	end

	for _, entry in ipairs(result.entries) do
		if not active[key(entry)] then
			view.other[#view.other + 1] = entry
		end
	end
	sort_entries(view.active)
	sort_entries(view.other)
	table.sort(view.diagnostics)
	return view
end

local STATUS_DETAIL = {
	missing = "not on $PATH",
	unknown = "unrecognised name",
	broken = "config error",
	unverifiable = "could not be verified",
}

---@param entry muster.Entry
---@param versions table<string, muster.Version>
---@return string
local function row(entry, versions)
	local probe = entry.probe
	local name = entry.name .. (entry.declared and "" or "*")
	local source = "—"
	local version = "—"
	local detail
	if probe.status == "found" then
		source = probe.source or "unknown"
		local resolved = versions[key(entry)]
		version = resolved and (resolved.value or "—") or "…"
		detail = probe.path or "path unavailable"
		if resolved and resolved.reason == "spawn failed" then
			detail = detail .. "  [version probe failed]"
		end
	else
		detail = STATUS_DETAIL[probe.status] or tostring(probe.status)
		if probe.reason then
			detail = detail .. ": " .. probe.reason
		end
	end
	return ("  %-21s %-10s %-9s %-10s %s"):format(name, entry.adapter, source, version, detail)
end

---@param lines string[]
---@param title string
---@param entries muster.Entry[]
---@param versions table<string, muster.Version>
local function section(lines, title, entries, versions)
	lines[#lines + 1] = title
	if #entries == 0 then
		lines[#lines + 1] = "  (none)"
	else
		for _, entry in ipairs(entries) do
			lines[#lines + 1] = row(entry, versions)
		end
	end
end

---@param view muster.OverlayView
---@param versions? table<string, muster.Version>
---@return string[]
function M.lines(view, versions)
	versions = versions or {}
	local ft = view.filetype ~= "" and view.filetype or "no filetype"
	local lines = { (" muster    %s  •  buf %d"):format(ft, view.bufnr), "" }
	section(lines, " ACTIVE IN THIS BUFFER", view.active, versions)
	lines[#lines + 1] = ""
	section(lines, " EVERYTHING ELSE", view.other, versions)
	lines[#lines + 1] = ""
	lines[#lines + 1] = " * discovered live; not declared in setup()"
	for _, diagnostic in ipairs(view.diagnostics) do
		lines[#lines + 1] = " ! " .. diagnostic
	end
	for _, note in ipairs(view.notes) do
		lines[#lines + 1] = " note: " .. note
	end
	return lines
end

local function report_buffer()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == "muster://report" then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "muster://report")
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = false
	return bufnr
end

---@param bufnr integer
---@param lines string[]
local function replace_lines(bufnr, lines)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
end

---@param source_bufnr? integer
---@return integer report_bufnr
---@return integer winid
function M.open(source_bufnr)
	local view = M.collect(source_bufnr)
	local versions = {}
	local initial = M.lines(view, versions)
	local bufnr = report_buffer()
	replace_lines(bufnr, initial)

	local width = math.max(1, math.min(100, vim.o.columns - 4))
	local height = math.max(1, math.min(#initial, vim.o.lines - 4))
	local winid = vim.api.nvim_open_win(bufnr, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " muster ",
		title_pos = "center",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
	})
	vim.wo[winid].wrap = false
	vim.wo[winid].cursorline = true
	local function close_report()
		if vim.api.nvim_win_is_valid(winid) then
			vim.api.nvim_win_close(winid, true)
		end
	end
	local map_options = {
		buffer = bufnr,
		desc = "Close Muster report",
		nowait = true,
		silent = true,
	}
	vim.keymap.set("n", "q", close_report, map_options)
	vim.keymap.set("n", "<Esc>", close_report, map_options)

	local version = require("muster.version")
	for _, entries in ipairs({ view.active, view.other }) do
		for _, entry in ipairs(entries) do
			if entry.probe.status == "found" then
				version.resolve(entry, function(resolved)
					versions[key(entry)] = resolved
					vim.schedule(function()
						replace_lines(bufnr, M.lines(view, versions))
					end)
				end)
			end
		end
	end
	return bufnr, winid
end

return M
