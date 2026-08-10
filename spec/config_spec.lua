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

	it("defaults install to false and the startup notification to on", function()
		config.setup({})
		assert.is_false(config.get().install)
		assert.is_true(config.get().notify_on_startup)
	end)

	it("accepts false or 'mason' for install and rejects anything else", function()
		config.setup({ install = "mason" })
		assert.equals("mason", config.get().install)
		assert.is_nil(config.error())
		config.reset()
		config.setup({ install = "npm" })
		assert.is_string(config.error(), "a rejection must be recorded")
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

	it("never mistakes an option key for a tool list", function()
		config.setup({ install = "mason" })
		assert.is_nil(config.list("install"))
	end)
end)
