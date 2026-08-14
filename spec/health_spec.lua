---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")
local env = require("muster.env")
local registry = require("muster.registry")

---Capture what `health.check()` emits, without a real :checkhealth session.
---
---This file exists because the render layer had no specs at all, and the one
---fix that shipped a defect for four rounds running was the one whose code
---lived here.
local function render(fn)
	local saved = vim.health
	local calls = {}
	local function record(level)
		return function(msg)
			calls[#calls + 1] = { level = level, msg = tostring(msg) }
		end
	end
	vim.health = {
		start = record("start"),
		ok = record("ok"),
		info = record("info"),
		warn = record("warn"),
		error = record("error"),
	}
	local ok, err = pcall(fn)
	vim.health = saved
	if not ok then
		error(err, 0)
	end
	return calls
end

local function levels(calls)
	return vim.tbl_map(function(c)
		return c.level
	end, calls)
end

local function has(calls, level, needle)
	return vim.iter(calls):any(function(c)
		return c.level == level and c.msg:find(needle, 1, true) ~= nil
	end)
end

describe("health.check", function()
	before_each(function()
		config.reset()
		registry.reset()
	end)

	it("does not raise when setup() was never called", function()
		-- The whole function dereferenced a nil config after the early return
		-- was removed, so a green page over missing tools became a traceback
		-- over the same missing tools.
		local calls = render(function()
			require("muster.health").check()
		end)
		assert.is_truthy(has(calls, "info", "setup() has not been called"))
	end)

	it("reports the rejected install tombstone as an error, not as never-called", function()
		config.setup({ install = "mason" })
		local calls = render(function()
			require("muster.health").check()
		end)
		assert.is_truthy(has(calls, "error", "rejected"))
		assert.is_truthy(has(calls, "error", "mason_install_fallback"))
		assert.is_falsy(has(calls, "info", "setup() has not been called"))
	end)

	it("documents automatic-only Mason authority and renders a terminal bridge failure", function()
		config.setup({ mason_install_fallback = true })
		local saved = package.loaded["muster.automatic"]
		package.loaded["muster.automatic"] = {
			status = function()
				return { state = "bridge_failed", reason = "both bridges rejected" }
			end,
		}
		local calls = render(function()
			require("muster.health").check()
		end)
		package.loaded["muster.automatic"] = saved
		assert.is_truthy(has(calls, "info", "only the automatic startup run may refresh or install"))
		assert.is_truthy(has(calls, "info", "health check is read-only"))
		assert.is_truthy(has(calls, "error", "both bridges rejected"))
		assert.is_falsy(has(calls, "warn", "not implemented"))
	end)

	it("renders a loaded automatic failed state honestly on the E1 path too", function()
		config.setup({})
		local saved = package.loaded["muster.automatic"]
		package.loaded["muster.automatic"] = {
			status = function()
				return { state = "failed", reason = "probe failed safely" }
			end,
		}
		local calls = render(function()
			require("muster.health").check()
		end)
		package.loaded["muster.automatic"] = saved
		assert.is_truthy(has(calls, "error", "automatic startup run failed"))
		assert.is_truthy(has(calls, "error", "probe failed safely"))
	end)

	it("does not load the automatic module during a read-only health check", function()
		config.setup({ mason_install_fallback = true })
		local saved = package.loaded["muster.automatic"]
		package.loaded["muster.automatic"] = nil
		render(function()
			require("muster.health").check()
		end)
		assert.is_nil(package.loaded["muster.automatic"])
		package.loaded["muster.automatic"] = saved
	end)

	it("never renders a page with no warn and no error while tools are unchecked", function()
		registry.register({
			id = "ghost",
			available = function()
				return false, "host plugin is not loaded"
			end,
			identity = tostring,
			probe = function()
				return { status = "missing", binary = "x" }
			end,
		})
		config.setup({ ghost = { "one", "two" } })
		local calls = render(function()
			require("muster.health").check()
		end)
		local loud = vim.iter(levels(calls)):any(function(l)
			return l == "warn" or l == "error"
		end)
		assert.is_true(loud, "two unchecked tools must not render as a clean page")
		assert.is_falsy(has(calls, "info", "no tools declared"))
	end)

	it("stays on the synchronous probe path without enrichment processes", function()
		registry.register({
			id = "ghost",
			available = function()
				return true
			end,
			identity = tostring,
			probe = function()
				return { status = "missing", binary = "ghost" }
			end,
		})
		config.setup({ ghost = { "ghost" } })

		local saved_executable = env.executable
		local saved_spawn = env.spawn
		local spawns = 0
		env.executable = function(name)
			return "/fake/bin/" .. name
		end
		env.spawn = function()
			spawns = spawns + 1
		end
		local ok, calls = pcall(render, function()
			require("muster.health").check()
		end)
		env.executable = saved_executable
		env.spawn = saved_spawn
		assert.is_true(ok)
		assert.is_table(calls)
		assert.equals(0, spawns)
	end)

	it("does not call a declared built-in key a typo", function()
		config.setup({ conform = { "stylua" } })
		local calls = render(function()
			require("muster.health").check()
		end)
		assert.is_falsy(has(calls, "error", "matches no registered adapter"))
	end)
end)
