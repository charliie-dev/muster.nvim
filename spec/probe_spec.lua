---@module 'luassert'
local assert = require("luassert")

local env = require("muster.env")
local probe = require("muster.probe")

---Replace the $PATH lookup for the duration of a call.
local function with_executable(fake, fn)
	local saved = env.executable
	env.executable = fake
	local ok, err = pcall(fn)
	env.executable = saved
	if not ok then
		error(err, 0)
	end
end

describe("probe.resolve", function()
	it("reports missing when the command is not on $PATH", function()
		with_executable(function()
			return nil
		end, function()
			local p = probe.resolve("stylua")
			assert.equals("missing", p.status)
			assert.equals("stylua", p.binary)
			assert.is_nil(p.path)
		end)
	end)

	it("reduces an absolute command to a basename for the registry key", function()
		-- Configs written as `command = vim.fn.exepath("codelldb")` hand over a
		-- path; `binary` doubles as the Mason registry key, which a path is not.
		with_executable(function()
			return nil
		end, function()
			local p = probe.resolve("/opt/x/bin/codelldb")
			assert.equals("codelldb", p.binary)
		end)
	end)

	it("carries path and source on a found probe", function()
		with_executable(function()
			return "/usr/bin/git"
		end, function()
			local p = probe.resolve("git")
			assert.equals("found", p.status)
			assert.equals("git", p.binary)
			assert.equals("/usr/bin/git", p.path)
			assert.is_string(p.source)
		end)
	end)

	it("treats an empty or non-string command as unverifiable, not missing", function()
		local p = probe.resolve("")
		assert.equals("unverifiable", p.status)
		assert.is_string(p.reason)
		---@diagnostic disable-next-line: param-type-mismatch
		assert.equals("unverifiable", probe.resolve(nil).status)
	end)
end)

describe("probe constructors", function()
	it("require a reason on unknown, broken and unverifiable", function()
		assert.is_string(probe.unknown("why").reason)
		assert.is_string(probe.broken("why").reason)
		assert.is_string(probe.unverifiable("why").reason)
	end)
end)

describe("probe.guarded", function()
	it("converts a raise into a string rather than letting it escape", function()
		local ok, value = probe.guarded(function()
			error("boom")
		end)
		assert.is_false(ok)
		assert.is_truthy(value:find("boom", 1, true))
	end)

	it("passes a value through untouched", function()
		local ok, value = probe.guarded(function()
			return { 1, 2 }
		end)
		assert.is_true(ok)
		assert.same({ 1, 2 }, value)
	end)

	it("stringifies a non-string error object", function()
		local ok, value = probe.guarded(function()
			-- Raising a table is legal Lua and is the case under test; selene's
			-- stdlib signature for `error` is stricter than the language.
			-- selene: allow(incorrect_standard_library_use)
			error({ code = 1 }, 0)
		end)
		assert.is_false(ok)
		assert.is_string(value)
	end)
end)
