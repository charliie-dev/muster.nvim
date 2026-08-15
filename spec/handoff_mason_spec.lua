---@module 'luassert'
local assert = require("luassert")

local handoff = require("muster.handoff.mason")
local mason_result = require("muster.mason_result")

local function with_pinned_mason(callback)
	local path = assert(vim.env.MUSTER_MASON_NVIM_PATH, "MUSTER_MASON_NVIM_PATH must name the pinned Mason input")
	vim.opt.runtimepath:prepend(path)
	local ok, err = pcall(callback)
	vim.opt.runtimepath:remove(path)
	if not ok then
		error(err, 0)
	end
end

local function advice(package_name)
	return { provider = "mason", action = "install", package = package_name, command = ":MasonInstall " .. package_name }
end

local function entry(adapter, name, binary, package_name, overrides)
	local value = {
		adapter = adapter,
		name = name,
		declared = true,
		probe = { status = "missing", binary = binary },
		advice = package_name and { advice(package_name) } or {},
	}
	return vim.tbl_deep_extend("force", value, overrides or {})
end

local function result(entries)
	return { entries = entries or {}, skipped = {}, bufnr = 1, notes = {} }
end

local function assert_result(item, outcome, availability, attestation)
	assert.equals(outcome, item.outcome)
	assert.equals(availability, item.availability)
	assert.equals(attestation, item.attestation)
end

local function install_handle(is_closed)
	return { is_closed = is_closed or function()
		return true
	end }
end

local function registry_identity(id, source)
	return {
		id = id,
		system = "unix",
		serialize = function()
			return { id = id, source = source or ("source:" .. id) }
		end,
		get_display_name = function()
			return "Registry " .. id
		end,
	}
end

local function compiler_fixture()
	return {
		parse = function(spec)
			return {
				is_success = function()
					return true
				end,
				get_or_nil = function()
					return {
						purl = { type = "cargo", value = spec.source.id },
						raw_source = spec.source,
						source = vim.tbl_extend("force", { compiled = true }, spec.source),
					}
				end,
			}
		end,
	}
end

local function mutable_compiler_fixture(purl_type, selected)
	return {
		parse = function(spec)
			return {
				is_success = function()
					return true
				end,
				get_or_nil = function()
					return {
						purl = { type = purl_type, value = spec.source.id },
						raw_source = spec.source,
						source = { selected = selected.value },
					}
				end,
			}
		end,
	}
end

local function purl_fixture()
	return {
		compile = function(purl)
			return purl.value
		end,
	}
end

local function receipt_fixture(data)
	return {
		get_name = function()
			return data.name
		end,
		get_schema_version = function()
			return data.schema_version
		end,
		get_source = function()
			return data.source
		end,
		get_registry = function()
			return data.registry
		end,
		get_install_options = function()
			return data.install_options
		end,
		get_links = function()
			return data.links
		end,
	}
end

local function pinned_fingerprint()
	return require("muster.mason_source").EXPECTED_FINGERPRINT
end

local function receipt_module_fixture()
	return {
		InstallReceipt = {
			from_json = function(value)
				return value
			end,
			get_name = function(self)
				return self.name
			end,
			get_schema_version = function(self)
				return self.schema_version
			end,
			get_source = function(self)
				return self.source
			end,
			get_registry = function(self)
				return self.registry
			end,
			get_install_options = function(self)
				return self.install_options
			end,
			get_links = function(self)
				return self.links
			end,
		},
	}
end

local function optional_fixture(value)
	return {
		or_else = function(_, fallback)
			return value or fallback
		end,
	}
end

local function fixture(definitions)
	local location = setmetatable({ dir = "/mason" }, {
		__index = {
			get_dir = function(self)
				return self.dir
			end,
		},
	})

	local packages = {}
	local installs = {}
	local live_installs = {}
	for name, definition in pairs(definitions) do
		definition = vim.tbl_extend("force", {
			name = name,
			bins = { [name] = "bin/" .. name },
			registry = registry_identity("registry-a"),
			installed = false,
			installing = false,
			installable = true,
		}, definition)
		local package = {
			name = definition.name,
			spec = definition.spec or {
				schema = "registry+v1",
				name = name,
				bin = definition.bins,
				source = { id = "pkg:generic/" .. name .. "@1.0.0" },
			},
			registry = definition.registry,
		}
		function package:get_install_path(bound_location)
			if definition.path then
				return definition.path(bound_location)
			end
			return bound_location:get_dir() .. "/packages/" .. name
		end
		function package:get_receipt(bound_location)
			assert.equals(location, bound_location)
			return optional_fixture(definition and definition.disk_receipt)
		end
		function package:is_installed(bound_location)
			assert.equals(location, bound_location)
			if definition.installed_error then
				error(definition.installed_error)
			end
			return definition.installed
		end
		function package:is_installing()
			if definition.installing_error then
				error(definition.installing_error)
			end
			if self.install_handle and type(self.install_handle.is_closed) == "function" then
				return not self.install_handle:is_closed()
			end
			return definition.installing
		end
		function package:is_installable(opts)
			assert.equals(location, opts.location)
			if definition.installable_error then
				error(definition.installable_error)
			end
			return definition.installable
		end
		function package:install(opts, callback)
			assert.is_false(self:is_installing())
			live_installs[#live_installs + 1] = { package = name, location = opts.location }
			if definition.install then
				return definition.install(callback)
			end
			callback(true, {})
			return {}
		end
		packages[name] = package
	end

	local registry = {}
	function registry.get_all_package_specs()
		local specs = {}
		for _, package in pairs(packages) do
			specs[#specs + 1] = package.spec
		end
		return specs
	end
	function registry.get_package(name)
		local package = packages[name]
		if not package then
			error("unknown package " .. name)
		end
		return package
	end

	local package_module = {
		DEFAULT_INSTALL_OPTS = { debug = false, force = false, strict = false },
	}
	function package_module:new(spec, registry_source)
		local name = spec.name
		local definition = definitions[name]
		local detached = { name = name, spec = spec, registry = registry_source }
		function detached.install(package_self, opts, callback)
			installs[#installs + 1] = {
				package = name,
				location = opts.location,
				object = package_self,
				spec = package_self.spec,
			}
			local settled = false
			local function tracked_callback(...)
				settled = true
				callback(...)
			end
			local handle
			if definition.install then
				handle = definition.install(tracked_callback)
			else
				tracked_callback(true, {})
			end
			return handle or install_handle(function()
				return settled
			end)
		end
		return detached
	end

	return {
		registry = registry,
		location = location,
		packages = packages,
		installs = installs,
		live_installs = live_installs,
		opts = {
			registry = registry,
			location = location,
			package_module = package_module,
			compiler = compiler_fixture(),
			purl = purl_fixture(),
			receipt_module = receipt_module_fixture(),
			_source_fingerprint = pinned_fingerprint,
			schedule = function(callback)
				callback()
			end,
			notify = function() end,
			probe = function(binary)
				return {
					status = "found",
					source = "mason",
					path = "/mason/bin/" .. binary,
					realpath = "/mason/packages/tool/bin/" .. binary,
				}
			end,
			verify = function(_, item)
				return vim.tbl_map(function(binary)
					return "/mason/bin/" .. binary
				end, item.binaries)
			end,
		},
	}
end

local function precedence_fixture()
	local location = setmetatable({ dir = "/mason" }, {
		__index = {
			get_dir = function(self)
				return self.dir
			end,
		},
	})

	local sources = {
		primary = {
			bad = {
				registry = registry_identity("registry-primary", "source:primary"),
				spec = {
					schema = "registry+v1",
					name = "bad",
					bin = { bad = "bin/bad" },
					source = { id = "pkg:generic/bad@1.0.0", install = { command = "primary", args = { "one" } } },
				},
			},
			good = {
				registry = registry_identity("registry-primary", "source:primary"),
				spec = {
					schema = "registry+v1",
					name = "good",
					bin = { good = "bin/good" },
					source = { id = "pkg:generic/good@1.0.0", install = { command = "primary", args = { "safe" } } },
				},
			},
		},
		secondary = {
			bad = {
				registry = registry_identity("registry-secondary", "source:secondary\nchanged"),
				spec = {
					schema = "registry+v1",
					name = "bad",
					bin = { bad = "bin/bad" },
					source = { id = "pkg:generic/bad@1.0.0", install = { command = "secondary", args = { "two" } } },
				},
			},
		},
	}
	local precedence = { "primary" }
	local objects = { primary = { bad = {}, good = {} }, secondary = { bad = {} } }
	local detached = {}

	local function winner(name)
		for _, source_name in ipairs(precedence) do
			local definition = sources[source_name][name]
			if definition then
				return source_name, definition
			end
		end
	end

	local function package_object(source_name, name, definition)
		local package = {
			name = name,
			spec = definition.spec,
			registry = definition.registry,
			install_calls = 0,
			source_name = source_name,
		}
		function package:get_install_path(bound_location)
			assert.equals(location, bound_location)
			return bound_location:get_dir() .. "/packages/" .. name
		end
		function package:get_receipt(bound_location)
			assert.equals(location, bound_location)
			return optional_fixture(definition and definition.disk_receipt)
		end
		function package:is_installed(bound_location)
			assert.equals(location, bound_location)
			return false
		end
		function package:is_installing()
			return false
		end
		function package:is_installable(opts)
			assert.equals(location, opts.location)
			return true
		end
		function package:install(opts, callback)
			assert.equals(location, opts.location)
			self.install_calls = self.install_calls + 1
			callback(true, {})
			return {}
		end
		objects[source_name][name][#objects[source_name][name] + 1] = package
		return package
	end

	local registry = {}
	function registry.get_all_package_specs()
		local specs = {}
		for _, name in ipairs({ "bad", "good" }) do
			local _, definition = winner(name)
			if definition then
				specs[#specs + 1] = definition.spec
			end
		end
		return specs
	end
	function registry.get_package(name)
		local source_name, definition = winner(name)
		if not definition then
			error("unknown package " .. name)
		end
		return package_object(source_name, name, definition)
	end

	local package_module = {
		DEFAULT_INSTALL_OPTS = { debug = false, force = false, strict = false },
	}
	function package_module:new(spec, registry_source)
		local package = { name = spec.name, spec = spec, registry = registry_source, install_calls = 0 }
		function package.install(package_self, opts, callback)
			assert.equals(location, opts.location)
			package_self.install_calls = package_self.install_calls + 1
			callback(true, {})
			return install_handle()
		end
		detached[#detached + 1] = package
		return package
	end

	return {
		location = location,
		registry = registry,
		objects = objects,
		detached = detached,
		opts = {
			registry = registry,
			location = location,
			package_module = package_module,
			compiler = compiler_fixture(),
			purl = purl_fixture(),
			receipt_module = receipt_module_fixture(),
			_source_fingerprint = pinned_fingerprint,
			schedule = function(callback)
				callback()
			end,
			notify = function() end,
			probe = function(binary)
				return {
					status = "found",
					source = "mason",
					path = "/mason/bin/" .. binary,
					realpath = "/mason/packages/tool/bin/" .. binary,
				}
			end,
			verify = function(_, item)
				return vim.tbl_map(function(binary)
					return "/mason/bin/" .. binary
				end, item.binaries)
			end,
		},
		set_precedence = function(value)
			precedence = value
		end,
	}
end

local function prepare_one(definition, item_entry)
	local fx = fixture({ tool = definition or { bins = { tool = "bin/tool" } } })
	local res = result({ item_entry or entry("conform", "tool", "tool", "tool") })
	local plan = handoff.prepare(res, fx.opts)
	return plan, res.entries[1].advice[1], fx
end

describe("muster.handoff.mason.prepare", function()
	it("selects only declared missing entries with one canonical packaged Mason advice", function()
		local fx = fixture({ tool = { bins = { tool = "bin/tool" } } })
		local entries = {
			entry("conform", "eligible", "tool", "tool"),
			entry("conform", "discovered", "tool", "tool", { declared = false }),
			entry("conform", "found", "tool", "tool", { probe = { status = "found", binary = "tool" } }),
			entry("conform", "unknown", "tool", "tool", { probe = { status = "unknown", binary = "tool" } }),
			entry("conform", "broken", "tool", "tool", { probe = { status = "broken", binary = "tool" } }),
			entry("conform", "unverifiable", "tool", "tool", { probe = { status = "unverifiable", binary = "tool" } }),
			entry("conform", "package-less", "tool", nil, { advice = { { provider = "mason", action = "install" } } }),
			entry("conform", "ambiguous", "tool", "tool", { advice = { advice("tool"), advice("tool") } }),
			entry(
				"conform",
				"wrong-provider",
				"tool",
				"tool",
				{ advice = { { provider = "nix", action = "declare", package = "tool" } } }
			),
		}
		local plan = handoff.prepare(result(entries), fx.opts)
		assert.equals(1, #plan.items)
		assert.same({ entries[1] }, plan.items[1].entries)
	end)

	it("validates package identifiers before lookup and fails closed", function()
		local invalid = {
			"",
			".",
			"..",
			"/absolute",
			"C:\\absolute",
			"a/b",
			"a\\b",
			"a\0b",
			"a\nb",
			"Tool",
			"_tool",
			"tool\226\128\174txt",
			string.rep("x", 256),
		}
		for _, identifier in ipairs(invalid) do
			local lookups = 0
			local fx = fixture({ tool = { bins = { tool = "bin/tool" } } })
			fx.registry.get_package = function()
				lookups = lookups + 1
			end
			local candidate = entry("conform", "tool", "tool", "tool")
			candidate.advice[1].package = identifier
			local res = result({ candidate })
			local plan = handoff.prepare(res, fx.opts)
			assert.equals(0, #plan.items, identifier)
			assert.equals(0, lookups, identifier)
			assert.is_false(candidate.advice[1].eligible, identifier)
			assert.equals("invalid Mason package identifier", candidate.advice[1].reason)
			assert.is_truthy(res.notes[1]:find("invalid Mason package identifier", 1, true))
		end
	end)

	it("requires a refreshed unique binary mapping to the advised package", function()
		for _, case in ipairs({
			{ name = "drift", packages = { tool = { bins = { other = "bin/other" } } } },
			{
				name = "ambiguous",
				packages = { tool = { bins = { tool = "bin/tool" } }, other = { bins = { tool = "bin/tool" } } },
			},
		}) do
			local fx = fixture(case.packages)
			local candidate = entry("conform", "tool", "tool", "tool")
			local plan = handoff.prepare(result({ candidate }), fx.opts)
			assert.equals(0, #plan.items, case.name)
			assert.is_false(candidate.advice[1].eligible)
			assert.equals("Mason binary mapping changed or is ambiguous", candidate.advice[1].reason)
		end
	end)

	it("requires exact package identity and protects package lookup", function()
		local mismatch_plan, mismatch_advice = prepare_one({ name = "other", bins = { tool = "bin/tool" } })
		assert.equals(0, #mismatch_plan.items)
		assert.equals("Mason package lookup or identity failed", mismatch_advice.reason)

		local _, _, fx = prepare_one({ bins = { tool = "bin/tool" } })
		fx.registry.get_package = function()
			error("lookup secret\ntext")
		end
		local candidate = entry("conform", "tool", "tool", "tool")
		local plan = handoff.prepare(result({ candidate }), fx.opts)
		assert.equals(0, #plan.items)
		assert.equals("Mason package lookup or identity failed", candidate.advice[1].reason)
	end)

	it("snapshots complete spec and registry identity without retaining the package object", function()
		local plan, _, fx = prepare_one({ bins = { tool = "bin/tool" } })
		local item = plan.items[1]
		assert.same(fx.packages.tool.spec, item.spec_snapshot)
		assert.is_not.equal(fx.packages.tool.spec, item.spec_snapshot)
		assert.same({
			id = "registry-a",
			system = "unix",
			serialized = { id = "registry-a", source = "source:registry-a" },
			display_name = "Registry registry-a",
		}, item.registry_identity)
		assert.is_nil(item.package_object)
		assert.same({ "registry-a" }, plan.registry_identities)

		fx.packages.tool.spec.bad = function() end
		local candidate = entry("conform", "tool", "tool", "tool")
		plan = handoff.prepare(result({ candidate }), fx.opts)
		assert.equals(0, #plan.items)
		assert.equals("Mason package snapshot failed", candidate.advice[1].reason)
	end)

	it("protects every registry identity field and rejects unrepresentable snapshots", function()
		local mutations = {
			function(registry)
				registry.id = function()
					error("id failed")
				end
			end,
			function(registry)
				registry.system = function()
					error("system failed")
				end
			end,
			function(registry)
				registry.serialize = function()
					error("serialize failed")
				end
			end,
			function(registry)
				registry.get_display_name = function()
					error("display failed")
				end
			end,
			function(registry)
				registry.serialize = function()
					return { bad = function() end }
				end
			end,
		}
		for _, mutate in ipairs(mutations) do
			local fx = fixture({ tool = { bins = { tool = "bin/tool" } } })
			mutate(fx.packages.tool.registry)
			local candidate = entry("conform", "tool", "tool", "tool")
			local plan = handoff.prepare(result({ candidate }), fx.opts)
			assert.equals(0, #plan.items)
			assert.equals("Mason package snapshot failed", candidate.advice[1].reason)
		end
	end)

	it("binds the install location, root, and package path", function()
		local plan, _, fx = prepare_one({ bins = { tool = "bin/tool" } })
		assert.equals(fx.location, plan.location)
		assert.equals("/mason", plan.install_root)
		assert.equals("/mason/packages/tool", plan.items[1].install_path)
	end)

	it("classifies installed, installing, non-installable, and query failures honestly", function()
		local cases = {
			{
				definition = { bins = { tool = "bin/tool" }, installed = true },
				reason = "already installed but binary is missing",
			},
			{
				definition = { bins = { tool = "bin/tool" }, installing = true },
				reason = "installation already in progress",
			},
			{
				definition = { bins = { tool = "bin/tool" }, installable = false },
				reason = "Mason reports package not installable on this platform",
			},
			{
				definition = { bins = { tool = "bin/tool" }, installed_error = "bad" },
				reason = "Mason package state query failed",
			},
			{
				definition = { bins = { tool = "bin/tool" }, installing_error = "bad" },
				reason = "Mason package state query failed",
			},
			{
				definition = { bins = { tool = "bin/tool" }, installable_error = "bad" },
				reason = "Mason package state query failed",
			},
		}
		for _, case in ipairs(cases) do
			local plan, record = prepare_one(case.definition)
			assert.equals(0, #plan.items)
			assert.is_false(record.eligible)
			assert.equals(case.reason, record.reason)
		end
	end)

	it("marks eligible advice without changing canonical provider fields", function()
		local plan, record = prepare_one({ bins = { tool = "bin/tool" } })
		assert.equals(1, #plan.items)
		assert.is_true(record.eligible)
		assert.is_nil(record.reason)
		assert.same({
			provider = "mason",
			action = "install",
			package = "tool",
			command = ":MasonInstall tool",
			eligible = true,
		}, record)
	end)

	it("deduplicates packages and sorted LSP attribution while preserving entries", function()
		local fx = fixture({ tool = { bins = { tool = "bin/tool", alias = "bin/alias" } } })
		local entries = {
			entry("lsp", "z_ls", "tool", "tool"),
			entry("conform", "formatter", "alias", "tool"),
			entry("lsp", "a_ls", "tool", "tool"),
			entry("lsp", "a_ls", "alias", "tool"),
		}
		local plan = handoff.prepare(result(entries), fx.opts)
		assert.equals(1, #plan.items)
		assert.same(entries, plan.items[1].entries)
		assert.same({ "alias", "tool" }, plan.items[1].binaries)
		assert.same({ "a_ls", "z_ls" }, plan.items[1].lsp_names)
	end)

	it("orders install items by package", function()
		local fx = fixture({ zed = { bins = { zed = "bin/zed" } }, alpha = { bins = { alpha = "bin/alpha" } } })
		local plan =
			handoff.prepare(result({ entry("a", "zed", "zed", "zed"), entry("a", "alpha", "alpha", "alpha") }), fx.opts)
		assert.same({ "alpha", "zed" }, { plan.items[1].package, plan.items[2].package })
	end)
end)

local function prepare_batch(definitions, entries, extra_opts)
	local fx = fixture(definitions)
	for key, value in pairs(extra_opts or {}) do
		fx.opts[key] = value
	end
	local plan = handoff.prepare(result(entries), fx.opts)
	return plan, fx
end

local function verification_harness(binaries, overrides)
	overrides = overrides or {}
	local held_callback
	local closed = false
	local definitions = {
		tool = {
			bins = binaries,
			install = function(callback)
				held_callback = callback
				return install_handle(function()
					return closed
				end)
			end,
		},
	}
	local entries = {}
	for binary in pairs(binaries) do
		entries[#entries + 1] = entry("a", binary, binary, "tool")
	end
	table.sort(entries, function(left, right)
		return left.name < right.name
	end)
	local notifications = {}
	local plan, fx = prepare_batch(definitions, entries, {
		compiler = overrides.compiler,
		purl = overrides.purl,
		_source_fingerprint = overrides._source_fingerprint,
		notify = function(message, level, opts)
			notifications[#notifications + 1] = { message = message, level = level, opts = opts }
		end,
		schedule = overrides.schedule or function(callback)
			callback()
		end,
		defer = overrides.defer,
		is_windows = overrides.is_windows,
	})
	fx.opts.verify = overrides.verify or false
	fx.opts.realpath = function(path)
		local mapped = overrides.realpaths and overrides.realpaths[path]
		if mapped == false then
			return nil
		end
		return mapped or path:gsub("^/mason", "/real/mason")
	end
	fx.opts.probe = function(binary)
		if overrides.probe then
			return overrides.probe(binary)
		end
		local probe = overrides.probes and overrides.probes[binary]
		if probe then
			return probe
		end
		return {
			status = "found",
			source = "mason",
			path = "/mason/bin/" .. binary,
			realpath = "/real/mason/packages/tool/" .. binaries[binary],
		}
	end

	handoff.execute(plan, fx.opts)
	local item = plan.items[1]
	local install_options = {
		debug = false,
		force = false,
		strict = false,
		location = fx.location,
	}
	local links = { bin = {} }
	for binary, target in pairs(binaries) do
		links.bin[overrides.is_windows and (binary .. ".cmd") or binary] = target
	end
	local data = {
		name = "tool",
		schema_version = "2.0",
		source = {
			type = item.spec_snapshot.schema,
			id = item.spec_snapshot.source.id,
			raw = vim.deepcopy(item.spec_snapshot.source),
		},
		registry = vim.deepcopy(item.registry_identity.serialized),
		install_options = install_options,
		links = links,
	}
	local callback_data = vim.deepcopy(data)
	local disk_data = vim.deepcopy(data)
	local callback_receipt = receipt_fixture(callback_data)
	local disk_receipt = receipt_fixture(disk_data)
	fx.packages.tool.is_installed = function()
		return true
	end
	fx.packages.tool.get_receipt = function()
		return optional_fixture(disk_receipt)
	end

	return {
		plan = plan,
		fx = fx,
		item = item,
		data = data,
		notifications = notifications,
		complete = function(callback_value)
			closed = true
			held_callback(true, callback_value or callback_receipt)
		end,
		callback = callback_receipt,
		callback_data = callback_data,
		disk = disk_receipt,
		disk_data = disk_data,
		set_disk = function(value)
			fx.packages.tool.get_receipt = function()
				return optional_fixture(value)
			end
		end,
	}
end

describe("muster.handoff.mason.execute", function()
	it("dispatches a detached prepared-spec package that cannot observe later live recipe drift", function()
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") }
		)
		local constructed, held_callback
		fx.opts.package_module = {
			DEFAULT_INSTALL_OPTS = { debug = false, force = false, strict = false },
			new = function(_, spec_snapshot, registry_source)
				constructed = {
					name = spec_snapshot.name,
					spec = spec_snapshot,
					registry = registry_source,
				}
				function constructed:install(opts, callback)
					assert.equals(fx.location, opts.location)
					held_callback = callback
					return install_handle(function()
						return false
					end)
				end
				return constructed
			end,
		}

		handoff.execute(plan, fx.opts)
		assert.is_table(constructed)
		assert.equals(0, #fx.live_installs, "the verified live package must never receive install")
		assert.equals("dispatched", plan.items[1].outcome)
		assert.is_not.equal(plan.items[1].spec_snapshot, constructed.spec)
		assert.equals("pkg:generic/tool@1.0.0", constructed.spec.source.id)

		fx.packages.tool.spec.source.id = "pkg:generic/changed@2.0.0"
		assert.equals("pkg:generic/tool@1.0.0", constructed.spec.source.id)
		held_callback(true, {})
		assert.equals("completed", plan.items[1].outcome)
	end)

	it("uses mason-core.package as the default detached constructor", function()
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") }
		)
		local saved = package.loaded["mason-core.package"]
		local constructed = 0
		package.loaded["mason-core.package"] = {
			DEFAULT_INSTALL_OPTS = { debug = false, force = false, strict = false },
			new = function(_, spec, registry)
				constructed = constructed + 1
				local detached = { name = spec.name, spec = spec, registry = registry }
				function detached:install(_, callback)
					callback(true, {})
					return install_handle()
				end
				return detached
			end,
		}
		fx.opts.package_module = nil
		local ok, err = pcall(handoff.execute, plan, fx.opts)
		package.loaded["mason-core.package"] = saved
		assert.is_true(ok, err)
		assert.equals(1, constructed)
		assert.equals(0, #fx.live_installs)
		assert.equals("completed", plan.items[1].outcome)
	end)

	it("fails closed on detached constructor or snapshot identity mismatch and continues", function()
		local cases = {
			raise = function()
				error("constructor failed")
			end,
			name = function(spec, registry)
				return { name = "other", spec = spec, registry = registry }
			end,
			live = function(_, _, fx)
				return fx.packages.bad
			end,
			spec = function(spec, registry)
				spec.source.id = "recipe:B"
				return { name = spec.name, spec = spec, registry = registry }
			end,
			registry = function(spec)
				return { name = spec.name, spec = spec, registry = registry_identity("registry-b") }
			end,
		}
		for case_name, bad_constructor in pairs(cases) do
			local plan, fx = prepare_batch({
				bad = { bins = { bad = "bin/bad" } },
				good = { bins = { good = "bin/good" } },
			}, { entry("a", "bad", "bad", "bad"), entry("a", "good", "good", "good") }, {
				notify = function() end,
				schedule = function(callback)
					callback()
				end,
			})
			local detached_installs = {}
			fx.opts.package_module = {
				DEFAULT_INSTALL_OPTS = { debug = false, force = false, strict = false },
				new = function(_, spec, registry)
					local detached
					if spec.name == "bad" then
						detached = bad_constructor(spec, registry, fx)
					else
						detached = { name = spec.name, spec = spec, registry = registry }
					end
					if detached then
						function detached:install(_, callback)
							detached_installs[#detached_installs + 1] = self.name
							callback(true, {})
							return install_handle()
						end
					end
					return detached
				end,
			}

			handoff.execute(plan, fx.opts)
			assert.equals(0, #fx.installs, case_name)
			assert.equals(0, #fx.live_installs, case_name)
			assert.same({ "good" }, detached_installs, case_name)
			assert.same({ "failed", "completed" }, { plan.items[1].outcome, plan.items[2].outcome }, case_name)
		end
	end)

	it("ignores disabled, empty, and non-planned items", function()
		handoff.execute({ enabled = false, items = {} }, {})
		handoff.execute({ enabled = true, items = {} }, {})
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") }
		)
		plan.items[1].outcome = "completed"
		handoff.execute(plan, fx.opts)
		assert.equals(0, #fx.installs)
	end)

	it("fails closed on a fresh same-name same-binary package winning by changed registry precedence", function()
		local fx = precedence_fixture()
		local messages = {}
		fx.opts.notify = function(message)
			messages[#messages + 1] = message
		end
		fx.opts.schedule = function(callback)
			callback()
		end
		local plan = handoff.prepare(
			result({
				entry("a", "bad", "bad", "bad"),
				entry("a", "good", "good", "good"),
			}),
			fx.opts
		)
		local prepared_bad = fx.objects.primary.bad[1]
		local prepared_good = fx.objects.primary.good[1]

		fx.set_precedence({ "secondary", "primary" })
		handoff.execute(plan, fx.opts)

		local newly_winning_bad = fx.objects.secondary.bad[1]
		local reacquired_good = fx.objects.primary.good[2]
		assert.equals(prepared_bad.name, newly_winning_bad.name)
		assert.same(prepared_bad.spec.bin, newly_winning_bad.spec.bin)
		assert.is_not.equal(prepared_bad.registry.id, newly_winning_bad.registry.id)
		assert.is_false(vim.deep_equal(prepared_bad.registry:serialize(), newly_winning_bad.registry:serialize()))
		assert.is_false(vim.deep_equal(prepared_bad.spec.source.install, newly_winning_bad.spec.source.install))
		assert.equals(0, prepared_bad.install_calls)
		assert.equals(0, newly_winning_bad.install_calls)
		assert.equals(0, prepared_good.install_calls)
		assert.equals(0, reacquired_good.install_calls)
		assert.equals(1, #fx.detached)
		assert.equals("good", fx.detached[1].name)
		assert.equals(1, fx.detached[1].install_calls)
		assert.same({ "failed", "completed" }, { plan.items[1].outcome, plan.items[2].outcome })
		assert.equals(3, #messages)
		assert.is_truthy(messages[1]:find("bad", 1, true))
		assert.is_truthy(messages[1]:find("outcome=failed availability=not_checked attestation=not_checked", 1, true))
		for _, message in ipairs(messages) do
			assert.is_falsy(message:find("[%z\1-\31\127]"))
			assert.is_true(#message <= 400)
		end
	end)

	it("dispatches only the freshly reacquired winner when precedence is unchanged", function()
		local fx = precedence_fixture()
		local plan = handoff.prepare(result({ entry("a", "bad", "bad", "bad") }), fx.opts)
		local prepared_package = fx.objects.primary.bad[1]

		handoff.execute(plan, fx.opts)

		assert.equals(2, #fx.objects.primary.bad)
		local reacquired_package = fx.objects.primary.bad[2]
		assert.is_not.equal(prepared_package, reacquired_package)
		assert.equals(0, prepared_package.install_calls)
		assert.equals(0, reacquired_package.install_calls)
		assert.equals(0, #fx.objects.secondary.bad)
		assert.equals(1, #fx.detached)
		assert.equals(1, fx.detached[1].install_calls)
		assert.is_not.equal(reacquired_package, fx.detached[1])
		assert.equals("completed", plan.items[1].outcome)
	end)

	it("rechecks all trust-boundary data and contains each failed item", function()
		local failure_cases = {
			mapping = function(fx)
				fx.packages.bad.spec.bin = { changed = "bin/changed" }
			end,
			lookup = function(fx)
				local original = fx.registry.get_package
				local unprintable = setmetatable({}, {
					__tostring = function()
						error("must not stringify")
					end,
				})
				fx.registry.get_package = function(name)
					if name == "bad" then
						error(unprintable, 0)
					end
					return original(name)
				end
			end,
			name = function(fx)
				fx.packages.bad.name = "other"
			end,
			registry = function(fx)
				fx.packages.bad.registry = registry_identity("registry-b")
			end,
			spec = function(fx)
				fx.packages.bad.spec.source.id = "new-recipe"
			end,
			path = function(fx)
				fx.packages.bad.get_install_path = function()
					return "/different/path"
				end
			end,
			installed = function(fx)
				fx.packages.bad.is_installed = function()
					return true
				end
			end,
			installing = function(fx)
				fx.packages.bad.is_installing = function()
					return true
				end
			end,
			noninstallable = function(fx)
				fx.packages.bad.is_installable = function()
					return false
				end
			end,
			installed_query = function(fx)
				fx.packages.bad.is_installed = function()
					error("state")
				end
			end,
			installing_query = function(fx)
				fx.packages.bad.is_installing = function()
					error("state")
				end
			end,
			installable_query = function(fx)
				fx.packages.bad.is_installable = function()
					error("state")
				end
			end,
		}
		for name, mutate in pairs(failure_cases) do
			local notifications = {}
			local plan, fx = prepare_batch({
				bad = { bins = { bad = "bin/bad" } },
				good = { bins = { good = "bin/good" } },
			}, { entry("a", "bad", "bad", "bad"), entry("a", "good", "good", "good") }, {
				notify = function(message)
					notifications[#notifications + 1] = message
				end,
				schedule = function(callback)
					callback()
				end,
			})
			mutate(fx, plan)
			handoff.execute(plan, fx.opts)
			assert.equals(1, #fx.installs, name)
			assert.equals("good", fx.installs[1].package, name)
			assert.equals("failed", plan.items[1].outcome, name)
			assert.equals("completed", plan.items[2].outcome, name)
			assert.equals(3, #notifications, name)
		end
	end)

	it("fails closed when the current canonical install root drifts", function()
		local current_root = "/mason"
		local plan, fx = prepare_batch({
			bad = { bins = { bad = "bin/bad" } },
			good = { bins = { good = "bin/good" } },
		}, { entry("a", "bad", "bad", "bad"), entry("a", "good", "good", "good") }, {
			get_install_root = function()
				return current_root
			end,
			notify = function() end,
			schedule = function(callback)
				callback()
			end,
		})
		current_root = "/changed-root"
		handoff.execute(plan, fx.opts)
		assert.equals(0, #fx.installs)
		assert.same({ "failed", "failed" }, { plan.items[1].outcome, plan.items[2].outcome })
	end)

	it("passes the prepared location and ledger path to install", function()
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") }
		)
		handoff.execute(plan, fx.opts)
		assert.equals(fx.location, fx.installs[1].location)
		assert.equals("/mason/packages/tool", plan.items[1].install_path)
		assert.equals("completed", plan.items[1].outcome)
	end)

	it("shares the detached install handle with the canonical package reservation", function()
		local held_callback
		local closed = false
		local handle = {
			is_closed = function()
				return closed
			end,
		}
		local plan, fx = prepare_batch({
			tool = {
				bins = { tool = "bin/tool" },
				install = function(callback)
					held_callback = callback
					return handle
				end,
			},
		}, { entry("a", "tool", "tool", "tool") })
		local canonical = fx.packages.tool
		handoff.execute(plan, fx.opts)
		assert.equals(handle, canonical.install_handle)
		assert.is_true(canonical:is_installing())
		closed = true
		held_callback(true, {})
		assert.is_false(canonical:is_installing())
		assert.equals("completed", plan.items[1].outcome)
	end)

	it("marks invalid handles or canonical reservation failure unknown and continues", function()
		for _, case_name in ipairs({ "invalid", "assignment" }) do
			local plan, fx = prepare_batch({
				bad = {
					bins = { bad = "bin/bad" },
					install = function(callback)
						callback(true, {})
						if case_name == "invalid" then
							return "not a handle"
						end
						return install_handle(function()
							return false
						end)
					end,
				},
				good = { bins = { good = "bin/good" } },
			}, { entry("a", "bad", "bad", "bad"), entry("a", "good", "good", "good") }, {
				notify = function() end,
				schedule = function(callback)
					callback()
				end,
			})
			if case_name == "assignment" then
				setmetatable(fx.packages.bad, {
					__newindex = function(_, key)
						if key == "install_handle" then
							error("reservation rejected")
						end
					end,
				})
			end

			handoff.execute(plan, fx.opts)
			if case_name == "invalid" then
				assert.same({ "unknown", "completed" }, { plan.items[1].outcome, plan.items[2].outcome }, case_name)
				assert.is_false(fx.packages.bad.install_handle:is_closed())
				assert.equals(2, #fx.installs, case_name)
			else
				assert.same({ "failed", "completed" }, { plan.items[1].outcome, plan.items[2].outcome }, case_name)
				assert.is_nil(rawget(fx.packages.bad, "install_handle"), case_name)
				assert.equals(1, #fx.installs, case_name)
			end
		end
	end)

	it("records completed, failed, and still-dispatched outcomes without inventing timeout state", function()
		local plan, fx = prepare_batch({
			a = {
				bins = { a = "bin/a" },
				install = function(callback)
					callback(true, {})
				end,
			},
			b = {
				bins = { b = "bin/b" },
				install = function(callback)
					callback(false, "failed")
				end,
			},
			c = {
				bins = { c = "bin/c" },
				install = function() end,
			},
		}, { entry("a", "a", "a", "a"), entry("a", "b", "b", "b"), entry("a", "c", "c", "c") }, {
			notify = function() end,
			schedule = function(callback)
				callback()
			end,
		})
		handoff.execute(plan, fx.opts)
		assert.same(
			{ "completed", "failed", "dispatched" },
			{ plan.items[1].outcome, plan.items[2].outcome, plan.items[3].outcome }
		)
		assert.equals("unknown at observation deadline", handoff.observed_outcome(plan.items[3], true))
		assert.equals("dispatched", plan.items[3].outcome)
	end)

	it("settles duplicate callbacks once and never enables captured LSP names", function()
		local enabled = {}
		local plan, fx = prepare_batch({
			tool = {
				bins = { tool = "bin/tool" },
				install = function(callback)
					callback(true, {})
					callback(false, "late")
				end,
			},
		}, { entry("lsp", "z_ls", "tool", "tool"), entry("lsp", "a_ls", "tool", "tool") }, {
			lsp_enable = function(name)
				enabled[#enabled + 1] = name
			end,
			schedule = function(callback)
				callback()
			end,
			notify = function()
				error("failure notification must not run")
			end,
		})
		handoff.execute(plan, fx.opts)
		assert.equals("completed", plan.items[1].outcome)
		assert.same({}, enabled)
	end)

	it("marks callback-then-throw and throw-after-dispatch unknown, suppresses effects, and continues", function()
		for _, install in ipairs({
			function(callback)
				callback(true, {})
				error("after callback")
			end,
			function()
				error("after internal dispatch")
			end,
		}) do
			local enabled, notifications = {}, {}
			local plan, fx = prepare_batch({
				bad = { bins = { bad = "bin/bad" }, install = install },
				good = { bins = { good = "bin/good" } },
			}, { entry("lsp", "bad_ls", "bad", "bad"), entry("a", "good", "good", "good") }, {
				lsp_enable = function(name)
					enabled[#enabled + 1] = name
				end,
				notify = function(message)
					notifications[#notifications + 1] = message
				end,
				schedule = function(callback)
					callback()
				end,
			})
			handoff.execute(plan, fx.opts)
			assert.equals("unknown", plan.items[1].outcome)
			assert.equals("completed", plan.items[2].outcome)
			assert.same({}, enabled)
			assert.equals(4, #notifications)
			assert.is_true(vim.iter(notifications):any(function(message)
				return message:find("outcome=unknown availability=not_checked attestation=not_checked", 1, true) ~= nil
			end))
		end
	end)

	it("ignores a late callback after an install invocation throws", function()
		local late_callback
		local effects = 0
		local plan, fx = prepare_batch({
			tool = {
				bins = { tool = "bin/tool" },
				install = function(callback)
					late_callback = callback
					error("after internal dispatch")
				end,
			},
		}, { entry("lsp", "tool_ls", "tool", "tool") }, {
			schedule = function(callback)
				callback()
			end,
			notify = function()
				effects = effects + 1
			end,
			lsp_enable = function()
				effects = effects + 1
			end,
		})
		handoff.execute(plan, fx.opts)
		assert.equals("unknown", plan.items[1].outcome)
		assert.equals(2, effects)
		late_callback(true, {})
		assert.equals("unknown", plan.items[1].outcome)
		assert.equals(2, effects)
	end)

	it("guards effects against duplicate scheduler execution and fallback", function()
		local effects = 0
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("lsp", "tool_ls", "tool", "tool") },
			{
				schedule = function(callback)
					callback()
					callback()
					error("rejected after execution")
				end,
				defer = function(callback)
					callback()
				end,
				lsp_enable = function()
					effects = effects + 1
				end,
			}
		)
		handoff.execute(plan, fx.opts)
		assert.equals(0, effects)
	end)

	it("bridges callback effects through scheduler then deferred fallback", function()
		local effects, deferred = {}, {}
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("lsp", "tool_ls", "tool", "tool") },
			{
				schedule = function()
					error("rejected")
				end,
				defer = function(callback, delay)
					assert.equals(0, delay)
					deferred[#deferred + 1] = callback
				end,
				lsp_enable = function(name)
					effects[#effects + 1] = name
				end,
			}
		)
		handoff.execute(plan, fx.opts)
		assert.equals("verifying", plan.items[1].outcome)
		assert.same({}, effects)
		deferred[1]()
		assert.equals("completed", plan.items[1].outcome)
		assert.same({}, effects)
	end)

	it("preserves terminal ledger truth and runs no unsafe effect when both bridges reject", function()
		for _, callback_result in ipairs({ { true, {} }, { false, "failure" } }) do
			local effects = 0
			local plan, fx = prepare_batch({
				tool = {
					bins = { tool = "bin/tool" },
					install = function(callback)
						callback(unpack(callback_result))
					end,
				},
			}, { entry("lsp", "tool_ls", "tool", "tool") }, {
				schedule = function()
					error("schedule rejected")
				end,
				defer = function()
					error("defer rejected")
				end,
				notify = function()
					effects = effects + 1
				end,
				lsp_enable = function()
					effects = effects + 1
				end,
			})
			handoff.execute(plan, fx.opts)
			if callback_result[1] then
				assert_result(plan.items[1], "completed", "not_checked", "failed")
				assert.equals("post-install safe-context bridge failed", plan.items[1].attestation_reason)
			else
				assert_result(plan.items[1], "failed", "not_checked", "not_checked")
			end
			assert.equals(1, effects)
		end
	end)

	it("contains notifier and individual LSP retry failures", function()
		local enabled = {}
		local plan, fx = prepare_batch({
			good = { bins = { good = "bin/good" } },
			bad = {
				bins = { bad = "bin/bad" },
				install = function(callback)
					callback(false, "bad")
				end,
			},
		}, {
			entry("lsp", "a_ls", "good", "good"),
			entry("lsp", "b_ls", "good", "good"),
			entry("a", "bad", "bad", "bad"),
		}, {
			schedule = function(callback)
				callback()
			end,
			notify = function()
				error("notifier broken")
			end,
			lsp_enable = function(name)
				if name == "a_ls" then
					error("lsp broken")
				end
				enabled[#enabled + 1] = name
			end,
		})
		assert.has_no.errors(function()
			handoff.execute(plan, fx.opts)
		end)
		assert.same({}, enabled)
		assert.same({ "failed", "completed" }, { plan.items[1].outcome, plan.items[2].outcome })
	end)

	it("sanitizes and bounds package and error notification text", function()
		local messages = {}
		local function notify(message)
			messages[#messages + 1] = message
		end
		local function schedule(callback)
			callback()
		end

		local malicious_package = "tool\n\27\0\226\128\174" .. string.rep("x", 400)
		local package_plan, package_fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") },
			{ notify = notify, schedule = schedule }
		)
		package_plan.items[1].package = malicious_package
		handoff.execute(package_plan, package_fx.opts)
		assert.equals(0, #package_fx.installs)

		local error_plan, error_fx = prepare_batch({
			tool = {
				bins = { tool = "bin/tool" },
				install = function(callback)
					callback(false, "bad\n\27\0\226\128\174" .. string.rep("y", 400))
				end,
			},
		}, { entry("a", "tool", "tool", "tool") }, { notify = notify, schedule = schedule })
		handoff.execute(error_plan, error_fx.opts)

		assert.equals(3, #messages)
		for _, message in ipairs(messages) do
			assert.is_falsy(message:find("\n", 1, true))
			assert.is_falsy(message:find("\27", 1, true))
			assert.is_falsy(message:find("\0", 1, true))
			assert.is_falsy(message:find("\226\128\174", 1, true))
			assert.is_true(#message <= 400)
		end
	end)
end)

describe("muster.handoff.mason pre-dispatch security contract", function()
	it("feature-checks receipt getters and Package Optional access before dispatch", function()
		local cases = {
			function(fx)
				fx.opts.receipt_module = { InstallReceipt = { from_json = function() end } }
			end,
			function(fx)
				fx.packages.tool.get_receipt = nil
			end,
			function(fx)
				fx.packages.tool.get_receipt = function()
					return {}
				end
			end,
		}
		for index, mutate in ipairs(cases) do
			local plan, fx = prepare_batch(
				{ tool = { bins = { tool = "bin/tool" } } },
				{ entry("a", "tool", "tool", "tool") }
			)
			mutate(fx)
			handoff.execute(plan, fx.opts)
			assert.equals(0, #fx.installs, index)
			assert.equals("failed", plan.items[1].outcome, index)
		end
	end)

	it("owns the canonical reservation before a reentrant start notifier can install", function()
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") }
		)
		local canonical = fx.packages.tool
		local external_ok
		fx.opts.notify = function(message)
			if message == "muster: installing tool via Mason" then
				assert.is_true(canonical:is_installing())
				external_ok = pcall(canonical.install, canonical, { location = fx.location }, function() end)
			end
		end
		handoff.execute(plan, fx.opts)
		assert.is_false(external_ok)
		assert.equals(0, #fx.live_installs)
		assert.equals(1, #fx.installs)
	end)

	it("blocks a competing canonical install from a detached handle listener", function()
		local canonical
		local external_ok
		local listener_running = false
		local plan, fx
		plan, fx = prepare_batch({
			tool = {
				bins = { tool = "bin/tool" },
				install = function(callback)
					if not listener_running then
						listener_running = true
						external_ok = pcall(canonical.install, canonical, { location = fx.location }, function() end)
					end
					callback(true, {})
					return install_handle()
				end,
			},
		}, { entry("a", "tool", "tool", "tool") })
		canonical = fx.packages.tool
		handoff.execute(plan, fx.opts)
		assert.is_false(external_ok)
		assert.equals(0, #fx.live_installs)
		assert.equals(1, #fx.installs)
	end)

	it("rejects a handle-listener overwrite unless the canonical slot still holds the exact sentinel", function()
		local canonical
		local foreign = install_handle(function()
			return false
		end)
		local actual = install_handle()
		local plan, fx = prepare_batch({
			tool = {
				bins = { tool = "bin/tool" },
				install = function(callback)
					assert.is_true(canonical:is_installing())
					canonical.install_handle = foreign
					callback(true, {})
					return actual
				end,
			},
		}, { entry("a", "tool", "tool", "tool") })
		canonical = fx.packages.tool
		handoff.execute(plan, fx.opts)
		assert.equals("unknown", plan.items[1].outcome)
		assert.equals(foreign, canonical.install_handle)
	end)
end)

describe("muster.handoff.mason receipt and path verification", function()
	it("completes with a real pinned schema-2 callback receipt and JSON disk roundtrip", function()
		with_pinned_mason(function()
			local compiler = require("mason-core.installer.compiler")
			local Purl = require("mason-core.purl")
			local receipt_module = require("mason-core.receipt")
			local closed = false
			local held_callback
			local spec = {
				schema = "registry+v1",
				name = "tool",
				bin = { tool = "bin/tool" },
				source = { id = "pkg:composer/vendor/tool@1.0.0" },
			}
			local plan, fx = prepare_batch({
				tool = {
					bins = spec.bin,
					spec = spec,
					install = function(callback)
						held_callback = callback
						return install_handle(function()
							return closed
						end)
					end,
				},
			}, { entry("a", "tool", "tool", "tool") })
			fx.opts.compiler = compiler
			fx.opts.purl = Purl
			fx.opts.receipt_module = receipt_module
			fx.opts._source_fingerprint = function()
				return require("muster.mason_source").fingerprint_root(vim.env.MUSTER_MASON_NVIM_PATH)
			end
			fx.opts.verify = false
			fx.opts.realpath = function(path)
				return path:gsub("^/mason", "/real/mason")
			end
			fx.opts.probe = function()
				return {
					status = "found",
					source = "mason",
					path = "/mason/bin/tool",
					realpath = "/real/mason/packages/tool/bin/tool",
				}
			end

			handoff.execute(plan, fx.opts)
			assert.equals("dispatched", plan.items[1].outcome)
			local install_options =
				vim.tbl_extend("force", fx.opts.package_module.DEFAULT_INSTALL_OPTS, { location = fx.location })
			local callback_receipt = receipt_module.InstallReceiptBuilder
				:new()
				:with_name("tool")
				:with_start_time(1, 0)
				:with_completion_time(2, 0)
				:with_source({ type = spec.schema, id = spec.source.id, raw = spec.source })
				:with_install_options(install_options)
				:with_registry(plan.items[1].registry_identity.serialized)
				:with_link("bin", "tool", "bin/tool")
				:build()
			local disk_receipt = receipt_module.InstallReceipt.from_json(vim.json.decode(callback_receipt:to_json()))
			fx.packages.tool.is_installed = function()
				return true
			end
			fx.packages.tool.get_receipt = function()
				return optional_fixture(disk_receipt)
			end
			closed = true
			held_callback(true, callback_receipt)
			assert.equals("completed", plan.items[1].outcome, plan.items[1].error)
		end)
	end)

	it("fails closed when pinned npm compiler settings mutate after capture", function()
		with_pinned_mason(function()
			local compiler = require("mason-core.installer.compiler")
			local Purl = require("mason-core.purl")
			local receipt_module = require("mason-core.receipt")
			local settings = require("mason.settings")
			local original_args = settings.current.npm.install_args
			settings.current.npm.install_args = { "--captured" }
			local closed = false
			local held_callback
			local spec = {
				schema = "registry+v1",
				name = "tool",
				bin = { tool = "bin/tool" },
				source = { id = "pkg:npm/tool@1.0.0" },
			}
			local plan, fx = prepare_batch({
				tool = {
					bins = spec.bin,
					spec = spec,
					install = function(callback)
						held_callback = callback
						return install_handle(function()
							return closed
						end)
					end,
				},
			}, { entry("a", "tool", "tool", "tool") })
			fx.opts.compiler = compiler
			fx.opts.purl = Purl
			fx.opts.receipt_module = receipt_module
			fx.opts._source_fingerprint = function()
				return require("muster.mason_source").fingerprint_root(vim.env.MUSTER_MASON_NVIM_PATH)
			end
			fx.opts.verify = false
			fx.opts.notify = function(message)
				if message == "muster: installing tool via Mason" then
					settings.current.npm.install_args = { "--mutated" }
				end
			end
			fx.opts.realpath = function(path)
				return path:gsub("^/mason", "/real/mason")
			end
			fx.opts.probe = function()
				return {
					status = "found",
					source = "mason",
					path = "/mason/bin/tool",
					realpath = "/real/mason/packages/tool/bin/tool",
				}
			end

			local ok, err = pcall(function()
				handoff.execute(plan, fx.opts)
				assert.same({ "--captured" }, plan.items[1]._compiler_state.source.npm.extra_args)
				local install_options =
					vim.tbl_extend("force", fx.opts.package_module.DEFAULT_INSTALL_OPTS, { location = fx.location })
				local callback_receipt = receipt_module.InstallReceiptBuilder
					:new()
					:with_name("tool")
					:with_start_time(1, 0)
					:with_completion_time(2, 0)
					:with_source({ type = spec.schema, id = spec.source.id, raw = spec.source })
					:with_install_options(install_options)
					:with_registry(plan.items[1].registry_identity.serialized)
					:with_link("bin", "tool", "bin/tool")
					:build()
				local disk_receipt =
					receipt_module.InstallReceipt.from_json(vim.json.decode(callback_receipt:to_json()))
				fx.packages.tool.is_installed = function()
					return true
				end
				fx.packages.tool.get_receipt = function()
					return optional_fixture(disk_receipt)
				end
				closed = true
				held_callback(true, callback_receipt)
				assert_result(plan.items[1], "completed", "found", "failed")
				assert.is_truthy(plan.items[1].attestation_reason)
			end)
			settings.current.npm.install_args = original_args
			assert.is_true(ok, err)
		end)
	end)

	it("completes only for matching schema-2 provenance and the exact Unix Mason link target", function()
		local harness = verification_harness({ tool = "bin/tool" })
		assert.equals("dispatched", harness.item.outcome)
		assert.same({
			message = "muster: installing tool via Mason",
			level = vim.log.levels.INFO,
			opts = { title = "muster" },
		}, harness.notifications[1])

		harness.complete()
		assert_result(harness.item, "completed", "found", "full")
		assert.equals(2, #harness.notifications)
		assert.equals(vim.log.levels.INFO, harness.notifications[2].level)
		assert.equals(
			"muster: Mason package tool: outcome=completed availability=found attestation=full",
			harness.notifications[2].message
		)
	end)

	it("emits exactly one bounded terminal notification with all dimensions for every computed tuple", function()
		local cases = {
			{ "found", { status = "full" }, vim.log.levels.INFO },
			{ "found", { status = "partial", reason = "closed gap" }, vim.log.levels.WARN },
			{ "found", { status = "failed", reason = "failed proof" }, vim.log.levels.ERROR },
			{ "missing", { status = "failed", reason = "failed proof" }, vim.log.levels.ERROR },
			{ "unknown", { status = "failed", reason = "failed proof" }, vim.log.levels.ERROR },
			{ "broken", { status = "failed", reason = "failed proof" }, vim.log.levels.ERROR },
			{ "unverifiable", { status = "failed", reason = "failed proof" }, vim.log.levels.ERROR },
		}
		for _, case in ipairs(cases) do
			local status, attestation, level = unpack(case)
			local probe = status == "found"
					and {
						status = "found",
						source = "mason",
						path = "/mason/bin/tool",
						realpath = "/real/mason/packages/tool/bin/tool",
					}
				or { status = status, reason = status .. " fixture" }
			local harness = verification_harness({ tool = "bin/tool" }, {
				probes = { tool = probe },
				verify = function()
					return vim.deepcopy(attestation)
				end,
			})
			harness.complete()
			assert.equals(2, #harness.notifications, status)
			assert.equals(level, harness.notifications[2].level, status)
			assert.is_truthy(harness.notifications[2].message:find("outcome=completed", 1, true))
			assert.is_truthy(harness.notifications[2].message:find("availability=" .. status, 1, true))
			assert.is_truthy(harness.notifications[2].message:find("attestation=" .. harness.item.attestation, 1, true))
			assert.is_true(#harness.notifications[2].message <= 400)
		end
	end)

	it("structurally budgets maximum package and dual reasons without dropping labels", function()
		local binaries = {}
		local probes = {}
		for index = 1, 12 do
			local binary = ("binary-%02d-%s"):format(index, string.rep("x", 30))
			binaries[binary] = "bin/" .. binary
			probes[binary] = { status = "broken", reason = string.rep("availability", 30) }
		end
		local harness = verification_harness(binaries, {
			probes = probes,
			verify = function()
				return { status = "failed", reason = string.rep("attestation", 30) }
			end,
		})
		harness.item.package = string.rep("p", 128)
		harness.complete()
		local message = harness.notifications[2].message
		assert.is_true(#message <= 400)
		assert.is_truthy(message:find("Mason package ", 1, true))
		assert.is_truthy(message:find("outcome=completed availability=broken attestation=failed", 1, true))
		assert.is_truthy(message:find("availability_reason=", 1, true))
		assert.is_truthy(message:find("attestation_reason=", 1, true))
	end)

	it("normalizes the callback receipt synchronously before scheduled verification", function()
		local effects = {}
		local harness = verification_harness({ tool = "bin/tool" }, {
			schedule = function(callback)
				effects[#effects + 1] = callback
			end,
		})
		harness.complete()
		assert.equals("verifying", harness.item.outcome)
		harness.callback_data.source.id = "pkg:generic/mutated@9.9.9"
		effects[1]()
		assert.equals("completed", harness.item.outcome)
	end)

	it("partially attests closed compiler gaps only when captured state remains stable", function()
		for _, purl_type in ipairs({ "npm", "pypi", "github", "mason", "generic", "openvsx" }) do
			local selected = { value = "platform-a" }
			local compiler = mutable_compiler_fixture(purl_type, selected)
			local harness = verification_harness({ tool = "bin/tool" }, { compiler = compiler })
			selected.value = "platform-b"
			local actual = compiler.parse(harness.item.spec_snapshot):get_or_nil()
			assert.equals("platform-b", actual.source.selected)
			selected.value = "platform-a"
			harness.complete()
			assert_result(harness.item, "completed", "found", "partial")
			assert.equals(vim.log.levels.WARN, harness.notifications[2].level, purl_type)
		end
	end)

	it("fully attests only the closed full compiler set with exact found Mason proofs", function()
		for _, purl_type in ipairs({ "cargo", "composer", "gem", "golang", "luarocks", "nuget", "opam" }) do
			local harness = verification_harness({ tool = "bin/tool" }, {
				compiler = mutable_compiler_fixture(purl_type, { value = "stable" }),
			})
			harness.complete()
			assert_result(harness.item, "completed", "found", "full")
		end
	end)

	it("fails attestation for unknown and future compiler types", function()
		for _, purl_type in ipairs({ "unknown", "future-installer" }) do
			local harness = verification_harness({ tool = "bin/tool" }, {
				compiler = mutable_compiler_fixture(purl_type, { value = "stable" }),
			})
			harness.complete()
			assert_result(harness.item, "completed", "found", "failed")
		end
	end)

	it("rejects API-compatible compiler runtimes with mismatched or unreadable source identity", function()
		for _, fingerprint in ipairs({
			function()
				return string.rep("0", 64)
			end,
			function()
				return 7
			end,
			function()
				error("source root unreadable")
			end,
		}) do
			local harness = verification_harness({ tool = "bin/tool" }, {
				_source_fingerprint = fingerprint,
			})
			harness.complete()
			assert_result(harness.item, "completed", "found", "failed")
			assert.equals("string", type(harness.item._compiler_state.fingerprint))
		end
	end)

	it("requires every binary in a package to resolve through its exact Mason link and target", function()
		local harness = verification_harness({ alpha = "bin/alpha", beta = "bin/beta" }, {
			probes = {
				beta = {
					status = "found",
					source = "mason",
					path = "/external/bin/beta",
					realpath = "/real/mason/packages/tool/bin/beta",
				},
			},
		})
		harness.complete()
		assert_result(harness.item, "completed", "found", "failed")
		assert.equals(vim.log.levels.ERROR, harness.notifications[2].level)
	end)

	it("isolates availability and attestation exceptions while continuing every binary probe", function()
		local probed = {}
		local attested = 0
		local availability_failure = verification_harness({ alpha = "bin/alpha", beta = "bin/beta" }, {
			probe = function(binary)
				probed[#probed + 1] = binary
				if binary == "alpha" then
					error("probe failed")
				end
				return {
					status = "found",
					source = "mason",
					path = "/mason/bin/" .. binary,
					realpath = "/real/mason/packages/tool/bin/" .. binary,
				}
			end,
			verify = function()
				attested = attested + 1
				return { status = "failed", reason = "attestation still ran" }
			end,
		})
		availability_failure.complete()
		assert.same({ "alpha", "beta" }, probed)
		assert.equals(1, attested)
		assert_result(availability_failure.item, "completed", "broken", "failed")

		local attestation_failure = verification_harness({ tool = "bin/tool" }, {
			verify = function()
				error("attestation failed")
			end,
		})
		attestation_failure.complete()
		assert_result(attestation_failure.item, "completed", "found", "failed")
		assert.equals("Mason attestation computation failed", attestation_failure.item.attestation_reason)
	end)

	it("aggregates mixed multi-binary availability by priority without laundering shadows", function()
		local harness = verification_harness({
			alpha = "bin/alpha",
			beta = "bin/beta",
			broken = "bin/broken",
			missing = "bin/missing",
			shadow = "bin/shadow",
		}, {
			probes = {
				broken = { status = "broken", reason = "probe broke" },
				missing = { status = "missing" },
				shadow = {
					status = "found",
					source = "system",
					path = "/usr/bin/shadow",
					realpath = "/usr/bin/shadow",
				},
			},
		})
		harness.complete()
		assert_result(harness.item, "completed", "broken", "failed")
		assert.is_truthy(harness.item.availability_reason:find("broken", 1, true))
	end)

	it("applies the closed multi-binary availability priority order", function()
		local cases = {
			{ "broken", { "found", "unverifiable", "unknown", "missing", "broken" } },
			{ "missing", { "found", "unverifiable", "unknown", "missing" } },
			{ "unknown", { "found", "unverifiable", "unknown" } },
			{ "unverifiable", { "found", "unverifiable" } },
			{ "found", { "found", "found" } },
		}
		for _, case in ipairs(cases) do
			local expected, statuses = unpack(case)
			local binaries = {}
			local probes = {}
			for index, status in ipairs(statuses) do
				local binary = "tool-" .. index
				binaries[binary] = "bin/" .. binary
				probes[binary] = status == "found"
						and {
							status = "found",
							source = "mason",
							path = "/mason/bin/" .. binary,
							realpath = "/real/mason/packages/tool/bin/" .. binary,
						}
					or { status = status, reason = status }
			end
			local harness = verification_harness(binaries, {
				probes = probes,
				verify = function()
					return { status = "failed", reason = "fixture" }
				end,
			})
			harness.complete()
			assert.equals(expected, harness.item.availability)
		end
	end)

	it("bounds and sorts aggregate availability names", function()
		local binaries = {}
		local probes = {}
		for index = 1, 12 do
			local name = ("binary-%02d-%s"):format(index, string.rep("x", 30))
			binaries[name] = "bin/" .. name
			probes[name] = { status = "broken", reason = "broken" }
		end
		local harness = verification_harness(binaries, { probes = probes })
		harness.complete()
		assert_result(harness.item, "completed", "broken", "failed")
		assert.is_true(#harness.item.availability_reason <= 200)
		assert.is_truthy(harness.item.availability_reason:find("more)", 1, true))
	end)

	it("rejects an exact Mason link that resolves to a different package target", function()
		local harness = verification_harness({ tool = "bin/tool" }, {
			probes = {
				tool = {
					status = "found",
					source = "mason",
					path = "/mason/bin/tool",
					realpath = "/real/mason/packages/tool/bin/other",
				},
			},
		})
		harness.complete()
		assert_result(harness.item, "completed", "found", "failed")
	end)

	it("rejects unsafe receipt targets and canonical package prefix collisions", function()
		for _, target in ipairs({ ".", "/outside/tool", "../outside/tool", "bin/../../outside/tool", "C:/outside/tool" }) do
			local harness = verification_harness({ tool = target })
			harness.complete()
			assert_result(harness.item, "completed", "found", "failed")
		end

		local harness = verification_harness({ tool = "bin/tool" }, {
			realpaths = {
				["/mason/packages/tool"] = "/real/mason-other/packages/tool",
			},
		})
		harness.complete()
		assert_result(harness.item, "completed", "found", "failed")
	end)

	it("rejects callback/disk, registry, source, option, schema, and link mismatches", function()
		local mutations = {
			function(harness)
				harness:set_disk(receipt_fixture(vim.tbl_deep_extend("force", vim.deepcopy(harness.data), {
					name = "other",
				})))
			end,
			function(harness)
				harness.data.registry = { id = "other" }
			end,
			function(harness)
				harness.data.source.id = "pkg:generic/other@2.0.0"
			end,
			function(harness)
				harness.data.install_options.force = true
			end,
			function(harness)
				harness.data.install_options.location = { dir = string.rep("x", 4097) }
			end,
			function(harness)
				harness.data.schema_version = "1.1"
			end,
			function(harness)
				harness.data.links.bin = {}
			end,
		}
		for _, mutate in ipairs(mutations) do
			local harness = verification_harness({ tool = "bin/tool" })
			mutate(harness)
			harness.complete(receipt_fixture(vim.deepcopy(harness.data)))
			assert_result(harness.item, "completed", "found", "failed")
		end
	end)

	it("allows the single closed Windows wrapper gap only after every other proof passes", function()
		local harness = verification_harness({ tool = "bin/tool.exe" }, { is_windows = true })
		assert.is_truthy(harness.data.links.bin["tool.cmd"])
		harness.complete()
		assert_result(harness.item, "completed", "found", "partial")
		assert.equals(
			"muster: Mason package tool: outcome=completed availability=found attestation=partial; attestation_reason=Windows wrapper binding is not fully attestable",
			harness.notifications[2].message
		)
		assert.equals(vim.log.levels.WARN, harness.notifications[2].level)
	end)

	it("fails Windows attestation for shadows, malformed evidence, negative .cmd cases, and combined gaps", function()
		for _, probe in ipairs({
			{ status = "found", source = "system", path = "C:/system/tool.cmd", realpath = "C:/system/tool.cmd" },
			{ status = "found", source = "unknown", path = "/mason/bin/tool.cmd", realpath = "/target/tool" },
			{ status = "found", source = "mason", path = "C:/outside/tool.cmd", realpath = "C:/outside/tool.cmd" },
			{ status = "found", source = "mason", path = "bad\npath", realpath = "/target/tool" },
		}) do
			local harness = verification_harness({ tool = "bin/tool.exe" }, {
				is_windows = true,
				probes = { tool = probe },
			})
			harness.complete()
			assert_result(harness.item, "completed", probe.path == "bad\npath" and "broken" or "found", "failed")
		end

		for _, mutate in ipairs({
			function(harness)
				harness.data.links.bin = {}
				harness.disk_data.links.bin = {}
			end,
			function(harness)
				harness.data.links.bin = { ["Tool.cmd"] = "bin/tool.exe" }
				harness.disk_data.links.bin = { ["Tool.cmd"] = "bin/tool.exe" }
			end,
			function(harness)
				harness.data.links.bin["tool.cmd"] = "bin/other.exe"
				harness.disk_data.links.bin["tool.cmd"] = "bin/other.exe"
			end,
		}) do
			local harness = verification_harness({ tool = "bin/tool.exe" }, { is_windows = true })
			mutate(harness)
			harness.complete(receipt_fixture(vim.deepcopy(harness.data)))
			assert_result(harness.item, "completed", "found", "failed")
		end

		for _, purl_type in ipairs({ "npm", "future-installer" }) do
			local harness = verification_harness({ tool = "bin/tool.exe" }, {
				is_windows = true,
				compiler = mutable_compiler_fixture(purl_type, { value = "stable" }),
			})
			harness.complete()
			assert_result(harness.item, "completed", "found", "failed")
		end
	end)

	it("emits exact callback-failure and unknown lifecycle errors independently of summary settings", function()
		local config_mod = require("muster.config")
		config_mod.reset()
		config_mod.setup({ notify_on_startup = false })
		for _, case in ipairs({
			{
				install = function(callback)
					callback(false, "installer rejected")
					return install_handle()
				end,
				outcome = "failed",
				error = "Mason installer callback reported failure: installer rejected",
			},
			{
				install = function()
					return "invalid handle"
				end,
				outcome = "unknown",
				error = "Mason install dispatch outcome is ambiguous",
			},
		}) do
			local notifications = {}
			local plan, fx = prepare_batch(
				{ tool = { bins = { tool = "bin/tool" }, install = case.install } },
				{ entry("a", "tool", "tool", "tool") },
				{
					notify = function(message, level, opts)
						notifications[#notifications + 1] = { message = message, level = level, opts = opts }
					end,
				}
			)
			handoff.execute(plan, fx.opts)
			assert.equals(case.outcome, plan.items[1].outcome)
			assert.equals(2, #notifications)
			assert.equals(vim.log.levels.INFO, notifications[1].level)
			assert.equals(vim.log.levels.ERROR, notifications[2].level)
			assert.equals(
				("muster: Mason package tool: outcome=%s availability=not_checked attestation=not_checked; error=%s"):format(
					case.outcome,
					case.error
				),
				notifications[2].message
			)
			assert.same({ title = "muster" }, notifications[2].opts)
		end
		config_mod.reset()
	end)

	it("fails compiler feature incompatibility before dispatch", function()
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") },
			{
				compiler = {},
				notify = function() end,
			}
		)
		handoff.execute(plan, fx.opts)
		assert.equals("failed", plan.items[1].outcome)
		assert.equals(0, #fx.installs)
	end)
end)

describe("muster.handoff.mason verified lifecycle contract", function()
	it("reserves dispatch before a reentrant or throwing start notifier", function()
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") }
		)
		local notices = 0
		fx.opts.notify = function(message, level, opts)
			if message == "muster: installing tool via Mason" then
				notices = notices + 1
				assert.equals("dispatched", plan.items[1].outcome)
				assert.equals(vim.log.levels.INFO, level)
				assert.same({ title = "muster" }, opts)
				handoff.execute(plan, fx.opts)
				error("notifier rejected")
			end
		end

		assert.has_no.errors(function()
			handoff.execute(plan, fx.opts)
		end)
		assert.equals(1, #fx.installs)
		assert.equals(1, notices)
	end)

	it("snapshots callback receipts and enters verifying before scheduled verification", function()
		local scheduled
		local callback_receipt = { marker = "before" }
		local plan, fx = prepare_batch({
			tool = {
				bins = { tool = "bin/tool" },
				install = function(callback)
					callback(true, callback_receipt)
				end,
			},
		}, { entry("a", "tool", "tool", "tool") }, {
			schedule = function(callback)
				scheduled = callback
			end,
		})

		fx.opts.verify = false
		handoff.execute(plan, fx.opts)
		assert.equals("verifying", plan.items[1].outcome)
		callback_receipt.marker = "after"
		assert.is_function(scheduled)
		scheduled()
		assert_result(plan.items[1], "completed", "found", "failed")
		assert.equals("Mason callback receipt was malformed", plan.items[1].attestation_reason)
	end)

	it("never enables LSP directly after a successful callback", function()
		local enabled = 0
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("lsp", "tool_ls", "tool", "tool") },
			{
				lsp_enable = function()
					enabled = enabled + 1
				end,
				schedule = function(callback)
					callback()
				end,
			}
		)
		handoff.execute(plan, fx.opts)
		assert.equals(0, enabled)
	end)

	it("fails closed on malformed Windows callback receipt before an injected attestation seam", function()
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") },
			{
				is_windows = true,
				verify = function()
					return { status = "failed", reason = "Windows attestation fixture rejected" }
				end,
				schedule = function(callback)
					callback()
				end,
			}
		)
		handoff.execute(plan, fx.opts)
		assert_result(plan.items[1], "completed", "found", "failed")
		assert.equals("Mason callback receipt was malformed", plan.items[1].attestation_reason)
	end)

	it("maps a verifying deadline to completed not-checked failed before one ERROR notification", function()
		local item = { package = "tool" }
		mason_result.planned(item)
		mason_result.dispatched(item)
		mason_result.verifying(item)
		local notifications = {}
		handoff.expire({ items = { item } }, {
			schedule = function(callback)
				callback()
			end,
			notify = function(message, level)
				notifications[#notifications + 1] = { message = message, level = level }
			end,
		})
		assert_result(item, "completed", "not_checked", "failed")
		assert.equals(1, #notifications)
		assert.equals(vim.log.levels.ERROR, notifications[1].level)
		assert.is_truthy(
			notifications[1].message:find("outcome=completed availability=not_checked attestation=failed", 1, true)
		)
	end)

	it("expires dispatched and verifying items once and permanently gates late work", function()
		local callback, effects
		effects = {}
		local notices = {}
		local plan, fx = prepare_batch({
			waiting = {
				bins = { waiting = "bin/waiting" },
				install = function(cb)
					callback = cb
				end,
			},
			checking = {
				bins = { checking = "bin/checking" },
				install = function(cb)
					cb(true, {})
				end,
			},
		}, { entry("a", "waiting", "waiting", "waiting"), entry("a", "checking", "checking", "checking") }, {
			notify = function(message, level)
				notices[#notices + 1] = { message = message, level = level }
			end,
			schedule = function(cb)
				effects[#effects + 1] = cb
			end,
		})
		handoff.execute(plan, fx.opts)
		assert.same({ "verifying", "dispatched" }, { plan.items[1].outcome, plan.items[2].outcome })

		handoff.expire(plan, fx.opts)
		assert.same({ "completed", "unknown" }, { plan.items[1].outcome, plan.items[2].outcome })
		assert_result(plan.items[1], "completed", "not_checked", "failed")
		for index = 2, #effects do
			effects[index]()
		end
		local notice_count = #notices
		callback(true, {})
		effects[1]()
		handoff.expire(plan, fx.opts)
		assert.same({ "completed", "unknown" }, { plan.items[1].outcome, plan.items[2].outcome })
		assert_result(plan.items[1], "completed", "not_checked", "failed")
		assert.equals(notice_count, #notices)
	end)
end)
