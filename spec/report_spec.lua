---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")
local report = require("muster.report")

---@return muster.Entry
local function entry(adapter, name, probe, advice)
	return { adapter = adapter, name = name, declared = true, probe = probe, advice = advice or {} }
end

---@return muster.Result
local function result(overrides)
	return vim.tbl_extend("force", { entries = {}, skipped = {}, bufnr = 1, notes = {} }, overrides or {})
end

---Capture a notify without emitting one.
local function notified(res)
	local saved = vim.notify
	local seen = nil
	vim.notify = function(msg, level)
		seen = { msg = msg, level = level }
	end
	local ok, emitted = pcall(report.emit, res)
	vim.notify = saved
	if not ok then
		error(emitted, 0)
	end
	return emitted, seen
end

describe("report.has_problems", function()
	it("is false for an all-found result carrying only notes", function()
		-- Mason's PATH = "prepend" is its DEFAULT, so notifying on a note would
		-- mean a warning popup on every startup for every Mason user, breaking
		-- the silent-when-nothing-is-wrong promise that justifies defaulting on.
		local res = result({
			entries = { entry("a", "x", { status = "found", binary = "x", path = "/x", source = "system" }) },
			notes = { "mason is configured with PATH = prepend" },
		})
		assert.is_false(report.has_problems(res))
	end)

	it("is true for a skip, even with no failing entry", function()
		assert.is_true(report.has_problems(result({
			skipped = { { adapter = "a", count = 2, severity = "warn", reason = "not loaded" } },
		})))
	end)
end)

describe("report.lines", function()
	it("carries each probe's own reason rather than inventing a cause", function()
		-- conform conflates unknown-name with malformed-config; muster accepts
		-- that only because it passes the message through verbatim.
		local res = result({
			entries = {
				entry("conform", "prettier", {
					status = "unknown",
					reason = "config is malformed: `command` must be a string",
				}),
			},
		})
		local text = table.concat(report.lines(res), "\n")
		assert.is_truthy(text:find("malformed", 1, true))
	end)

	it("does not claim an unverifiable result is buffer-specific", function()
		local res = result({
			entries = { entry("dap", "codelldb", { status = "unverifiable", reason = "not registered" }) },
		})
		local text = table.concat(report.lines(res), "\n")
		assert.is_falsy(text:find("this buffer", 1, true))
	end)

	it("lists unverifiable entries at all", function()
		local res = result({
			entries = { entry("nvim_lint", "z", { status = "unverifiable", reason = "cmd is a function" }) },
		})
		assert.is_truthy(#report.lines(res) > 0, '"we could not tell" must not render as silence')
	end)
end)

describe("report advice rendering", function()
	it("renders provider records without re-deriving package names", function()
		local res = result({
			entries = {
				entry("conform", "stylua", { status = "missing", binary = "stylua" }, {
					{
						provider = "mason",
						action = "install",
						package = "stylua",
						command = ":MasonInstall stylua",
					},
					{ provider = "nix", action = "declare", package = "stylua.out" },
					{ provider = "mise", action = "declare", package = "stylua" },
				}),
				entry("nvim_lint", "ambiguous", { status = "missing", binary = "tool" }, {
					{ provider = "nix", action = "declare" },
				}),
			},
		})
		local text = table.concat(report.lines(res), "\n")
		assert.is_truthy(text:find(":MasonInstall stylua", 1, true))
		assert.is_truthy(text:find("stylua.out", 1, true))
		assert.is_truthy(text:find("mise", 1, true))
		assert.is_truthy(text:find("ambiguous", 1, true))
		assert.is_truthy(text:find("no package guessed", 1, true))
	end)

	it("uses action rather than command presence to render install advice", function()
		local res = result({
			entries = {
				entry("conform", "stylua", { status = "missing", binary = "stylua" }, {
					{ provider = "mason", action = "install", package = "stylua" },
				}),
			},
		})
		local text = table.concat(report.lines(res), "\n")
		assert.is_truthy(text:find("install stylua via mason", 1, true))
		assert.is_falsy(text:find("declare stylua via mason", 1, true))
	end)

	it("renders eligible Mason advice as planned after this report", function()
		local res = result({
			entries = {
				entry("conform", "stylua", { status = "missing", binary = "stylua" }, {
					{ provider = "mason", action = "install", package = "stylua", eligible = true },
				}),
			},
		})
		local text = table.concat(report.lines(res), "\n")
		assert.is_truthy(text:find("will install stylua via mason after this report", 1, true))
	end)

	it("renders ineligible Mason advice with its reason and makes no install claim", function()
		local res = result({
			entries = {
				entry("conform", "stylua", { status = "missing", binary = "stylua" }, {
					{
						provider = "mason",
						action = "install",
						package = "stylua",
						eligible = false,
						reason = "installation already in progress",
					},
				}),
			},
		})
		local text = table.concat(report.lines(res), "\n")
		assert.is_truthy(text:find("installation already in progress", 1, true))
		assert.is_falsy(text:find("will install", 1, true))
	end)

	it("keeps E1 recommendation wording when eligibility is absent", function()
		local res = result({
			entries = {
				entry("conform", "stylua", { status = "missing", binary = "stylua" }, {
					{ provider = "mason", action = "install", package = "stylua", command = ":MasonInstall stylua" },
				}),
			},
		})
		local text = table.concat(report.lines(res), "\n")
		assert.is_truthy(text:find(":MasonInstall stylua", 1, true))
		assert.is_falsy(text:find("after this report", 1, true))
	end)
end)

describe("report.emit", function()
	before_each(function()
		config.reset()
		config.setup({})
	end)

	it("stays silent when nothing is wrong", function()
		local emitted = notified(result({
			entries = { entry("a", "x", { status = "found", binary = "x", path = "/x", source = "system" }) },
		}))
		assert.is_false(emitted)
	end)

	it("keeps Mason fallback authority independent from summary notification", function()
		config.setup({ mason_install_fallback = true, notify_on_startup = false })
		local emitted = notified(result({
			entries = { entry("a", "x", { status = "missing", binary = "x" }) },
		}))
		assert.is_false(emitted)
	end)

	it("escalates to ERROR when any skip is an error", function()
		-- A crashed adapter and a not-yet-loaded plugin must not read alike.
		local _, seen = notified(result({
			skipped = { { adapter = "a", count = 3, severity = "error", reason = "adapter raised" } },
		}))
		assert.equals(vim.log.levels.ERROR, seen.level)
	end)

	it("stays at WARN for an ordinary not-loaded skip", function()
		local _, seen = notified(result({
			skipped = { { adapter = "a", count = 1, severity = "warn", reason = "host plugin is not loaded" } },
		}))
		assert.equals(vim.log.levels.WARN, seen.level)
	end)

	it("counts unchecked tools in the header", function()
		local _, seen = notified(result({
			skipped = { { adapter = "a", count = 3, severity = "warn", reason = "host plugin is not loaded" } },
		}))
		assert.is_truthy(seen.msg:find("3 unchecked", 1, true))
	end)

	it("pluralises the header correctly", function()
		local _, one = notified(result({
			entries = { entry("a", "x", { status = "missing", binary = "x" }) },
		}))
		assert.is_truthy(one.msg:find("1 tool needs attention", 1, true))
		local _, two = notified(result({
			entries = {
				entry("a", "x", { status = "missing", binary = "x" }),
				entry("a", "y", { status = "missing", binary = "y" }),
			},
		}))
		assert.is_truthy(two.msg:find("2 tools need attention", 1, true))
	end)
end)
