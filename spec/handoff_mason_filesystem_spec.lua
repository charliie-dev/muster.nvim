---@module 'luassert'
local assert = require("luassert")

local handoff = require("muster.handoff.mason")

local BINARY = "muster-fixture-tool"

local function with_pinned_mason(callback)
	local path = assert(vim.env.MUSTER_MASON_NVIM_PATH)
	vim.opt.runtimepath:prepend(path)
	local ok, err = pcall(callback)
	vim.opt.runtimepath:remove(path)
	if not ok then
		error(err, 0)
	end
end

local function write_executable(path)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path)
	assert(vim.uv.fs_chmod(path, 493))
end

local function symlink(target, path)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	assert(vim.uv.fs_symlink(target, path))
end

local function run_case(kind)
	local old_path = vim.env.PATH
	local old_mason = vim.env.MASON
	local temp = vim.fn.tempname()
	local root = temp .. "/mason"
	local package_path = root .. "/packages/tool"
	local target = package_path .. "/bin/" .. BINARY
	local link = root .. "/bin/" .. BINARY
	local receipt_path = package_path .. "/mason-receipt.json"
	local empty_path = temp .. "/empty"
	vim.fn.mkdir(empty_path, "p")
	write_executable(target)

	if kind == "wrong_target" then
		local wrong = package_path .. "/bin/wrong"
		write_executable(wrong)
		symlink(wrong, link)
	else
		symlink(target, link)
	end
	if kind == "external_shadow" then
		local external = temp .. "/external/bin/" .. BINARY
		symlink(target, external)
		vim.env.PATH = temp .. "/external/bin:" .. root .. "/bin"
	elseif kind == "path_skip" then
		vim.env.PATH = empty_path
	else
		vim.env.PATH = root .. "/bin"
	end
	vim.env.MASON = assert(vim.uv.fs_realpath(root))

	local ok, value = pcall(function()
		local compiler = require("mason-core.installer.compiler")
		local InstallLocation = require("mason-core.installer.InstallLocation")
		local Optional = require("mason-core.optional")
		local package_class = require("mason-core.package")
		local Purl = require("mason-core.purl")
		local receipt_module = require("mason-core.receipt")
		local location = InstallLocation:new(root)
		local registry_source = {
			id = "fixture",
			system = "unix",
			serialize = function()
				return { proto = "lua", mod = "fixture" }
			end,
			get_display_name = function()
				return "fixture"
			end,
		}
		local spec = {
			schema = "registry+v1",
			name = "tool",
			bin = { [BINARY] = "bin/" .. BINARY },
			source = { id = "pkg:composer/vendor/tool@1.0.0" },
		}
		local installed = false
		local canonical = { name = "tool", spec = spec, registry = registry_source }
		function canonical:get_install_path(bound_location)
			assert.equals(location, bound_location)
			return package_path
		end
		function canonical:is_installed(bound_location)
			assert.equals(location, bound_location)
			return installed
		end
		function canonical:is_installing()
			return self.install_handle ~= nil and not self.install_handle:is_closed()
		end
		function canonical:is_installable(opts)
			assert.equals(location, opts.location)
			return true
		end
		function canonical:get_receipt(bound_location)
			assert.equals(location, bound_location)
			if vim.uv.fs_stat(receipt_path) == nil then
				return Optional.empty()
			end
			local json = table.concat(vim.fn.readfile(receipt_path), "\n")
			return Optional.of(receipt_module.InstallReceipt.from_json(vim.json.decode(json)))
		end

		local registry = {}
		function registry.get_all_package_specs()
			return { spec }
		end
		function registry.get_package(name)
			assert.equals("tool", name)
			return canonical
		end

		local package_module = { DEFAULT_INSTALL_OPTS = package_class.DEFAULT_INSTALL_OPTS }
		function package_module.new(_, detached_spec, detached_registry)
			local detached = { name = "tool", spec = detached_spec, registry = detached_registry }
			function detached:install(opts, callback)
				local closed = false
				local handle = {
					is_closed = function()
						return closed
					end,
				}
				local receipt = receipt_module.InstallReceiptBuilder
					:new()
					:with_name("tool")
					:with_start_time(1, 0)
					:with_completion_time(2, 0)
					:with_source({ type = spec.schema, id = spec.source.id, raw = spec.source })
					:with_install_options(opts)
					:with_registry(registry_source:serialize())
					:with_link("bin", BINARY, "bin/" .. BINARY)
					:build()
				if kind == "corrupt_receipt" then
					vim.fn.writefile({ "{" }, receipt_path)
				else
					vim.fn.writefile({ receipt:to_json() }, receipt_path)
				end
				installed = true
				closed = true
				callback(true, receipt)
				return handle
			end
			return detached
		end

		local notes = {}
		local result = {
			entries = {
				{
					adapter = "conform",
					name = BINARY,
					declared = true,
					probe = { status = "missing", binary = BINARY },
					advice = {
						{ provider = "mason", action = "install", package = "tool", command = ":MasonInstall tool" },
					},
				},
			},
			skipped = {},
			bufnr = 1,
			notes = notes,
		}
		local opts = {
			registry = registry,
			location = location,
			package_module = package_module,
			compiler = compiler,
			purl = Purl,
			receipt_module = receipt_module,
			_source_fingerprint = function()
				return require("muster.mason_source").fingerprint_root(vim.env.MUSTER_MASON_NVIM_PATH)
			end,
			notify = function() end,
			schedule = kind == "bridge_rejection" and function()
				error("schedule rejected")
			end or function(callback)
				callback()
			end,
			defer = kind == "bridge_rejection" and function()
				error("defer rejected")
			end or vim.defer_fn,
		}
		assert.is_nil(opts.probe)
		assert.is_nil(opts.realpath)
		local plan = handoff.prepare(result, opts)
		assert.equals(1, #plan.items)
		handoff.execute(plan, opts)
		local resolved = require("muster.probe").resolve(BINARY)
		return {
			outcome = plan.items[1].outcome,
			availability = plan.items[1].availability,
			attestation = plan.items[1].attestation,
			reason = plan.items[1].error or plan.items[1].attestation_reason,
			probe = resolved,
			root = root,
			target = vim.uv.fs_realpath(target),
			link = link,
		}
	end)

	vim.env.PATH = old_path
	vim.env.MASON = old_mason
	vim.fn.delete(temp, "rf")
	if not ok then
		error(value, 0)
	end
	return value
end

describe("Mason real filesystem verification", function()
	it("completes with the actual PATH probe, source classification, symlink, target, and disk receipt", function()
		with_pinned_mason(function()
			local result = run_case("success")
			assert.equals("completed", result.outcome, result.reason)
			assert.equals("found", result.availability)
			assert.equals("full", result.attestation)
			assert.equals("found", result.probe.status)
			assert.equals("mason", result.probe.source)
			assert.equals(result.link, result.probe.path)
			assert.equals(result.target, result.probe.realpath)
		end)
	end)

	it("fails closed for PATH skip, external shadow, wrong target, corrupt receipt, and bridge rejection", function()
		with_pinned_mason(function()
			for _, kind in ipairs({
				"path_skip",
				"external_shadow",
				"wrong_target",
				"corrupt_receipt",
				"bridge_rejection",
			}) do
				local result = run_case(kind)
				assert.equals("completed", result.outcome, kind)
				assert.equals("failed", result.attestation, kind)
				assert.equals(
					kind == "bridge_rejection" and "not_checked" or (kind == "path_skip" and "missing" or "found"),
					result.availability,
					kind
				)
			end
		end)
	end)
end)
