---@module 'luassert'
local assert = require("luassert")

local handoff = require("muster.handoff.mason")

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

local function fixture(definitions)
	local location = { root = "/mason" }
	function location:get_dir()
		return self.root
	end

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
			spec = definition.spec or { name = name, bin = definition.bins, source = { id = "recipe:" .. name } },
			registry = definition.registry,
		}
		function package:get_install_path(bound_location)
			if definition.path then
				return definition.path(bound_location)
			end
			return bound_location.root .. "/packages/" .. name
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

	local package_module = {}
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
		opts = { registry = registry, location = location, package_module = package_module },
	}
end

local function precedence_fixture()
	local location = { root = "/mason" }
	function location:get_dir()
		return self.root
	end

	local sources = {
		primary = {
			bad = {
				registry = registry_identity("registry-primary", "source:primary"),
				spec = {
					name = "bad",
					bin = { bad = "bin/bad" },
					source = { id = "recipe:bad", install = { command = "primary", args = { "one" } } },
				},
			},
			good = {
				registry = registry_identity("registry-primary", "source:primary"),
				spec = {
					name = "good",
					bin = { good = "bin/good" },
					source = { id = "recipe:good", install = { command = "primary", args = { "safe" } } },
				},
			},
		},
		secondary = {
			bad = {
				registry = registry_identity("registry-secondary", "source:secondary\nchanged"),
				spec = {
					name = "bad",
					bin = { bad = "bin/bad" },
					source = { id = "recipe:bad", install = { command = "secondary", args = { "two" } } },
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
			return bound_location.root .. "/packages/" .. name
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

	local package_module = {}
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
		opts = { registry = registry, location = location, package_module = package_module },
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

describe("muster.handoff.mason.execute", function()
	it("dispatches a detached prepared-spec package that cannot observe later live recipe drift", function()
		local plan, fx = prepare_batch(
			{ tool = { bins = { tool = "bin/tool" } } },
			{ entry("a", "tool", "tool", "tool") }
		)
		local constructed, held_callback
		fx.opts.package_module = {
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
		assert.equals("recipe:tool", constructed.spec.source.id)

		fx.packages.tool.spec.source.id = "recipe:B"
		assert.equals("recipe:tool", constructed.spec.source.id)
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
		assert.equals(1, #messages)
		assert.is_truthy(messages[1]:find("bad", 1, true))
		assert.is_truthy(messages[1]:find(":MasonLog", 1, true))
		assert.is_falsy(messages[1]:find("[%z\1-\31\127]"))
		assert.is_true(#messages[1] <= 400)
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
			assert.equals(1, #notifications, name)
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
			assert.same({ "unknown", "completed" }, { plan.items[1].outcome, plan.items[2].outcome }, case_name)
			assert.is_nil(rawget(fx.packages.bad, "install_handle"), case_name)
			assert.equals(2, #fx.installs, case_name)
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

	it("settles duplicate callbacks once and retries sorted captured LSP names", function()
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
		assert.same({ "a_ls", "z_ls" }, enabled)
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
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1]:find("outcome unknown; inspect :MasonLog", 1, true))
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
		assert.equals(1, effects)
		late_callback(true, {})
		assert.equals("unknown", plan.items[1].outcome)
		assert.equals(1, effects)
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
		assert.equals(1, effects)
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
		assert.equals("completed", plan.items[1].outcome)
		assert.same({}, effects)
		deferred[1]()
		assert.same({ "tool_ls" }, effects)
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
			assert.equals(callback_result[1] and "completed" or "failed", plan.items[1].outcome)
			assert.equals(0, effects)
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
		assert.same({ "b_ls" }, enabled)
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

		local malicious_package = "tool\n\27\0" .. string.rep("x", 400)
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
					callback(false, "bad\n\27\0" .. string.rep("y", 400))
				end,
			},
		}, { entry("a", "tool", "tool", "tool") }, { notify = notify, schedule = schedule })
		handoff.execute(error_plan, error_fx.opts)

		assert.equals(2, #messages)
		for _, message in ipairs(messages) do
			assert.is_falsy(message:find("\n", 1, true))
			assert.is_falsy(message:find("\27", 1, true))
			assert.is_falsy(message:find("\0", 1, true))
			assert.is_true(#message <= 400)
		end
	end)
end)
