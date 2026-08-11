---@module 'luassert'
local assert = require("luassert")

local function with_modules(fn)
	local saved_schedule = vim.schedule
	local saved_muster = package.loaded["muster"]
	local saved_check = package.loaded["muster.check"]
	local saved_enrich = package.loaded["muster.enrich"]
	local raw = { entries = {}, skipped = {}, bufnr = 17, notes = {} }
	local scheduled = {}
	local probed
	local enriched
	local enrich_calls = 0
	vim.schedule = function(callback)
		scheduled[#scheduled + 1] = callback
	end
	package.loaded["muster.check"] = {
		run = function(bufnr)
			probed = bufnr
			return raw
		end,
	}
	package.loaded["muster.enrich"] = {
		run = function(result, callback)
			enrich_calls = enrich_calls + 1
			enriched = { result = result, callback = callback }
		end,
	}
	package.loaded["muster"] = nil
	local muster = require("muster")
	local ok, err = pcall(
		fn,
		muster,
		raw,
		function()
			return probed
		end,
		function()
			return enriched
		end,
		scheduled,
		function()
			return enrich_calls
		end
	)
	vim.schedule = saved_schedule
	package.loaded["muster"] = saved_muster
	package.loaded["muster.check"] = saved_check
	package.loaded["muster.enrich"] = saved_enrich
	if not ok then
		error(err, 0)
	end
end

describe("muster probe/check API", function()
	it("probe returns the synchronous raw Result without enrichment", function()
		with_modules(function(muster, raw, probed, enriched)
			assert.equals(raw, muster.probe(17))
			assert.equals(17, probed())
			assert.is_nil(enriched())
		end)
	end)

	it("check schedules one guarded enrichment and delivers only one complete callback", function()
		with_modules(function(muster, raw, probed, enriched, scheduled, enrich_calls)
			local callbacks = 0
			assert.is_nil(muster.check(23, function(result)
				callbacks = callbacks + 1
				assert.equals(raw, result)
			end))
			assert.equals(23, probed())
			assert.equals(1, #scheduled)
			assert.is_nil(enriched())
			assert.equals(0, enrich_calls())

			scheduled[1]()
			scheduled[1]()
			assert.equals(1, enrich_calls(), "a duplicate scheduler execution must not start enrichment twice")
			assert.equals(raw, enriched().result)
			enriched().callback(raw)
			enriched().callback(raw)
			assert.equals(1, callbacks)
		end)
	end)

	it("requires an explicit callback before probing", function()
		with_modules(function(muster, _, probed)
			local ok, err = pcall(muster.check, 1, nil)
			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("callback", 1, true))
			assert.is_nil(probed())
		end)
	end)

	it("reports scheduler rejection synchronously instead of losing the callback", function()
		with_modules(function(muster)
			vim.schedule = function()
				error("scheduler rejected")
			end
			local ok, err = pcall(muster.check, 1, function() end)
			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("scheduler rejected", 1, true))
		end)
	end)

	it("does not start enrichment when the scheduler invokes then rejects", function()
		with_modules(function(muster, _, _, enriched, _, enrich_calls)
			local callbacks = 0
			vim.schedule = function(fn)
				fn()
				error("scheduler rejected after invocation")
			end
			local ok, err = pcall(muster.check, 1, function()
				callbacks = callbacks + 1
			end)
			assert.is_false(ok)
			assert.is_truthy(tostring(err):find("after invocation", 1, true))
			assert.is_nil(enriched())
			assert.equals(0, enrich_calls())
			assert.equals(0, callbacks)
		end)
	end)
end)
