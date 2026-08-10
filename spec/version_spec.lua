---@module 'luassert'
local assert = require("luassert")

local env = require("muster.env")

local function found(source, opts)
	opts = opts or {}
	return {
		adapter = opts.adapter or "test",
		name = opts.name or "tool",
		declared = true,
		advice = {},
		probe = {
			status = "found",
			binary = opts.binary or "tool",
			path = opts.path or "/bin/tool",
			realpath = opts.realpath or opts.path or "/bin/tool",
			source = source,
		},
	}
end

local function resolve(version, entry)
	local result
	version.resolve(entry, function(value)
		result = value
	end)
	assert.is_table(result, "the fake spawn completes synchronously in this spec")
	return result
end

local function with_fakes(opts, fn)
	local saved_spawn = env.spawn
	local saved_stat = vim.uv.fs_stat
	local saved_registry = package.loaded["mason-registry"]
	env.spawn = opts.spawn or function(_, _, callback)
		callback({ code = 1, output = "" })
	end
	vim.uv.fs_stat = opts.stat or function()
		return { mtime = { sec = 1, nsec = 0 } }
	end
	package.loaded["mason-registry"] = opts.registry
	package.loaded["muster.version"] = nil
	local version = require("muster.version")
	local ok, err = pcall(fn, version)
	env.spawn = saved_spawn
	vim.uv.fs_stat = saved_stat
	package.loaded["mason-registry"] = saved_registry
	package.loaded["muster.version"] = nil
	if not ok then
		error(err, 0)
	end
end

describe("version.resolve", function()
	it("does not spawn or cache an entry that was not found", function()
		local spawns = 0
		with_fakes({
			spawn = function()
				spawns = spawns + 1
			end,
		}, function(version)
			local entry = found("system")
			entry.probe = { status = "missing", binary = "tool" }
			local first = resolve(version, entry)
			local second = resolve(version, entry)
			assert.equals("status is missing", first.reason)
			assert.equals("status is missing", second.reason)
			assert.equals(0, spawns)
		end)
	end)

	it("reads an installed Mason version without spawning", function()
		local pkg = {
			spec = { bin = { tool = "bin/tool" } },
			get_installed_version = function()
				return "3.19.0"
			end,
		}
		with_fakes({
			registry = {
				get_all_packages = function()
					return { pkg }
				end,
			},
			spawn = function()
				error("tier 1 must not spawn when the receipt has a version")
			end,
		}, function(version)
			assert.same({ value = "3.19.0", tier = 1 }, resolve(version, found("mason")))
		end)
	end)

	it("takes the last version-shaped token from a nix store path", function()
		with_fakes({
			spawn = function()
				error("tier 2 must not spawn when the path carries a version")
			end,
		}, function(version)
			local entry = found("nix", {
				path = "/profile/bin/git-filter-repo",
				realpath = "/nix/store/hash-python3.14-git-filter-repo-2.47.0/bin/git-filter-repo",
			})
			assert.same({ value = "2.47.0", tier = 2 }, resolve(version, entry))
		end)
	end)

	it("reads a mise version from realpath rather than the latest path", function()
		with_fakes({
			spawn = function()
				error("tier 3 must not spawn when realpath carries a version")
			end,
		}, function(version)
			local entry = found("mise", {
				path = "/mise/installs/stylua/latest/bin/stylua",
				realpath = "/mise/installs/stylua/2.5.2/bin/stylua",
			})
			assert.same({ value = "2.5.2", tier = 3 }, resolve(version, entry))
		end)
	end)

	it("falls through to tier 4 and tries flags in the specified order", function()
		local calls = {}
		with_fakes({
			spawn = function(cmd, opts, callback)
				calls[#calls + 1] = { cmd = vim.deepcopy(cmd), opts = vim.deepcopy(opts) }
				local flag = cmd[2]
				if flag == "version" then
					callback({ code = 0, output = "tool 1.2.3\n" })
				else
					callback({ code = 2, output = "usage" })
				end
			end,
		}, function(version)
			local result = resolve(version, found("system"))
			assert.same({ value = "1.2.3", tier = 4 }, result)
			assert.same(
				{ "--version", "version" },
				vim.tbl_map(function(call)
					return call.cmd[2]
				end, calls)
			)
			assert.equals(5000, calls[1].opts.timeout_ms)
		end)
	end)

	it("falls through from unsuccessful Mason, nix, and mise tiers to tier 4", function()
		local spawned = {}
		with_fakes({
			registry = {
				get_all_packages = function()
					return {}
				end,
			},
			spawn = function(cmd, _, callback)
				spawned[#spawned + 1] = cmd[1]
				callback({ code = 0, output = "tool 7.8.9" })
			end,
		}, function(version)
			local entries = {
				found("mason", { path = "/mason/bin/tool", realpath = "/mason/packages/tool/bin/tool" }),
				found("nix", { path = "/profile/bin/tool", realpath = "/nix/store/hash-tool/bin/tool" }),
				found("mise", { path = "/mise/shims/tool", realpath = "/nix/store/hash-mise/bin/mise" }),
			}
			for _, entry in ipairs(entries) do
				assert.same({ value = "7.8.9", tier = 4 }, resolve(version, entry))
			end
			assert.same({ "/mason/bin/tool", "/profile/bin/tool", "/mise/shims/tool" }, spawned)
		end)
	end)

	it("scans beyond a banner for the first version-shaped output line", function()
		with_fakes({
			spawn = function(_, _, callback)
				callback({ code = 0, output = "ShellCheck - shell script analysis tool\nversion: 0.11.0\n" })
			end,
		}, function(version)
			assert.equals("0.11.0", resolve(version, found("system")).value)
		end)
	end)

	it("rejects usage text, timestamped logs, and date-only output", function()
		local outputs = {
			"Usage: tool 1.2.3 <file>",
			"2026/08/10 18:01:53 starting GOROOT=/go/1.26.5",
			"2026-02-08",
		}
		local call = 0
		with_fakes({
			spawn = function(_, _, callback)
				call = call + 1
				callback({ code = 0, output = outputs[call] })
			end,
		}, function(version)
			local result = resolve(version, found("system"))
			assert.is_nil(result.value)
			assert.equals("no version-shaped output", result.reason)
			assert.equals(3, call)
		end)
	end)

	it("reports spawn failure when every version command fails", function()
		with_fakes({}, function(version)
			local result = resolve(version, found("system"))
			assert.is_nil(result.value)
			assert.equals("spawn failed", result.reason)
		end)
	end)

	it("caches found results by path and mtime", function()
		local spawns = 0
		local mtime = 10
		with_fakes({
			stat = function()
				return { mtime = { sec = mtime, nsec = 0 } }
			end,
			spawn = function(_, _, callback)
				spawns = spawns + 1
				callback({ code = 0, output = "tool 1.0.0" })
			end,
		}, function(version)
			assert.equals("1.0.0", resolve(version, found("system")).value)
			assert.equals("1.0.0", resolve(version, found("system")).value)
			assert.equals(1, spawns)
			mtime = 11
			assert.equals("1.0.0", resolve(version, found("system")).value)
			assert.equals(2, spawns)
		end)
	end)

	it("keys shim cache entries by path, not their shared realpath", function()
		local spawns = 0
		with_fakes({
			spawn = function(cmd, _, callback)
				spawns = spawns + 1
				callback({ code = 0, output = cmd[1]:match("black") and "black 24.1" or "prettier 3.9" })
			end,
		}, function(version)
			local shared = "/nix/store/hash-mise/bin/mise"
			local black = found("mise", { binary = "black", path = "/mise/shims/black", realpath = shared })
			local prettier = found("mise", { binary = "prettier", path = "/mise/shims/prettier", realpath = shared })
			assert.equals("24.1", resolve(version, black).value)
			assert.equals("3.9", resolve(version, prettier).value)
			assert.equals(2, spawns)
		end)
	end)
end)
