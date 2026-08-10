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
		config.reset()
		config.setup({ install = "npm" })
		assert.is_nil(config.get(), "an invalid config must not be applied")
	end)

	it("rejects a tool list that is not a table", function()
		config.setup({ conform = "stylua" })
		assert.is_nil(config.get())
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
