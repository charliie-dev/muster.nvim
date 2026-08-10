---@module 'luassert'
local assert = require("luassert")

local check = require("muster.check")
local config = require("muster.config")
local registry = require("muster.registry")

---@return muster.Adapter
local function fake(id, opts)
	opts = opts or {}
	return {
		id = id,
		available = function()
			return opts.available ~= false
		end,
		identity = opts.identity or tostring,
		probe = opts.probe or function(entry)
			return { status = "missing", binary = tostring(entry) }
		end,
		registered = opts.registered,
	}
end

---Run `check` against exactly the adapters given, with no builtins loaded.
local function with_adapters(adapters, opts, fn)
	registry.reset()
	for _, adapter in ipairs(adapters) do
		registry.register(adapter)
	end
	-- load_builtins() would re-add the real five; stub it out for the duration.
	local saved = registry.load_builtins
	registry.load_builtins = function() end
	config.setup(opts)
	local ok, err = pcall(fn)
	registry.load_builtins = saved
	config.reset()
	registry.reset()
	if not ok then
		error(err, 0)
	end
end

describe("check.run", function()
	it("probes only the adapters with a declared list", function()
		with_adapters({ fake("a"), fake("b") }, { a = { "one", "two" } }, function()
			local result = check.run()
			assert.equals(2, #result.entries)
			assert.equals("a", result.entries[1].adapter)
		end)
	end)

	it("marks declared entries as declared", function()
		with_adapters({ fake("a") }, { a = { "one" } }, function()
			assert.is_true(check.run().entries[1].declared)
		end)
	end)

	it("skips an adapter whose host plugin is absent, rather than calling it a typo", function()
		with_adapters({ fake("a", { available = false }) }, { a = { "one", "two" } }, function()
			local result = check.run()
			assert.equals(0, #result.entries)
			assert.equals(1, #result.skipped)
			assert.equals("a", result.skipped[1].adapter)
			assert.equals(2, result.skipped[1].count)
		end)
	end)

	it("dedupes within an adapter but not across adapters", function()
		-- conform's prettier and none-ls's prettier are two entries: they are
		-- configured separately and can fail separately.
		with_adapters({ fake("a"), fake("b") }, { a = { "p", "p" }, b = { "p" } }, function()
			local result = check.run()
			assert.equals(2, #result.entries)
		end)
	end)

	it("turns a raising probe into a broken entry instead of propagating", function()
		local boom = fake("a", {
			probe = function()
				error("kaboom")
			end,
		})
		with_adapters({ boom }, { a = { "one" } }, function()
			local entry = check.run().entries[1]
			assert.equals("broken", entry.probe.status)
			assert.is_truthy(entry.probe.reason:find("kaboom", 1, true))
		end)
	end)

	it("skips an entry whose identity cannot be determined", function()
		local nameless = fake("a", {
			identity = function()
				error("no usable name")
			end,
		})
		with_adapters({ nameless }, { a = { {} } }, function()
			local result = check.run()
			assert.equals(0, #result.entries)
			assert.equals(1, #result.skipped)
		end)
	end)

	it("treats a loaded-but-empty none_ls as a skip, not an all-clear", function()
		local none_ls = fake("none_ls", {
			registered = function()
				return {}
			end,
		})
		with_adapters({ none_ls }, {}, function()
			local result = check.run()
			assert.equals(0, #result.entries)
			assert.equals(1, #result.skipped)
			assert.is_truthy(result.skipped[1].reason:find("no registered sources", 1, true))
		end)
	end)

	it("says nothing at all about none_ls when none-ls is not installed", function()
		-- An unavailable adapter yields an empty registered(); reporting "loaded
		-- but has no registered sources" would describe a plugin that is absent.
		local none_ls = fake("none_ls", {
			available = false,
			registered = function()
				return {}
			end,
		})
		with_adapters({ none_ls }, {}, function()
			local result = check.run()
			assert.equals(0, #result.entries)
			assert.equals(0, #result.skipped)
		end)
	end)

	it("falls back to none_ls's own registry and still counts as declared", function()
		local none_ls = fake("none_ls", {
			registered = function()
				return { "src_a", "src_b" }
			end,
		})
		with_adapters({ none_ls }, {}, function()
			local result = check.run()
			assert.equals(2, #result.entries)
			assert.is_true(result.entries[1].declared)
		end)
	end)

	it("records the buffer probes were resolved against", function()
		with_adapters({ fake("a") }, { a = { "one" } }, function()
			assert.equals(vim.api.nvim_get_current_buf(), check.run().bufnr)
		end)
	end)

	it("sorts entries by adapter then name so output is stable", function()
		with_adapters({ fake("b"), fake("a") }, { a = { "z", "y" }, b = { "x" } }, function()
			local result = check.run()
			assert.same(
				{ "a/y", "a/z", "b/x" },
				vim.tbl_map(function(e)
					return e.adapter .. "/" .. e.name
				end, result.entries)
			)
		end)
	end)
end)

describe("check.tally", function()
	it("counts every status, including zeroes", function()
		with_adapters({ fake("a") }, { a = { "one", "two" } }, function()
			local counts = check.tally(check.run())
			assert.equals(2, counts.missing)
			assert.equals(0, counts.found)
			assert.equals(0, counts.broken)
		end)
	end)
end)
