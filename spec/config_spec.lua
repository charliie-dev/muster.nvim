---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")

describe("config", function()
	before_each(function()
		config.reset()
	end)

	it("is nil until setup() runs, so the automatic check can stay silent", function()
		assert.is_nil(config.get())
		config.setup({})
		assert.is_table(config.get())
	end)

	it("defaults Mason installation fallback to false and the startup notification to on", function()
		config.setup({})
		assert.is_false(config.get().mason_install_fallback)
		assert.is_true(config.get().notify_on_startup)
	end)

	it("accepts only booleans for mason_install_fallback", function()
		for _, value in ipairs({ true, false }) do
			config.setup({ mason_install_fallback = value })
			assert.equals(value, config.get().mason_install_fallback)
			assert.is_nil(config.error())
		end
		config.setup({ mason_install_fallback = "mason" })
		assert.is_string(config.error(), "a rejection must be recorded")
	end)

	it("always rejects the install tombstone with migration guidance", function()
		for _, value in ipairs({ false, true, "mason", {} }) do
			config.setup({ install = value })
			assert.is_truthy(config.error():find("`install` was removed", 1, true))
			assert.is_truthy(config.error():find("mason_install_fallback", 1, true))
		end
	end)

	it("keeps a usable config after a rejection, so health can tell the two apart", function()
		-- A nil config means "setup was never called", which would send a user
		-- who did call it to fix the one thing that is not wrong.
		config.setup({ conform = "stylua" })
		assert.is_table(config.get(), "the config must not be left nil")
		assert.is_string(config.error())
		assert.is_nil(config.list("conform"), "the rejected list must not be used")
	end)

	it("clears a previous rejection on a later valid setup", function()
		config.setup({ conform = "stylua" })
		assert.is_string(config.error())
		config.setup({ conform = { "stylua" } })
		assert.is_nil(config.error())
		assert.same({ "stylua" }, config.list("conform"))
	end)

	it("returns a declared list by adapter id, and nil when the key is absent", function()
		config.setup({ conform = { "stylua" } })
		assert.same({ "stylua" }, config.list("conform"))
		assert.is_nil(config.list("lint"))
	end)

	it("never mistakes option or tombstone keys for tool lists", function()
		config.setup({ mason_install_fallback = true })
		assert.is_nil(config.list("mason_install_fallback"))
		assert.is_nil(config.list("install"))
	end)

	it("accepts valid LSP strings and explicit command maps", function()
		config.setup({
			lsp = {
				"lua_ls",
				{ name = "jsonls", command = "vscode-json-language-server" },
				{ name = "server.name-1", command = "server_name+1.0" },
			},
		})
		assert.is_nil(config.error())
	end)

	it("rejects invalid LSP declaration shapes and grammar", function()
		local metatable_entry = setmetatable({ name = "jsonls", command = "jsonls" }, {})
		local fixtures = {
			7,
			{},
			{ name = "jsonls" },
			{ command = "jsonls" },
			{ name = "jsonls", command = "jsonls", extra = true },
			{ name = "jsonls", command = "jsonls", [1] = "extra" },
			{ name = 7, command = "jsonls" },
			{ name = "jsonls", command = 7 },
			metatable_entry,
			"*",
			"bad name",
			"/absolute",
			string.rep("n", 129),
			{ name = "jsonls", command = "bad command" },
			{ name = "jsonls", command = "bin/server" },
			{ name = "jsonls", command = "bin\\server" },
			{ name = "jsonls", command = "bad\ncommand" },
			{ name = "jsonls", command = string.rep("c", 256) },
		}
		for index, entry in ipairs(fixtures) do
			config.setup({ lsp = { entry } })
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
		end
	end)

	it("rejects ambiguous duplicate LSP declarations independent of order", function()
		local fixtures = {
			{ "jsonls", { name = "jsonls", command = "jsonls" } },
			{ { name = "jsonls", command = "jsonls" }, "jsonls" },
			{
				{ name = "jsonls", command = "jsonls-a" },
				{ name = "jsonls", command = "jsonls-b" },
			},
			{
				{ name = "jsonls", command = "jsonls-b" },
				{ name = "jsonls", command = "jsonls-a" },
			},
		}
		for index, entries in ipairs(fixtures) do
			config.setup({ lsp = entries })
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
		end
	end)

	it("leaves identical duplicate LSP declarations to the existing duplicate warning", function()
		config.setup({
			lsp = {
				"lua_ls",
				"lua_ls",
				{ name = "jsonls", command = "jsonls" },
				{ name = "jsonls", command = "jsonls" },
			},
		})
		assert.is_nil(config.error())
	end)
end)
