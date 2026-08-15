---Read-only planning and best-effort execution for the optional Mason hand-off.
---The automatic pipeline owns ordering; this module never refreshes a registry.

local M = {}

local mason_result = require("muster.mason_result")
local sanitize = require("muster.text").sanitize

local REASON = {
	identifier = "invalid Mason package identifier",
	mapping = "Mason binary mapping changed or is ambiguous",
	lookup = "Mason package lookup or identity failed",
	snapshot = "Mason package snapshot failed",
	state = "Mason package state query failed",
}

local function valid_identifier(value)
	return type(value) == "string" and #value <= 128 and value:match("^[a-z0-9][a-z0-9._-]*$") ~= nil
end

local function clone(value, seen)
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		return value
	end
	if kind ~= "table" or getmetatable(value) ~= nil then
		error("unrepresentable value")
	end
	seen = seen or {}
	if seen[value] then
		error("cyclic value")
	end
	seen[value] = true
	local copy = {}
	for key, item in pairs(value) do
		local key_kind = type(key)
		if key_kind ~= "boolean" and key_kind ~= "number" and key_kind ~= "string" then
			error("unrepresentable key")
		end
		copy[key] = clone(item, seen)
	end
	seen[value] = nil
	return copy
end

local function equal(left, right, seen)
	if type(left) ~= type(right) then
		return false
	end
	if type(left) ~= "table" then
		return left == right
	end
	seen = seen or {}
	if seen[left] == right then
		return true
	end
	seen[left] = right
	for key, value in pairs(left) do
		if not equal(value, right[key], seen) then
			return false
		end
	end
	for key in pairs(right) do
		if left[key] == nil then
			return false
		end
	end
	return true
end

local function call_or_value(object, key)
	local value = object[key]
	if type(value) == "function" then
		return value(object)
	end
	return value
end

local function registry_snapshot(package)
	return clone({
		id = call_or_value(package.registry, "id"),
		system = call_or_value(package.registry, "system"),
		serialized = call_or_value(package.registry, "serialize"),
		display_name = call_or_value(package.registry, "get_display_name"),
	})
end

local function registry_id(snapshot)
	if type(snapshot.id) == "string" and snapshot.id ~= "" then
		return snapshot.id
	end
	return sanitize(snapshot.display_name, 120)
end

local function get_registry(opts)
	return opts.registry or package.loaded["mason-registry"]
end

local function get_location(opts)
	if opts.location then
		return opts.location
	end
	local location = require("mason-core.installer.InstallLocation")
	return location.global()
end

local function get_root(location, opts)
	if type(opts.get_install_root) == "function" then
		return opts.get_install_root()
	end
	if type(opts.install_root) == "string" then
		return opts.install_root
	end
	if not opts.location then
		local settings = require("mason.settings")
		return settings.current.install_root_dir
	end
	return location:get_dir()
end

local function all_specs(registry)
	local specs = registry.get_all_package_specs()
	if type(specs) ~= "table" then
		error("registry specs are not a table")
	end
	return specs
end

local function binary_owners(specs)
	local owners = {}
	for _, spec in pairs(specs) do
		if type(spec) == "table" and type(spec.name) == "string" and type(spec.bin) == "table" then
			for binary in pairs(spec.bin) do
				if type(binary) == "string" and binary ~= "" then
					local bucket = owners[binary] or {}
					bucket[spec.name] = true
					owners[binary] = bucket
				end
			end
		end
	end
	return owners
end

local function uniquely_owned(owners, binary, package_name)
	if type(binary) ~= "string" or binary == "" then
		return false
	end
	local bucket = owners[binary]
	if type(bucket) ~= "table" or not bucket[package_name] then
		return false
	end
	local count = 0
	for _ in pairs(bucket) do
		count = count + 1
	end
	return count == 1
end

local function canonical_advice(entry)
	local found
	for _, record in ipairs(entry.advice or {}) do
		if record.provider == "mason" and record.action == "install" and type(record.package) == "string" then
			if found then
				return nil
			end
			found = record
		end
	end
	return found
end

local function mark_ineligible(result, record, reason)
	record.eligible = false
	record.reason = reason
	result.notes[#result.notes + 1] = reason
end

local function protected_package(registry, name)
	local package = registry.get_package(name)
	if type(package) ~= "table" or package.name ~= name then
		error("package identity mismatch")
	end
	return package
end

local function package_state(package, location)
	local installed = package:is_installed(location)
	local installing = package:is_installing()
	local installable = package:is_installable({ location = location })
	return installed, installing, installable
end

local function stable_values(set)
	local values = {}
	for value in pairs(set) do
		values[#values + 1] = value
	end
	table.sort(values)
	return values
end

---@param result muster.Result
---@param opts? table
---@return muster.MasonPlan
function M.prepare(result, opts)
	opts = opts or {}
	local plan =
		{ enabled = false, refreshed = true, registry_identities = {}, install_root = "", items = {}, notes = {} }
	local ok_setup, registry, location, root, owners = pcall(function()
		local selected_registry = get_registry(opts)
		if type(selected_registry) ~= "table" then
			error("Mason registry unavailable")
		end
		local selected_location = get_location(opts)
		local selected_root = get_root(selected_location, opts)
		if type(selected_root) ~= "string" or selected_root == "" then
			error("Mason install root unavailable")
		end
		return selected_registry, selected_location, selected_root, binary_owners(all_specs(selected_registry))
	end)
	if not ok_setup then
		plan.notes[#plan.notes + 1] = "Mason hand-off setup failed"
		result.notes[#result.notes + 1] = "Mason hand-off setup failed"
		return plan
	end
	plan.enabled = true
	plan.location = location
	plan.install_root = root

	local grouped = {}
	local registry_ids = {}
	for _, entry in ipairs(result.entries or {}) do
		local probe = entry.probe or {}
		local record = canonical_advice(entry)
		if entry.declared == true and probe.status == "missing" and record then
			local package_name = record.package
			local reason
			if not valid_identifier(package_name) then
				reason = REASON.identifier
			elseif not uniquely_owned(owners, probe.binary, package_name) then
				reason = REASON.mapping
			end
			if reason then
				mark_ineligible(result, record, reason)
			else
				local ok_package, package = pcall(protected_package, registry, package_name)
				if not ok_package then
					mark_ineligible(result, record, REASON.lookup)
				else
					local ok_snapshot, spec_snapshot, identity, install_path = pcall(function()
						local spec = clone(package.spec)
						local registry_data = registry_snapshot(package)
						local path = package:get_install_path(location)
						if type(path) ~= "string" or path == "" then
							error("invalid install path")
						end
						return spec, registry_data, path
					end)
					if not ok_snapshot then
						mark_ineligible(result, record, REASON.snapshot)
					else
						local ok_state, installed, installing, installable = pcall(package_state, package, location)
						if not ok_state then
							mark_ineligible(result, record, REASON.state)
						elseif installed then
							mark_ineligible(result, record, "already installed but binary is missing")
						elseif installing then
							mark_ineligible(result, record, "installation already in progress")
						elseif not installable then
							mark_ineligible(result, record, "Mason reports package not installable on this platform")
						else
							record.eligible = true
							record.reason = nil
							local item = grouped[package_name]
							if not item then
								item = {
									package = package_name,
									binaries = {},
									registry_identity = identity,
									spec_snapshot = spec_snapshot,
									entries = {},
									lsp_names = {},
									install_path = install_path,
								}
								mason_result.planned(item)
								grouped[package_name] = item
								registry_ids[registry_id(identity)] = true
							end
							item.entries[#item.entries + 1] = entry
							item.binaries[probe.binary] = true
							if entry.adapter == "lsp" then
								item.lsp_names[entry.name] = true
							end
						end
					end
				end
			end
		end
	end
	for _, item in pairs(grouped) do
		item.binaries = stable_values(item.binaries)
		item.lsp_names = stable_values(item.lsp_names)
		plan.items[#plan.items + 1] = item
	end
	table.sort(plan.items, function(left, right)
		return left.package < right.package
	end)
	plan.registry_identities = stable_values(registry_ids)
	return plan
end

local function defaults(opts)
	local package_module = opts.package_module or require("mason-core.package")
	local compiler = opts.compiler or require("mason-core.installer.compiler")
	local purl = opts.purl or require("mason-core.purl")
	local receipt_module = opts.receipt_module or require("mason-core.receipt")
	local mason_source = require("muster.mason_source")
	local source_fingerprint = opts._source_fingerprint
		or function()
			return mason_source.fingerprint_runtime({
				compiler = compiler,
				package_module = package_module,
				purl = purl,
				receipt = receipt_module.InstallReceipt,
			})
		end
	return {
		registry = get_registry(opts),
		package_module = package_module,
		notify = opts.notify or vim.notify,
		schedule = opts.schedule or vim.schedule,
		defer = opts.defer or vim.defer_fn,
		probe = opts.probe or require("muster.probe").resolve,
		realpath = opts.realpath or vim.uv.fs_realpath,
		is_windows = opts.is_windows == true or (opts.is_windows == nil and vim.fn.has("win32") == 1),
		compiler = compiler,
		purl = purl,
		receipt_module = receipt_module,
		source_fingerprint = source_fingerprint,
		expected_fingerprint = mason_source.EXPECTED_FINGERPRINT,
		verify = opts.verify,
	}
end

local function notification_runtime(opts)
	return {
		notify = opts.notify or vim.notify,
		schedule = opts.schedule or vim.schedule,
		defer = opts.defer or vim.defer_fn,
	}
end

local function bridge(runtime, effect)
	local ran = false
	local function guarded_effect()
		if ran then
			return
		end
		ran = true
		effect()
	end
	local ok = pcall(runtime.schedule, guarded_effect)
	if ok then
		return true
	end
	return pcall(runtime.defer, guarded_effect, 0)
end

-- All terminal labels fit within 400 bytes even when every reason is present.
local NOTIFICATION_PACKAGE_LIMIT = 64
local NOTIFICATION_REASON_LIMIT = { error = 80, availability_reason = 56, attestation_reason = 56 }

local function notify(runtime, message, level)
	pcall(runtime.notify, message, level, { title = "muster" })
end

local function notify_start(runtime, item)
	notify(runtime, ("muster: installing %s via Mason"):format(sanitize(item.package, 120)), vim.log.levels.INFO)
end

local function terminal_message(item, result)
	local message = ("muster: Mason package %s: outcome=%s availability=%s attestation=%s"):format(
		sanitize(item.package, NOTIFICATION_PACKAGE_LIMIT),
		result.outcome,
		result.availability,
		result.attestation
	)
	for _, field in ipairs({ "error", "availability_reason", "attestation_reason" }) do
		if result[field] then
			message = message .. ("; %s=%s"):format(field, sanitize(result[field], NOTIFICATION_REASON_LIMIT[field]))
		end
	end
	return message
end

local function terminal_notify(runtime, item)
	local result = mason_result.normalize(item)
	local level = vim.log.levels[mason_result.severity(result):upper()]
	return bridge(runtime, function()
		notify(runtime, terminal_message(item, result), level)
	end)
end

local function fail_item(runtime, item, detail)
	mason_result.failed(item, detail)
	terminal_notify(runtime, item)
end

local function revalidate(plan, item, registry, opts, installed_expected)
	if not valid_identifier(item.package) then
		error(REASON.identifier)
	end
	local owners = binary_owners(all_specs(registry))
	for _, binary in ipairs(item.binaries) do
		if not uniquely_owned(owners, binary, item.package) then
			error(REASON.mapping)
		end
	end
	local package = protected_package(registry, item.package)
	local identity = registry_snapshot(package)
	local spec = clone(package.spec)
	if not equal(identity, item.registry_identity) or not equal(spec, item.spec_snapshot) then
		error("Mason registry or package specification changed")
	end
	local root = get_root(plan.location, opts)
	if root ~= plan.install_root then
		error("Mason install root changed")
	end
	local path = package:get_install_path(plan.location)
	if path ~= item.install_path then
		error("Mason package install path changed")
	end
	local installed, installing, installable = package_state(package, plan.location)
	if installed_expected then
		if not installed then
			error("Mason package is not installed after success callback")
		elseif installing then
			error("Mason package handle remains open after success callback")
		end
	else
		if installed then
			error("package became installed while binary is missing")
		elseif installing then
			error("package installation is already in progress")
		elseif not installable then
			error("package is no longer installable")
		end
	end
	return package
end

local function valid_handle(handle)
	local kind = type(handle)
	if kind ~= "table" and kind ~= "userdata" then
		return false
	end
	local ok_method, is_closed = pcall(function()
		return handle.is_closed
	end)
	return ok_method and type(is_closed) == "function"
end

local function reserve_canonical(canonical)
	local existing = canonical.install_handle
	if existing ~= nil then
		if not valid_handle(existing) then
			error("Mason canonical package has an invalid install reservation")
		end
		local ok_closed, closed = pcall(existing.is_closed, existing)
		if not ok_closed or closed ~= true then
			error("Mason canonical package already has an active install reservation")
		end
	end
	local sentinel = {
		is_closed = function()
			return false
		end,
	}
	canonical.install_handle = sentinel
	if canonical.install_handle ~= sentinel then
		error("Mason canonical package rejected install reservation")
	end
	return sentinel
end

local function swap_install_handle(canonical, sentinel, handle)
	if not valid_handle(handle) then
		error("Mason install returned an invalid handle")
	end
	if canonical.install_handle ~= sentinel then
		error("Mason canonical install reservation changed during dispatch")
	end
	canonical.install_handle = handle
	if canonical.install_handle ~= handle then
		error("Mason canonical package rejected install reservation")
	end
	return handle
end

local function detached_package(item, live_package, package_module)
	if type(package_module) ~= "table" or type(package_module.new) ~= "function" then
		error("Mason detached package constructor unavailable")
	end
	local detached = package_module:new(clone(item.spec_snapshot), live_package.registry)
	if type(detached) ~= "table" or detached == live_package or detached.name ~= item.package then
		error("detached Mason package identity mismatch")
	end
	local spec = clone(detached.spec)
	local identity = registry_snapshot(detached)
	if not equal(spec, item.spec_snapshot) or not equal(identity, item.registry_identity) then
		error("detached Mason package snapshot mismatch")
	end
	return detached
end

local function plain(value, seen, omit_install)
	local kind = type(value)
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		return value
	end
	if kind ~= "table" then
		error("unrepresentable value")
	end
	seen = seen or {}
	if seen[value] then
		error("cyclic value")
	end
	seen[value] = true
	local copy = {}
	for key, item in pairs(value) do
		local key_kind = type(key)
		if key_kind ~= "boolean" and key_kind ~= "number" and key_kind ~= "string" then
			error("unrepresentable key")
		end
		if not (omit_install and key == "install") then
			copy[key] = plain(item, seen, false)
		end
	end
	seen[value] = nil
	return copy
end

local function location_dir(location)
	if type(location) ~= "table" and type(location) ~= "userdata" then
		error("Mason install location unavailable")
	end
	local ok_getter, get_dir = pcall(function()
		return location.get_dir
	end)
	local dir
	if ok_getter and type(get_dir) == "function" then
		dir = get_dir(location)
	elseif type(location) == "table" and getmetatable(location) == nil then
		for key in pairs(location) do
			if key ~= "dir" then
				error("Mason serialized install location shape unavailable")
			end
		end
		dir = location.dir
	else
		error("Mason install location getter unavailable")
	end
	if type(dir) ~= "string" or dir == "" or #dir > 4096 or sanitize(dir, 4096) ~= dir then
		error("Mason install location directory unavailable")
	end
	return dir
end

local function normalize_install_options(options)
	if type(options) ~= "table" then
		error("Mason install options unavailable")
	end
	return plain({
		debug = options.debug,
		force = options.force,
		strict = options.strict,
		target = options.target,
		version = options.version,
		location_dir = location_dir(options.location),
	})
end

local function result_value(result)
	if type(result) ~= "table" or type(result.is_success) ~= "function" or type(result.get_or_nil) ~= "function" then
		error("Mason compiler Result contract unavailable")
	end
	if result:is_success() ~= true then
		error("Mason compiler rejected package specification")
	end
	local value = result:get_or_nil()
	if type(value) ~= "table" then
		error("Mason compiler returned invalid parsed source")
	end
	return value
end

local FULL_COMPILERS = {
	cargo = true,
	composer = true,
	gem = true,
	golang = true,
	luarocks = true,
	nuget = true,
	opam = true,
}

local PARTIAL_COMPILERS = {
	npm = true,
	pypi = true,
	github = true,
	mason = true,
	generic = true,
	openvsx = true,
}

local function compiler_state(parsed, runtime)
	if type(parsed.purl) ~= "table" or type(parsed.purl.type) ~= "string" or type(parsed.source) ~= "table" then
		error("Mason compiler parsed source unavailable")
	end
	local source_ok, source = pcall(plain, parsed.source)
	local fingerprint_ok, fingerprint = pcall(runtime.source_fingerprint)
	local fingerprint_value = fingerprint_ok and type(fingerprint) == "string" and fingerprint or "unavailable"
	local identity_matches = fingerprint_value == runtime.expected_fingerprint
	return {
		fingerprint = fingerprint_value,
		identity_matches = identity_matches,
		purl_type = parsed.purl.type,
		source_representable = source_ok,
		source = source_ok and source or {},
	}
end

local function capture_contract(plan, item, runtime)
	if type(runtime.package_module.DEFAULT_INSTALL_OPTS) ~= "table" then
		error("Mason install defaults unavailable")
	end
	if type(runtime.compiler) ~= "table" or type(runtime.compiler.parse) ~= "function" then
		error("Mason compiler parse unavailable")
	end
	if type(runtime.purl) ~= "table" or type(runtime.purl.compile) ~= "function" then
		error("Mason Purl compiler unavailable")
	end
	local effective = vim.tbl_extend("force", runtime.package_module.DEFAULT_INSTALL_OPTS, { location = plan.location })
	local parsed = result_value(runtime.compiler.parse(item.spec_snapshot, effective))
	if type(parsed.purl) ~= "table" or type(parsed.raw_source) ~= "table" then
		error("Mason compiler parsed source unavailable")
	end
	local state = compiler_state(parsed, runtime)
	local source = {
		type = item.spec_snapshot.schema,
		id = runtime.purl.compile(parsed.purl),
		raw = plain(parsed.raw_source, nil, parsed.purl.type == "mason"),
	}
	if type(source.type) ~= "string" or type(source.id) ~= "string" then
		error("Mason compiler source contract unavailable")
	end
	return effective, plain(source), normalize_install_options(effective), state
end

local function receipt_value(receipt, method)
	if type(receipt) ~= "table" or type(receipt[method]) ~= "function" then
		error("Mason receipt getter unavailable")
	end
	return receipt[method](receipt)
end

local function normalize_receipt(receipt)
	return plain({
		name = receipt_value(receipt, "get_name"),
		schema_version = receipt_value(receipt, "get_schema_version"),
		source = receipt_value(receipt, "get_source"),
		registry = receipt_value(receipt, "get_registry"),
		install_options = normalize_install_options(receipt_value(receipt, "get_install_options")),
		links = receipt_value(receipt, "get_links"),
	})
end

local RECEIPT_GETTERS = {
	"get_name",
	"get_schema_version",
	"get_source",
	"get_registry",
	"get_install_options",
	"get_links",
}

local function preflight_receipt(runtime, package, location)
	local receipt = runtime.receipt_module and runtime.receipt_module.InstallReceipt
	if type(receipt) ~= "table" or type(receipt.from_json) ~= "function" then
		error("Mason receipt class unavailable")
	end
	for _, method in ipairs(RECEIPT_GETTERS) do
		if type(receipt[method]) ~= "function" then
			error("Mason receipt getter unavailable")
		end
	end
	if type(package.get_receipt) ~= "function" then
		error("Mason receipt reader unavailable")
	end
	local optional = package:get_receipt(location)
	if type(optional) ~= "table" or type(optional.or_else) ~= "function" then
		error("Mason receipt Optional contract unavailable")
	end
	local existing = optional:or_else(nil)
	if existing ~= nil then
		normalize_receipt(existing)
	end
end

local function disk_receipt(package, location)
	if type(package.get_receipt) ~= "function" then
		error("Mason receipt reader unavailable")
	end
	local optional = package:get_receipt(location)
	if type(optional) ~= "table" or type(optional.or_else) ~= "function" then
		error("Mason receipt Optional contract unavailable")
	end
	local receipt = optional:or_else(nil)
	if receipt == nil then
		error("Mason disk receipt unavailable")
	end
	return receipt
end

local function normalize_path(path)
	if type(path) ~= "string" or path == "" or path:find("[%z\1-\31\127]") then
		error("invalid path")
	end
	local ok, normalized = pcall(vim.fs.normalize, path)
	if not ok or type(normalized) ~= "string" or normalized == "" then
		error("invalid path")
	end
	return normalized:gsub("/+$", "")
end

local function under(path, root)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function safe_relative(path)
	if type(path) ~= "string" or path == "" or path:find("[%z\1-\31\127]") then
		return false
	end
	if path:match("^[/\\]") or path:match("^[A-Za-z]:") then
		return false
	end
	for segment in path:gmatch("[^/\\]+") do
		if segment == ".." then
			return false
		end
	end
	return true
end

local function canonical(runtime, path)
	local value = runtime.realpath(path)
	if type(value) ~= "string" or value == "" then
		error("Mason path canonicalization failed")
	end
	return normalize_path(value)
end

local function handle_closed(handle)
	local ok, closed = pcall(handle.is_closed, handle)
	if not ok or closed ~= true then
		error("Mason install handle remains open after success callback")
	end
end

local function compiler_policy(item, runtime)
	local captured = item._compiler_state
	if
		type(captured) ~= "table"
		or captured.identity_matches ~= true
		or captured.source_representable ~= true
		or type(captured.purl_type) ~= "string"
	then
		return nil
	end
	local parsed = result_value(runtime.compiler.parse(item.spec_snapshot, item._effective_install_options))
	local current = compiler_state(parsed, runtime)
	if current.identity_matches ~= true or current.source_representable ~= true or not equal(current, captured) then
		return nil
	end
	if FULL_COMPILERS[current.purl_type] then
		return "full"
	end
	if PARTIAL_COMPILERS[current.purl_type] then
		return "partial"
	end
	return "unsupported"
end

local PROBE_STATUS = {
	found = true,
	missing = true,
	unverifiable = true,
	unknown = true,
	broken = true,
}

local PROBE_SOURCE = {
	mason = true,
	nix = true,
	mise = true,
	brew = true,
	system = true,
	unknown = true,
}

local AVAILABILITY_PRIORITY = { "broken", "missing", "unknown", "unverifiable", "found" }

local function availability_reason(status, names)
	local prefix = ("%s binaries: "):format(status)
	local limited = {}
	for index = 1, math.min(#names, 8) do
		local candidate = vim.list_extend(vim.deepcopy(limited), { sanitize(names[index], 40) })
		local omitted = #names - #candidate
		local suffix = omitted > 0 and (" … (+%d more)"):format(omitted) or ""
		if #(prefix .. table.concat(candidate, ", ") .. suffix) > 200 then
			break
		end
		limited = candidate
	end
	local omitted = #names - #limited
	local suffix = omitted > 0 and (" … (+%d more)"):format(omitted) or ""
	return prefix .. table.concat(limited, ", ") .. suffix
end

local function compute_availability(item, runtime)
	local names = {}
	local seen = {}
	for _, binary in ipairs(item.binaries or {}) do
		if type(binary) == "string" and binary ~= "" and not seen[binary] then
			seen[binary] = true
			names[#names + 1] = binary
		end
	end
	table.sort(names)
	local probes = {}
	local by_status = {}
	for _, binary in ipairs(names) do
		local ok, raw = pcall(runtime.probe, binary)
		local probe
		if not ok or type(raw) ~= "table" or not PROBE_STATUS[raw.status] then
			probe = { status = "broken", reason = "Mason availability probe failed" }
		elseif raw.status == "found" then
			local path_ok = pcall(normalize_path, raw.path)
			local realpath_ok = raw.realpath == nil or type(raw.realpath) == "string"
			if not PROBE_SOURCE[raw.source] or not path_ok or not realpath_ok then
				probe = { status = "broken", reason = "Mason availability probe returned malformed evidence" }
			else
				probe = { status = "found", source = raw.source, path = raw.path, realpath = raw.realpath }
			end
		else
			probe = { status = raw.status, reason = sanitize(raw.reason or (raw.status .. " binary"), 200) }
		end
		probes[binary] = probe
		by_status[probe.status] = by_status[probe.status] or {}
		by_status[probe.status][#by_status[probe.status] + 1] = binary
	end
	if #names == 0 then
		return {
			status = "not_checked",
			reason = "no Mason binary availability probes ran",
			probes = probes,
		}
	end
	for _, status in ipairs(AVAILABILITY_PRIORITY) do
		if by_status[status] then
			local reason
			if status ~= "found" then
				reason = availability_reason(status, by_status[status])
			end
			return { status = status, reason = reason, probes = probes }
		end
	end
	return { status = "broken", reason = "Mason availability aggregation failed", probes = probes }
end

local function verify_receipt(plan, item, runtime, handle, callback_receipt, availability)
	local live_package = revalidate(plan, item, runtime.registry, runtime.opts, true)
	handle_closed(handle)
	local disk = normalize_receipt(disk_receipt(live_package, plan.location))
	if not equal(callback_receipt, disk) then
		error("Mason callback and disk receipts differ")
	end
	if callback_receipt.schema_version ~= "2.0" or callback_receipt.name ~= item.package then
		error("Mason receipt schema or package identity mismatch")
	end
	if not equal(callback_receipt.registry, item.registry_identity.serialized) then
		error("Mason receipt registry provenance mismatch")
	end
	if not equal(callback_receipt.source, item._expected_source) then
		error("Mason receipt source provenance mismatch")
	end
	if not equal(callback_receipt.install_options, item._install_options) then
		error("Mason receipt install options mismatch")
	end
	if type(callback_receipt.links) ~= "table" or type(callback_receipt.links.bin) ~= "table" then
		error("Mason receipt bin links unavailable")
	end

	local root = canonical(runtime, plan.install_root)
	local package_path = canonical(runtime, item.install_path)
	if package_path == root or not under(package_path, root) then
		error("Mason package escaped install root")
	end
	local targets = {}
	for _, binary in ipairs(item.binaries) do
		local linked_name = runtime.is_windows and (binary .. ".cmd") or binary
		local relative = callback_receipt.links.bin[linked_name]
		if not safe_relative(relative) then
			error("Mason receipt contains unsafe bin link")
		end
		if runtime.is_windows and relative ~= item.spec_snapshot.bin[binary] then
			error("Mason Windows receipt target mismatch")
		end
		local target = canonical(runtime, normalize_path(item.install_path .. "/" .. relative))
		if target == package_path or not under(target, package_path) then
			error("Mason receipt target escaped package directory")
		end
		targets[binary] = target
	end

	local policy = compiler_policy(item, runtime)
	if not policy or policy == "unsupported" then
		error("Mason compiler policy or provenance failed")
	end
	if availability.status ~= "found" then
		error("Mason binary availability is degraded")
	end
	for _, binary in ipairs(item.binaries) do
		local probe = availability.probes[binary]
		if type(probe) ~= "table" or probe.status ~= "found" or probe.source ~= "mason" then
			error("Mason binary source verification failed")
		end
		if runtime.is_windows then
			local bin = normalize_path(plan.install_root .. "/bin")
			local path = normalize_path(probe.path)
			if path == bin or not under(path, bin) then
				error("Mason Windows binary path escaped Mason bin")
			end
		else
			local expected_link = normalize_path(plan.install_root .. "/bin/" .. binary)
			if
				type(probe.realpath) ~= "string"
				or normalize_path(probe.path) ~= expected_link
				or canonical(runtime, probe.realpath) ~= targets[binary]
			then
				error("Mason binary link or target verification failed")
			end
		end
	end

	if runtime.is_windows then
		if policy ~= "full" then
			error("Mason Windows attestation has multiple gaps")
		end
		return { status = "partial", reason = "Windows wrapper binding is not fully attestable" }
	end
	if policy == "partial" then
		return { status = "partial", reason = "compiler policy provides partial attestation" }
	end
	return { status = "full" }
end

local function compute_attestation(plan, item, runtime, handle, callback_receipt, availability)
	if callback_receipt == nil then
		return { status = "failed", reason = "Mason callback receipt was malformed" }
	end
	if runtime.verify then
		local first, second = runtime.verify(plan, item, runtime, handle, callback_receipt, availability)
		if type(first) == "table" and first.status then
			return first
		end
		if first ~= nil and availability.status == "found" then
			return { status = "full" }
		end
		return { status = "failed", reason = sanitize(second or "Mason attestation test seam failed", 200) }
	end
	return verify_receipt(plan, item, runtime, handle, callback_receipt, availability)
end

local function blocked(item)
	return item.deadline_reached == true or item._effects_disabled == true
end

---@param plan muster.MasonPlan
---@param opts? table
function M.execute(plan, opts)
	opts = opts or {}
	if type(plan) ~= "table" or not plan.enabled or type(plan.items) ~= "table" or #plan.items == 0 then
		return
	end
	local ok_runtime, runtime = pcall(defaults, opts)
	if not ok_runtime or type(runtime.registry) ~= "table" then
		local fallback = notification_runtime(opts)
		for _, item in ipairs(plan.items) do
			if item.outcome == "planned" then
				fail_item(fallback, item, "Mason install contract validation failed")
			end
		end
		return
	end
	runtime.opts = opts
	for _, item in ipairs(plan.items) do
		if item.outcome == "planned" then
			item.deadline_reached = false
			item._effects_disabled = false
			local ok_package, live_or_error, detached, install_opts, sentinel = pcall(function()
				local live_package = revalidate(plan, item, runtime.registry, opts, false)
				preflight_receipt(runtime, live_package, plan.location)
				local package = detached_package(item, live_package, runtime.package_module)
				local effective, expected_source, normalized_opts, captured_compiler =
					capture_contract(plan, item, runtime)
				item._expected_source = expected_source
				item._install_options = normalized_opts
				item._effective_install_options = effective
				item._compiler_state = captured_compiler
				local reservation = reserve_canonical(live_package)
				return live_package, package, effective, reservation
			end)
			if not ok_package then
				fail_item(runtime, item, "Mason install contract validation failed")
			else
				local canonical_package = live_or_error
				local package = detached
				local callback_seen = false
				local invoking = true
				local callback_receipt
				local callback_error
				local callback_success
				local handle

				local function verification_effect()
					if blocked(item) or item.outcome ~= "verifying" then
						return
					end
					local ok_availability, availability = pcall(compute_availability, item, runtime)
					if not ok_availability then
						availability = {
							status = "broken",
							reason = "Mason availability computation failed",
							probes = {},
						}
					end
					local ok_attestation, attestation =
						pcall(compute_attestation, plan, item, runtime, handle, callback_receipt, availability)
					if not ok_attestation or type(attestation) ~= "table" then
						attestation = { status = "failed", reason = "Mason attestation computation failed" }
					end
					if availability.status ~= "found" and attestation.status ~= "failed" then
						attestation = { status = "failed", reason = "binary availability does not support attestation" }
					end
					if blocked(item) or item.outcome ~= "verifying" then
						return
					end
					mason_result.completed(item, availability, attestation)
					terminal_notify(runtime, item)
				end

				local function settle_callback()
					if blocked(item) then
						return
					end
					if callback_success then
						mason_result.verifying(item)
						local accepted = bridge(runtime, verification_effect)
						if not accepted and not blocked(item) and item.outcome == "verifying" then
							mason_result.completed(
								item,
								{ status = "not_checked", reason = "safe-context availability computation did not run" },
								{ status = "failed", reason = "post-install safe-context bridge failed" }
							)
							terminal_notify(runtime, item)
						end
					else
						mason_result.failed(
							item,
							("Mason installer callback reported failure: %s"):format(callback_error)
						)
						terminal_notify(runtime, item)
					end
				end

				local function callback(ok, value)
					if callback_seen or blocked(item) then
						return
					end
					callback_seen = true
					callback_success = ok == true
					if callback_success then
						local ok_receipt, normalized = pcall(normalize_receipt, value)
						callback_receipt = ok_receipt and normalized or nil
					else
						callback_error = sanitize(value, 160)
					end
					if not invoking then
						settle_callback()
					end
				end

				mason_result.dispatched(item)
				notify_start(runtime, item)
				local ok_install, handle_or_error = pcall(package.install, package, install_opts, callback)
				if ok_install then
					ok_install, handle_or_error =
						pcall(swap_install_handle, canonical_package, sentinel, handle_or_error)
				end
				if ok_install then
					handle = handle_or_error
				end
				invoking = false
				if not ok_install then
					item._effects_disabled = true
					mason_result.unknown(item, "Mason install dispatch outcome is ambiguous")
					terminal_notify(runtime, item)
				elseif callback_seen then
					settle_callback()
				end
			end
		end
	end
end

---@param plan muster.MasonPlan
---@param opts? table
function M.expire(plan, opts)
	opts = opts or {}
	if type(plan) ~= "table" or type(plan.items) ~= "table" then
		return
	end
	local runtime = notification_runtime(opts)
	for _, item in ipairs(plan.items) do
		if item.outcome == "dispatched" then
			item.deadline_reached = true
			mason_result.unknown(item, "Mason install did not complete before the observation deadline")
			terminal_notify(runtime, item)
		elseif item.outcome == "verifying" then
			item.deadline_reached = true
			mason_result.completed(
				item,
				{ status = "not_checked", reason = "availability was not observed before the deadline" },
				{ status = "failed", reason = "post-install verification did not complete before the deadline" }
			)
			terminal_notify(runtime, item)
		end
	end
end

---@param item muster.MasonInstallItem
---@param deadline_reached boolean
---@return string
function M.observed_outcome(item, deadline_reached)
	if deadline_reached and item.outcome == "dispatched" then
		return "unknown at observation deadline"
	end
	return item.outcome
end

return M
