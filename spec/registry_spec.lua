---@module 'luassert'
local assert = require("luassert")

local registry = require("muster.registry")

---@return muster.Adapter
local function fake(id, overrides)
	return vim.tbl_extend("force", {
		id = id,
		available = function()
			return true
		end,
		identity = tostring,
		probe = function()
			return { status = "missing", binary = "x" }
		end,
	}, overrides or {})
end

describe("registry", function()
	before_each(function()
		registry.reset()
	end)

	it("registers and returns an adapter", function()
		local adapter = fake("demo")
		registry.register(adapter)
		assert.equals(adapter, registry.get("demo"))
	end)

	it("errors rather than silently overwriting a registered id", function()
		registry.register(fake("demo"))
		assert.has_error(function()
			registry.register(fake("demo"))
		end)
	end)

	it("rejects an adapter missing a required member", function()
		assert.has_error(function()
			registry.register({ id = "bad" })
		end)
		assert.has_error(function()
			registry.register(fake("bad", { probe = "not a function" }))
		end)
	end)

	it("accepts an adapter without the optional live member", function()
		assert.has_no.errors(function()
			registry.register(fake("nolive"))
		end)
		assert.is_nil(registry.get("nolive").live)
	end)

	it("rejects a live member that is not a function", function()
		assert.has_error(function()
			registry.register(fake("badlive", { live = 42 }))
		end)
	end)

	it("loads the five builtins idempotently", function()
		registry.load_builtins()
		local first = registry.get("conform")
		registry.load_builtins()
		assert.equals(first, registry.get("conform"))
		for _, id in ipairs({ "lsp", "conform", "lint", "dap", "none_ls" }) do
			assert.is_table(registry.get(id), id .. " should be registered")
		end
	end)
end)
