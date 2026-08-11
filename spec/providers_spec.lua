---@module 'luassert'
local assert = require("luassert")

local env = require("muster.env")

local function reload(name)
	package.loaded[name] = nil
	return require(name)
end

local function protect(body, cleanup)
	local ok, err = xpcall(body, debug.traceback)
	local cleanup_ok, cleanup_err = xpcall(cleanup, debug.traceback)
	if not ok then
		if not cleanup_ok then
			err = err .. "\ncleanup failed:\n" .. cleanup_err
		end
		error(err, 0)
	end
	if not cleanup_ok then
		error(cleanup_err, 0)
	end
end

describe("Mason advice provider", function()
	it("reverse-indexes a unique spec.bin hit", function()
		local saved = package.loaded["mason-registry"]
		package.loaded["mason-registry"] = {
			get_all_package_specs = function()
				return {
					{ name = "cmakelang", bin = { ["cmake-format"] = "bin/cmake-format" } },
					{ name = "stylua", bin = { stylua = "bin/stylua" } },
				}
			end,
		}
		protect(function()
			local advice = reload("muster.providers.mason").collect({ "cmake-format" })
			assert.same({
				provider = "mason",
				action = "install",
				package = "cmakelang",
				command = ":MasonInstall cmakelang",
			}, advice["cmake-format"])
		end, function()
			package.loaded["mason-registry"] = saved
			package.loaded["muster.providers.mason"] = nil
		end)
	end)

	it("does not guess when multiple packages export one binary", function()
		local saved = package.loaded["mason-registry"]
		package.loaded["mason-registry"] = {
			get_all_package_specs = function()
				return {
					{ name = "a", bin = { tool = "a" } },
					{ name = "b", bin = { tool = "b" } },
				}
			end,
		}
		protect(function()
			local advice = reload("muster.providers.mason").collect({ "tool" })
			assert.same({ provider = "mason", action = "install" }, advice.tool)
		end, function()
			package.loaded["mason-registry"] = saved
			package.loaded["muster.providers.mason"] = nil
		end)
	end)

	it("quietly omits advice for absent or cold registries", function()
		local saved = package.loaded["mason-registry"]
		local cases = {
			false,
			{},
			{
				get_all_package_specs = function()
					return {}
				end,
			},
		}
		protect(function()
			for _, registry in ipairs(cases) do
				package.loaded["mason-registry"] = registry or nil
				local advice, err = reload("muster.providers.mason").collect({ "tool" })
				assert.same({}, advice)
				assert.is_nil(err)
			end
		end, function()
			package.loaded["mason-registry"] = saved
			package.loaded["muster.providers.mason"] = nil
		end)
	end)

	it("reports unexpected registry exceptions and malformed returns", function()
		local saved = package.loaded["mason-registry"]
		local cases = {
			{
				get_all_package_specs = function()
					error("registry decoder failed")
				end,
			},
			{
				get_all_package_specs = function()
					return "not specs"
				end,
			},
			{
				get_all_package_specs = function()
					return { stylua = { name = "stylua", bin = { stylua = "bin/stylua" } } }
				end,
			},
			{
				get_all_package_specs = function()
					return { [2] = { name = "stylua", bin = { stylua = "bin/stylua" } } }
				end,
			},
		}
		protect(function()
			for _, registry in ipairs(cases) do
				package.loaded["mason-registry"] = registry
				local advice, err = reload("muster.providers.mason").collect({ "tool" })
				assert.same({}, advice)
				assert.is_string(err)
			end
		end, function()
			package.loaded["mason-registry"] = saved
			package.loaded["muster.providers.mason"] = nil
		end)
	end)
end)

describe("nix advice provider", function()
	local saved_executable
	local saved_spawn

	before_each(function()
		saved_executable = env.executable
		saved_spawn = env.spawn
		package.loaded["muster.providers.nix"] = nil
	end)

	after_each(function()
		env.executable = saved_executable
		env.spawn = saved_spawn
		package.loaded["muster.providers.nix"] = nil
	end)

	it("queries exact executable paths and returns a unique attribute", function()
		local command
		env.executable = function(name)
			return name == "nix-locate" and "/nix/bin/nix-locate" or nil
		end
		env.spawn = function(cmd, _, callback)
			command = cmd
			callback({ code = 0, output = "stylua.out\n" })
		end
		local result
		reload("muster.providers.nix").collect({ "stylua" }, 4, function(advice, err)
			assert.is_nil(err)
			result = advice
		end)
		assert.same({
			"/nix/bin/nix-locate",
			"--minimal",
			"--whole-name",
			"--type",
			"x",
			"bin/stylua",
		}, command)
		assert.same({ provider = "nix", action = "declare", package = "stylua.out" }, result.stylua)
	end)

	it("returns provider-only advice for multiple or indirect hits", function()
		env.executable = function()
			return "/nix-locate"
		end
		local outputs = {
			multi = "z.out\na.out\na.out\n",
			indirect = "(wrapper.out)\n",
		}
		env.spawn = function(cmd, _, callback)
			local binary = cmd[#cmd]:match("bin/(.+)")
			callback({ code = 0, output = outputs[binary] })
		end
		local result
		reload("muster.providers.nix").collect({ "multi", "indirect" }, 4, function(advice)
			result = advice
		end)
		assert.same({ provider = "nix", action = "declare" }, result.multi)
		assert.same({ provider = "nix", action = "declare" }, result.indirect)
	end)

	it("omits ordinary no-match and absent-provider cases", function()
		local spawns = 0
		env.executable = function()
			return nil
		end
		env.spawn = function()
			spawns = spawns + 1
		end
		local result
		reload("muster.providers.nix").collect({ "missing" }, 4, function(advice, err)
			assert.is_nil(err)
			result = advice
		end)
		assert.same({}, result)
		assert.equals(0, spawns)

		env.executable = function()
			return "/nix-locate"
		end
		env.spawn = function(_, _, callback)
			callback({ code = 0, output = "" })
		end
		reload("muster.providers.nix").collect({ "missing" }, 4, function(advice, err)
			assert.is_nil(err)
			result = advice
		end)
		assert.same({}, result)
	end)

	it("contains process raises before or after a synchronous callback", function()
		env.executable = function()
			return "/nix-locate"
		end
		local calls, failure, result = 0, nil, nil
		local function collect()
			reload("muster.providers.nix").collect({ "tool" }, 4, function(advice, err)
				calls = calls + 1
				result, failure = advice, err
			end)
		end

		env.spawn = function()
			error("spawn exploded")
		end
		collect()
		assert.equals(1, calls)
		assert.same({}, result)
		assert.is_truthy(failure:find("spawn exploded", 1, true))

		calls, failure, result = 0, nil, nil
		env.spawn = function(_, _, callback)
			callback({ code = 0, output = "tool.out\n" })
			error("spawn exploded after callback")
		end
		collect()
		assert.equals(1, calls)
		assert.same({}, result)
		assert.is_truthy(failure:find("after callback", 1, true))
	end)

	it("contains query failures and continues other binaries", function()
		env.executable = function()
			return "/nix-locate"
		end
		env.spawn = function(cmd, _, callback)
			local binary = cmd[#cmd]:match("bin/(.+)")
			if binary == "bad" then
				callback({ code = 2, signal = 0, output = "database broken" })
			elseif binary == "terminated" then
				callback({ code = 0, signal = 15, output = "wrong.out\n" })
			else
				callback({ code = 0, signal = 0, output = binary .. ".out\n" })
			end
		end
		local result, failure
		reload("muster.providers.nix").collect({ "bad", "good", "terminated" }, 4, function(advice, err)
			result, failure = advice, err
		end)
		assert.same({ provider = "nix", action = "declare", package = "good.out" }, result.good)
		assert.is_nil(result.terminated)
		assert.is_truthy(failure:find("bad", 1, true))
		assert.is_truthy(failure:find("terminated", 1, true))
		assert.is_truthy(failure:find("signal 15", 1, true))
	end)

	it("never exceeds the requested concurrency and calls back once", function()
		env.executable = function()
			return "/nix-locate"
		end
		local active, peak, calls = 0, 0, 0
		local pending = {}
		env.spawn = function(cmd, _, callback)
			active = active + 1
			peak = math.max(peak, active)
			pending[#pending + 1] = function()
				active = active - 1
				callback({ code = 0, output = cmd[#cmd]:sub(5) .. ".out\n" })
			end
		end
		reload("muster.providers.nix").collect({ "a", "b", "c", "d", "e" }, 2, function()
			calls = calls + 1
		end)
		assert.equals(2, #pending)
		while #pending > 0 do
			local complete = table.remove(pending, 1)
			complete()
		end
		assert.equals(2, peak)
		assert.equals(1, calls)
	end)
end)

describe("mise advice provider", function()
	local saved_executable
	local saved_spawn

	before_each(function()
		saved_executable = env.executable
		saved_spawn = env.spawn
		package.loaded["muster.providers.mise"] = nil
	end)

	after_each(function()
		env.executable = saved_executable
		env.spawn = saved_spawn
		package.loaded["muster.providers.mise"] = nil
	end)

	it("runs registry once and matches exact first-column tool names", function()
		local spawns = 0
		env.executable = function(name)
			return name == "mise" and "/bin/mise" or nil
		end
		env.spawn = function(cmd, _, callback)
			spawns = spawns + 1
			assert.same({ "/bin/mise", "registry" }, cmd)
			callback({
				code = 0,
				output = "stylua aqua:StyLua cargo:stylua\nstylua-extra aqua:other\nprettier npm:prettier\nhttp-tool http:provider-value\n",
			})
		end
		local result
		reload("muster.providers.mise").collect({ "stylua", "style", "prettier", "http-tool" }, function(advice, err)
			assert.is_nil(err)
			result = advice
		end)
		assert.equals(1, spawns)
		assert.same({ provider = "mise", action = "declare", package = "stylua" }, result.stylua)
		assert.same({ provider = "mise", action = "declare", package = "prettier" }, result.prettier)
		assert.same({ provider = "mise", action = "declare", package = "http-tool" }, result["http-tool"])
		assert.is_nil(result.style)
	end)

	it("rejects truncated or malformed registry rows", function()
		env.executable = function()
			return "/bin/mise"
		end
		local outputs = {
			"stylua   \n",
			"stylua\n",
			"stylua backend-without-colon\n",
			"stylua warning https://example.invalid\n",
			"stylua warning http://example.invalid\n",
			"stylua description:key\n",
			"  stylua aqua:StyLua\n",
		}
		for _, output in ipairs(outputs) do
			env.spawn = function(_, _, callback)
				callback({ code = 0, output = output })
			end
			local result
			reload("muster.providers.mise").collect({ "stylua" }, function(advice)
				result = advice
			end)
			assert.same({}, result)
		end
	end)

	it("omits absence and reports process failure without inventing packages", function()
		local spawns = 0
		env.executable = function()
			return nil
		end
		env.spawn = function()
			spawns = spawns + 1
		end
		local result, failure
		reload("muster.providers.mise").collect({ "stylua" }, function(advice, err)
			result, failure = advice, err
		end)
		assert.same({}, result)
		assert.is_nil(failure)
		assert.equals(0, spawns)

		env.executable = function()
			return "/bin/mise"
		end
		env.spawn = function(_, _, callback)
			callback({ code = 1, output = "registry failed" })
		end
		reload("muster.providers.mise").collect({ "stylua" }, function(advice, err)
			result, failure = advice, err
		end)
		assert.same({}, result)
		assert.is_truthy(failure:find("mise registry", 1, true))

		env.spawn = function(_, _, callback)
			callback({ code = 0, signal = 15, output = "stylua aqua:StyLua\n" })
		end
		reload("muster.providers.mise").collect({ "stylua" }, function(advice, err)
			result, failure = advice, err
		end)
		assert.same({}, result)
		assert.is_truthy(failure:find("signal 15", 1, true))
	end)

	it("contains spawn raises and ignores duplicate process callbacks", function()
		env.executable = function()
			return "/bin/mise"
		end
		local calls, failure, result = 0, nil, nil
		local function collect()
			reload("muster.providers.mise").collect({ "stylua" }, function(advice, err)
				calls = calls + 1
				result, failure = advice, err
			end)
		end

		env.spawn = function()
			error("spawn exploded")
		end
		collect()
		assert.equals(1, calls)
		assert.same({}, result)
		assert.is_truthy(failure:find("spawn exploded", 1, true))

		calls, failure, result = 0, nil, nil
		env.spawn = function(_, _, callback)
			callback({ code = 0, output = "stylua aqua:StyLua\n" })
			error("spawn exploded after callback")
		end
		collect()
		assert.equals(1, calls)
		assert.same({}, result)
		assert.is_truthy(failure:find("after callback", 1, true))

		calls = 0
		env.spawn = function(_, _, callback)
			callback({ code = 0, output = "stylua aqua:StyLua\n" })
			callback({ code = 0, output = "stylua aqua:late\n" })
		end
		reload("muster.providers.mise").collect({ "stylua" }, function()
			calls = calls + 1
		end)
		assert.equals(1, calls)
	end)
end)
