---@module 'luassert'
local assert = require("luassert")

local env = require("muster.env")

describe("env.spawn", function()
	it("schedules asynchronous capture with closed stdin and both output streams", function()
		local saved_system = vim.system
		local saved_schedule = vim.schedule
		local observed
		local scheduled
		vim.system = function(cmd, opts, callback)
			observed = { cmd = cmd, opts = opts }
			callback({ code = 0, signal = 15, stdout = "out", stderr = "err" })
			return {}
		end
		vim.schedule = function(callback)
			scheduled = callback
		end

		local result
		env.spawn({ "tool", "--version" }, { timeout_ms = 42 }, function(value)
			result = value
		end)
		vim.system = saved_system
		vim.schedule = saved_schedule

		assert.same({ "tool", "--version" }, observed.cmd)
		assert.is_false(observed.opts.stdin)
		assert.is_true(observed.opts.text)
		assert.equals(42, observed.opts.timeout)
		assert.is_nil(result)
		assert.is_function(scheduled)
		scheduled()
		assert.same({ code = 0, signal = 15, output = "out\nerr" }, result)
	end)

	it("falls back outside fast-event context when primary scheduling rejects", function()
		local saved_system = vim.system
		local saved_schedule = vim.schedule
		local saved_defer = vim.defer_fn
		local deferred
		vim.system = function(_, _, callback)
			callback({ code = 0, signal = 0, stdout = "partial", stderr = "" })
			return {}
		end
		vim.schedule = function()
			error("scheduler rejected")
		end
		vim.defer_fn = function(callback, delay)
			assert.equals(0, delay)
			deferred = callback
		end

		local result
		local ok = pcall(env.spawn, { "tool" }, nil, function(value)
			result = value
		end)
		vim.system = saved_system
		vim.schedule = saved_schedule
		vim.defer_fn = saved_defer

		assert.is_true(ok)
		assert.is_nil(result)
		assert.is_function(deferred)
		deferred()
		assert.equals(-1, result.code)
		assert.is_truthy(result.error:find("scheduler rejected", 1, true))
	end)

	it("delivers a real process completion outside fast-event context", function()
		local result
		local fast
		env.spawn({ "sh", "-c", "printf ok" }, nil, function(value)
			result = value
			fast = vim.in_fast_event()
		end)
		assert.is_true(vim.wait(5000, function()
			return result ~= nil
		end, 10))
		assert.is_false(fast)
		assert.equals(0, result.code)
		assert.equals(0, result.signal)
		assert.is_truthy(result.output:find("ok", 1, true))
	end)
end)
