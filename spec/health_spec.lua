---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")
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

	it("reports a rejected setup as an error, not as never-called", function()
		config.setup({ conform = "not a list" })
		local calls = render(function()
			require("muster.health").check()
		end)
		assert.is_truthy(has(calls, "error", "rejected"))
		assert.is_falsy(has(calls, "info", "setup() has not been called"))
	end)

	it("says plainly that install = mason does nothing yet", function()
		config.setup({ install = "mason" })
		local calls = render(function()
			require("muster.health").check()
		end)
		assert.is_truthy(has(calls, "warn", "not implemented yet"))
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

	it("does not call a declared built-in key a typo", function()
		config.setup({ conform = { "stylua" } })
		local calls = render(function()
			require("muster.health").check()
		end)
		assert.is_falsy(has(calls, "error", "matches no registered adapter"))
	end)
end)
