---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")

local function harness(configured, fn)
	local saved_schedule = vim.schedule
	local saved_notify = vim.notify
	local saved_muster = package.loaded["muster"]
	local saved_report = package.loaded["muster.report"]
	local saved_runner = package.loaded["muster.runner"]
	local scheduled = {}
	local notifications = {}
	local check_callback
	local checks, reports = 0, 0
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end
	vim.notify = function(message, level, opts)
		notifications[#notifications + 1] = { message = message, level = level, opts = opts }
	end
	package.loaded["muster"] = {
		check = function(_, callback)
			checks = checks + 1
			check_callback = callback
		end,
	}
	package.loaded["muster.report"] = {
		emit = function()
			reports = reports + 1
		end,
	}
	package.loaded["muster.runner"] = nil
	config.reset()
	if configured then
		config.setup({})
	end
	local runner = require("muster.runner")
	local ok, err = pcall(fn, runner, scheduled, function()
		return check_callback
	end, function()
		return checks, reports
	end, notifications)
	vim.schedule = saved_schedule
	vim.notify = saved_notify
	package.loaded["muster"] = saved_muster
	package.loaded["muster.report"] = saved_report
	package.loaded["muster.runner"] = saved_runner
	config.reset()
	if not ok then
		error(err, 0)
	end
end

describe("runner.start async barrier", function()
	it("waits for enriched check completion and emits exactly once", function()
		harness(true, function(runner, scheduled, callback, counts)
			runner.start()
			assert.is_true(runner.has_run())
			assert.equals(1, #scheduled)
			assert.same({ 0, 0 }, { counts() })

			scheduled[1]()
			assert.same({ 1, 0 }, { counts() })
			local result = { entries = {}, skipped = {}, bufnr = 1, notes = {} }
			callback()(result)
			callback()(result)
			assert.same({ 1, 1 }, { counts() })
			runner.start()
			assert.equals(1, #scheduled)
		end)
	end)

	it("brands failures before and after enrichment", function()
		harness(true, function(runner, scheduled, _, _, notifications)
			package.loaded["muster"].check = function()
				error("probe exploded")
			end
			runner.start()
			scheduled[1]()
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1].message:find("muster: the startup check failed", 1, true))
			assert.is_truthy(notifications[1].message:find("probe exploded", 1, true))
			assert.equals(vim.log.levels.ERROR, notifications[1].level)
			assert.equals("muster", notifications[1].opts.title)
		end)

		harness(true, function(runner, scheduled, callback, _, notifications)
			package.loaded["muster.report"].emit = function()
				error("render exploded")
			end
			runner.start()
			scheduled[1]()
			callback()({ entries = {}, skipped = {}, bufnr = 1, notes = {} })
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1].message:find("muster: the startup check failed", 1, true))
			assert.is_truthy(notifications[1].message:find("render exploded", 1, true))
			assert.equals(vim.log.levels.ERROR, notifications[1].level)
			assert.equals("muster", notifications[1].opts.title)
		end)
	end)

	it("contains rejection of the initial scheduler", function()
		harness(true, function(runner, _, _, _, notifications)
			vim.schedule = function()
				error("scheduler exploded")
			end
			local ok = pcall(runner.start)
			assert.is_true(ok)
			assert.is_true(runner.has_run())
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1].message:find("scheduler exploded", 1, true))
		end)
	end)

	it("does not start check work when scheduling invokes then rejects", function()
		harness(true, function(runner, _, _, counts, notifications)
			local starts = 0
			package.loaded["muster"].check = function(_, callback)
				starts = starts + 1
				callback({ entries = {}, skipped = {}, bufnr = 1, notes = {} })
			end
			vim.schedule = function(fn)
				fn()
				error("scheduler rejected after invocation")
			end
			local ok = pcall(runner.start)
			assert.is_true(ok)
			assert.equals(0, starts)
			assert.same({ 0, 0 }, { counts() })
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1].message:find("after invocation", 1, true))
		end)
	end)

	it("contains failure even when vim.notify itself is broken", function()
		harness(true, function(runner, scheduled, callback)
			package.loaded["muster.report"].emit = function()
				vim.notify("reporting")
			end
			runner.start()
			scheduled[1]()
			vim.notify = function()
				error("notify exploded")
			end
			local ok = pcall(callback(), { entries = {}, skipped = {}, bufnr = 1, notes = {} })
			assert.is_true(ok, "the fallback notifier must not leak another scheduled exception")
		end)
	end)

	it("does nothing when setup was never called", function()
		harness(false, function(runner, scheduled, _, counts)
			runner.start()
			assert.is_false(runner.has_run())
			assert.equals(0, #scheduled)
			assert.same({ 0, 0 }, { counts() })
		end)
	end)
end)
