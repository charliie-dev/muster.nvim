---@module 'luassert'
local assert = require("luassert")

local adapter = require("muster.adapters.lsp")
local probe = require("muster.probe")

describe("LSP adapter", function()
	local saved_config
	local saved_resolve

	before_each(function()
		saved_config = vim.lsp.config
		saved_resolve = probe.resolve
	end)

	after_each(function()
		vim.lsp.config = saved_config
		probe.resolve = saved_resolve
	end)

	it("keeps string declarations compatible with static argv catalogs", function()
		vim.lsp.config = { lua_ls = { cmd = { "lua-language-server", "--stdio" } } }
		local resolved
		probe.resolve = function(command)
			resolved = command
			return { status = "missing", binary = command }
		end
		local result = adapter.probe("lua_ls", 1)
		assert.equals("lua-language-server", resolved)
		assert.equals("lua-language-server", result.binary)
	end)

	it("uses an explicit command without invoking a function-form catalog command", function()
		local invoked = 0
		vim.lsp.config = {
			jsonls = {
				cmd = function()
					invoked = invoked + 1
				end,
			},
			yamlls = {
				cmd = function()
					invoked = invoked + 1
				end,
			},
		}
		local resolved = {}
		probe.resolve = function(command)
			resolved[#resolved + 1] = command
			return { status = "missing", binary = command }
		end
		adapter.probe({ name = "jsonls", command = "vscode-json-language-server" }, 1)
		adapter.probe({ name = "yamlls", command = "yaml-language-server" }, 1)
		assert.same({ "vscode-json-language-server", "yaml-language-server" }, resolved)
		assert.equals(0, invoked)
	end)

	it("gives the explicit command precedence over static catalog argv", function()
		vim.lsp.config = { jsonls = { cmd = { "catalog-command" } } }
		local resolved
		probe.resolve = function(command)
			resolved = command
			return { status = "missing", binary = command }
		end
		adapter.probe({ name = "jsonls", command = "explicit-command" }, 1)
		assert.equals("explicit-command", resolved)
	end)

	it("uses the explicit binary for found, missing, and Mason advice", function()
		vim.lsp.config = { jsonls = { cmd = { "catalog-command" } } }
		probe.resolve = function(command)
			return { status = "missing", binary = command }
		end
		local missing = adapter.probe({ name = "jsonls", command = "explicit-command" }, 1)
		local result = {
			entries = {
				{ adapter = "lsp", name = "jsonls", declared = true, probe = missing, advice = {} },
			},
			skipped = {},
			bufnr = 1,
			notes = {},
		}
		local mason_binaries
		require("muster.enrich").run(result, function() end, {
			providers = {
				mason = {
					collect = function(binaries)
						mason_binaries = binaries
						return {
							["explicit-command"] = {
								provider = "mason",
								action = "install",
								package = "json-lsp",
							},
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
		assert.same({ "explicit-command" }, mason_binaries)
		assert.equals("json-lsp", result.entries[1].advice[1].package)

		probe.resolve = function(command)
			return { status = "found", binary = command, path = "/bin/" .. command, source = "system" }
		end
		assert.equals("found", adapter.probe({ name = "jsonls", command = "explicit-command" }, 1).status)
	end)

	it("requires a readable catalog entry even for explicit declarations", function()
		vim.lsp.config = {}
		assert.equals("unknown", adapter.probe({ name = "jsonls", command = "jsonls" }, 1).status)

		vim.lsp.config = setmetatable({}, {
			__index = function()
				error("catalog exploded")
			end,
		})
		local result = adapter.probe({ name = "jsonls", command = "jsonls" }, 1)
		assert.equals("broken", result.status)
		assert.is_truthy(result.reason:find("catalog exploded", 1, true))
	end)

	it("preserves server identity across explicit declarations and live clients", function()
		assert.equals("jsonls", adapter.identity({ name = "jsonls", command = "vscode-json-language-server" }))
		local saved_get_clients = vim.lsp.get_clients
		vim.lsp.get_clients = function(filter)
			assert.same({ bufnr = 12 }, filter)
			return { { name = "jsonls" } }
		end
		local live = adapter.live(12)
		vim.lsp.get_clients = saved_get_clients
		assert.same({ "jsonls" }, live)
		assert.equals(adapter.identity({ name = "jsonls", command = "jsonls" }), adapter.identity(live[1]))
	end)
end)
