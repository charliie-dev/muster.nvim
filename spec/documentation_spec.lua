---@module 'luassert'
local assert = require("luassert")

local mason_result = require("muster.mason_result")

local function read(path)
	return table.concat(vim.fn.readfile(path), "\n")
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
end)
