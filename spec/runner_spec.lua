---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")

local function harness(configured, fn)
	local saved_schedule = vim.schedule
	local saved_notify = vim.notify
	local saved_automatic = package.loaded["muster.automatic"]
	local saved_runner = package.loaded["muster.runner"]
	local scheduled = {}
	local notifications = {}
	local runs = 0
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end
	vim.notify = function(message, level, opts)
		notifications[#notifications + 1] = { message = message, level = level, opts = opts }
	end
	package.loaded["muster.automatic"] = {
		run = function()
			runs = runs + 1
		end,
	}
	package.loaded["muster.runner"] = nil
	config.reset()
	if configured then
		config.setup({})
	end
	local runner = require("muster.runner")
	local ok, err = pcall(fn, runner, scheduled, function()
		return runs
	end, notifications)
	vim.schedule = saved_schedule
	vim.notify = saved_notify
	package.loaded["muster.automatic"] = saved_automatic
	package.loaded["muster.runner"] = saved_runner
	config.reset()
	if not ok then
		error(err, 0)
	end
end

describe("runner.start", function()
	it("is the single guarded production caller of automatic.run", function()
		harness(true, function(runner, scheduled, runs)
			runner.start()
			assert.is_true(runner.has_run())
			assert.equals(1, #scheduled)
			assert.equals(0, runs())
			scheduled[1]()
			assert.equals(1, runs())
			runner.start()
			assert.equals(1, #scheduled)
			assert.equals(1, runs())
		end)
	end)

	it("contains automatic pipeline failure", function()
		harness(true, function(runner, scheduled, _, notifications)
			package.loaded["muster.automatic"].run = function()
				error("pipeline exploded")
			end
			runner.start()
			scheduled[1]()
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1].message:find("startup check failed", 1, true))
			assert.is_truthy(notifications[1].message:find("pipeline exploded", 1, true))
			assert.equals(vim.log.levels.ERROR, notifications[1].level)
		end)
	end)

	it("keeps scheduler rejection health-visible and allows one later retry", function()
		harness(true, function(runner, scheduled, runs, notifications)
			vim.schedule = function(callback)
				callback()
				error("scheduler rejected after invocation")
			end
			assert.is_true(pcall(runner.start))
			assert.is_false(runner.has_run())
			assert.equals(0, runs())
			assert.equals(1, #notifications)

			local saved_health = vim.health
			local health_messages = {}
			local function record(message)
				health_messages[#health_messages + 1] = tostring(message)
			end
			vim.health = { start = record, ok = record, info = record, warn = record, error = record }
			require("muster.health").check()
			vim.health = saved_health
			assert.is_true(vim.iter(health_messages):any(function(message)
				return message:find("has not run this session", 1, true) ~= nil
			end))

			vim.schedule = function(callback)
				scheduled[#scheduled + 1] = callback
			end
			runner.start()
			assert.is_true(runner.has_run())
			assert.equals(1, #scheduled)
			scheduled[1]()
			assert.equals(1, runs())
			runner.start()
			assert.equals(1, #scheduled)
			assert.equals(1, runs())
		end)
	end)

	it("allows retry after scheduler rejects before invocation", function()
		harness(true, function(runner, scheduled, runs)
			vim.schedule = function()
				error("scheduler rejected")
			end
			runner.start()
			assert.is_false(runner.has_run())
			assert.equals(0, runs())
			vim.schedule = function(callback)
				scheduled[#scheduled + 1] = callback
			end
			runner.start()
			assert.is_true(runner.has_run())
			scheduled[1]()
			assert.equals(1, runs())
		end)
	end)

	it("contains failure even when vim.notify is broken", function()
		harness(true, function(runner, scheduled)
			package.loaded["muster.automatic"].run = function()
				error("pipeline exploded")
			end
			runner.start()
			vim.notify = function()
				error("notify exploded")
			end
			assert.is_true(pcall(scheduled[1]))
		end)
	end)

	it("does nothing when setup was never called", function()
		harness(false, function(runner, scheduled, runs)
			runner.start()
			assert.is_false(runner.has_run())
			assert.equals(0, #scheduled)
			assert.equals(0, runs())
		end)
	end)
end)
