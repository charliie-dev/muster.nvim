---@module 'luassert'
local assert = require("luassert")

local function entry(name, status, binary, declared)
	return {
		adapter = "test",
		name = name,
		declared = declared ~= false,
		probe = { status = status, binary = binary },
		advice = {},
	}
end

local function result(entries)
	return { entries = entries, skipped = {}, bufnr = 1, notes = {} }
end

describe("enrich.run", function()
	it("enriches only declared missing entries, dedupes binaries, and preserves provider order", function()
		local seen = {}
		local nix_done, mise_done
		local providers = {
			mason = {
				collect = function(binaries)
					seen.mason = vim.deepcopy(binaries)
					return {
						tool = { provider = "mason", action = "install", package = "mason-tool" },
					}
				end,
			},
			nix = {
				collect = function(binaries, concurrency, callback)
					seen.nix = vim.deepcopy(binaries)
					seen.concurrency = concurrency
					nix_done = callback
				end,
			},
			mise = {
				collect = function(binaries, callback)
					seen.mise = vim.deepcopy(binaries)
					mise_done = callback
				end,
			},
		}
		local duplicate = entry("duplicate", "missing", "tool")
		local res = result({
			entry("missing", "missing", "tool"),
			duplicate,
			entry("found", "found", "found"),
			entry("unknown", "unknown", nil),
			entry("live-only", "missing", "live", false),
		})
		local completed
		require("muster.enrich").run(res, function(value)
			completed = value
		end, {
			providers = providers,
			nix_concurrency = 2,
		})

		assert.same({ "tool" }, seen.mason)
		assert.same({ "tool" }, seen.nix)
		assert.same({ "tool" }, seen.mise)
		assert.equals(2, seen.concurrency)
		assert.is_nil(completed)
		assert.same({}, res.entries[1].advice, "no partial advice is visible before the barrier")

		mise_done({ tool = { provider = "mise", action = "declare", package = "tool" } })
		assert.is_nil(completed)
		nix_done({ tool = { provider = "nix", action = "declare", package = "tool.out" } })
		assert.equals(res, completed)
		local expected = {
			{ provider = "mason", action = "install", package = "mason-tool" },
			{ provider = "nix", action = "declare", package = "tool.out" },
			{ provider = "mise", action = "declare", package = "tool" },
		}
		assert.same(expected, res.entries[1].advice)
		assert.same(expected, duplicate.advice)
		assert.is_false(res.entries[1].advice == duplicate.advice, "fan-out must not alias advice arrays")
		assert.same({}, res.entries[3].advice)
		assert.same({}, res.entries[5].advice)
	end)

	it("contains provider raises and double callbacks, then completes exactly once", function()
		local callbacks = 0
		local res = result({ entry("x", "missing", "x") })
		local providers = {
			mason = {
				collect = function()
					error("mason exploded")
				end,
			},
			nix = {
				collect = function(_, _, callback)
					callback({}, "nix failed")
					callback({ x = { provider = "nix", action = "declare", package = "late" } })
				end,
			},
			mise = {
				collect = function(_, callback)
					callback({})
				end,
			},
		}
		require("muster.enrich").run(res, function()
			callbacks = callbacks + 1
		end, {
			providers = providers,
		})
		assert.equals(1, callbacks)
		assert.same({}, res.entries[1].advice)
		local notes = table.concat(res.notes, "\n")
		assert.is_truthy(notes:find("mason exploded", 1, true))
		assert.is_truthy(notes:find("nix failed", 1, true))
	end)

	it("preserves a Mason provider error returned alongside empty advice", function()
		local res = result({ entry("tool", "missing", "tool") })
		local completed
		require("muster.enrich").run(res, function(value)
			completed = value
		end, {
			providers = {
				mason = {
					collect = function()
						return {}, "registry decoder failed"
					end,
				},
				nix = {
					collect = function(_, _, callback)
						callback({})
					end,
				},
				mise = {
					collect = function(_, callback)
						callback({})
					end,
				},
			},
		})
		assert.same({}, completed.entries[1].advice)
		assert.is_truthy(table.concat(completed.notes, "\n"):find("registry decoder failed", 1, true))
	end)

	it("prefers a collector throw over its buffered synchronous callback", function()
		local res = result({ entry("tool", "missing", "tool") })
		local completed
		require("muster.enrich").run(res, function(value)
			completed = value
		end, {
			providers = {
				mason = {
					collect = function()
						return {}
					end,
				},
				nix = {
					collect = function(_, _, callback)
						callback({ tool = { provider = "nix", action = "declare", package = "tool.out" } })
						error("collector failed after callback")
					end,
				},
				mise = {
					collect = function(_, callback)
						callback({})
					end,
				},
			},
		})
		assert.same({}, completed.entries[1].advice)
		assert.is_truthy(table.concat(completed.notes, "\n"):find("collector failed after callback", 1, true))
	end)

	it("drops malformed provider maps and records before they reach the public Result", function()
		local invalid_records = {
			{ provider = "unknown", action = "declare" },
			{ provider = "nix", action = "erase" },
			{ provider = "nix", action = "declare", package = 42 },
			{ provider = "nix", action = "declare", package = "" },
			{ provider = "nix", action = "declare", command = {} },
			{ provider = "nix", action = "declare", command = "" },
			{ provider = "nix", action = "declare", command = "nix profile install" },
		}
		for _, invalid in ipairs(invalid_records) do
			local res = result({ entry("tool", "missing", "tool") })
			local completed
			require("muster.enrich").run(res, function(value)
				completed = value
			end, {
				providers = {
					mason = {
						collect = function()
							return {}
						end,
					},
					nix = {
						collect = function(_, _, callback)
							callback({ tool = invalid })
						end,
					},
					mise = {
						collect = function(_, callback)
							callback({})
						end,
					},
				},
			})
			assert.same({}, completed.entries[1].advice)
			assert.is_truthy(table.concat(completed.notes, "\n"):find("nix", 1, true))
		end
	end)

	it("treats malformed top-level returns from every provider as failures", function()
		local res = result({ entry("tool", "missing", "tool") })
		local completed
		require("muster.enrich").run(res, function(value)
			completed = value
		end, {
			providers = {
				mason = {
					collect = function()
						return nil
					end,
				},
				nix = {
					collect = function(_, _, callback)
						callback(nil)
					end,
				},
				mise = {
					collect = function(_, callback)
						callback("not a map")
					end,
				},
			},
		})
		assert.same({}, completed.entries[1].advice)
		local notes = table.concat(completed.notes, "\n")
		local mason_at = notes:find("mason enrichment failed", 1, true)
		local nix_at = notes:find("nix enrichment failed", 1, true)
		local mise_at = notes:find("mise enrichment failed", 1, true)
		assert.is_truthy(mason_at)
		assert.is_truthy(nix_at)
		assert.is_truthy(mise_at)
		assert.is_true(mason_at < nix_at and nix_at < mise_at)
	end)

	it("settles exactly once when there are no eligible entries", function()
		local calls = 0
		local res = result({ entry("found", "found", "found") })
		require("muster.enrich").run(res, function()
			calls = calls + 1
		end, {
			providers = {
				mason = {
					collect = function()
						return {}
					end,
				},
				nix = {
					collect = function(_, _, callback)
						callback({})
					end,
				},
				mise = {
					collect = function(_, callback)
						callback({})
					end,
				},
			},
		})
		assert.equals(1, calls)
	end)
end)
