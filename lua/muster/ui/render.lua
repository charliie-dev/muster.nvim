local M = {}

local HIGHLIGHTS = {
	MusterNormal = "NormalFloat",
	MusterBackdrop = "Normal",
	MusterHeader = "Title",
	MusterTabActive = "Visual",
	MusterTabInactive = "Comment",
	MusterStatusFound = "DiagnosticOk",
	MusterStatusMissing = "DiagnosticWarn",
	MusterStatusBroken = "DiagnosticError",
	MusterStatusUnknown = "DiagnosticWarn",
	MusterStatusUnverifiable = "DiagnosticInfo",
	MusterAdapter = "Type",
	MusterVersion = "String",
	MusterMuted = "Comment",
	MusterDetailKey = "Identifier",
	MusterSearchMatch = "IncSearch",
}

local STATUS_ORDER = { broken = 1, unknown = 2, unverifiable = 3, missing = 4, found = 5 }
local STATUS_HL = {
	found = "MusterStatusFound",
	missing = "MusterStatusMissing",
	unknown = "MusterStatusUnknown",
	broken = "MusterStatusBroken",
	unverifiable = "MusterStatusUnverifiable",
}

local MAX_INPUT_BYTES = 4096
local MAX_DISPLAY_CELLS = 512
local LABEL_BYTES = 128
local ICON_BYTES = 32
local QUERY_BYTES = 256
local ELLIPSIS = "…"

local highlights_registered = false

local function apply_highlights()
	for name, link in pairs(HIGHLIGHTS) do
		local current = vim.api.nvim_get_hl(0, { name = name, link = true })
		if next(current) == nil then
			vim.api.nvim_set_hl(0, name, { link = link })
		else
			vim.api.nvim_set_hl(0, name, { link = link, default = true })
		end
	end
end

function M.setup_highlights()
	apply_highlights()
	if highlights_registered then
		return
	end
	local group_ok, group = pcall(vim.api.nvim_create_augroup, "muster_ui_highlights", { clear = true })
	if not group_ok then
		pcall(vim.api.nvim_del_augroup_by_name, "muster_ui_highlights")
		error(group, 0)
	end
	local autocmd_ok, err =
		pcall(vim.api.nvim_create_autocmd, "ColorScheme", { group = group, callback = apply_highlights })
	if not autocmd_ok then
		pcall(vim.api.nvim_del_augroup_by_id, group)
		error(err, 0)
	end
	highlights_registered = true
end

local function decode_utf8(value, index, limit)
	local first = value:byte(index)
	if first < 0x80 then
		return first, index + 1
	end

	local length
	if first >= 0xC2 and first <= 0xDF then
		length = 2
	elseif first >= 0xE0 and first <= 0xEF then
		length = 3
	elseif first >= 0xF0 and first <= 0xF4 then
		length = 4
	else
		return nil, index, "invalid"
	end
	if index + length - 1 > limit then
		return nil, index, "incomplete"
	end

	local second = value:byte(index + 1)
	if second < 0x80 or second > 0xBF then
		return nil, index, "invalid"
	end
	if length == 2 then
		return (first - 0xC0) * 0x40 + second - 0x80, index + 2
	end

	local third = value:byte(index + 2)
	if third < 0x80 or third > 0xBF then
		return nil, index, "invalid"
	end
	if first == 0xE0 and second < 0xA0 then
		return nil, index, "invalid"
	end
	if first == 0xED and second > 0x9F then
		return nil, index, "invalid"
	end
	if length == 3 then
		return (first - 0xE0) * 0x1000 + (second - 0x80) * 0x40 + third - 0x80, index + 3
	end

	local fourth = value:byte(index + 3)
	if fourth < 0x80 or fourth > 0xBF then
		return nil, index, "invalid"
	end
	if first == 0xF0 and second < 0x90 then
		return nil, index, "invalid"
	end
	if first == 0xF4 and second > 0x8F then
		return nil, index, "invalid"
	end
	return (first - 0xF0) * 0x40000 + (second - 0x80) * 0x1000 + (third - 0x80) * 0x40 + fourth - 0x80, index + 4
end

local function escaped_control(codepoint)
	if codepoint == 0x09 then
		return "<TAB>"
	elseif codepoint == 0x0A then
		return "<LF>"
	elseif codepoint == 0x0D then
		return "<CR>"
	elseif codepoint <= 0x1F or (codepoint >= 0x7F and codepoint <= 0x9F) then
		return ("<U+%04X>"):format(codepoint)
	elseif
		codepoint == 0x061C
		or codepoint == 0x200E
		or codepoint == 0x200F
		or (codepoint >= 0x202A and codepoint <= 0x202E)
		or (codepoint >= 0x2066 and codepoint <= 0x2069)
	then
		return ("<U+%04X>"):format(codepoint)
	end
end

local function clip_units(units, max_cells, force_ellipsis)
	if max_cells <= 0 then
		return ""
	end
	local text = table.concat(units)
	local width = vim.fn.strdisplaywidth(text)
	if not force_ellipsis and width <= max_cells then
		return text
	end
	if force_ellipsis and width + 1 <= max_cells then
		return text .. ELLIPSIS
	end
	if max_cells == 1 then
		return ELLIPSIS
	end

	local low = 0
	local high = #units
	while low < high do
		local middle = math.floor((low + high + 1) / 2)
		local candidate = table.concat(units, "", 1, middle) .. ELLIPSIS
		if vim.fn.strdisplaywidth(candidate) <= max_cells then
			low = middle
		else
			high = middle - 1
		end
	end
	return table.concat(units, "", 1, low) .. ELLIPSIS
end

local function invalid_marker(kind, max_cells)
	local marker = "<invalid:" .. kind .. ">"
	local units = {}
	for index = 1, #marker do
		units[index] = marker:sub(index, index)
	end
	return clip_units(units, max_cells, false)
end

local function normalize_display(value, max_cells, max_bytes)
	max_cells = math.min(max_cells or MAX_DISPLAY_CELLS, MAX_DISPLAY_CELLS)
	max_bytes = math.min(max_bytes or MAX_INPUT_BYTES, MAX_INPUT_BYTES)
	if type(value) ~= "string" then
		return invalid_marker(type(value), max_cells)
	end

	local units = {}
	local limit = math.min(#value, max_bytes)
	local index = 1
	local truncated = #value > max_bytes
	while index <= limit do
		local codepoint, next_index, problem = decode_utf8(value, index, limit)
		if not codepoint then
			if problem == "incomplete" and #value > limit then
				truncated = true
				break
			end
			return invalid_marker("utf8", max_cells)
		end
		local escaped = escaped_control(codepoint)
		units[#units + 1] = escaped or value:sub(index, next_index - 1)
		index = next_index
	end
	return clip_units(units, max_cells, truncated)
end

local function format_buffer_number(value)
	if type(value) == "number" and value == value and value >= 0 and value <= 2147483647 and value % 1 == 0 then
		return ("%d"):format(value)
	end
	return "<invalid:integer>"
end

local function clip_valid(text, max_cells)
	if max_cells <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= max_cells then
		return text
	end
	if max_cells == 1 then
		return ELLIPSIS
	end
	local characters = vim.fn.strchars(text)
	local low = 0
	local high = characters
	while low < high do
		local middle = math.floor((low + high + 1) / 2)
		local candidate = vim.fn.strcharpart(text, 0, middle) .. ELLIPSIS
		if vim.fn.strdisplaywidth(candidate) <= max_cells then
			low = middle
		else
			high = middle - 1
		end
	end
	return vim.fn.strcharpart(text, 0, low) .. ELLIPSIS
end

local function fit(text, width)
	local clipped = clip_valid(text, width)
	return clipped .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(clipped)))
end

local function append_extmark(output, line, col, text, highlight)
	if highlight and text ~= "" then
		output.extmarks[#output.extmarks + 1] = {
			line = line,
			col = col,
			opts = { end_col = col + #text, hl_group = highlight },
		}
	end
end

local function add_line(output, width, segments)
	local line_number = #output.lines
	local text = ""
	local used = 0
	for _, segment in ipairs(segments) do
		local remaining = width - used
		if remaining <= 0 then
			break
		end
		local value = clip_valid(segment[1], remaining)
		local col = #text
		text = text .. value
		used = vim.fn.strdisplaywidth(text)
		append_extmark(output, line_number, col, value, segment[2])
	end
	output.lines[#output.lines + 1] = text
	return #output.lines
end

local function add_centered_line(output, width, segments)
	local content_width = 0
	for _, segment in ipairs(segments) do
		content_width = content_width + vim.fn.strdisplaywidth(segment[1])
	end
	local centered = { { string.rep(" ", math.max(0, math.floor((width - content_width) / 2))) } }
	vim.list_extend(centered, segments)
	return add_line(output, width, centered)
end

local function safe_optional(value, max_cells, max_bytes)
	if value == nil then
		return nil
	end
	return normalize_display(value, max_cells, max_bytes)
end

local function safe_identity(entry)
	local adapter = normalize_display(entry.adapter, MAX_DISPLAY_CELLS)
	local name = normalize_display(entry.name, MAX_DISPLAY_CELLS)
	local key
	if type(entry.adapter) == "string" and type(entry.name) == "string" then
		key = entry.adapter .. "\0" .. entry.name
	else
		key = adapter .. "\0" .. name
	end
	return adapter, name, key
end

local function metadata_scalar(value)
	local kind = type(value)
	if kind == "string" or kind == "number" or kind == "boolean" then
		return value
	end
end

local function metadata_path(value)
	local kind = type(value)
	if kind == "string" or kind == "number" or kind == "boolean" then
		return value
	end
	if value ~= nil then
		return {}
	end
end

local function raw_entry_copy(entry)
	local probe = type(entry.probe) == "table" and entry.probe or {}
	local advice = {}
	if type(entry.advice) == "table" then
		for _, item in ipairs(entry.advice) do
			if type(item) == "table" then
				advice[#advice + 1] = {
					provider = metadata_scalar(item.provider),
					action = metadata_scalar(item.action),
					package = metadata_scalar(item.package),
					command = metadata_scalar(item.command),
					eligible = metadata_scalar(item.eligible),
					reason = metadata_scalar(item.reason),
				}
			end
		end
	end
	return {
		adapter = metadata_scalar(entry.adapter),
		name = metadata_scalar(entry.name),
		declared = metadata_scalar(entry.declared),
		probe = {
			status = metadata_scalar(probe.status),
			binary = metadata_scalar(probe.binary),
			path = metadata_path(probe.path),
			realpath = metadata_path(probe.realpath),
			source = metadata_scalar(probe.source),
			reason = metadata_scalar(probe.reason),
		},
		advice = advice,
	}
end

local function safe_entry(entry, versions, ui)
	local adapter, name, key = safe_identity(entry)
	local probe = type(entry.probe) == "table" and entry.probe or {}
	local status = normalize_display(probe.status, MAX_DISPLAY_CELLS)
	local raw_status = type(probe.status) == "string" and probe.status or nil
	local resolved = versions[key]
	local safe = {
		metadata = raw_entry_copy(entry),
		adapter = adapter,
		name = name,
		key = key,
		declared = entry.declared ~= false,
		status = status,
		raw_status = raw_status,
		binary = safe_optional(probe.binary, MAX_DISPLAY_CELLS),
		path = safe_optional(probe.path, MAX_DISPLAY_CELLS),
		realpath = safe_optional(probe.realpath, MAX_DISPLAY_CELLS),
		source = safe_optional(probe.source, MAX_DISPLAY_CELLS),
		reason = safe_optional(probe.reason, MAX_DISPLAY_CELLS),
		advice = {},
	}
	if type(resolved) == "table" then
		safe.version = safe_optional(resolved.value, MAX_DISPLAY_CELLS)
		safe.version_reason = safe_optional(resolved.reason, MAX_DISPLAY_CELLS)
		safe.version_resolved = true
	else
		safe.version_resolved = false
	end
	if type(entry.advice) == "table" then
		for _, item in ipairs(entry.advice) do
			if type(item) == "table" then
				safe.advice[#safe.advice + 1] = {
					provider = safe_optional(item.provider, MAX_DISPLAY_CELLS),
					action = safe_optional(item.action, MAX_DISPLAY_CELLS),
					package = safe_optional(item.package, MAX_DISPLAY_CELLS),
					command = safe_optional(item.command, MAX_DISPLAY_CELLS),
					reason = safe_optional(item.reason, MAX_DISPLAY_CELLS),
				}
			end
		end
	end
	local configured_label = type(entry.adapter) == "string" and ui.adapter_labels[entry.adapter] or nil
	safe.adapter_label = configured_label or adapter
	return safe
end

local function compare_entries(left, right)
	if left.adapter ~= right.adapter then
		return left.adapter < right.adapter
	end
	if left.name ~= right.name then
		return left.name < right.name
	end
	return left.key < right.key
end

local function copied_entries(entries, versions, ui, seen)
	local copied = {}
	if type(entries) ~= "table" then
		return copied
	end
	for _, entry in ipairs(entries) do
		if type(entry) == "table" then
			local safe = safe_entry(entry, versions, ui)
			if not seen or not seen[safe.key] then
				copied[#copied + 1] = safe
				if seen then
					seen[safe.key] = true
				end
			end
		end
	end
	return copied
end

local function sorted_active_and_all(view, versions, ui)
	local active_seen = {}
	local active = copied_entries(view.active, versions, ui, active_seen)
	table.sort(active, compare_entries)

	local all_seen = {}
	local all = copied_entries(view.active, versions, ui, all_seen)
	local other = copied_entries(view.other, versions, ui, all_seen)
	for _, entry in ipairs(other) do
		all[#all + 1] = entry
	end
	table.sort(all, compare_entries)
	return active, all
end

local function safe_ui(ui)
	local labels = ui.labels
	local icons = ui.icons
	local safe = {
		icons = {},
		adapter_labels = {},
		labels = {
			title = normalize_display(labels.title, LABEL_BYTES, LABEL_BYTES),
			empty = normalize_display(labels.empty, LABEL_BYTES, LABEL_BYTES),
			no_matches = normalize_display(labels.no_matches, LABEL_BYTES, LABEL_BYTES),
			no_issues = normalize_display(labels.no_issues, LABEL_BYTES, LABEL_BYTES),
			search_prompt = normalize_display(labels.search_prompt, LABEL_BYTES, LABEL_BYTES),
			help = normalize_display(labels.help, LABEL_BYTES, LABEL_BYTES),
			tabs = {},
			columns = {},
			details = {},
		},
		keymaps = {},
	}
	for _, key in ipairs({
		"found",
		"missing",
		"unknown",
		"broken",
		"unverifiable",
		"pending",
		"discovered",
		"expanded",
		"collapsed",
	}) do
		safe.icons[key] = normalize_display(icons[key], ICON_BYTES, ICON_BYTES)
	end
	for _, key in ipairs({ "active", "all", "issues" }) do
		safe.labels.tabs[key] = normalize_display(labels.tabs[key], LABEL_BYTES, LABEL_BYTES)
	end
	for key, value in pairs(labels.adapters) do
		if type(key) == "string" then
			safe.adapter_labels[key] = normalize_display(value, LABEL_BYTES, LABEL_BYTES)
		end
	end
	for _, key in ipairs({ "status", "tool", "adapter", "version" }) do
		safe.labels.columns[key] = normalize_display(labels.columns[key], LABEL_BYTES, LABEL_BYTES)
	end
	for _, key in ipairs({ "source", "executable", "path", "realpath", "reason", "advice" }) do
		safe.labels.details[key] = normalize_display(labels.details[key], LABEL_BYTES, LABEL_BYTES)
	end
	for key, value in pairs(ui.keymaps) do
		safe.keymaps[key] = value
	end
	return safe
end

local function keymap_list(mapping)
	if mapping == false or mapping == nil then
		return nil
	end
	if type(mapping) ~= "table" then
		return { normalize_display(mapping, 64, 64) }
	end
	local keys = {}
	for _, value in ipairs(mapping) do
		keys[#keys + 1] = normalize_display(value, 64, 64)
	end
	return keys
end

local function action_hints(ui)
	local declarations = {
		{ action = "close", section = "Closing", description = "close dashboard" },
		{ action = "search", section = "Inspection", description = ui.labels.search_prompt },
		{ action = "help", section = "Closing", description = ui.labels.help },
		{ action = "refresh", section = "Inspection", description = "refresh" },
		{ action = "copy_path", section = "Inspection", description = "copy path" },
		{ action = "active", section = "Navigation", description = ui.labels.tabs.active .. " tab" },
		{ action = "all", section = "Navigation", description = ui.labels.tabs.all .. " tab" },
		{ action = "issues", section = "Navigation", description = ui.labels.tabs.issues .. " tab" },
		{ action = "next_tab", section = "Navigation", description = "next tab" },
		{ action = "previous_tab", section = "Navigation", description = "previous tab" },
		{ action = "details", section = "Rows", description = "details" },
	}
	local hints = {}
	for _, declaration in ipairs(declarations) do
		local keys = keymap_list(ui.keymaps[declaration.action])
		if keys then
			hints[#hints + 1] = {
				action = declaration.action,
				section = declaration.section,
				key_text = table.concat(keys, "/"),
				description = declaration.description,
			}
		end
	end
	return hints
end

local function display_version(entry, ui)
	if entry.raw_status ~= "found" then
		return "—"
	end
	if entry.version then
		return entry.version
	end
	if entry.version_resolved then
		return "—"
	end
	return ui.icons.pending
end

local function tab_pill(label, count)
	return "[ " .. label .. " (" .. count .. ") ]"
end

local function render_tabs(output, width, active_tab, labels, counts)
	local first_line = #output.lines + 1
	local segments = {}
	local line_width = 0
	local function flush()
		if #segments == 0 then
			return
		end
		add_centered_line(output, width, segments)
		segments = {}
		line_width = 0
	end

	for _, tab in ipairs({ "active", "all", "issues" }) do
		local pill = tab_pill(labels[tab], counts[tab])
		local pill_width = vim.fn.strdisplaywidth(pill)
		if #segments > 0 and line_width + 1 + pill_width > width then
			flush()
		end
		if #segments > 0 then
			segments[#segments + 1] = { " " }
			line_width = line_width + 1
		end
		segments[#segments + 1] = {
			pill,
			tab == active_tab and "MusterTabActive" or "MusterTabInactive",
		}
		line_width = line_width + pill_width
		if pill_width > width then
			flush()
		end
	end
	flush()
	return first_line
end

local function status_icon(entry, ui)
	if entry.raw_status and ui.icons[entry.raw_status] and ui.icons[entry.raw_status] ~= "" then
		return ui.icons[entry.raw_status]
	end
	return entry.status
end

local function expansion_icon(entry, expanded_key, ui)
	if entry.key == expanded_key then
		return ui.icons.expanded
	end
	return ui.icons.collapsed
end

local function rendered_status(entry, expanded_key, ui)
	return expansion_icon(entry, expanded_key, ui) .. " " .. status_icon(entry, ui)
end

local function max_width(current, value)
	return math.max(current, vim.fn.strdisplaywidth(value))
end

local function table_side_margin(width)
	local available = math.max(0, math.floor((width - 2) / 2))
	local preferred = math.min(32, math.max(8, math.floor(width * 0.2)))
	return math.min(available, preferred)
end

local function wide_columns(entries, expanded_key, ui, width, margin)
	local table_width = width - 2 * margin
	if table_width < 1 then
		return nil
	end
	local status_width = math.max(3, vim.fn.strdisplaywidth(ui.labels.columns.status))
	local adapter_heading_width = vim.fn.strdisplaywidth(ui.labels.columns.adapter)
	local version_heading_width = vim.fn.strdisplaywidth(ui.labels.columns.version)
	local adapter_value_width = 0
	local version_value_width = 0
	for _, entry in ipairs(entries) do
		status_width = max_width(status_width, rendered_status(entry, expanded_key, ui))
		adapter_value_width = max_width(adapter_value_width, entry.adapter_label)
		version_value_width = max_width(version_value_width, display_version(entry, ui))
	end
	local adapter_width = math.max(adapter_heading_width, math.min(adapter_value_width, 16))
	local version_width = math.max(version_heading_width, math.min(version_value_width, 18))
	local tool_width = math.max(16, vim.fn.strdisplaywidth(ui.labels.columns.tool))
	if status_width + tool_width + adapter_width + version_width + 6 > table_width then
		return nil
	end
	tool_width = table_width - status_width - adapter_width - version_width - 6
	return {
		margin = margin,
		status = status_width,
		tool = tool_width,
		adapter = adapter_width,
		version = version_width,
	}
end

local function tool_name(entry, ui)
	if entry.declared then
		return entry.name
	end
	return entry.name .. ui.icons.discovered
end

local function add_row_metadata(output, line, entry)
	output.row_by_line[line] = { kind = "entry", key = entry.key, entry = entry.metadata }
	output.line_by_key[entry.key] = line
end

local function render_wide_header(output, width, columns, ui)
	add_line(output, width, {
		{ string.rep(" ", columns.margin) },
		{ fit(ui.labels.columns.status, columns.status), "MusterMuted" },
		{ "  " },
		{ fit(ui.labels.columns.tool, columns.tool), "MusterMuted" },
		{ "  " },
		{ fit(ui.labels.columns.adapter, columns.adapter), "MusterMuted" },
		{ "  " },
		{ fit(ui.labels.columns.version, columns.version), "MusterMuted" },
	})
end

local function render_wide_row(output, width, columns, entry, state, ui)
	local status = rendered_status(entry, state.expanded_key, ui)
	local line = add_line(output, width, {
		{ string.rep(" ", columns.margin) },
		{ fit(status, columns.status), STATUS_HL[entry.raw_status] or "MusterMuted" },
		{ "  " },
		{ fit(tool_name(entry, ui), columns.tool) },
		{ "  " },
		{ fit(entry.adapter_label, columns.adapter), "MusterAdapter" },
		{ "  " },
		{ fit(display_version(entry, ui), columns.version), "MusterVersion" },
	})
	add_row_metadata(output, line, entry)
end

local function render_compact_row(output, width, margin, entry, state, ui, searching)
	local padding = string.rep(" ", margin)
	local table_width = math.max(1, width - 2 * margin)
	local status = rendered_status(entry, state.expanded_key, ui)
	local tool = tool_name(entry, ui)
	local adapter = entry.adapter_label
	local version = display_version(entry, ui)
	local status_width = vim.fn.strdisplaywidth(status)
	local tool_width = vim.fn.strdisplaywidth(tool)
	local adapter_width = vim.fn.strdisplaywidth(adapter)
	local version_width = vim.fn.strdisplaywidth(version)
	local main_width = status_width + 1 + tool_width
	local metadata_width = adapter_width + 2 + version_width
	local gap_width = table_width - main_width - metadata_width
	local line
	if not searching and gap_width >= 2 then
		line = add_line(output, width, {
			{ padding },
			{ status, STATUS_HL[entry.raw_status] or "MusterMuted" },
			{ " " },
			{ tool },
			{ string.rep(" ", gap_width) },
			{ adapter, "MusterAdapter" },
			{ "  " },
			{ version, "MusterVersion" },
		})
	else
		local status_text = clip_valid(status, table_width)
		local remaining = table_width - vim.fn.strdisplaywidth(status_text)
		local main_segments = {
			{ padding },
			{ status_text, STATUS_HL[entry.raw_status] or "MusterMuted" },
		}
		if remaining > 0 then
			main_segments[#main_segments + 1] = { " " }
			remaining = remaining - 1
		end
		if remaining > 0 then
			local tool_text = clip_valid(tool, remaining)
			main_segments[#main_segments + 1] = { tool_text }
			remaining = remaining - vim.fn.strdisplaywidth(tool_text)
		end
		if remaining > 0 then
			main_segments[#main_segments + 1] = { string.rep(" ", remaining) }
		end
		line = add_line(output, width, main_segments)

		if metadata_width <= table_width then
			add_line(output, width, {
				{ padding },
				{ adapter, "MusterAdapter" },
				{ string.rep(" ", table_width - adapter_width - version_width) },
				{ version, "MusterVersion" },
			})
		else
			local separator_width = table_width >= 3 and 2 or 0
			local version_cells = math.min(version_width, math.max(1, math.floor(table_width * 0.4)))
			local adapter_cells = math.max(0, table_width - separator_width - version_cells)
			add_line(output, width, {
				{ padding },
				{ fit(adapter, adapter_cells), "MusterAdapter" },
				{ string.rep(" ", separator_width) },
				{ fit(version, version_cells), "MusterVersion" },
			})
		end
	end
	add_row_metadata(output, line, entry)
end

local function take_display_cells(value, max_cells)
	if value == "" or max_cells <= 0 then
		return "", value
	end
	local count = vim.fn.strchars(value, true)
	local consumed = 0
	local used = 0
	while consumed < count do
		local unit = vim.fn.strcharpart(value, consumed, 1, true)
		local unit_width = vim.fn.strdisplaywidth(unit)
		if used + unit_width > max_cells then
			if consumed == 0 then
				return clip_valid(unit, max_cells), vim.fn.strcharpart(value, 1, count, true)
			end
			break
		end
		used = used + unit_width
		consumed = consumed + 1
	end
	return vim.fn.strcharpart(value, 0, consumed, true), vim.fn.strcharpart(value, consumed, count, true)
end

local function detail(output, width, margin, label, value)
	if value == nil then
		return
	end
	local padding = string.rep(" ", margin)
	local table_width = math.max(1, width - 2 * margin)
	local label_text = label .. ": "
	local label_width = vim.fn.strdisplaywidth(label_text)
	local remainder = value
	if label_width < table_width then
		local first = ""
		local available = table_width - label_width
		local first_unit = vim.fn.strcharpart(remainder, 0, 1, true)
		if first_unit == "" or vim.fn.strdisplaywidth(first_unit) <= available then
			first, remainder = take_display_cells(remainder, available)
		end
		add_line(output, width, {
			{ padding },
			{ label, "MusterDetailKey" },
			{ ": " },
			{ first },
		})
	else
		add_line(output, width, {
			{ padding },
			{ clip_valid(label_text, table_width), "MusterDetailKey" },
		})
	end
	while remainder ~= "" do
		local chunk
		chunk, remainder = take_display_cells(remainder, table_width)
		add_line(output, width, { { padding }, { chunk } })
	end
end

local function render_details(output, width, margin, entry, ui)
	if not entry.declared then
		local marker = ui.icons.discovered ~= "" and (ui.icons.discovered .. " ") or ""
		detail(output, width, margin, ui.labels.details.source, marker .. "discovered live; not declared in setup()")
	end
	detail(output, width, margin, ui.labels.details.source, entry.source)
	detail(output, width, margin, ui.labels.details.executable, entry.binary)
	detail(output, width, margin, ui.labels.details.path, entry.path)
	detail(output, width, margin, ui.labels.details.realpath, entry.realpath)
	detail(output, width, margin, ui.labels.details.reason, entry.reason)
	detail(output, width, margin, ui.labels.details.reason, entry.version_reason)
	for _, advice in ipairs(entry.advice) do
		local fields = {}
		for _, field in ipairs({ advice.provider, advice.action, advice.package, advice.command, advice.reason }) do
			if field ~= nil then
				fields[#fields + 1] = field
			end
		end
		if #fields > 0 then
			detail(output, width, margin, ui.labels.details.advice, table.concat(fields, " · "))
		end
	end
end

local function issue_entries(all)
	local issues = {}
	for _, entry in ipairs(all) do
		if entry.raw_status ~= "found" then
			issues[#issues + 1] = entry
		end
	end
	table.sort(issues, function(left, right)
		local left_status = STATUS_ORDER[left.raw_status] or 0
		local right_status = STATUS_ORDER[right.raw_status] or 0
		if left_status ~= right_status then
			return left_status < right_status
		end
		return compare_entries(left, right)
	end)
	return issues
end

local function contains(haystack, needle)
	return type(haystack) == "string" and haystack:lower():find(needle:lower(), 1, true) ~= nil
end

local function matches_query(entry, query)
	return query == ""
		or contains(entry.name, query)
		or contains(entry.adapter, query)
		or contains(entry.adapter_label, query)
		or contains(entry.status, query)
		or contains(entry.source, query)
		or contains(entry.binary, query)
		or contains(entry.path, query)
		or contains(entry.realpath, query)
end

local function filtered_entries(entries, query)
	if query == "" then
		return entries
	end
	local filtered = {}
	for _, entry in ipairs(entries) do
		if matches_query(entry, query) then
			filtered[#filtered + 1] = entry
		end
	end
	return filtered
end

local function add_search_extmarks(output, first_line, last_line, query)
	if query == "" then
		return
	end
	local needle = query:lower()
	for line_number = first_line, last_line do
		local line = output.lines[line_number]
		local lower = line:lower()
		local start = 1
		while true do
			local match_start, match_end = lower:find(needle, start, true)
			if not match_start then
				break
			end
			append_extmark(
				output,
				line_number - 1,
				match_start - 1,
				line:sub(match_start, match_end),
				"MusterSearchMatch"
			)
			start = match_end + 1
		end
	end
end

local function safe_messages(messages)
	local result = {}
	if type(messages) ~= "table" then
		return result
	end
	for _, message in ipairs(messages) do
		result[#result + 1] = normalize_display(message, MAX_DISPLAY_CELLS)
	end
	return result
end

local function render_message(output, width, kind, prefix, message, highlight)
	local line = add_line(output, width, { { prefix, highlight }, { message, highlight } })
	output.row_by_line[line] = { kind = kind }
end

local function render_footer(output, width, hints)
	local first_line = #output.lines + 1
	local segments = {}
	local line_width = 0
	local function flush()
		if #segments == 0 then
			return
		end
		add_centered_line(output, width, segments)
		segments = {}
		line_width = 0
	end
	local function wrap(item)
		flush()
		local wrapped = {}
		local wrapped_width = 0
		for _, segment in ipairs(item) do
			local remainder = segment[1]
			while remainder ~= "" do
				if wrapped_width == width then
					add_centered_line(output, width, wrapped)
					wrapped = {}
					wrapped_width = 0
				end
				local chunk
				chunk, remainder = take_display_cells(remainder, width - wrapped_width)
				wrapped[#wrapped + 1] = { chunk, segment[2] }
				wrapped_width = wrapped_width + vim.fn.strdisplaywidth(chunk)
				if remainder ~= "" then
					add_centered_line(output, width, wrapped)
					wrapped = {}
					wrapped_width = 0
				end
			end
		end
		if #wrapped > 0 then
			add_centered_line(output, width, wrapped)
		end
	end

	for _, hint in ipairs(hints) do
		if hint.action == "search" or hint.action == "help" then
			local description = hint.description
			local item = {
				{ hint.key_text, "MusterDetailKey" },
				{ " " .. description, "MusterMuted" },
			}
			local item_width = vim.fn.strdisplaywidth(hint.key_text .. " " .. description)
			if item_width > width then
				wrap(item)
			else
				if #segments > 0 and line_width + 2 + item_width > width then
					flush()
				end
				if #segments > 0 then
					segments[#segments + 1] = { "  " }
					line_width = line_width + 2
				end
				vim.list_extend(segments, item)
				line_width = line_width + item_width
			end
		end
	end
	flush()
	if #output.lines < first_line then
		add_centered_line(output, width, { { "", "MusterMuted" } })
	end
	return first_line
end

local function empty_output(revision)
	return {
		lines = {},
		extmarks = {},
		virtual_text = {},
		row_by_line = {},
		line_by_key = {},
		anchors = {},
		revision = revision,
	}
end

local function render_help(output, width, ui, hints)
	output.anchors.help = add_centered_line(output, width, { { ui.labels.help, "MusterHeader" } })
	for _, section in ipairs({ "Navigation", "Rows", "Inspection", "Closing" }) do
		add_line(output, width, { { section, "MusterDetailKey" } })
		if section == "Closing" then
			add_line(output, width, {
				{ "  " },
				{ "q/<Esc>", "MusterDetailKey" },
				{ "  close Help" },
			})
		end
		for _, hint in ipairs(hints) do
			if hint.section == section then
				add_line(output, width, {
					{ "  " },
					{ hint.key_text, "MusterDetailKey" },
					{ "  " },
					{ hint.description },
				})
			end
		end
	end
end

---@param state muster.UiRenderState
---@param width integer
---@return muster.UiRender
function M.help(state, width)
	width = math.max(1, math.floor(width))
	local ui = safe_ui(state.ui)
	local output = empty_output(state.revision)
	render_help(output, width, ui, action_hints(ui))
	return output
end

---@param state muster.UiRenderState
---@param width integer
---@return muster.UiRender
function M.render(state, width)
	width = math.max(1, math.floor(width))
	local ui = safe_ui(state.ui)
	local versions = type(state.versions) == "table" and state.versions or {}
	local active, all = sorted_active_and_all(state.view, versions, ui)
	local issues = issue_entries(all)
	local diagnostics = safe_messages(state.view.diagnostics)
	local notes = safe_messages(state.view.notes)
	local source_error = safe_optional(state.source_error, MAX_DISPLAY_CELLS)
	local query = normalize_display(state.query, QUERY_BYTES, QUERY_BYTES)
	local issue_count = #issues + #diagnostics + #notes + (state.source_error ~= nil and 1 or 0)
	local counts = { active = #active, all = #all, issues = issue_count }
	local output = empty_output(state.revision)

	local filetype = normalize_display(state.view.filetype, MAX_DISPLAY_CELLS)
	local bufnr = format_buffer_number(state.view.bufnr)
	output.anchors.title = add_centered_line(output, width, {
		{ ui.labels.title, "MusterHeader" },
	})
	output.anchors.context = add_centered_line(output, width, {
		{ filetype, "MusterMuted" },
		{ "  •  buf " },
		{ bufnr, "MusterMuted" },
	})

	output.anchors.tabs = render_tabs(output, width, state.tab, ui.labels.tabs, counts)
	output.anchors.body = #output.lines + 1
	local hints = action_hints(ui)

	local entries
	if state.tab == "active" then
		entries = active
	elseif state.tab == "issues" then
		entries = issues
	else
		entries = all
	end
	entries = filtered_entries(entries, query)

	local show_messages = state.tab == "issues"
	local message_count = #diagnostics + #notes + (source_error and 1 or 0)
	local margin = table_side_margin(width)
	local columns = wide_columns(entries, state.expanded_key, ui, width, margin)
	if #entries == 0 then
		local empty
		if state.tab == "issues" then
			if issue_count == 0 then
				empty = ui.labels.no_issues
			elseif query ~= "" then
				empty = ui.labels.no_matches
			end
		elseif query ~= "" then
			empty = ui.labels.no_matches
		else
			empty = ui.labels.empty
		end
		if empty ~= nil then
			add_line(output, width, { { empty, "MusterMuted" } })
		end
	end
	if columns and #entries > 0 then
		render_wide_header(output, width, columns, ui)
	end
	for _, entry in ipairs(entries) do
		local first_line = #output.lines + 1
		if columns then
			render_wide_row(output, width, columns, entry, state, ui)
		else
			render_compact_row(output, width, margin, entry, state, ui, query ~= "")
		end
		if entry.key == state.expanded_key then
			render_details(output, width, margin, entry, ui)
		end
		add_search_extmarks(output, first_line, #output.lines, query)
	end

	if show_messages and message_count > 0 then
		for _, message in ipairs(diagnostics) do
			render_message(output, width, "diagnostic", "! ", message, "MusterStatusBroken")
		end
		for _, message in ipairs(notes) do
			render_message(output, width, "note", "note: ", message, "MusterMuted")
		end
		if source_error then
			render_message(output, width, "diagnostic", "! ", source_error, "MusterStatusBroken")
		end
	end

	output.anchors.footer = render_footer(output, width, hints)
	return output
end

return M
