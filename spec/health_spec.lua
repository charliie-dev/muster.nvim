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

describe("Mason result severity", function()
	it("keeps enum and severity state private", function()
		local result = require("muster.mason_result")
		local outcomes = result.outcomes()
		outcomes[1] = "corrupt"
		assert.equals("planned", result.outcomes()[1])
		assert.same({
			outcome = "unknown",
			availability = "not_checked",
			attestation = "not_checked",
			error = "invalid Mason install result",
		}, result.normalize("corrupt"))
		assert.equals("error", result.severity("corrupt"))
		assert.equals("error", result.severity({ outcome = "completed" }))
	end)
end)

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

	it("renders reported reasons as degraded warnings", function()
		config.setup({})
		local saved = package.loaded["muster.automatic"]
		package.loaded["muster.automatic"] = {
			status = function()
				return { state = "reported", reason = "refresh degraded" }
			end,
		}
		local calls = render(function()
			require("muster.health").check()
		end)
		package.loaded["muster.automatic"] = saved
		assert.is_truthy(has(calls, "warn", "automatic startup run degraded"))
		assert.is_truthy(has(calls, "warn", "refresh degraded"))
	end)

	it("renders all dimensions and applies the closed terminal severity matrix", function()
		config.setup({ mason_install_fallback = true })
		local saved = package.loaded["muster.automatic"]
		package.loaded["muster.automatic"] = {
			status = function()
				return {
					state = "reported",
					mason = {
						items = {
							{
								package = "partial",
								outcome = "completed",
								availability = "found",
								attestation = "partial",
								attestation_reason = "closed compiler gap",
							},
							{
								package = "failed",
								outcome = "completed",
								availability = "found",
								attestation = "failed",
								attestation_reason = "receipt mismatch",
							},
						},
					},
				}
			end,
		}
		local calls = render(function()
			require("muster.health").check()
		end)
		package.loaded["muster.automatic"] = saved
		assert.is_truthy(has(calls, "warn", "outcome=completed availability=found attestation=partial"))
		assert.is_truthy(has(calls, "warn", "closed compiler gap"))
		assert.is_truthy(has(calls, "error", "outcome=completed availability=found attestation=failed"))
		assert.is_truthy(has(calls, "error", "receipt mismatch"))
	end)

	it("renders a verified valid package as INFO and malformed packages as fixed ERROR", function()
		config.setup({ mason_install_fallback = true })
		local saved = package.loaded["muster.automatic"]
		local package_name = string.rep("a", 120) .. ".tool-1"
		package.loaded["muster.automatic"] = {
			status = function()
				return {
					state = "reported",
					mason = {
						items = {
							{
								package = package_name,
								outcome = "completed",
								availability = "found",
								attestation = "full",
							},
							{ package = "", outcome = "completed", availability = "found", attestation = "full" },
						},
					},
				}
			end,
		}
		local calls = render(function()
			require("muster.health").check()
		end)
		package.loaded["muster.automatic"] = saved
		assert.is_truthy(has(calls, "info", "outcome=completed availability=found attestation=full"))
		assert.is_truthy(has(calls, "error", "Mason package unknown: outcome=unknown"))
		assert.is_truthy(has(calls, "error", "malformed Mason status item"))
	end)

	it("renders retained-plan malformed DTOs as ERROR", function()
		config.setup({ mason_install_fallback = true })
		local saved = package.loaded["muster.automatic"]
		package.loaded["muster.automatic"] = {
			status = function()
				return {
					state = "reported",
					mason = {
						items = {
							{
								package = "unknown",
								outcome = "unknown",
								availability = "not_checked",
								attestation = "not_checked",
								error = "malformed Mason status item",
							},
						},
					},
				}
			end,
		}
		local calls = render(function()
			require("muster.health").check()
		end)
		package.loaded["muster.automatic"] = saved
		assert.is_truthy(has(calls, "error", "Mason package unknown: outcome=unknown"))
		assert.is_truthy(has(calls, "error", "malformed Mason status item"))
	end)

	it("renders corrupt Mason outcomes as unknown errors", function()
		config.setup({ mason_install_fallback = true })
		local saved = package.loaded["muster.automatic"]
		package.loaded["muster.automatic"] = {
			status = function()
				return {
					state = "reported",
					mason = { items = { { package = "tool", outcome = "corrupt", reason = "raw detail" } } },
				}
			end,
		}
		local calls = render(function()
			require("muster.health").check()
		end)
		package.loaded["muster.automatic"] = saved
		assert.is_truthy(has(calls, "error", "Mason package tool: outcome=unknown"))
		assert.is_truthy(has(calls, "error", "invalid Mason install result"))
		assert.is_falsy(has(calls, "info", "corrupt"))
	end)

	it("fails closed when automatic status throws or has malformed top-level and item shapes", function()
		config.setup({ mason_install_fallback = true })
		local saved = package.loaded["muster.automatic"]
		for _, status in ipairs({
			function()
				error("status failed")
			end,
			function()
				return "bad"
			end,
			function()
				return { state = "future" }
			end,
			function()
				return { state = "reported", mason = "bad" }
			end,
			function()
				return { state = "failed" }
			end,
			function()
				return { state = "reported", mason = { items = { [2] = false, bad = {} } } }
			end,
			function()
				return { state = "reported", mason = { items = { [1000000000] = {} } } }
			end,
			function()
				return {
					state = "reported",
					mason = {
						items = {
							setmetatable({}, {
								__index = function()
									error("must not index")
								end,
							}),
						},
					},
				}
			end,
		}) do
			package.loaded["muster.automatic"] = { status = status }
			local calls = render(function()
				require("muster.health").check()
			end)
			assert.is_true(vim.iter(calls):any(function(call)
				return call.level == "error" and call.msg:find("malformed", 1, true) ~= nil
			end))
		end
		package.loaded["muster.automatic"] = saved
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

	it("surfaces the rejected lint tombstone with nvim_lint migration guidance", function()
		config.setup({ lint = { "selene" } })
		local calls = render(function()
			require("muster.health").check()
		end)
		assert.is_true(has(calls, "error", "setup() was called but rejected"))
		assert.is_true(has(calls, "error", "nvim_lint"))
		assert.is_falsy(has(calls, "error", "matches no registered adapter"))
	end)
end)
