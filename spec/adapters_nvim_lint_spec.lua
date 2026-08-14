---@module 'luassert'
local assert = require("luassert")

local env = require("muster.env")
local adapter = require("muster.adapters.nvim_lint")

local saved_lint
local saved_executable

local function catalog(linters, fn)
	saved_lint = package.loaded["lint"]
	package.loaded["lint"] = { linters = linters }
	local ok, err = pcall(fn)
	package.loaded["lint"] = saved_lint
	if not ok then
		error(err, 0)
	end
end

describe("nvim-lint adapter", function()
	before_each(function()
		saved_executable = env.executable
	end)

	after_each(function()
		env.executable = saved_executable
		package.loaded["lint"] = saved_lint
	end)

	it("uses the public nvim_lint identity for strings and explicit declarations", function()
		assert.equals("nvim_lint", adapter.id)
		assert.equals("selene", adapter.identity("selene"))
		assert.equals("oxlint", adapter.identity({ name = "oxlint", command = "oxlint" }))
	end)

	it("preserves string command and definition-factory behavior", function()
		local factory_calls = 0
		catalog({
			selene = { cmd = "selene" },
			factory = function()
				factory_calls = factory_calls + 1
				return { cmd = "factory-bin" }
			end,
		}, function()
			env.executable = function(command)
				return "/usr/bin/" .. command
			end
			assert.equals("selene", adapter.probe("selene", 1).binary)
			assert.equals("factory-bin", adapter.probe("factory", 1).binary)
			assert.equals(1, factory_calls)
		end)
	end)

	it("probes a bare command for a project-local-only linter without invoking cmd=function", function()
		local cmd_calls = 0
		catalog({
			oxlint = {
				cmd = function()
					cmd_calls = cmd_calls + 1
					return "node_modules/.bin/oxlint"
				end,
			},
		}, function()
			env.executable = function(command)
				assert.equals("oxlint", command)
				return nil
			end
			local result = adapter.probe({ name = "oxlint", command = "oxlint" }, 1)
			assert.equals("missing", result.status)
			assert.equals("oxlint", result.binary)
			assert.equals(0, cmd_calls)
		end)
	end)

	it("requires the named linter to exist even with an explicit command", function()
		catalog({}, function()
			local result = adapter.probe({ name = "invented", command = "tool" }, 1)
			assert.equals("unknown", result.status)
			assert.is_truthy(result.reason:find("lint.linters.invented", 1, true))
		end)
	end)

	it("keeps function commands unverifiable for string declarations", function()
		local calls = 0
		catalog({
			oxlint = {
				cmd = function()
					calls = calls + 1
				end,
			},
		}, function()
			local result = adapter.probe("oxlint", 1)
			assert.equals("unverifiable", result.status)
			assert.equals(0, calls)
		end)
	end)

	it("reports the names nvim-lint resolves live for the buffer", function()
		saved_lint = package.loaded["lint"]
		package.loaded["lint"] = {
			_resolve_linter_by_ft = function(filetype)
				assert.equals("javascript", filetype)
				return { "eslint", "oxlint" }
			end,
		}
		vim.bo[1].filetype = "javascript"
		local entries, err = adapter.live(1)
		assert.same({ "eslint", "oxlint" }, entries)
		assert.is_nil(err)
	end)

	it("always enriches an explicit missing command with available advice", function()
		local item = {
			adapter = "nvim_lint",
			name = "oxlint",
			declared = true,
			probe = { status = "missing", binary = "oxlint" },
			advice = {},
		}
		local result = { entries = { item }, skipped = {}, notes = {}, bufnr = 1 }
		local delivered
		require("muster.enrich").run(result, function(value)
			delivered = value
		end, {
			providers = {
				mason = {
					collect = function()
						return {
							oxlint = { provider = "mason", action = "install", package = "oxlint" },
						}
					end,
				},
				nix = {
					collect = function(_, _, callback)
						callback({})
					end,
				},
				mise = {
					collect = function(_, callback)
						callback({})
					end,
				},
			},
		})
		assert.equals(result, delivered)
		assert.same({ { provider = "mason", action = "install", package = "oxlint" } }, item.advice)
	end)
end)
