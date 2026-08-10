---@module 'luassert'
local assert = require("luassert")

local source = require("muster.source")

---Swap an env var for the duration of a call and restore it afterwards.
local function with_env(vars, fn)
	local saved = {}
	for k, v in pairs(vars) do
		saved[k] = vim.env[k]
		vim.env[k] = v
	end
	local ok, err = pcall(fn)
	for k in pairs(vars) do
		vim.env[k] = saved[k]
	end
	if not ok then
		error(err, 0)
	end
end

describe("source.classify", function()
	it("returns unknown when realpath could not be obtained", function()
		-- Not the fallback for an unrecognised prefix: that case is `system`.
		assert.equals("unknown", source.classify("/usr/bin/git", nil))
	end)

	it("falls back to system for an unrecognised prefix", function()
		with_env({ MASON = "/m", MISE_DATA_DIR = "/mise", HOMEBREW_PREFIX = "/brew" }, function()
			assert.equals("system", source.classify("/usr/bin/git", "/usr/bin/git"))
		end)
	end)

	it("classifies a mise shim on the pre-realpath path", function()
		-- Every shim is a symlink to the mise binary itself, so the realpath
		-- escapes the shim root entirely. Testing realpath here would yield the
		-- source that provides mise, never `mise`.
		with_env({ MISE_DATA_DIR = "/data/mise", MASON = "/m", HOMEBREW_PREFIX = "/brew" }, function()
			assert.equals("mise", source.classify("/data/mise/shims/actionlint", "/nix/store/abc-mise/bin/mise"))
		end)
	end)

	it("does not let a shim's realpath win over the shim row", function()
		with_env({ MISE_DATA_DIR = "/data/mise", MASON = "/m", HOMEBREW_PREFIX = "/brew" }, function()
			-- Same realpath for two different shims: the path is what separates them.
			local a = source.classify("/data/mise/shims/black", "/nix/store/abc-mise/bin/mise")
			local b = source.classify("/data/mise/shims/prettier", "/nix/store/abc-mise/bin/mise")
			assert.equals("mise", a)
			assert.equals("mise", b)
		end)
	end)

	it("classifies mason by realpath, since $PATH yields the bin symlink", function()
		with_env({ MASON = "/data/mason", MISE_DATA_DIR = "/data/mise", HOMEBREW_PREFIX = "/brew" }, function()
			assert.equals("mason", source.classify("/data/mason/bin/stylua", "/data/mason/packages/stylua/stylua"))
		end)
	end)

	it("classifies a mise install by realpath", function()
		with_env({ MISE_DATA_DIR = "/data/mise", MASON = "/m", HOMEBREW_PREFIX = "/brew" }, function()
			assert.equals(
				"mise",
				source.classify("/data/mise/installs/node/latest/bin/node", "/data/mise/installs/node/26.7.0/bin/node")
			)
		end)
	end)

	it("classifies a nix store path", function()
		with_env({ MASON = "/m", MISE_DATA_DIR = "/data/mise", HOMEBREW_PREFIX = "/brew" }, function()
			assert.equals("nix", source.classify("/home/u/.nix-profile/bin/rg", "/nix/store/abc-ripgrep-15.2.0/bin/rg"))
		end)
	end)

	it("classifies a homebrew prefix", function()
		with_env({ HOMEBREW_PREFIX = "/opt/homebrew", MASON = "/m", MISE_DATA_DIR = "/data/mise" }, function()
			assert.equals(
				"brew",
				source.classify("/opt/homebrew/bin/shellcheck", "/opt/homebrew/Cellar/shellcheck/0.11.0/bin/shellcheck")
			)
		end)
	end)

	it("respects path boundaries rather than matching a bare substring", function()
		with_env({ HOMEBREW_PREFIX = "/usr/local", MASON = "/m", MISE_DATA_DIR = "/data/mise" }, function()
			-- "/usr/localhost/..." must not match the "/usr/local" prefix.
			assert.equals("system", source.classify("/usr/localhost/bin/x", "/usr/localhost/bin/x"))
		end)
	end)

	it("skips a row whose prefix cannot be determined rather than guessing", function()
		with_env({ MASON = "", MISE_DATA_DIR = "/data/mise", HOMEBREW_PREFIX = "/brew" }, function()
			-- With no mason root, a mason-looking path is simply not mason.
			assert.equals("system", source.classify("/data/mason/bin/x", "/data/mason/packages/x/x"))
		end)
	end)
end)

describe("source prefix discovery", function()
	it("prefers $MISE_DATA_DIR, then $XDG_DATA_HOME, then ~/.local/share", function()
		with_env({ MISE_DATA_DIR = "/explicit", XDG_DATA_HOME = "/xdg" }, function()
			assert.equals("/explicit", source.mise_data_dir())
		end)
		with_env({ MISE_DATA_DIR = "", XDG_DATA_HOME = "/xdg" }, function()
			assert.equals("/xdg/mise", source.mise_data_dir())
		end)
	end)

	it("returns both standard homebrew prefixes when the env var is unset", function()
		with_env({ HOMEBREW_PREFIX = "" }, function()
			assert.same({ "/opt/homebrew", "/usr/local" }, source.brew_prefixes())
		end)
	end)
end)
