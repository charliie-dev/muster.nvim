---@module 'luassert'
local assert = require("luassert")

local mason_result = require("muster.mason_result")

local function read(path)
	return table.concat(vim.fn.readfile(path), "\n")
end

local function setup_ui_block(text, fence)
	local marker = "muster%-dashboard%-ui%-defaults"
	local pattern = fence == "markdown" and ("```lua\n%-%- " .. marker .. "\n(.-)\n```")
		or (">lua\n    %-%- " .. marker .. "\n(.-)\n<")
	local block = text:match(pattern)
	assert.is_string(block, "documentation must contain the canonical dashboard UI block")
	return block:gsub("^    ", ""):gsub("\n    ", "\n")
end

local function execute_setup_ui(block)
	local argument = block:match('require%("muster"%).setup%((%b{})%)')
	assert.is_string(argument, "canonical dashboard UI block must contain a compact setup call")
	local chunk, err = loadstring("return " .. argument, "documented dashboard defaults")
	assert.is_function(chunk, err)
	return chunk().ui
end

local function assert_contains_all(text, phrases, path)
	local compact = text:gsub("%s+", " ")
	for _, phrase in ipairs(phrases) do
		assert.is_truthy(compact:find(phrase, 1, true), path .. " must contain: " .. phrase)
	end
end

local function has_bit(mask, bit)
	return math.floor(mask / bit) % 2 == 1
end

local function result_key(
	outcome,
	availability,
	attestation,
	has_error,
	has_availability_reason,
	has_attestation_reason
)
	return table.concat({
		outcome,
		availability,
		attestation,
		has_error and "error" or "-",
		has_availability_reason and "availability_reason" or "-",
		has_attestation_reason and "attestation_reason" or "-",
	}, "/")
end

local function documented_results(readme)
	local matrix = readme:match("```text\n(outcome | availability | attestation | level | detail\n[%s%S]-)\n```")
	assert.is_string(matrix, "README must contain the fenced result matrix")

	local results = {}
	for line in matrix:gmatch("[^\n]+") do
		local outcome, availability, attestation, level, detail =
			line:match("^([a-z_]+) | ([a-z_]+) | ([a-z_]+) | ([A-Z]+) | (.+)$")
		if outcome then
			local detail_kind = vim.trim(detail:match("^[^;]+"))
			local has_error = detail_kind == "operation error"
			local has_availability_reason = detail_kind == "both reasons"
			local has_attestation_reason = detail_kind == "attestation reason" or detail_kind == "both reasons"
			assert.is_true(
				detail_kind == "none"
					or has_error
					or detail_kind == "attestation reason"
					or detail_kind == "both reasons",
				"unknown result detail: " .. detail
			)
			results[result_key(
				outcome,
				availability,
				attestation,
				has_error,
				has_availability_reason,
				has_attestation_reason
			)] =
				level:lower()
		end
	end
	return results
end

local function runtime_results()
	local results = {}
	for _, outcome in ipairs(mason_result.outcomes()) do
		for _, availability in ipairs(mason_result.availabilities()) do
			for _, attestation in ipairs(mason_result.attestations()) do
				for mask = 0, 7 do
					local value = {
						outcome = outcome,
						availability = availability,
						attestation = attestation,
						error = has_bit(mask, 1) and "operation" or nil,
						availability_reason = has_bit(mask, 2) and "availability" or nil,
						attestation_reason = has_bit(mask, 4) and "attestation" or nil,
					}
					if vim.deep_equal(mason_result.normalize(value), value) then
						results[result_key(
							outcome,
							availability,
							attestation,
							value.error ~= nil,
							value.availability_reason ~= nil,
							value.attestation_reason ~= nil
						)] =
							mason_result.severity(value)
					end
				end
			end
		end
	end
	return results
end

describe("public documentation", function()
	local readme = read("README.md")
	local vimdoc = read("doc/muster.txt")
	local api_source = read("lua/muster/init.lua")
	local design = read("docs/superpowers/specs/2026-08-15-muster-dashboard-ui-design.md")
	local plan = read("docs/superpowers/plans/2026-08-15-muster-dashboard-ui.md")

	it("uses the nvim_lint API and rejects stale public names and states", function()
		for path, text in pairs({
			["README.md"] = readme,
			["doc/muster.txt"] = vimdoc,
			["lua/muster/init.lua"] = api_source,
		}) do
			assert.is_nil(text:find("installed_unverified", 1, true), path .. " contains a removed result state")
			assert.is_nil(text:match("[%s{,]lint%s*="), path .. " contains the removed lint setup key in an example")
			assert.is_nil(text:find("adapter=lint", 1, true), path .. " contains the removed adapter id")
		end
		assert.is_truthy(readme:find("nvim_lint = {", 1, true))
		assert.is_truthy(readme:find('"selene"', 1, true))
		assert.is_truthy(readme:find('{ name = "oxlint", command = "oxlint" }', 1, true))
		assert.is_truthy(readme:find("rejected tombstone", 1, true))
		assert.is_truthy(readme:find("duplicate global tool", 1, true))
	end)

	it("documents both lazy triggers and the separate late automatic run", function()
		local compact = readme:gsub("%s+", " ")
		for _, phrase in ipairs({
			"first `BufReadPost`/`BufNewFile` event",
			"when `:Muster` is invoked",
			"Lazy loads the dependencies before the plugin on either trigger",
			"If `:Muster` first loads and configures the plugin after `VimEnter`",
			"setup schedules a separate automatic run",
			"perform fallback installation when `mason_install_fallback = true`",
		}) do
			assert.is_truthy(compact:find(phrase, 1, true), "README must contain: " .. phrase)
		end
		assert.is_truthy(compact:find("Mason install lifecycle INFO/WARN/ERROR notifications", 1, true))
	end)

	it("keeps adapter ownership and local-integration boundaries explicit", function()
		for _, phrase in ipairs({
			"Conform declarations remain string-only formatter names",
			"formatter_deps",
			"linter_deps",
			"The DAP setup key remains `dap`",
			"dap-go",
			"dap-python",
			"user-approved",
			"`.env`",
			"ambient Python",
			"Muster does not choose, approve, or provision them",
		}) do
			assert.is_truthy(readme:find(phrase, 1, true), "README must contain: " .. phrase)
		end
	end)

	it("matches the fenced result matrix to runtime legality and severity", function()
		assert.same(runtime_results(), documented_results(readme))
		local header = "outcome | availability | attestation | level | detail"
		local planned = "planned | not_checked | not_checked | INFO | none; internal state"
		for path, text in pairs({ ["README.md"] = readme, ["doc/muster.txt"] = vimdoc }) do
			assert.is_truthy(text:find(header, 1, true), path .. " must preserve the matrix header")
			assert.is_truthy(text:find(planned, 1, true), path .. " must preserve the planned INFO detail")
			assert.is_nil(text:find("INFOinternal", 1, true), path .. " contains a joined level and detail")
			assert.is_nil(text:find("Leveland", 1, true), path .. " contains the former joined heading")
			assert.is_nil(text:find("Requireddetail", 1, true), path .. " contains the former joined heading")
		end
		assert.is_truthy(readme:find("```text\n" .. header, 1, true))
		assert.is_truthy(vimdoc:find(">text\n", 1, true))
		assert.is_truthy(readme:find("verification phase reached a terminal result", 1, true))
		assert.is_truthy(readme:find("verification safe-context bridge could not run", 1, true))
		assert.is_truthy(readme:find("verification deadline expired", 1, true))
		assert.is_truthy(readme:find("by itself it is not success", 1, true))
		assert.is_truthy(readme:find("no result path enables an LSP server", 1, true))
	end)

	it("preserves the examples heading and spaced bullets", function()
		assert.is_truthy(readme:find("### Examples", 1, true))
		assert.is_truthy(vimdoc:find("EXAMPLES ~", 1, true))
		for path, text in pairs({ ["README.md"] = readme, ["doc/muster.txt"] = vimdoc }) do
			assert.is_truthy(
				text:find("- A successful npm callback", 1, true),
				path .. " must preserve the spaced first bullet"
			)
			assert.is_nil(text:find("Asuccessful", 1, true), path .. " contains a joined bullet opening")
			assert.is_nil(text:find("RESULTEXAMPLES", 1, true), path .. " contains the former joined heading")
			assert.is_nil(text:find("Forexample", 1, true), path .. " contains a joined paragraph opening")
		end
	end)

	it("documents compiler policies and representative terminal results", function()
		local compact = readme:gsub("%s+", " ")
		for _, phrase in ipairs({
			"cargo, composer, gem, golang, luarocks, nuget, and opam",
			"`npm`, `pypi`, `github`,",
			"`mason`, `generic`, and `openvsx`",
			"unknown` or future compiler type fails attestation",
			"completed/found/partial",
			"completed/missing/failed",
			"completed/found/failed",
			"failed/not_checked/not_checked",
			"Windows plus a PARTIAL compiler fails",
		}) do
			assert.is_truthy(compact:find(phrase, 1, true), "README must contain: " .. phrase)
		end
	end)

	it("keeps every README Lua block syntactically valid", function()
		local count = 0
		for block in readme:gmatch("```lua\n(.-)\n```") do
			count = count + 1
			local chunk, err = loadstring(block, "README Lua block " .. count)
			assert.is_function(chunk, err)
		end
		assert.is_true(count >= 7)
	end)

	it("publishes the complete executable dashboard defaults in README and vimdoc", function()
		local config = require("muster.config")
		config.reset()
		for path, block in pairs({
			["README.md"] = setup_ui_block(readme, "markdown"),
			["doc/muster.txt"] = setup_ui_block(vimdoc, "vimdoc"),
		}) do
			assert.same(config.ui(), execute_setup_ui(block), path .. " dashboard defaults differ from runtime")
			assert_contains_all(block, {
				"width = 0.8",
				"height = 0.8",
				'border = "rounded"',
				"backdrop = 60",
				"found",
				"missing",
				"unknown",
				"broken",
				"unverifiable",
				"pending",
				"discovered",
				"expanded",
				"collapsed",
				"title",
				"tabs",
				"active",
				"all",
				"issues",
				"adapters",
				"lsp",
				"conform",
				"nvim_lint",
				"dap",
				"none_ls",
				"columns",
				"status",
				"tool",
				"adapter",
				"version",
				"details",
				"source",
				"executable",
				"path",
				"realpath",
				"reason",
				"advice",
				"empty",
				"no_matches",
				"no_issues",
				"search_prompt",
				"help",
				"keymaps",
				"close",
				"next_tab",
				"previous_tab",
				"search",
				"refresh",
				"copy_path",
			}, path)
		end
	end)

	it("keeps the public no-match label aligned across canonical documentation", function()
		local declaration = 'no_matches = "No matching tools."'
		for path, text in pairs({
			["README.md"] = readme,
			["doc/muster.txt"] = vimdoc,
			["lua/muster/init.lua"] = api_source,
			["dashboard design"] = design,
			["dashboard plan"] = plan,
		}) do
			assert.is_truthy(text:find(declaration, 1, true), path .. " must contain the canonical no-match label")
		end
	end)

	it("documents the complete dashboard behavior, validation, and safety contract", function()
		local phrases = {
			"Active shows tools live in the inspected buffer; All shows every collected tool.",
			"All tab counts come from the unfiltered collection.",
			"Rows become compact at narrow widths",
			"Collapsed rows show status, tool, type, and version; executable path and realpath are available in expanded details.",
			"expanded details",
			"literal, normalized, and limited to 256 bytes",
			"two centered header rows",
			"tabs and the footer are centered too",
			"footer shows only Search and Help",
			"exact default text is:",
			"active query is never appended",
			"Help opens in a separate overlay",
			"80% of the dashboard width and height",
			"fixed `q/<Esc> close Help` controls",
			"all enabled configured mappings",
			"configured close action `close dashboard`",
			"main revision",
			"without scheduling or drawing main",
			"Refresh re-probes the canonical source buffer",
			"resizing redraws the same singleton",
			"80% of the resized parent",
			"closing the parent or either Help resource cleans up the child",
			"closing and reopening creates a fresh dashboard",
			"Values in `(0, 1]` are ratios; values greater than 1 are fixed columns or lines.",
			"Raw mapping text is at most 64 bytes",
			"vim.keycode",
			"1 to 50 bytes",
			"semantic collisions",
			"string, a non-empty dense list of strings, or `false`",
			"plain, acyclic tables",
			"dense lists",
			"Labels allow 128 bytes, icons 32 bytes, border characters 16 bytes, and highlight names 128 bytes.",
			"C0, DEL, C1",
			"U+061C",
			"U+200E",
			"U+200F",
			"U+202A-U+202E",
			"U+2066-U+2069",
			"Adapter keys are the exception",
			'inert register allowlist is `"`, `a-z`, `A-Z`, `0-9`, `+`, `*`, `-`, and `_`',
			"Special registers outside that allowlist are rejected",
			"preferred copy path",
			"fallback only when path is absent",
			"4096 bytes is accepted and 4097 bytes is rejected",
			"stale render revisions refuse to copy",
			"Only numeric zero from `setreg` means success",
			"Rejected copy inputs never call `setreg`; throws and nonzero, false, or nil returns never report success.",
			"WARN on failure and INFO on success",
			"Command-like text remains inert",
			"never requires runner, automatic, report, enrich, Mason handoff",
			"mason-lspconfig is not required",
			"never installs, removes, updates, or reconfigures a package",
		}
		local highlights = {
			"MusterNormal -> NormalFloat",
			"MusterBackdrop -> Normal",
			"MusterHeader -> Title",
			"MusterTabActive -> Visual",
			"MusterTabInactive -> Comment",
			"MusterStatusFound -> DiagnosticOk",
			"MusterStatusMissing -> DiagnosticWarn",
			"MusterStatusBroken -> DiagnosticError",
			"MusterStatusUnknown -> DiagnosticWarn",
			"MusterStatusUnverifiable -> DiagnosticInfo",
			"MusterAdapter -> Type",
			"MusterVersion -> String",
			"MusterMuted -> Comment",
			"MusterDetailKey -> Identifier",
			"MusterSearchMatch -> IncSearch",
		}
		for path, text in pairs({ ["README.md"] = readme, ["doc/muster.txt"] = vimdoc }) do
			assert_contains_all(text, phrases, path)
			assert_contains_all(text, highlights, path)
			assert.is_truthy(
				text:find("/ Muster search:   ? Help", 1, true),
				path .. " must preserve the exact stable footer"
			)
		end
	end)

	it("documents reviewed issue, geometry, rejection, and copy safety details", function()
		local phrases = {
			"Issues includes non-found tools, unfiltered adapter diagnostics, report notes, and source-buffer errors.",
			"An active query with no matching tool shows `no_matches`; an issue-free Issues tab shows `no_issues`.",
			"Its stable count includes each item exactly once.",
			"Width and height must be positive finite numbers.",
			"Values in `(0, 1]` are ratios; values greater than 1 are fixed columns or lines.",
			"Backdrop must be an integer from 0 through 100.",
			"Border is a supported named border or exactly eight parts.",
			"Each border character is at most 16 bytes and at most one display cell",
			"highlight text is non-empty, printable, and at most 128 bytes",
			"Invalid UI configuration rejects the entire candidate and restores all defaults.",
			"The selected copy value must be a non-empty string of at most 4096 bytes.",
			"Copy rejects exactly C0, DEL, C1, U+061C, U+200E, U+200F, U+202A-U+202E, and U+2066-U+2069 controls.",
			"Arbitrary other bytes and command-like text remain inert.",
		}
		for path, text in pairs({ ["README.md"] = readme, ["doc/muster.txt"] = vimdoc }) do
			assert_contains_all(text, phrases, path)
		end
	end)

	it("keeps a compact parseable dashboard LuaDoc example", function()
		local commented = api_source:match("%-%-%-```lua\n([%s%S]-)\n%-%-%-```")
		assert.is_string(commented)
		local block = commented:gsub("^%-%-%-?", ""):gsub("\n%-%-%-?", "\n")
		local chunk, err = loadstring(block, "muster setup LuaDoc")
		assert.is_function(chunk, err)
		assert_contains_all(block, {
			"ui",
			"width",
			"height",
			"border",
			"backdrop",
			"icons",
			"labels",
			'no_matches = "No matching tools."',
			"keymaps",
			'require("muster").setup({',
		}, "lua/muster/init.lua")
	end)
end)
