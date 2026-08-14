---@module 'luassert'
local assert = require("luassert")

local PIN = "2a6940af80375532e5e9e7c1f2fc6319a1b7a69d"

local function mason_path()
	local path = vim.env.MUSTER_MASON_NVIM_PATH
	if path and vim.fn.isdirectory(path) == 1 then
		return path
	end
end

local function copy_tree(source, destination)
	vim.fn.mkdir(destination, "p")
	local scanner = assert(vim.uv.fs_scandir(source))
	while true do
		local name, kind = vim.uv.fs_scandir_next(scanner)
		if not name then
			break
		end
		local from = source .. "/" .. name
		local to = destination .. "/" .. name
		if kind == "directory" then
			copy_tree(from, to)
		elseif kind == "file" then
			assert(vim.uv.fs_copyfile(from, to))
		end
	end
end

local function with_mason(callback)
	local path = assert(mason_path(), "set MUSTER_MASON_NVIM_PATH to the pinned mason.nvim checkout")
	vim.opt.runtimepath:prepend(path)
	local ok, err = pcall(callback, path)
	vim.opt.runtimepath:remove(path)
	if not ok then
		error(err, 0)
	end
end

describe("pinned mason.nvim lifecycle contract", function()
	it("exposes schema-2 receipt getters, compiler parse, Purl, and Optional disk receipt", function()
		with_mason(function()
			local lock = vim.json.decode(table.concat(vim.fn.readfile("flake.lock"), "\n"))
			assert.equals(PIN, lock.nodes["mason-nvim"].locked.rev)

			local compiler = require("mason-core.installer.compiler")
			local package_module = require("mason-core.package")
			local InstallLocation = require("mason-core.installer.InstallLocation")
			local Purl = require("mason-core.purl")
			local receipt_module = require("mason-core.receipt")
			assert.is_function(compiler.parse)
			assert.is_function(Purl.compile)
			assert.is_table(package_module.DEFAULT_INSTALL_OPTS)

			local spec = {
				schema = "registry+v1",
				name = "contract-tool",
				description = "contract fixture",
				homepage = "https://example.invalid",
				licenses = {},
				languages = {},
				categories = {},
				source = { id = "pkg:npm/contract-tool@1.0.0" },
				bin = { ["contract-tool"] = "bin/contract-tool" },
			}
			local parsed = compiler.parse(spec, package_module.DEFAULT_INSTALL_OPTS)
			assert.is_true(parsed:is_success())
			assert.equals("pkg:npm/contract-tool@1.0.0", Purl.compile(parsed:get_or_nil().purl))

			local temp = vim.fn.tempname()
			local install_path = temp .. "/packages/contract-tool"
			vim.fn.mkdir(install_path, "p")
			local location = InstallLocation:new(temp)
			local registry = {
				serialize = function()
					return { proto = "lua", mod = "contract" }
				end,
			}
			local package = package_module:new(spec, registry)
			assert.is_nil(package:get_receipt(location):or_else(nil))

			local receipt = receipt_module.InstallReceiptBuilder
				:new()
				:with_name("contract-tool")
				:with_start_time(1, 0)
				:with_completion_time(2, 0)
				:with_source({ type = "registry+v1", id = "pkg:npm/contract-tool@1.0.0", raw = spec.source })
				:with_install_options(
					vim.tbl_extend("force", package_module.DEFAULT_INSTALL_OPTS, { location = location })
				)
				:with_registry(registry:serialize())
				:with_link("bin", "contract-tool", "bin/contract-tool")
				:build()
			assert.equals("2.0", receipt:get_schema_version())
			assert.equals("contract-tool", receipt:get_name())
			assert.same({ ["contract-tool"] = "bin/contract-tool" }, receipt:get_links().bin)
			vim.fn.writefile({ receipt:to_json() }, install_path .. "/mason-receipt.json")
			local disk = package:get_receipt(location):or_else(nil)
			assert.is_table(disk)
			assert.equals("2.0", disk:get_schema_version())
			assert.same(receipt:get_source(), disk:get_source())
			vim.fn.delete(temp, "rf")
		end)
	end)

	it("shows pinned generic and openvsx parsing changes with mutable platform selection", function()
		with_mason(function()
			local compiler = require("mason-core.installer.compiler")
			local package_module = require("mason-core.package")
			local platform = require("mason-core.platform")
			local original_darwin = rawget(platform.is, "darwin")
			local original_linux = rawget(platform.is, "linux")
			local function set_platform(darwin, linux)
				rawset(platform.is, "darwin", darwin)
				rawset(platform.is, "linux", linux)
			end
			local function parse(purl_type)
				local source
				if purl_type == "generic" then
					source = {
						id = "pkg:generic/tool@1.0.0",
						download = {
							{ target = "darwin", files = { tool = "https://example.invalid/a" } },
							{ target = "linux", files = { tool = "https://example.invalid/b" } },
						},
					}
				else
					source = {
						id = "pkg:openvsx/vendor/tool@1.0.0",
						download = {
							{ target = "darwin", file = "a" },
							{ target = "linux", file = "b" },
						},
					}
				end
				local parsed = compiler.parse(
					{ schema = "registry+v1", name = "tool", source = source },
					package_module.DEFAULT_INSTALL_OPTS
				)
				assert.is_true(parsed:is_success())
				return parsed:get_or_nil().source
			end

			local ok, err = pcall(function()
				for _, purl_type in ipairs({ "generic", "openvsx" }) do
					set_platform(true, false)
					local first = parse(purl_type)
					set_platform(false, true)
					local second = parse(purl_type)
					assert.is_false(vim.deep_equal(first, second), purl_type)
				end
			end)
			rawset(platform.is, "darwin", original_darwin)
			rawset(platform.is, "linux", original_linux)
			assert.is_true(ok, err)
		end)
	end)

	it("locks the complete runtime Lua fingerprint and rejects one changed byte", function()
		with_mason(function(path)
			local source = require("muster.mason_source")
			assert.equals(source.EXPECTED_FINGERPRINT, source.fingerprint_root(path))
			assert.equals(
				source.EXPECTED_FINGERPRINT,
				source.fingerprint_runtime({
					compiler = require("mason-core.installer.compiler"),
					package_module = require("mason-core.package"),
					purl = require("mason-core.purl"),
					receipt = require("mason-core.receipt").InstallReceipt,
				})
			)

			local temp = vim.fn.tempname()
			copy_tree(path .. "/lua", temp .. "/lua")
			local compiler_path = temp .. "/lua/mason-core/installer/compiler/init.lua"
			assert(vim.uv.fs_chmod(compiler_path, 420))
			local file = assert(io.open(compiler_path, "ab"))
			file:write("x")
			file:close()
			assert.is_not.equal(source.EXPECTED_FINGERPRINT, source.fingerprint_root(temp))
			vim.fn.delete(temp, "rf")

			assert.has_error(function()
				source.fingerprint_root(temp .. "/missing")
			end)
			vim.fn.mkdir(temp, "p")
			assert(vim.uv.fs_symlink(path .. "/lua", temp .. "/lua"))
			assert.has_error(function()
				source.fingerprint_root(temp)
			end)
			vim.fn.delete(temp, "rf")
		end)
	end)
end)
