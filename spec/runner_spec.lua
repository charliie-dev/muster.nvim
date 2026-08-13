---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")

local function harness(configured, fn)
	local saved_schedule = vim.schedule
	local saved_defer_fn = vim.defer_fn
	local saved_notify = vim.notify
	local saved_automatic = package.loaded["muster.automatic"]
	local saved_automatic_preload = package.preload["muster.automatic"]
	local saved_runner = package.loaded["muster.runner"]
	local scheduled = {}
	local deferred = {}
	local notifications = {}
	local runs = 0
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end
	vim.defer_fn = function(callback, delay)
		deferred[#deferred + 1] = { callback = callback, delay = delay }
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
	end, notifications, deferred)
	vim.schedule = saved_schedule
	vim.defer_fn = saved_defer_fn
	vim.notify = saved_notify
	package.loaded["muster.automatic"] = saved_automatic
	package.preload["muster.automatic"] = saved_automatic_preload
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

	it("contains automatic module loading failure", function()
		harness(true, function(runner, scheduled, _, notifications)
			package.loaded["muster.automatic"] = nil
			package.preload["muster.automatic"] = function()
				error("automatic module exploded")
			end
			runner.start()
			assert.is_true(pcall(scheduled[1]))
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1].message:find("startup check failed", 1, true))
			assert.is_truthy(notifications[1].message:find("automatic module exploded", 1, true))
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

describe("runner.defer_start", function()
	it("runs once from an accepted scheduled callback", function()
		harness(true, function(runner, scheduled, runs, _, deferred)
			runner.defer_start()
			assert.equals(1, #scheduled)
			assert.equals(0, #deferred)
			assert.equals(0, runs())
			scheduled[1]()
			assert.is_true(runner.has_run())
			assert.equals(1, runs())
		end)
	end)

	it("falls back when schedule rejects before invocation", function()
		harness(true, function(runner, _, runs, _, deferred)
			vim.schedule = function()
				error("schedule rejected")
			end
			assert.is_true(pcall(runner.defer_start))
			assert.equals(1, #deferred)
			assert.equals(0, deferred[1].delay)
			assert.equals(0, runs())
			deferred[1].callback()
			assert.equals(1, runs())
		end)
	end)

	it("falls back after an invoke-then-throw scheduler without starting early", function()
		harness(true, function(runner, _, runs, _, deferred)
			vim.schedule = function(callback)
				callback()
				error("schedule rejected after invocation")
			end
			runner.defer_start()
			assert.equals(0, runs())
			assert.equals(1, #deferred)
			deferred[1].callback()
			assert.equals(1, runs())
		end)
	end)

	it("contains an invoke-then-throw defer fallback without starting early", function()
		harness(true, function(runner, _, runs)
			local runs_during_callback
			vim.schedule = function()
				error("schedule rejected")
			end
			vim.defer_fn = function(callback)
				callback()
				runs_during_callback = runs()
				error("defer rejected after invocation")
			end
			assert.is_true(pcall(runner.defer_start))
			assert.equals(0, runs_during_callback)
			assert.equals(1, runs())
		end)
	end)

	it("uses a contained immediate fallback when both bridges reject", function()
		harness(true, function(runner, _, runs)
			vim.schedule = function()
				error("schedule rejected")
			end
			vim.defer_fn = function()
				error("defer rejected")
			end
			assert.is_true(pcall(runner.defer_start))
			assert.equals(1, runs())
		end)
	end)

	it("reports a deferred startup failure exactly once", function()
		harness(true, function(runner, scheduled, _, notifications)
			runner.start = function()
				error("deferred start exploded")
			end
			runner.defer_start()
			assert.equals(1, #scheduled)
			scheduled[1]()
			scheduled[1]()
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1].message:find("startup check failed", 1, true))
			assert.is_truthy(notifications[1].message:find("deferred start exploded", 1, true))
		end)
	end)
end)
