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

	it("accepts nil as defaults but rejects false", function()
		config.setup(nil)
		assert.is_nil(config.error())
		assert.is_false(config.get().mason_install_fallback)

		config.setup(false)
		assert.is_string(config.error())
		assert.is_false(config.get().mason_install_fallback)
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

	it("copies setup input before validation and storage", function()
		local opts = {
			mason_install_fallback = true,
			conform = { "stylua" },
			lsp = { { name = "jsonls", command = "vscode-json-language-server" } },
		}
		config.setup(opts)
		opts.mason_install_fallback = false
		opts.conform[1] = "prettier"
		opts.lsp[1].name = "mutated"
		opts.lsp[1].command = "mutated"

		local snapshot = config.get()
		assert.is_true(snapshot.mason_install_fallback)
		assert.same({ "stylua" }, snapshot.conform)
		assert.same({ { name = "jsonls", command = "vscode-json-language-server" } }, snapshot.lsp)
	end)

	it("preserves opaque adapter entry identity while isolating list containers", function()
		local timer = assert(vim.uv.new_timer())
		local opaque = setmetatable({ value = 1 }, { __index = { marker = true } })
		local thread = coroutine.create(function() end)
		local opts = { third_party = { timer, opaque, thread } }
		local ok, err = pcall(function()
			config.setup(opts)
			assert.is_nil(config.error())
			opts.third_party[1] = "caller mutation"

			local first = config.list("third_party")
			assert.equals(timer, first[1])
			assert.equals(opaque, first[2])
			assert.equals(thread, first[3])
			first[1] = "list mutation"

			local from_get = config.get().third_party
			assert.equals(timer, from_get[1])
			assert.equals(opaque, from_get[2])
			assert.equals(thread, from_get[3])
			from_get[2] = "get mutation"
			assert.equals(opaque, config.list("third_party")[2])

			opaque.value = 2
			assert.equals(2, config.list("third_party")[2].value)
		end)
		pcall(timer.close, timer)
		assert.is_true(ok, err)
	end)

	it("returns independent get and list snapshots", function()
		config.setup({
			mason_install_fallback = true,
			conform = { "stylua" },
			lsp = { { name = "jsonls", command = "vscode-json-language-server" } },
		})
		local first = config.get()
		first.mason_install_fallback = false
		first.conform[1] = "prettier"
		first.lsp[1].command = "mutated"
		local conform = config.list("conform")
		conform[1] = "mutated"
		local lsp = config.list("lsp")
		lsp[1].name = "mutated"

		local second = config.get()
		assert.is_true(second.mason_install_fallback)
		assert.same({ "stylua" }, second.conform)
		assert.same({ { name = "jsonls", command = "vscode-json-language-server" } }, second.lsp)
		assert.same({ "stylua" }, config.list("conform"))
		assert.same({ { name = "jsonls", command = "vscode-json-language-server" } }, config.list("lsp"))
	end)

	it("accepts and snapshots structured nvim-lint declarations", function()
		local opts = {
			nvim_lint = { "selene", { name = "oxlint", command = "oxlint" } },
		}
		config.setup(opts)
		assert.is_nil(config.error())
		opts.nvim_lint[2].command = "mutated"
		local first = config.get()
		first.nvim_lint[2].name = "mutated"
		local listed = config.list("nvim_lint")
		listed[2].command = "mutated"
		assert.same({ "selene", { name = "oxlint", command = "oxlint" } }, config.get().nvim_lint)
		assert.same({ "selene", { name = "oxlint", command = "oxlint" } }, config.list("nvim_lint"))
	end)

	it("rejects invalid nvim-lint declarations and conflicting duplicates", function()
		local metatable_entry = setmetatable({ name = "oxlint", command = "oxlint" }, {})
		local invalid = {
			7,
			{},
			{ name = "oxlint" },
			{ command = "oxlint" },
			{ name = "oxlint", command = "oxlint", extra = true },
			{ name = "bad name", command = "oxlint" },
			{ name = "oxlint", command = "bin/oxlint" },
			metatable_entry,
		}
		for index, entry in ipairs(invalid) do
			config.setup({ nvim_lint = { entry } })
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
		end
		for _, entries in ipairs({
			{ "oxlint", { name = "oxlint", command = "oxlint" } },
			{ { name = "oxlint", command = "oxlint" }, "oxlint" },
			{ { name = "oxlint", command = "a" }, { name = "oxlint", command = "b" } },
			{ { name = "oxlint", command = "b" }, { name = "oxlint", command = "a" } },
		}) do
			config.setup({ nvim_lint = entries })
			assert.is_string(config.error())
		end
	end)

	it("keeps identical nvim-lint duplicates for the normal duplicate warning", function()
		config.setup({
			nvim_lint = {
				"selene",
				"selene",
				{ name = "oxlint", command = "oxlint" },
				{ name = "oxlint", command = "oxlint" },
			},
		})
		assert.is_nil(config.error())
	end)

	it("rejects malformed Conform formatter lists", function()
		local fixtures = {
			{ "" },
			{ "bad\nname" },
			{ string.rep("x", 129) },
			{ { name = "stylua" } },
			setmetatable({ "stylua" }, {}),
		}
		for index, conform in ipairs(fixtures) do
			config.setup({ conform = conform })
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
		end
	end)

	it("always rejects the old lint setup tombstone", function()
		for _, value in ipairs({ {}, { "selene" }, false, "selene" }) do
			config.setup({ lint = value })
			assert.is_truthy(config.error():find("nvim_lint", 1, true))
			assert.is_nil(config.list("lint"))
		end
	end)

	it("keeps reserved option authority private", function()
		assert.is_nil(config.OPTIONS)
		assert.is_true(config.is_option("install"))
		assert.is_true(config.is_option("lint"))
		assert.is_true(config.is_option("mason_install_fallback"))
		assert.is_false(config.is_option("nvim_lint"))
	end)
end)
