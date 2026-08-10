---@module 'luassert'
local assert = require("luassert")

local env = require("muster.env")

describe("env.spawn", function()
	it("supports asynchronous capture with closed stdin and both output streams", function()
		local saved = vim.system
		local observed
		vim.system = function(cmd, opts, callback)
			observed = { cmd = cmd, opts = opts }
			callback({ code = 0, stdout = "out", stderr = "err" })
			return {}
		end

		local result
		env.spawn({ "tool", "--version" }, { timeout_ms = 42 }, function(value)
			result = value
		end)
		vim.system = saved

		assert.same({ "tool", "--version" }, observed.cmd)
		assert.is_false(observed.opts.stdin)
		assert.is_true(observed.opts.text)
		assert.equals(42, observed.opts.timeout)
		assert.same({ code = 0, output = "out\nerr" }, result)
	end)
end)
