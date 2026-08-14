---@module 'luassert'
local assert = require("luassert")

local function result()
	return { entries = {}, skipped = {}, bufnr = 1, notes = {} }
end

local function harness(overrides)
	local events = {}
	local value = result()
	local timer = { stops = 0, closes = 0 }
	function timer:start(_, _, callback)
		events[#events + 1] = "timer.start"
		self.callback = callback
	end
	function timer:stop()
		self.stops = self.stops + 1
	end
	function timer:close()
		self.closes = self.closes + 1
	end
	local opts = {
		config = { mason_install_fallback = true },
		mason = { has_setup = true },
		registry = {
			refresh = function(callback)
				events[#events + 1] = "refresh"
				callback(true, {})
			end,
		},
		probe = function()
			events[#events + 1] = "probe"
			return value
		end,
		enrich = function(input, callback)
			events[#events + 1] = "enrich"
			callback(input)
		end,
		handoff = {
			prepare = function()
				events[#events + 1] = "prepare"
				return { enabled = true, items = {} }
			end,
			execute = function()
				events[#events + 1] = "execute"
			end,
		},
		report = function()
			events[#events + 1] = "report"
			return true
		end,
		timer_factory = function()
			events[#events + 1] = "timer.create"
			return timer
		end,
		schedule = function(callback)
			callback()
		end,
		defer = function(callback)
			callback()
		end,
		notify = function()
			events[#events + 1] = "notify"
		end,
	}
	for key, item in pairs(overrides or {}) do
		opts[key] = item
	end
	package.loaded["muster.automatic"] = nil
	local automatic = require("muster.automatic")
	automatic.reset()
	return automatic, opts, events, value, timer
end

local function count(events, wanted)
	local total = 0
	for _, event in ipairs(events) do
		if event == wanted then
			total = total + 1
		end
	end
	return total
end

describe("automatic Mason pipeline", function()
	it("uses the existing E1 check path when installation is disabled", function()
		local callback
		local automatic, opts, events = harness({ config = { mason_install_fallback = false } })
		opts.check = function(_, done)
			events[#events + 1] = "check"
			callback = done
		end
		automatic.run(nil, opts)
		assert.same({ "check" }, events)
		callback(result())
		assert.same({ "check", "report" }, events)
		assert.same({ state = "reported" }, automatic.status())
	end)

	it("orders probe, refresh, enrich, prepare, report, then execute", function()
		local automatic, opts, events, _, timer = harness()
		automatic.run(nil, opts)
		assert.same({
			"probe",
			"timer.create",
			"timer.start",
			"refresh",
			"enrich",
			"prepare",
			"report",
			"execute",
		}, events)
		assert.equals(1, timer.stops)
		assert.equals(1, timer.closes)
		assert.same({ state = "reported" }, automatic.status())
	end)

	it("accepts Neovim's userdata timer handles", function()
		local automatic, opts, events = harness({ timer_factory = vim.uv.new_timer })
		automatic.run(nil, opts)
		assert.equals(1, count(events, "report"))
		assert.equals(1, count(events, "execute"))
		assert.same({ state = "reported" }, automatic.status())
	end)

	it("executes after a suppressed report, but not after report or prepare raises", function()
		local automatic, opts, events = harness()
		opts.report = function()
			events[#events + 1] = "report"
			return false
		end
		automatic.run(nil, opts)
		assert.equals(1, count(events, "execute"))
		assert.equals("reported", automatic.status().state)

		automatic, opts, events = harness()
		opts.report = function()
			events[#events + 1] = "report"
			error("render exploded")
		end
		automatic.run(nil, opts)
		assert.equals(0, count(events, "execute"))
		assert.equals(1, count(events, "notify"))
		assert.equals("failed", automatic.status().state)

		local value
		automatic, opts, events, value = harness()
		opts.handoff.prepare = function()
			events[#events + 1] = "prepare"
			error("prepare exploded")
		end
		automatic.run(nil, opts)
		assert.equals(1, count(events, "report"))
		assert.equals(0, count(events, "execute"))
		assert.is_truthy(value.notes[1]:find("prepare", 1, true))
		assert.equals("reported", automatic.status().state)

		automatic, opts, events = harness()
		opts.handoff.execute = function()
			events[#events + 1] = "execute"
			error("execute exploded")
		end
		automatic.run(nil, opts)
		assert.equals(1, count(events, "report"))
		assert.equals(1, count(events, "execute"))
		assert.equals(1, count(events, "notify"))
		assert.equals("reported", automatic.status().state)
	end)

	it("uses failed status and completes exactly once for check, probe, and report raises", function()
		local fixtures = {
			{
				name = "check",
				configure = function(opts)
					opts.config = { mason_install_fallback = false }
					opts.check = function()
						error("check exploded\nwith detail")
					end
				end,
				expect_result = false,
			},
			{
				name = "probe",
				configure = function(opts)
					opts.probe = function()
						error("probe exploded\nwith detail")
					end
				end,
				expect_result = false,
			},
			{
				name = "report",
				configure = function(opts)
					opts.report = function()
						error("report exploded\nwith detail")
					end
				end,
				expect_result = true,
			},
		}
		for _, fixture in ipairs(fixtures) do
			local automatic, opts, _, value = harness()
			fixture.configure(opts)
			local completions = {}
			automatic.run(function(completed_result, status)
				completions[#completions + 1] = { result = completed_result, status = status }
			end, opts)
			assert.equals(1, #completions, fixture.name)
			assert.equals("failed", automatic.status().state, fixture.name)
			assert.equals("failed", completions[1].status.state, fixture.name)
			assert.is_truthy(automatic.status().reason:find(fixture.name .. " exploded", 1, true))
			assert.is_falsy(automatic.status().reason:find("\n", 1, true))
			if fixture.expect_result then
				assert.equals(value, completions[1].result)
			else
				assert.is_nil(completions[1].result)
			end
		end
	end)

	it("fails exactly once when check calls back and then raises", function()
		local automatic, opts, events = harness({ config = { mason_install_fallback = false } })
		opts.check = function(_, callback)
			callback(result())
			error("late check throw")
		end
		local completions = {}
		automatic.run(function(completed_result, status)
			completions[#completions + 1] = { result = completed_result, status = status }
		end, opts)
		assert.equals(1, #completions)
		assert.is_nil(completions[1].result)
		assert.equals("failed", completions[1].status.state)
		assert.equals("failed", automatic.status().state)
		assert.equals(0, count(events, "report"))
	end)

	it("settles synchronous, asynchronous, duplicate, and callback-then-throw refresh once", function()
		local refresh_callback
		local automatic, opts, events = harness()
		opts.registry = {
			refresh = function(callback)
				events[#events + 1] = "refresh"
				refresh_callback = callback
			end,
		}
		automatic.run(nil, opts)
		assert.same({ state = "running" }, automatic.status())
		refresh_callback(true, {})
		refresh_callback(false, "late")
		assert.equals(1, count(events, "report"))
		assert.equals(1, count(events, "execute"))

		automatic, opts, events = harness({
			registry = {
				refresh = function(callback)
					callback(true, {})
					error("refresh threw after callback")
				end,
			},
		})
		automatic.run(nil, opts)
		assert.equals(1, count(events, "report"))
		assert.equals(0, count(events, "prepare"))
		assert.equals(0, count(events, "execute"))
		assert.is_truthy(opts.probe().notes[1]:find("refresh failed", 1, true))
	end)

	it("retains degraded refresh reason after asynchronous enrichment completes", function()
		local enrich_callback
		local completions = {}
		local automatic, opts = harness({
			registry = {
				refresh = function(callback)
					callback(false, "offline registry")
				end,
			},
		})
		opts.enrich = function(_, callback)
			enrich_callback = callback
		end
		automatic.run(function(completed_result, status)
			completions[#completions + 1] = { result = completed_result, status = status }
		end, opts)
		assert.same({ state = "running" }, automatic.status())
		enrich_callback(opts.probe())
		assert.equals("reported", automatic.status().state)
		assert.is_truthy(automatic.status().reason:find("offline registry", 1, true))
		assert.equals(1, #completions)
		assert.equals(automatic.status().reason, completions[1].status.reason)
	end)

	it("reports refresh callback failure or raise-before-callback and skips hand-off", function()
		for _, refresh in ipairs({
			function(callback)
				callback(false, "offline\nregistry")
			end,
			function()
				error("refresh invocation exploded")
			end,
		}) do
			local automatic, opts, events, value, timer = harness()
			opts.registry = { refresh = refresh }
			automatic.run(nil, opts)
			assert.equals(1, count(events, "enrich"))
			assert.equals(1, count(events, "report"))
			assert.equals(0, count(events, "prepare"))
			assert.equals(0, count(events, "execute"))
			assert.is_truthy(value.notes[1]:find("refresh failed", 1, true))
			assert.is_falsy(value.notes[1]:find("\n", 1, true))
			assert.equals(1, timer.stops)
			assert.equals(1, timer.closes)
			assert.equals("reported", automatic.status().state)
		end
	end)

	it("uses the deferred bridge when the primary scheduler rejects", function()
		local automatic, opts, events = harness()
		opts.schedule = function()
			error("primary rejected")
		end
		automatic.run(nil, opts)
		assert.equals(1, count(events, "report"))
		assert.equals(1, count(events, "execute"))
		assert.equals("reported", automatic.status().state)
	end)

	it("lets the watchdog settle an uncalled refresh and ignores a late callback", function()
		local refresh_callback
		local automatic, opts, events, value, timer = harness()
		opts.registry = {
			refresh = function(callback)
				events[#events + 1] = "refresh"
				refresh_callback = callback
			end,
		}
		automatic.run(nil, opts)
		timer.callback()
		assert.equals(1, count(events, "report"))
		assert.equals(0, count(events, "prepare"))
		assert.is_truthy(value.notes[1]:find("timed out", 1, true))
		refresh_callback(true, {})
		assert.equals(1, count(events, "report"))
		assert.equals(1, timer.stops)
		assert.equals(1, timer.closes)
	end)

	it("skips refresh and installation when watchdog creation or start fails", function()
		local automatic, opts, events, value = harness({
			timer_factory = function()
				error("factory\nfailed")
			end,
		})
		automatic.run(nil, opts)
		assert.equals(0, count(events, "refresh"))
		assert.equals(1, count(events, "enrich"))
		assert.equals(1, count(events, "report"))
		assert.is_truthy(value.notes[1]:find("watchdog setup failed", 1, true))
		assert.is_falsy(value.notes[1]:find("\n", 1, true))
		assert.equals("reported", automatic.status().state)

		local timer
		automatic, opts, events, value, timer = harness()
		timer.start = function()
			error("start failed")
		end
		automatic.run(nil, opts)
		assert.equals(0, count(events, "refresh"))
		assert.equals(1, timer.stops)
		assert.equals(1, timer.closes)
		assert.equals(1, count(events, "report"))
	end)

	it("records bridge_failed when callback or watchdog cannot cross either bridge", function()
		local refresh_callback
		local reject = function()
			error("bridge rejected")
		end
		local automatic, opts, events, _, timer = harness({
			registry = {
				refresh = function(callback)
					refresh_callback = callback
				end,
			},
			schedule = reject,
			defer = reject,
		})
		automatic.run(nil, opts)
		refresh_callback(true, {})
		assert.equals("bridge_failed", automatic.status().state)
		assert.is_truthy(automatic.status().reason:find("safe%-context bridge"))
		assert.equals(0, count(events, "enrich"))
		assert.equals(0, count(events, "report"))
		assert.equals(1, timer.stops)
		assert.equals(1, timer.closes)
		timer.callback()
		refresh_callback(true, {})
		assert.equals(1, timer.closes)

		automatic, opts, events, _, timer = harness({
			registry = { refresh = function() end },
			schedule = reject,
			defer = reject,
		})
		automatic.run(nil, opts)
		timer.callback()
		assert.equals("bridge_failed", automatic.status().state)
		assert.equals(0, count(events, "report"))
		assert.equals(1, timer.closes)
	end)

	it("does not force-load Mason and skips hand-off unless loaded and set up", function()
		for _, fixture in ipairs({
			{ mason = false, registry = false, text = "not loaded" },
			{ mason = { has_setup = false }, registry = {}, text = "not been set up" },
		}) do
			local automatic, opts, events, value = harness()
			opts.mason = fixture.mason
			opts.registry = fixture.registry
			automatic.run(nil, opts)
			assert.equals(0, count(events, "refresh"))
			assert.equals(1, count(events, "enrich"))
			assert.equals(1, count(events, "report"))
			assert.equals(0, count(events, "prepare"))
			assert.is_truthy(value.notes[1]:find(fixture.text, 1, true))
		end
	end)
end)
