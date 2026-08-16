---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")
local render = require("muster.ui.render")

local function entry(adapter, name, status, opts)
	opts = opts or {}
	local probe = vim.tbl_extend("force", { status = status }, opts.probe or {})
	return {
		adapter = adapter,
		name = name,
		declared = opts.declared ~= false,
		probe = probe,
		advice = opts.advice or {},
	}
end

local function fixture_view()
	return {
		bufnr = 12,
		filetype = "lua",
		active = {
			entry("lsp", "lua_ls", "found", {
				probe = {
					binary = "lua-language-server",
					path = "/mason/bin/lua-language-server",
					realpath = "/mason/packages/lua-language-server/bin/lua-language-server",
					source = "mason",
				},
				advice = {
					{
						provider = "mason",
						action = "install",
						package = "lua-language-server",
						command = ":MasonInstall lua-language-server",
						eligible = true,
					},
				},
			}),
			entry("conform", "stylua", "found", {
				declared = false,
				probe = { binary = "stylua", path = "/nix/bin/stylua", source = "nix" },
			}),
		},
		other = {
			entry("nvim_lint", "selene", "missing", {
				probe = { binary = "selene", reason = "not on PATH" },
				advice = {
					{
						provider = "nix",
						action = "declare",
						package = "selene",
						command = "nix profile install nixpkgs#selene",
						eligible = false,
						reason = "manual declaration required",
					},
				},
			}),
			entry("dap", "codelldb", "broken", { probe = { reason = "adapter raised" } }),
			entry("lsp", "pyright", "unknown", { probe = { reason = "not recognised" } }),
			entry("conform", "shfmt", "unverifiable", { probe = { reason = "buffer required" } }),
			entry("lsp", "rust_analyzer", "found", {
				probe = { binary = "rust-analyzer", path = "/usr/bin/rust-analyzer", source = "system" },
			}),
		},
		diagnostics = { "live adapter diagnostic" },
		notes = { "mason PATH note" },
	}
end

local function state_for(tab, view)
	return {
		view = view or fixture_view(),
		ui = config.ui(),
		tab = tab or "all",
		query = "",
		showing_help = false,
		expanded_key = "lsp\0lua_ls",
		versions = {
			["lsp\0lua_ls"] = { value = "3.14.0", tier = 1 },
			["conform\0stylua"] = { value = "0.20.0", tier = 2 },
			["lsp\0rust_analyzer"] = { reason = "spawn failed", tier = 4 },
		},
		source_error = "source buffer error",
		revision = 7,
	}
end

local function output_text(output)
	return table.concat(output.lines, "\n")
end

local function expected_table_margin(width)
	local available = math.max(0, math.floor((width - 2) / 2))
	local preferred = math.min(32, math.max(8, math.floor(width * 0.2)))
	return math.min(available, preferred)
end

local function leading_spaces(line)
	return #line - #line:gsub("^ +", "")
end

local function assert_table_margins(line, width)
	local margin = expected_table_margin(width)
	assert.equals(margin, leading_spaces(line))
	assert.equals(margin, width - vim.fn.strdisplaywidth(line))
end

local function assert_centered(line, width)
	local content = line:gsub("^ +", "")
	local padding = #line - #content
	assert.equals(math.floor((width - vim.fn.strdisplaywidth(content)) / 2), padding)
end

local function assert_ranges(output, width)
	assert.is_true(#output.lines > 0)
	for _, line in ipairs(output.lines) do
		assert.is_true(vim.fn.strdisplaywidth(line) <= width, ("line exceeds width %d: %q"):format(width, line))
	end
	for _, mark in ipairs(output.extmarks) do
		assert.is_number(mark.line)
		assert.is_number(mark.col)
		assert.is_true(mark.line >= 0 and mark.line < #output.lines)
		local line = output.lines[mark.line + 1]
		assert.is_true(mark.col >= 0 and mark.col <= #line)
		if mark.opts.end_col ~= nil then
			assert.is_true(mark.opts.end_col >= mark.col and mark.opts.end_col <= #line)
		end
	end
	for _, virtual in ipairs(output.virtual_text) do
		assert.is_true(virtual.line >= 0 and virtual.line < #output.lines)
		assert.is_true(virtual.pos == nil or virtual.pos == "eol" or virtual.pos == "right_align")
		for _, chunk in ipairs(virtual.chunks) do
			assert.is_string(chunk[1])
			assert.is_string(chunk[2])
		end
	end
	for _, line in pairs(output.anchors) do
		assert.is_true(line >= 1 and line <= #output.lines)
	end
	for line, row in pairs(output.row_by_line) do
		assert.is_true(line >= 1 and line <= #output.lines)
		assert.is_table(row)
	end
	for _, line in pairs(output.line_by_key) do
		assert.is_true(line >= 1 and line <= #output.lines)
	end
end

local function assert_plain(value, seen)
	if type(value) ~= "table" then
		return
	end
	seen = seen or {}
	if seen[value] then
		return
	end
	seen[value] = true
	assert.is_nil(getmetatable(value))
	for key, child in pairs(value) do
		assert_plain(key, seen)
		assert_plain(child, seen)
	end
end

local function render_without_mutation(state, width, render_fn)
	local names = {
		"nvim_create_buf",
		"nvim_open_win",
		"nvim_win_set_config",
		"nvim_buf_set_lines",
		"nvim_buf_clear_namespace",
		"nvim_buf_set_extmark",
		"nvim_buf_add_highlight",
		"nvim_set_hl",
		"nvim_create_autocmd",
	}
	local saved = {}
	local called = {}
	for _, name in ipairs(names) do
		saved[name] = vim.api[name]
		vim.api[name] = function()
			called[name] = true
			error("mutation trap: " .. name)
		end
	end
	local ok, result = xpcall(function()
		return (render_fn or render.render)(state, width)
	end, debug.traceback)
	for _, name in ipairs(names) do
		vim.api[name] = saved[name]
	end
	assert.is_true(ok, result)
	assert.same({}, called)
	assert_plain(result)
	assert.equals(state.revision, result.revision)
	return result
end

local function visible_strings(output)
	local strings = {}
	for _, line in ipairs(output.lines) do
		strings[#strings + 1] = line
	end
	strings[#strings + 1] = table.concat(output.lines)
	for _, mark in ipairs(output.extmarks) do
		for _, value in pairs(mark.opts) do
			if type(value) == "string" then
				strings[#strings + 1] = value
			end
		end
	end
	for _, virtual in ipairs(output.virtual_text) do
		for _, chunk in ipairs(virtual.chunks) do
			strings[#strings + 1] = chunk[1]
			strings[#strings + 1] = chunk[2]
		end
	end
	return strings
end

local function assert_not_visible(output, raw)
	if type(raw) ~= "string" or raw == "" then
		return
	end
	for _, value in ipairs(visible_strings(output)) do
		assert.is_nil(value:find(raw, 1, true), ("raw value leaked into %q"):format(value))
	end
end

local function visible_text(output)
	return table.concat(visible_strings(output), "\n")
end

local function assert_visible(output, expected, context)
	assert.is_truthy(visible_text(output):find(expected, 1, true), context or ("expected visible %q"):format(expected))
end

local function display_start(line, needle)
	local byte = assert(line:find(needle, 1, true), "missing column value " .. needle)
	return vim.fn.strdisplaywidth(line:sub(1, byte - 1))
end

local function assert_scalar_metadata(value, seen)
	local kind = type(value)
	assert.is_true(kind == "nil" or kind == "table" or kind == "string" or kind == "number" or kind == "boolean")
	if kind ~= "table" then
		return
	end
	seen = seen or {}
	if seen[value] then
		return
	end
	seen[value] = true
	assert.is_nil(getmetatable(value))
	for key, child in pairs(value) do
		assert_scalar_metadata(key, seen)
		assert_scalar_metadata(child, seen)
	end
end

local function row_line(output, key)
	local line = output.line_by_key[key]
	assert.is_number(line, "expected row " .. key)
	return line
end

local function empty_view()
	return { bufnr = 1, filetype = "", active = {}, other = {}, diagnostics = {}, notes = {} }
end

local function reviewer_state()
	local view = {
		bufnr = 12,
		filetype = "lua",
		active = {},
		other = {
			entry("custom", "tool", "missing", {
				probe = {
					binary = "binary",
					path = "/raw/path",
					realpath = "/real/path",
					source = "source",
					reason = "probe reason",
				},
				advice = {
					{
						provider = "provider",
						action = "action",
						package = "package",
						command = "command",
						eligible = false,
						reason = "advice reason",
					},
				},
			}),
			entry("custom", "versioned", "found", { probe = { path = "/versioned" } }),
			entry("custom", "pending", "found", { probe = { path = "/pending" } }),
			entry("custom", "unknown", "unknown"),
			entry("custom", "broken", "broken"),
			entry("custom", "unverifiable", "unverifiable"),
			entry("custom", "discovered", "found", { declared = false, probe = { path = "/live" } }),
		},
		diagnostics = { "diagnostic" },
		notes = { "note" },
	}
	local state = state_for("all", view)
	state.expanded_key = "custom\0tool"
	state.versions = {
		["custom\0versioned"] = { value = "version", reason = "version reason", tier = 4 },
	}
	return state
end

local function force_compact(state)
	for key in pairs(state.ui.labels.columns) do
		state.ui.labels.columns[key] = string.rep(key:sub(1, 1), 128)
	end
end

local function general_display_fields()
	return {
		{
			"tool name",
			function(s, v)
				s.view.other[1].name = v
			end,
		},
		{
			"adapter",
			function(s, v)
				s.view.other[1].adapter = v
				s.view.other[1].probe.status = string.rep("s", 512)
				force_compact(s)
			end,
			compact = true,
		},
		{
			"probe status",
			function(s, v)
				s.view.other[1].probe.status = v
				s.view.other[1].name = ""
				force_compact(s)
			end,
			compact = true,
		},
		{
			"probe binary",
			function(s, v)
				s.view.other[1].probe.binary = v
			end,
		},
		{
			"probe path",
			function(s, v)
				s.view.other[1].probe.path = v
			end,
		},
		{
			"probe realpath",
			function(s, v)
				s.view.other[1].probe.realpath = v
			end,
		},
		{
			"probe source",
			function(s, v)
				s.view.other[1].probe.source = v
			end,
		},
		{
			"probe reason",
			function(s, v)
				s.view.other[1].probe.reason = v
			end,
		},
		{
			"filetype",
			function(s, v)
				s.view.filetype = v
			end,
		},
		{
			"version value",
			function(s, v)
				s.versions["custom\0versioned"].value = v
				s.view.other[1].probe.status = string.rep("s", 512)
				force_compact(s)
			end,
			compact = true,
		},
		{
			"version reason",
			function(s, v)
				s.versions["custom\0versioned"].reason = v
				s.expanded_key = "custom\0versioned"
			end,
		},
		{
			"advice provider",
			function(s, v)
				s.view.other[1].advice[1].provider = v
			end,
		},
		{
			"advice action",
			function(s, v)
				s.view.other[1].advice[1].action = v
			end,
		},
		{
			"advice package",
			function(s, v)
				s.view.other[1].advice[1].package = v
			end,
		},
		{
			"advice command",
			function(s, v)
				s.view.other[1].advice[1].command = v
			end,
		},
		{
			"advice reason",
			function(s, v)
				s.view.other[1].advice[1].reason = v
			end,
		},
		{
			"diagnostic",
			function(s, v)
				s.view.diagnostics[1] = v
				s.tab = "issues"
			end,
		},
		{
			"note",
			function(s, v)
				s.view.notes[1] = v
				s.tab = "issues"
			end,
		},
		{
			"source error",
			function(s, v)
				s.source_error = v
				s.tab = "issues"
			end,
		},
	}
end

local function label_display_fields()
	return {
		{
			"title",
			function(s, v)
				s.ui.labels.title = v
			end,
		},
		{
			"active tab",
			function(s, v)
				s.ui.labels.tabs.active = v
			end,
		},
		{
			"all tab",
			function(s, v)
				s.ui.labels.tabs.all = v
			end,
		},
		{
			"issues tab",
			function(s, v)
				s.ui.labels.tabs.issues = v
			end,
		},
		{
			"adapter label",
			function(s, v)
				s.ui.labels.adapters.custom = v
				force_compact(s)
			end,
			width = 500,
		},
		{
			"status column",
			function(s, v)
				s.ui.labels.columns.status = v
			end,
		},
		{
			"tool column",
			function(s, v)
				s.ui.labels.columns.tool = v
			end,
		},
		{
			"adapter column",
			function(s, v)
				s.ui.labels.columns.adapter = v
			end,
		},
		{
			"version column",
			function(s, v)
				s.ui.labels.columns.version = v
			end,
		},
		{
			"source detail",
			function(s, v)
				s.ui.labels.details.source = v
			end,
		},
		{
			"executable detail",
			function(s, v)
				s.ui.labels.details.executable = v
			end,
		},
		{
			"path detail",
			function(s, v)
				s.ui.labels.details.path = v
			end,
		},
		{
			"realpath detail",
			function(s, v)
				s.ui.labels.details.realpath = v
			end,
		},
		{
			"reason detail",
			function(s, v)
				s.ui.labels.details.reason = v
			end,
		},
		{
			"advice detail",
			function(s, v)
				s.ui.labels.details.advice = v
			end,
		},
		{
			"empty",
			function(s, v)
				s.ui.labels.empty = v
				s.view = empty_view()
				s.source_error = nil
			end,
		},
		{
			"no matches",
			function(s, v)
				s.ui.labels.no_matches = v
				s.query = "absent"
			end,
		},
		{
			"no issues",
			function(s, v)
				s.ui.labels.no_issues = v
				s.view = empty_view()
				s.source_error = nil
				s.tab = "issues"
			end,
		},
		{
			"search prompt",
			function(s, v)
				s.ui.labels.search_prompt = v
			end,
		},
		{
			"help",
			function(s, v)
				s.ui.labels.help = v
			end,
		},
	}
end

local function icon_display_fields()
	local fields = {}
	for _, icon in ipairs({
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
		local key = icon
		fields[#fields + 1] = {
			key,
			function(state, value)
				state.ui.icons[key] = value
				force_compact(state)
			end,
		}
	end
	return fields
end

describe("muster.ui.render", function()
	before_each(function()
		config.reset()
		config.setup({})
	end)

	it("renders title, tabs, counts, compact rows, details, footer, and revisioned metadata", function()
		local output = render.render(state_for("all"), 100)
		local text = output_text(output)
		assert.is_truthy(text:find("muster.nvim", 1, true))
		assert.is_truthy(text:find("buf 12", 1, true))
		assert.is_nil(text:find("<invalid:number>", 1, true))
		assert.is_truthy(text:find("Active (2)", 1, true))
		assert.is_truthy(text:find("All (7)", 1, true))
		assert.is_truthy(text:find("Issues (7)", 1, true))
		assert.is_truthy(text:find("lua_ls", 1, true))
		assert.is_truthy(text:find("3.14.0", 1, true))
		assert.is_truthy(text:find("source", 1, true))
		assert.is_truthy(text:find("/mason/bin/lua-language-server", 1, true))
		local line = output.line_by_key["lsp\0lua_ls"]
		assert.equals("lsp\0lua_ls", output.row_by_line[line].key)
		assert.equals(fixture_view().active[1].probe.path, output.row_by_line[line].entry.probe.path)
		assert.equals(7, output.revision)
		assert_ranges(output, 100)
	end)

	it("centers the two-line header and tabs and limits the footer to highlighted search and help", function()
		for _, width in ipairs({ 100, 36 }) do
			local output = render.render(state_for("all"), width)
			assert.equals("muster.nvim", vim.trim(output.lines[output.anchors.title]))
			assert.equals("lua  •  buf 12", vim.trim(output.lines[output.anchors.context]))
			assert_centered(output.lines[output.anchors.title], width)
			assert_centered(output.lines[output.anchors.context], width)
			for line = output.anchors.tabs, output.anchors.body - 1 do
				assert_centered(output.lines[line], width)
			end
		end

		local width = 50
		local footer_state = state_for("all")
		footer_state.query = "active-query-must-not-change-footer"
		local output = render.render(footer_state, width)
		local footer_lines = vim.list_slice(output.lines, output.anchors.footer)
		local footer = table.concat(footer_lines, "\n")
		assert.equals(1, #footer_lines)
		assert.equals("/ Muster search:   ? Help", vim.trim(footer_lines[1]))
		assert_centered(footer_lines[1], width)
		for _, hidden in ipairs({ "close", "refresh", "copy path", "Active tab", "details" }) do
			assert.is_nil(footer:find(hidden, 1, true), "footer includes nonessential hint " .. hidden)
		end
		local highlighted_keys = {}
		for _, mark in ipairs(output.extmarks) do
			if mark.line == output.anchors.footer - 1 and mark.opts.hl_group == "MusterDetailKey" then
				local line = output.lines[mark.line + 1]
				highlighted_keys[#highlighted_keys + 1] = line:sub(mark.col + 1, mark.opts.end_col)
			end
		end
		assert.same({ "/", "?" }, highlighted_keys)
		assert_ranges(output, width)

		local overwide_state = state_for("all")
		for action in pairs(overwide_state.ui.keymaps) do
			overwide_state.ui.keymaps[action] = false
		end
		local key = string.rep("界", 16)
		overwide_state.ui.keymaps.search = key
		local overwide = render.render(overwide_state, 10)
		local overwide_lines = vim.list_slice(overwide.lines, overwide.anchors.footer)
		assert.equals((key .. "Mustersearch:"):gsub("%s", ""), table.concat(overwide_lines):gsub("%s", ""))
		for _, line in ipairs(overwide_lines) do
			assert_centered(line, 10)
		end
		assert_ranges(overwide, 10)
	end)

	it("renders Active from active rows only and All from an active-first deduplicated union", function()
		local view = fixture_view()
		view.other[#view.other + 1] = entry("lsp", "lua_ls", "missing", { probe = { path = "/losing/path" } })
		local active = render.render(state_for("active", view), 100)
		assert.equals(2, vim.tbl_count(active.line_by_key))
		assert.is_number(active.line_by_key["lsp\0lua_ls"])
		assert.is_nil(active.line_by_key["nvim_lint\0selene"])

		local all = render.render(state_for("all", view), 100)
		assert.equals(7, vim.tbl_count(all.line_by_key))
		local winner = all.row_by_line[all.line_by_key["lsp\0lua_ls"]].entry
		assert.equals("found", winner.probe.status)
		assert.equals("/mason/bin/lua-language-server", winner.probe.path)
	end)

	it("orders issue entries by severity and includes diagnostics, notes, and one source error", function()
		local output = render.render(state_for("issues"), 100)
		local broken = row_line(output, "dap\0codelldb")
		local unknown = row_line(output, "lsp\0pyright")
		local unverifiable = row_line(output, "conform\0shfmt")
		local missing = row_line(output, "nvim_lint\0selene")
		assert.is_true(broken < unknown)
		assert.is_true(unknown < unverifiable)
		assert.is_true(unverifiable < missing)
		assert.equals(4, vim.tbl_count(output.line_by_key))
		local diagnostics = 0
		local notes = 0
		for _, row in pairs(output.row_by_line) do
			if row.kind == "diagnostic" then
				diagnostics = diagnostics + 1
			elseif row.kind == "note" then
				notes = notes + 1
			end
		end
		assert.equals(2, diagnostics)
		assert.equals(1, notes)
		local text = output_text(output)
		assert.is_truthy(text:find("live adapter diagnostic", 1, true))
		assert.is_truthy(text:find("mason PATH note", 1, true))
		assert.is_truthy(text:find("source buffer error", 1, true))
	end)

	it("computes tab counts from the unfiltered underlying view", function()
		local state = state_for("all")
		state.query = "lua_ls"
		local output = render.render(state, 100)
		local text = output_text(output)
		assert.is_truthy(text:find("Active (2)", 1, true))
		assert.is_truthy(text:find("All (7)", 1, true))
		assert.is_truthy(text:find("Issues (7)", 1, true))
	end)

	it("filters case-insensitively across each normalized search field without changing metadata", function()
		local cases = {
			{
				name = "tool name",
				apply = function(_, target)
					target.name = "tool-needle"
				end,
			},
			{
				name = "adapter ID",
				apply = function(state, target)
					target.adapter = "adapter-needle"
					state.ui.labels.adapters[target.adapter] = "Adapter"
				end,
			},
			{
				name = "adapter display label",
				apply = function(state, target)
					state.ui.labels.adapters[target.adapter] = "Display Needle"
				end,
			},
			{
				name = "probe status",
				apply = function(_, target)
					target.probe.status = "status-needle"
				end,
			},
			{
				name = "source",
				apply = function(_, target)
					target.probe.source = "source-needle"
				end,
			},
			{
				name = "executable",
				apply = function(_, target)
					target.probe.binary = "binary-needle"
				end,
			},
			{
				name = "path",
				apply = function(_, target)
					target.probe.path = "/path/needle"
				end,
			},
			{
				name = "realpath",
				apply = function(_, target)
					target.probe.realpath = "/real/needle"
				end,
			},
		}

		for _, case in ipairs(cases) do
			local target = entry("target", "matching", "found", {
				probe = {
					binary = "binary",
					path = "/path",
					realpath = "/realpath",
					source = "source",
				},
			})
			local other = entry("other", "nonmatching", "found", {
				probe = {
					binary = "executable",
					path = "/elsewhere",
					realpath = "/canonical",
					source = "system",
				},
			})
			local view = empty_view()
			view.other = { target, other }
			local state = state_for("all", view)
			case.apply(state, target)
			local key = target.adapter .. "\0" .. target.name
			state.expanded_key = key
			state.query = "NEEDLE"

			local unfiltered_state = vim.deepcopy(state)
			unfiltered_state.query = ""
			local unfiltered = render.render(unfiltered_state, 160)
			local filtered = render.render(state, 160)
			assert.equals(7, unfiltered.revision, case.name)
			assert.equals(7, filtered.revision, case.name)
			assert.equals(1, vim.tbl_count(filtered.line_by_key), case.name)
			assert.equals(1, vim.tbl_count(filtered.row_by_line), case.name)
			local line = filtered.line_by_key[key]
			assert.is_number(line, case.name)
			assert.same(target, filtered.row_by_line[line].entry, case.name)
			assert_plain(filtered.row_by_line)
			assert.is_nil(filtered.line_by_key[other.adapter .. "\0" .. other.name], case.name)
		end
	end)

	it("matches normalized controls and literal Lua metacharacters without display bypass", function()
		local control = entry("custom", "control", "found", { probe = { path = "/tmp/raw\npath" } })
		local literal = entry("custom", "tool%[.^$*+-?", "found", { probe = { path = "/literal" } })
		local view = empty_view()
		view.other = { control, literal }

		local control_state = state_for("all", view)
		control_state.expanded_key = "custom\0control"
		control_state.query = "<lf>"
		local normalized = render.render(control_state, 160)
		assert.is_number(normalized.line_by_key["custom\0control"])
		assert.is_nil(normalized.line_by_key["custom\0tool%[.^$*+-?"])
		assert.equals(
			"/tmp/raw\npath",
			normalized.row_by_line[normalized.line_by_key["custom\0control"]].entry.probe.path
		)
		assert_visible(normalized, "/tmp/raw<LF>path")
		assert_not_visible(normalized, "/tmp/raw\npath")

		local literal_state = state_for("all", view)
		literal_state.expanded_key = nil
		literal_state.query = "%[.^$*+-?"
		local literal_output = render.render(literal_state, 160)
		assert.is_number(literal_output.line_by_key["custom\0tool%[.^$*+-?"])
		assert.is_nil(literal_output.line_by_key["custom\0control"])
	end)

	it("matches invalid markers without invoking hostile __tostring metamethods", function()
		local hostile = setmetatable({}, {
			__tostring = function()
				error("search must not stringify hostile values")
			end,
		})
		local target = entry("custom", "hostile", "found", { probe = { source = hostile } })
		local other = entry("custom", "other", "found", { probe = { source = "safe" } })
		local view = empty_view()
		view.other = { target, other }
		local state = state_for("all", view)
		state.query = "<INVALID:TABLE>"
		state.expanded_key = "custom\0hostile"
		local ok, output = pcall(render.render, state, 160)
		assert.is_true(ok, output)
		assert.is_number(output.line_by_key["custom\0hostile"])
		assert.is_nil(output.line_by_key["custom\0other"])
		assert_visible(output, "<invalid:table>")
		assert.is_nil(output.row_by_line[output.line_by_key["custom\0hostile"]].entry.probe.source)
	end)

	it("isolates filtering to the selected tab and keeps unfiltered pill counts", function()
		local active = entry("custom", "active-only", "found")
		local all_only = entry("custom", "all-needle", "missing")
		local view = empty_view()
		view.active = { active }
		view.other = { all_only }

		local state = state_for("active", view)
		state.source_error = nil
		local baseline = output_text(render.render(state, 120))
		state.query = "needle"
		local filtered = render.render(state, 120)
		local text = output_text(filtered)
		assert.same({}, filtered.line_by_key)
		assert.same({}, filtered.row_by_line)
		assert.is_truthy(text:find(state.ui.labels.no_matches, 1, true))
		for _, pill in ipairs({ "Active (1)", "All (2)", "Issues (1)" }) do
			assert.is_truthy(baseline:find(pill, 1, true))
			assert.is_truthy(text:find(pill, 1, true))
		end
	end)

	it("renders the configured no-match state and no entry metadata when search has no match", function()
		local state = state_for("all")
		state.ui.labels.no_matches = "NO FILTER RESULTS"
		state.query = "absent-search-token"
		local output = render.render(state, 120)
		assert_visible(output, "NO FILTER RESULTS")
		assert.same({}, output.line_by_key)
		assert.same({}, output.row_by_line)
		assert.equals(state.revision, output.revision)
	end)

	it("keeps issue messages unfiltered and distinguishes no matches from no issues", function()
		local state = state_for("issues")
		state.ui.labels.no_matches = "NO MATCHES"
		state.ui.labels.no_issues = "NO ISSUES"
		state.query = "absent-search-token"
		local output = render.render(state, 120)
		assert_visible(output, "NO MATCHES")
		assert_visible(output, "live adapter diagnostic")
		assert_visible(output, "mason PATH note")
		assert_visible(output, "source buffer error")
		assert.is_nil(output_text(output):find("NO ISSUES", 1, true))
		assert.same({}, output.line_by_key)

		local issue_free = state_for("issues", empty_view())
		issue_free.ui.labels.no_matches = "NO MATCHES"
		issue_free.ui.labels.no_issues = "NO ISSUES"
		issue_free.source_error = nil
		issue_free.query = "absent-search-token"
		local clean = render.render(issue_free, 120)
		assert_visible(clean, "NO ISSUES")
		assert.is_nil(output_text(clean):find("NO MATCHES", 1, true))
	end)

	it("emits byte-accurate search extmarks only for visible matching text", function()
		local target = entry("custom", "NeedleTool", "found", {
			probe = { path = "/tmp/needle/path", realpath = "/canonical/NEEDLE" },
		})
		local view = empty_view()
		view.other = { target, entry("custom", "other", "found", { probe = { path = "/other" } }) }
		local state = state_for("all", view)
		state.query = "nEeDlE"
		state.expanded_key = "custom\0NeedleTool"
		local output = render.render(state, 180)
		local matches = 0
		for _, mark in ipairs(output.extmarks) do
			if mark.opts.hl_group == "MusterSearchMatch" then
				matches = matches + 1
				assert.is_true(mark.line >= 0 and mark.line < #output.lines)
				assert.is_true(mark.line + 1 ~= output.anchors.footer)
				local line = output.lines[mark.line + 1]
				assert.equals("needle", line:sub(mark.col + 1, mark.opts.end_col):lower())
			end
		end
		assert.is_true(matches >= 3)
		assert_ranges(output, 180)
	end)

	it("caps the normalized query at 256 display cells and treats capped metacharacters literally", function()
		local capped = string.rep("q", 255) .. "…"
		local target = entry("custom", capped, "found")
		local view = empty_view()
		view.other = { target, entry("custom", "other", "found") }
		local state = state_for("all", view)
		state.query = string.rep("q", 256) .. ".^$%[]*+-?"
		state.expanded_key = nil
		local output = render.render(state, 700)
		assert.is_number(output.line_by_key["custom\0" .. capped])
		assert.is_nil(output.line_by_key["custom\0other"])
		assert_visible(output, capped)
		assert_not_visible(output, string.rep("q", 256))
	end)

	it("generates complete help and only essential footer hints", function()
		local state = state_for("all")
		state.ui.labels.title = "Configured Dashboard"
		state.ui.labels.tabs.active = "Active Tools"
		state.ui.labels.tabs.all = "Every Tool"
		state.ui.labels.tabs.issues = "Problems"
		state.ui.labels.search_prompt = "Find: "
		state.ui.labels.help = "Configured Help"
		state.ui.keymaps.close = { "Q", "<Esc>" }
		state.ui.keymaps.details = "D"
		state.ui.keymaps.refresh = false

		local normal = render.render(state, 1000)
		state.showing_help = true
		local main = render.render(state, 1000)
		local help = render.help(state, 800)
		local help_text = output_text(help)
		assert.is_truthy(output_text(main):find("lua_ls", 1, true))
		assert.equals(state.revision, normal.revision)
		assert.equals(state.revision, help.revision)
		for _, label in ipairs({
			"Active Tools",
			"Every Tool",
			"Problems",
			"Configured Help",
		}) do
			assert.is_truthy(help_text:find(label, 1, true), "missing configured label " .. label)
		end
		for _, section in ipairs({ "Navigation", "Rows", "Inspection", "Closing" }) do
			assert.is_truthy(help_text:find(section, 1, true), "missing help section " .. section)
		end
		assert.equals("/ Find:   ? Configured Help", vim.trim(normal.lines[normal.anchors.footer]))
		for _, hint in ipairs({
			"q/<Esc>  close Help",
			"Q/<Esc>  close dashboard",
			"1  Active Tools tab",
			"2  Every Tool tab",
			"3  Problems tab",
			"<Tab>  next tab",
			"<S-Tab>  previous tab",
			"D  details",
			"/  Find: ",
			"?  Configured Help",
			"y  copy path",
		}) do
			assert.is_truthy(help_text:find(hint, 1, true), "help missing enabled hint " .. hint)
		end
		assert.is_nil(help_text:find("<CR>", 1, true))
		assert.is_nil(help_text:find("r  refresh", 1, true))
		assert.is_nil(help_text:find("lua_ls", 1, true))
		assert.is_nil(help_text:find("/mason/bin/lua-language-server", 1, true))
		assert.is_nil(help_text:find(state.ui.labels.empty, 1, true))
		assert.same({}, help.row_by_line)
		assert.same({}, help.line_by_key)
		assert.is_nil(help.anchors["lsp\0lua_ls"])
		for _, anchor in pairs(help.anchors) do
			assert.is_number(anchor)
		end
	end)

	it("shows the complete accepted 64-byte keymap source in footer and help hints", function()
		local state = state_for("all")
		local source = ("<F1>"):rep(16)
		assert.equals(64, #source)
		state.ui.keymaps.search = source
		local footer = output_text(render.render(state, 1000))
		assert.is_truthy(footer:find(source .. " Muster search: ", 1, true))
		local help = output_text(render.help(state, 1000))
		assert.is_truthy(help:find(source .. "  Muster search: ", 1, true))
	end)

	it("falls back to normalized status text when configured status icons are empty", function()
		local view = empty_view()
		for _, status in ipairs({ "found", "missing", "unknown", "broken", "unverifiable" }) do
			view.other[#view.other + 1] = entry("custom", status .. "-tool", status)
		end
		local state = state_for("all", view)
		state.expanded_key = nil
		state.source_error = nil
		state.versions = {}
		for _, status in ipairs({ "found", "missing", "unknown", "broken", "unverifiable" }) do
			state.ui.icons[status] = ""
		end
		local output = render.render(state, 120)
		for _, status in ipairs({ "found", "missing", "unknown", "broken", "unverifiable" }) do
			local line = output.lines[row_line(output, "custom\0" .. status .. "-tool")]
			assert.is_truthy(line:find(status, 1, true), status .. " lost its textual fallback")
		end
	end)

	it("keeps textual status fallbacks inside wide status cells and selects compact when they do not fit", function()
		local fixtures = {
			{ name = "alpha", status = "found" },
			{ name = "bravo", status = "missing" },
			{ name = "charlie", status = "unknown" },
			{ name = "delta", status = "broken" },
			{ name = "echo", status = "unverifiable" },
		}
		local view = empty_view()
		for _, fixture in ipairs(fixtures) do
			view.other[#view.other + 1] = entry("custom", fixture.name, fixture.status)
		end
		local state = state_for("all", view)
		state.expanded_key = nil
		state.source_error = nil
		state.versions = {}
		state.ui.labels.columns.status = ""
		for _, fixture in ipairs(fixtures) do
			state.ui.icons[fixture.status] = ""
		end

		local wide = render.render(state, 112)
		local header = wide.lines[wide.anchors.body]
		local tool_start = display_start(header, state.ui.labels.columns.tool)
		for _, fixture in ipairs(fixtures) do
			local line = wide.lines[row_line(wide, "custom\0" .. fixture.name)]
			local status_byte = assert(line:find(fixture.status, 1, true), fixture.status .. " fallback was clipped")
			local status_start = vim.fn.strdisplaywidth(line:sub(1, status_byte - 1))
			assert.is_true(status_start < tool_start, fixture.status .. " appeared outside the status cell")
			assert.is_true(display_start(line, fixture.name) >= tool_start, fixture.name .. " escaped the tool cell")
		end

		local compact = render.render(state, 48)
		assert.is_nil(compact.lines[compact.anchors.body]:find(state.ui.labels.columns.tool, 1, true))
		for _, fixture in ipairs(fixtures) do
			local line = compact.lines[row_line(compact, "custom\0" .. fixture.name)]
			assert.is_truthy(line:find(fixture.status, 1, true), fixture.status .. " compact fallback was clipped")
		end
	end)

	it("uses configured empty and no-issues labels for the three unfiltered empty tab states", function()
		config.setup({
			ui = { labels = { empty = "EMPTY TOOLS", no_matches = "NO MATCHES", no_issues = "CLEAN BILL" } },
		})
		for _, tab in ipairs({ "active", "all" }) do
			local state = state_for(tab, empty_view())
			state.ui = config.ui()
			state.source_error = nil
			assert.is_truthy(output_text(render.render(state, 60)):find("EMPTY TOOLS", 1, true))
		end
		local issues = state_for("issues", empty_view())
		issues.ui = config.ui()
		issues.source_error = nil
		local text = output_text(render.render(issues, 60))
		assert.is_truthy(text:find("CLEAN BILL", 1, true))
		assert.is_nil(text:find("EMPTY TOOLS", 1, true))
	end)

	it("marks undeclared live rows, renders explicit provenance, and omits unavailable details", function()
		local state = state_for("active")
		state.expanded_key = "conform\0stylua"
		state.versions["conform\0stylua"] = nil
		local output = render.render(state, 100)
		local line = row_line(output, "conform\0stylua")
		local text = output_text(output)
		assert.is_truthy(output.lines[line]:find(state.ui.icons.discovered, 1, true))
		assert.is_truthy(text:find("discovered live; not declared in setup()", 1, true))
		assert.is_truthy(text:find(state.ui.icons.discovered, 1, true))
		assert.is_nil(text:find(state.ui.labels.details.realpath, 1, true))
		assert.is_nil(text:find(state.ui.labels.details.reason, 1, true))
	end)

	it("sorts copied Active and All rows deterministically without mutating either input", function()
		local view_a = fixture_view()
		local view_b = fixture_view()
		view_b.active = { view_b.active[2], view_b.active[1] }
		view_b.other = { view_b.other[5], view_b.other[3], view_b.other[1], view_b.other[4], view_b.other[2] }
		local before_a = vim.deepcopy(view_a)
		local before_b = vim.deepcopy(view_b)
		for _, tab in ipairs({ "active", "all" }) do
			local a = render.render(state_for(tab, view_a), 100)
			local b = render.render(state_for(tab, view_b), 100)
			assert.same(a.lines, b.lines)
			assert.same(a.virtual_text, b.virtual_text)
			assert.same(a.line_by_key, b.line_by_key)
			assert.same(a.row_by_line, b.row_by_line)
		end
		assert.same(before_a, view_a)
		assert.same(before_b, view_b)
	end)

	it("emits highlights for active tabs, statuses, adapters, versions, and detail keys", function()
		local output = render.render(state_for("all"), 100)
		local groups = {}
		for _, mark in ipairs(output.extmarks) do
			groups[mark.opts.hl_group] = true
		end
		for _, group in ipairs({
			"MusterHeader",
			"MusterTabActive",
			"MusterTabInactive",
			"MusterStatusFound",
			"MusterStatusMissing",
			"MusterStatusBroken",
			"MusterStatusUnknown",
			"MusterStatusUnverifiable",
			"MusterAdapter",
			"MusterVersion",
			"MusterDetailKey",
		}) do
			assert.is_true(groups[group], "missing highlight " .. group)
		end
	end)

	it("renders normal wide and compact layouts and always bounds narrow widths", function()
		for _, width in ipairs({ 100, 60, 36, 2, 1 }) do
			local output = render.render(state_for("all"), width)
			assert_ranges(output, width)
			assert.equals(7, output.revision)
			if width >= 60 then
				assert.is_truthy(output_text(output):find("lua_ls", 1, true))
			end
		end
		local wide = render.render(state_for("all"), 100)
		assert.is_truthy(output_text(wide):find("STATUS", 1, true))
		assert.is_truthy(output_text(wide):find("VERSION", 1, true))
		local compact = render.render(state_for("all"), 36)
		assert.is_true(#compact.virtual_text > 0 or #compact.lines > #wide.lines)
		assert.is_truthy(output_text(render.render(state_for("all"), 1)):find("…", 1, true))
	end)

	it("wraps complete tab pills and uses the same ellipsis only for over-wide pills", function()
		for _, width in ipairs({ 100, 36 }) do
			local text = output_text(render.render(state_for("all"), width))
			assert.is_truthy(text:find("[ Active (2) ]", 1, true))
			assert.is_truthy(text:find("[ All (7) ]", 1, true))
			assert.is_truthy(text:find("[ Issues (7) ]", 1, true))
		end
		local state = state_for("all")
		state.ui.labels.tabs.active = string.rep("a", 128)
		local first = render.render(state, 12)
		local second = render.render(state, 12)
		assert.same(first.lines, second.lines)
		assert.is_truthy(output_text(first):find("…", 1, true))
	end)

	it("aligns wide, compact, and detail rows to adaptive side margins", function()
		local width = 100
		local output = render.render(state_for("all"), width)
		local heading
		for _, line in ipairs(output.lines) do
			if line:find("STATUS", 1, true) and line:find("TOOL", 1, true) then
				heading = line
				break
			end
		end
		assert.is_string(heading)
		assert_table_margins(heading, width)
		for _, line in pairs(output.line_by_key) do
			assert_table_margins(output.lines[line], width)
		end
		local detail
		for _, line in ipairs(output.lines) do
			if line:find("source:", 1, true) then
				detail = line
				break
			end
		end
		assert.is_string(detail)
		local margin = expected_table_margin(width)
		assert.equals(margin, leading_spaces(detail))
		assert.is_true(vim.fn.strdisplaywidth(detail) <= width - margin)

		local compact_width = 50
		local compact = render.render(state_for("all"), compact_width)
		for _, line in pairs(compact.line_by_key) do
			assert_table_margins(compact.lines[line], compact_width)
		end
	end)

	it("moves a wide first detail unit intact to the common-margin continuation", function()
		local view = empty_view()
		view.other = { entry("custom", "tool", "missing", { probe = { source = "界abc" } }) }
		local state = state_for("all", view)
		state.expanded_key = "custom\0tool"
		state.source_error = nil
		state.versions = {}
		local width = 25
		local output = render.render(state, width)
		local source_line
		for index, line in ipairs(output.lines) do
			if line:find("source:", 1, true) then
				source_line = index
				break
			end
		end
		assert.is_number(source_line)
		assert.is_nil(output.lines[source_line]:find("…", 1, true))
		assert.is_truthy(output.lines[source_line + 1]:find("界abc", 1, true))
		local margin = expected_table_margin(width)
		assert.equals(margin, leading_spaces(output.lines[source_line]))
		assert.is_true(width - vim.fn.strdisplaywidth(output.lines[source_line]) >= margin)
		assert.equals(margin, leading_spaces(output.lines[source_line + 1]))
		assert.is_true(vim.fn.strdisplaywidth(output.lines[source_line + 1]) <= width - expected_table_margin(width))

		local tiny_width = 17
		local tiny = render.render(state, tiny_width)
		local tiny_margin = expected_table_margin(tiny_width)
		local first_value_line
		for index, line in ipairs(tiny.lines) do
			if line:find("界", 1, true) then
				first_value_line = index
				break
			end
		end
		assert.is_number(first_value_line)
		local reconstructed = ""
		for index = first_value_line, tiny.anchors.footer - 1 do
			local line = tiny.lines[index]
			assert.equals(tiny_margin, leading_spaces(line))
			assert.is_true(vim.fn.strdisplaywidth(line) <= tiny_width - tiny_margin)
			reconstructed = reconstructed .. line:sub(tiny_margin + 1)
		end
		assert.equals("界abc", reconstructed)
	end)

	it("uses full configured adapter and version headings as wide-layout minima", function()
		local view = empty_view()
		view.other = { entry("custom", "tool", "found", { probe = { path = "/tool" } }) }
		local state = state_for("all", view)
		state.expanded_key = nil
		state.source_error = nil
		state.versions = { ["custom\0tool"] = { value = "1", tier = 4 } }

		local function first_visible(label)
			for width = 1, 200 do
				if output_text(render.render(state, width)):find(label, 1, true) then
					return width
				end
			end
		end

		local adapter_heading = string.rep("A", 40)
		state.ui.labels.columns.adapter = adapter_heading
		local adapter_width = assert(first_visible(adapter_heading))
		assert.is_nil(output_text(render.render(state, adapter_width - 1)):find(adapter_heading, 1, true))

		state.ui.labels.columns.adapter = "TYPE"
		local version_heading = string.rep("V", 30)
		state.ui.labels.columns.version = version_heading
		local version_width = assert(first_visible(version_heading))
		assert.is_nil(output_text(render.render(state, version_width - 1)):find(version_heading, 1, true))
	end)

	it("aligns compact metadata inside adaptive margins and uses continuation when needed", function()
		local view = empty_view()
		view.other = { entry("custom", "x", "found", { probe = { path = "/x" } }) }
		local state = state_for("all", view)
		state.expanded_key = nil
		state.source_error = nil
		state.versions = { ["custom\0x"] = { value = "1", tier = 4 } }
		local function highlighted(output, line, group)
			local values = {}
			for _, mark in ipairs(output.extmarks) do
				if mark.line == line - 1 and mark.opts.hl_group == group then
					local text = output.lines[line]
					values[#values + 1] = text:sub(mark.col + 1, mark.opts.end_col)
				end
			end
			return values
		end

		local compact_width = 50
		local aligned = render.render(state, compact_width)
		local line = row_line(aligned, "custom\0x")
		assert.same({}, aligned.virtual_text)
		assert.is_truthy(aligned.lines[line]:find("custom", 1, true))
		assert.is_truthy(aligned.lines[line]:find("1", 1, true))
		assert_table_margins(aligned.lines[line], compact_width)
		assert.same({ "▸ ●" }, highlighted(aligned, line, "MusterStatusFound"))
		assert.same({ "custom" }, highlighted(aligned, line, "MusterAdapter"))
		assert.same({ "1" }, highlighted(aligned, line, "MusterVersion"))

		view.other[1].name = "long-tool-name"
		state.ui.labels.adapters.custom = "very-long-adapter"
		state.versions = { ["custom\0long-tool-name"] = { value = "123456", tier = 4 } }
		local continuation_width = 30
		local continuation = render.render(state, continuation_width)
		local long_line = row_line(continuation, "custom\0long-tool-name")
		assert.same({}, continuation.virtual_text)
		local metadata = continuation.lines[long_line + 1]
		assert.is_truthy(metadata:find("very", 1, true))
		assert.is_truthy(metadata:find("123", 1, true))
		assert.equals(expected_table_margin(continuation_width), leading_spaces(metadata))
		assert.is_truthy(highlighted(continuation, long_line + 1, "MusterAdapter")[1]:find("very", 1, true))
		assert.is_truthy(highlighted(continuation, long_line + 1, "MusterVersion")[1]:find("123", 1, true))
	end)

	it("keeps wide column starts aligned for CJK and combining values", function()
		local combining = vim.fn.nr2char(0x0301)
		local view = empty_view()
		view.other = { entry("custom", "工具" .. combining, "found", { probe = { path = "/tool" } }) }
		local state = state_for("all", view)
		state.expanded_key = nil
		state.source_error = nil
		state.versions = { ["custom\0工具" .. combining] = { value = "値" .. combining, tier = 4 } }
		state.ui.labels.adapters.custom = "類" .. combining
		state.ui.labels.columns.status = "状"
		state.ui.labels.columns.tool = "工" .. combining
		state.ui.labels.columns.adapter = "型" .. combining
		state.ui.labels.columns.version = "版" .. combining
		local output = render.render(state, 80)
		local header = output.lines[output.anchors.body]
		local row = output.lines[row_line(output, "custom\0工具" .. combining)]
		assert.equals(display_start(header, "工" .. combining), display_start(row, "工具" .. combining))
		assert.equals(display_start(header, "型" .. combining), display_start(row, "類" .. combining))
		assert.equals(display_start(header, "版" .. combining), display_start(row, "値" .. combining))
	end)

	it("sanitizes hostile metadata into recursively plain scalar leaves", function()
		local hostile = setmetatable({ nested = setmetatable({ value = true }, {}) }, {
			__tostring = function()
				error("must not stringify hostile metadata")
			end,
		})
		local item = entry("custom", "hostile", "found", {
			probe = {
				binary = hostile,
				path = "/raw/path",
				realpath = "/raw/realpath",
				source = function() end,
				reason = io.stdout,
			},
			advice = {
				{
					provider = hostile,
					action = function() end,
					package = io.stdout,
					command = "install safely",
					eligible = true,
					reason = hostile,
				},
			},
		})
		local view = empty_view()
		view.other = { item }
		local state = state_for("all", view)
		state.expanded_key = "custom\0hostile"
		state.source_error = nil
		local output = render.render(state, 100)
		local metadata = output.row_by_line[row_line(output, "custom\0hostile")].entry
		assert.equals("/raw/path", metadata.probe.path)
		assert.equals("/raw/realpath", metadata.probe.realpath)
		assert.is_nil(metadata.probe.binary)
		assert.is_nil(metadata.probe.source)
		assert.is_nil(metadata.probe.reason)
		assert.is_nil(metadata.advice[1].provider)
		assert.is_nil(metadata.advice[1].action)
		assert.is_nil(metadata.advice[1].package)
		assert.equals("install safely", metadata.advice[1].command)
		assert.is_nil(metadata.advice[1].reason)
		assert_plain(output)
		assert_scalar_metadata(output.row_by_line)
	end)

	it("wraps every normalized detail value without loss and with stable indentation", function()
		local value = ("界/é/segment/"):rep(18)
		local cases = {
			{ field = "source", label = "source" },
			{ field = "binary", label = "executable" },
			{ field = "path", label = "path" },
			{ field = "realpath", label = "realpath" },
			{ field = "reason", label = "reason" },
			{ field = "version_reason", label = "reason" },
			{ field = "advice", label = "advice" },
		}
		for _, case in ipairs(cases) do
			local item = entry("custom", "wrapped", case.field == "version_reason" and "found" or "missing")
			local view = empty_view()
			view.other = { item }
			local state = state_for("all", view)
			state.expanded_key = "custom\0wrapped"
			state.source_error = nil
			state.versions = {}
			if case.field == "version_reason" then
				state.versions["custom\0wrapped"] = { reason = value, tier = 4 }
			elseif case.field == "advice" then
				item.advice = { { provider = value } }
			else
				item.probe[case.field] = value
			end

			local detail_width = 40
			local first = render.render(state, detail_width)
			local second = render.render(state, detail_width)
			assert.same(first.lines, second.lines, case.field)
			assert_ranges(first, detail_width)
			local margin = expected_table_margin(detail_width)
			local padding = string.rep(" ", margin)
			local prefix = padding .. state.ui.labels.details[case.label] .. ": "
			local start
			for index, line in ipairs(first.lines) do
				if line:sub(1, #prefix) == prefix then
					start = index
					break
				end
			end
			assert.is_number(start, case.field)
			local reconstructed = first.lines[start]:sub(#prefix + 1)
			assert.is_true(vim.fn.strdisplaywidth(first.lines[start]) <= detail_width - margin)
			local index = start + 1
			while #reconstructed < #value do
				local line = assert(first.lines[index], case.field .. " ended before preserving the value")
				assert.equals(padding, line:sub(1, #padding), case.field)
				assert.is_true(vim.fn.strdisplaywidth(line) <= detail_width - margin, case.field)
				reconstructed = reconstructed .. line:sub(#padding + 1)
				index = index + 1
			end
			assert.equals(value, reconstructed, case.field)
		end
	end)

	it("keeps query and help branches buffer/window-pure with plain revisioned output", function()
		local query_state = state_for("all")
		query_state.query = "lua"
		local query_output = render_without_mutation(query_state, 100)
		assert.is_number(query_output.line_by_key["lsp\0lua_ls"])

		local help_state = state_for("all")
		local help_output = render_without_mutation(help_state, 100, render.help)
		assert.same({}, help_output.row_by_line)
		assert.same({}, help_output.line_by_key)
	end)

	it("registers highlights transactionally across augroup and autocmd failures", function()
		local saved_module = package.loaded["muster.ui.render"]
		local saved_create_augroup = vim.api.nvim_create_augroup
		local saved_create_autocmd = vim.api.nvim_create_autocmd
		local ok, err = xpcall(function()
			for _, stage in ipairs({ "augroup", "autocmd" }) do
				package.loaded["muster.ui.render"] = nil
				local fresh = require("muster.ui.render")
				pcall(vim.api.nvim_del_augroup_by_name, "muster_ui_highlights")
				local failed = false
				vim.api.nvim_create_augroup = function(...)
					if stage == "augroup" and not failed then
						failed = true
						error("highlight augroup failed", 0)
					end
					return saved_create_augroup(...)
				end
				vim.api.nvim_create_autocmd = function(...)
					if stage == "autocmd" and not failed then
						failed = true
						error("highlight autocmd failed", 0)
					end
					return saved_create_autocmd(...)
				end
				local registered, register_err = pcall(fresh.setup_highlights)
				assert.is_false(registered, stage)
				assert.is_truthy(tostring(register_err):find("highlight " .. stage .. " failed", 1, true), stage)
				assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = "muster_ui_highlights" }), stage)

				vim.api.nvim_create_augroup = saved_create_augroup
				vim.api.nvim_create_autocmd = saved_create_autocmd
				fresh.setup_highlights()
				local commands = vim.api.nvim_get_autocmds({ group = "muster_ui_highlights", event = "ColorScheme" })
				assert.equals(1, #commands, stage)
				vim.api.nvim_set_hl(0, "MusterStatusMissing", {})
				vim.api.nvim_exec_autocmds("ColorScheme", { group = "muster_ui_highlights" })
				assert.equals(
					"DiagnosticWarn",
					vim.api.nvim_get_hl(0, { name = "MusterStatusMissing", link = true }).link,
					stage
				)
				pcall(vim.api.nvim_del_augroup_by_name, "muster_ui_highlights")
			end
		end, debug.traceback)
		vim.api.nvim_create_augroup = saved_create_augroup
		vim.api.nvim_create_autocmd = saved_create_autocmd
		package.loaded["muster.ui.render"] = saved_module
		pcall(vim.api.nvim_del_augroup_by_name, "muster_ui_highlights")
		assert.is_true(ok, err)
	end)

	it("registers default highlight links, restores cleared defaults, and preserves user groups", function()
		render.setup_highlights()
		local header = vim.api.nvim_get_hl(0, { name = "MusterHeader", link = true })
		assert.equals("Title", header.link)
		vim.api.nvim_set_hl(0, "MusterStatusMissing", {})
		vim.api.nvim_set_hl(0, "MusterHeader", { fg = 0x123456 })
		vim.api.nvim_exec_autocmds("ColorScheme", {})
		local restored = vim.api.nvim_get_hl(0, { name = "MusterStatusMissing", link = true })
		local custom = vim.api.nvim_get_hl(0, { name = "MusterHeader", link = true })
		assert.equals("DiagnosticWarn", restored.link)
		assert.equals(0x123456, custom.fg)
		assert.is_nil(custom.link)
	end)

	it("normalizes malformed UTF-8, non-strings, controls, and bidi markers from every display field", function()
		local function exposed_state()
			local view = {
				bufnr = 4,
				filetype = "lua",
				active = {},
				other = {
					entry("custom", "tool", "missing", {
						probe = {
							binary = "binary",
							path = "/raw/path",
							realpath = "/real/path",
							source = "source",
							reason = "probe reason",
						},
						advice = {
							{
								provider = "provider",
								action = "action",
								package = "package",
								command = "command",
								eligible = false,
								reason = "advice reason",
							},
						},
					}),
					entry("custom", "found", "found", { probe = { path = "/found" } }),
					entry("custom", "unknown", "unknown"),
					entry("custom", "broken", "broken"),
					entry("custom", "unverifiable", "unverifiable"),
					entry("custom", "discovered", "found", { declared = false, probe = { path = "/live" } }),
				},
				diagnostics = { "diagnostic" },
				notes = { "note" },
			}
			local state = state_for("all", view)
			state.expanded_key = "custom\0tool"
			state.versions = {
				["custom\0tool"] = { value = "version", reason = "version reason", tier = 4 },
				["custom\0found"] = { reason = "pending version", tier = 4 },
			}
			return state
		end

		local fields = {
			{
				"tool name",
				function(s, v)
					s.view.other[1].name = v
				end,
			},
			{
				"adapter",
				function(s, v)
					s.view.other[1].adapter = v
				end,
			},
			{
				"probe status",
				function(s, v)
					s.view.other[1].probe.status = v
				end,
			},
			{
				"probe binary",
				function(s, v)
					s.view.other[1].probe.binary = v
				end,
			},
			{
				"probe path",
				function(s, v)
					s.view.other[1].probe.path = v
				end,
			},
			{
				"probe realpath",
				function(s, v)
					s.view.other[1].probe.realpath = v
				end,
			},
			{
				"probe source",
				function(s, v)
					s.view.other[1].probe.source = v
				end,
			},
			{
				"probe reason",
				function(s, v)
					s.view.other[1].probe.reason = v
				end,
			},
			{
				"filetype",
				function(s, v)
					s.view.filetype = v
				end,
			},
			{
				"version value",
				function(s, v)
					s.versions["custom\0tool"].value = v
				end,
			},
			{
				"version reason",
				function(s, v)
					s.versions["custom\0tool"].reason = v
				end,
			},
			{
				"advice provider",
				function(s, v)
					s.view.other[1].advice[1].provider = v
				end,
			},
			{
				"advice action",
				function(s, v)
					s.view.other[1].advice[1].action = v
				end,
			},
			{
				"advice package",
				function(s, v)
					s.view.other[1].advice[1].package = v
				end,
			},
			{
				"advice command",
				function(s, v)
					s.view.other[1].advice[1].command = v
				end,
			},
			{
				"advice reason",
				function(s, v)
					s.view.other[1].advice[1].reason = v
				end,
			},
			{
				"diagnostic",
				function(s, v)
					s.view.diagnostics[1] = v
				end,
			},
			{
				"note",
				function(s, v)
					s.view.notes[1] = v
				end,
			},
			{
				"source error",
				function(s, v)
					s.source_error = v
				end,
			},
			{
				"query",
				function(s, v)
					s.query = v
				end,
			},
			{
				"title label",
				function(s, v)
					s.ui.labels.title = v
				end,
			},
			{
				"active tab label",
				function(s, v)
					s.ui.labels.tabs.active = v
				end,
			},
			{
				"all tab label",
				function(s, v)
					s.ui.labels.tabs.all = v
				end,
			},
			{
				"issues tab label",
				function(s, v)
					s.ui.labels.tabs.issues = v
				end,
			},
			{
				"adapter label",
				function(s, v)
					s.ui.labels.adapters.custom = v
				end,
			},
			{
				"status column",
				function(s, v)
					s.ui.labels.columns.status = v
				end,
			},
			{
				"tool column",
				function(s, v)
					s.ui.labels.columns.tool = v
				end,
			},
			{
				"adapter column",
				function(s, v)
					s.ui.labels.columns.adapter = v
				end,
			},
			{
				"version column",
				function(s, v)
					s.ui.labels.columns.version = v
				end,
			},
			{
				"source detail",
				function(s, v)
					s.ui.labels.details.source = v
				end,
			},
			{
				"executable detail",
				function(s, v)
					s.ui.labels.details.executable = v
				end,
			},
			{
				"path detail",
				function(s, v)
					s.ui.labels.details.path = v
				end,
			},
			{
				"realpath detail",
				function(s, v)
					s.ui.labels.details.realpath = v
				end,
			},
			{
				"reason detail",
				function(s, v)
					s.ui.labels.details.reason = v
				end,
			},
			{
				"advice detail",
				function(s, v)
					s.ui.labels.details.advice = v
				end,
			},
			{
				"empty label",
				function(s, v)
					s.ui.labels.empty = v
					s.view = empty_view()
					s.source_error = nil
					s.tab = "all"
				end,
			},
			{
				"no matches label",
				function(s, v)
					s.ui.labels.no_matches = v
					s.query = "absent"
				end,
			},
			{
				"no issues label",
				function(s, v)
					s.ui.labels.no_issues = v
					s.view = empty_view()
					s.source_error = nil
					s.tab = "issues"
				end,
			},
			{
				"search prompt",
				function(s, v)
					s.ui.labels.search_prompt = v
				end,
			},
			{
				"help label",
				function(s, v)
					s.ui.labels.help = v
				end,
			},
		}
		for _, icon in ipairs({
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
			fields[#fields + 1] = {
				icon .. " icon",
				function(s, v)
					s.ui.icons[icon] = v
				end,
			}
		end

		local hostile = { "\255", {}, 42, false }
		for codepoint = 0x00, 0x1F do
			hostile[#hostile + 1] = codepoint == 0 and "\0" or vim.fn.nr2char(codepoint)
		end
		hostile[#hostile + 1] = vim.fn.nr2char(0x7F)
		for codepoint = 0x80, 0x9F do
			hostile[#hostile + 1] = vim.fn.nr2char(codepoint)
		end
		for _, codepoint in ipairs({
			0x061C,
			0x200E,
			0x200F,
			0x202A,
			0x202B,
			0x202C,
			0x202D,
			0x202E,
			0x2066,
			0x2067,
			0x2068,
			0x2069,
		}) do
			hostile[#hostile + 1] = vim.fn.nr2char(codepoint)
		end

		for _, field in ipairs(fields) do
			for sample_index, value in ipairs(hostile) do
				local state = exposed_state()
				field[2](state, value)
				local ok, output = pcall(render.render, state, 100)
				assert.is_true(ok, ("%s hostile sample %d failed: %s"):format(field[1], sample_index, output))
				assert_ranges(output, 100)
				assert_not_visible(output, value)
			end
		end
	end)

	it("renders explicit invalid markers and escaped controls from every visible display field", function()
		local fields = general_display_fields()
		for _, field in ipairs(label_display_fields()) do
			fields[#fields + 1] = field
		end
		for _, field in ipairs(icon_display_fields()) do
			fields[#fields + 1] = field
		end

		local hostile = {
			{ value = "\255", expected = "<invalid:utf8>" },
			{ value = {}, expected = "<invalid:table>" },
			{ value = 42, expected = "<invalid:number>" },
			{ value = false, expected = "<invalid:boolean>" },
		}
		local function add_control(codepoint)
			local value = codepoint == 0 and "\0" or vim.fn.nr2char(codepoint)
			local expected
			if codepoint == 0x09 then
				expected = "<TAB>"
			elseif codepoint == 0x0A then
				expected = "<LF>"
			elseif codepoint == 0x0D then
				expected = "<CR>"
			else
				expected = ("<U+%04X>"):format(codepoint)
			end
			hostile[#hostile + 1] = { value = value, expected = expected }
		end
		for codepoint = 0x00, 0x1F do
			add_control(codepoint)
		end
		add_control(0x7F)
		for codepoint = 0x80, 0x9F do
			add_control(codepoint)
		end
		for _, codepoint in ipairs({
			0x061C,
			0x200E,
			0x200F,
			0x202A,
			0x202B,
			0x202C,
			0x202D,
			0x202E,
			0x2066,
			0x2067,
			0x2068,
			0x2069,
		}) do
			add_control(codepoint)
		end

		for _, field in ipairs(fields) do
			for sample_index, sample in ipairs(hostile) do
				local state = reviewer_state()
				field[2](state, sample.value)
				local output = render.render(state, field.width or 100)
				assert_ranges(output, field.width or 100)
				local visible = visible_text(output):find(sample.expected, 1, true)
					or table.concat(output.lines):gsub("%s", ""):find(sample.expected:gsub("%s", ""), 1, true)
				assert.is_truthy(
					visible,
					("%s hostile sample %d was normalized but not visible"):format(field[1], sample_index)
				)
				assert_not_visible(output, sample.value)
				assert_plain(output)
			end
		end
	end)

	it("enforces 4096/4097-byte and 512/513-cell boundaries on every general display path", function()
		local combining = vim.fn.nr2char(0x0301)
		local bytes_4096 = "aa" .. combining:rep(2047)
		local bytes_4097 = "a" .. combining:rep(2048)
		local clipped_bytes = "a" .. combining:rep(2047) .. "…"
		local cells_512 = string.rep("x", 512)
		local cells_513 = string.rep("x", 513)
		local clipped_cells = string.rep("x", 511) .. "…"
		assert.equals(4096, #bytes_4096)
		assert.equals(4097, #bytes_4097)
		assert.equals(512, vim.fn.strdisplaywidth(cells_512))
		assert.equals(513, vim.fn.strdisplaywidth(cells_513))

		for _, field in ipairs(general_display_fields()) do
			local width = field.compact and 600 or 700
			local function rendered(value)
				local state = reviewer_state()
				field[2](state, value)
				if field.compact then
					force_compact(state)
					state.ui.labels.adapters.custom = ""
				end
				return render.render(state, width)
			end

			local exact_bytes = rendered(bytes_4096)
			assert_visible(exact_bytes, bytes_4096, field[1] .. " lost the exact byte boundary")
			local over_bytes = rendered(bytes_4097)
			assert_not_visible(over_bytes, bytes_4097)
			assert_visible(over_bytes, clipped_bytes, field[1] .. " missed the byte ellipsis boundary")
			local exact_cells = rendered(cells_512)
			assert_visible(exact_cells, cells_512, field[1] .. " lost the exact cell boundary")
			local over_cells = rendered(cells_513)
			assert_not_visible(over_cells, cells_513)
			assert_visible(over_cells, clipped_cells, field[1] .. " missed the cell ellipsis boundary")
		end
	end)

	it("enforces 128/129 label, 32/33 icon, and 256/257 query boundaries", function()
		local label_exact = string.rep("l", 128)
		local label_over = string.rep("l", 129)
		local label_clipped = string.rep("l", 127) .. "…"
		for _, field in ipairs(label_display_fields()) do
			local function rendered(value)
				local state = reviewer_state()
				field[2](state, value)
				return render.render(state, field.width or 700)
			end
			assert_visible(rendered(label_exact), label_exact, field[1] .. " lost the exact label boundary")
			local over = rendered(label_over)
			assert_not_visible(over, label_over)
			assert_visible(over, label_clipped, field[1] .. " missed the label ellipsis boundary")
		end

		local icon_exact = string.rep("i", 32)
		local icon_over = string.rep("i", 33)
		local icon_clipped = string.rep("i", 31) .. "…"
		for _, field in ipairs(icon_display_fields()) do
			local function rendered(value)
				local state = reviewer_state()
				field[2](state, value)
				return render.render(state, 500)
			end
			assert_visible(rendered(icon_exact), icon_exact, field[1] .. " lost the exact icon boundary")
			local over = rendered(icon_over)
			assert_not_visible(over, icon_over)
			assert_visible(over, icon_clipped, field[1] .. " missed the icon ellipsis boundary")
		end

		local query_exact = string.rep("q", 256)
		local query_over = string.rep("q", 257)
		local exact_state = reviewer_state()
		exact_state.query = query_exact
		local exact_query = render.render(exact_state, 700)
		assert_not_visible(exact_query, query_exact)
		assert.equals("/ Muster search:   ? Help", vim.trim(exact_query.lines[exact_query.anchors.footer]))
		local over_state = reviewer_state()
		over_state.query = query_over
		local over_query = render.render(over_state, 700)
		assert_not_visible(over_query, query_over)
		assert_not_visible(over_query, string.rep("q", 255) .. "…")
		assert.equals("/ Muster search:   ? Help", vim.trim(over_query.lines[over_query.anchors.footer]))
	end)

	it("bounds fully hostile states at widths one and two and preserves raw path only in metadata", function()
		local raw_path = "raw\n\255" .. vim.fn.nr2char(0x202E) .. string.rep("p", 4097)
		local state = state_for("all")
		state.view.filetype = raw_path
		state.view.active[1].name = raw_path
		state.view.active[1].adapter = raw_path
		state.view.active[1].probe.binary = raw_path
		state.view.active[1].probe.path = raw_path
		state.view.active[1].probe.realpath = raw_path
		state.view.active[1].probe.source = raw_path
		state.view.active[1].probe.reason = raw_path
		state.view.active[1].advice[1].provider = raw_path
		state.view.active[1].advice[1].action = raw_path
		state.view.active[1].advice[1].package = raw_path
		state.view.active[1].advice[1].command = raw_path
		state.view.active[1].advice[1].reason = raw_path
		state.view.diagnostics[1] = raw_path
		state.view.notes[1] = raw_path
		state.source_error = raw_path
		state.query = raw_path
		for key in pairs(state.ui.icons) do
			state.ui.icons[key] = raw_path
		end
		state.ui.labels.title = raw_path
		state.ui.labels.empty = raw_path
		state.ui.labels.no_matches = raw_path
		state.ui.labels.no_issues = raw_path
		state.ui.labels.search_prompt = raw_path
		state.ui.labels.help = raw_path
		for key in pairs(state.ui.labels.tabs) do
			state.ui.labels.tabs[key] = raw_path
		end
		for key in pairs(state.ui.labels.columns) do
			state.ui.labels.columns[key] = raw_path
		end
		for key in pairs(state.ui.labels.details) do
			state.ui.labels.details[key] = raw_path
		end
		state.ui.labels.adapters.lsp = raw_path
		state.versions = {}
		state.expanded_key = nil

		for _, width in ipairs({ 2, 1 }) do
			local output = render.render(state, width)
			assert_ranges(output, width)
			assert_not_visible(output, raw_path)
			assert.equals(7, output.revision)
			local metadata_path
			for _, row in pairs(output.row_by_line) do
				if row.entry and row.entry.probe.path == raw_path then
					metadata_path = row.entry.probe.path
				end
			end
			assert.equals(raw_path, metadata_path)
		end
	end)
end)
