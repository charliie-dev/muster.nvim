---Read-only planning and best-effort execution for the optional Mason hand-off.
---The automatic pipeline owns ordering; this module never refreshes a registry.

local M = {}

local REASON = {
	identifier = "invalid Mason package identifier",
	mapping = "Mason binary mapping changed or is ambiguous",
	lookup = "Mason package lookup or identity failed",
	snapshot = "Mason package snapshot failed",
	state = "Mason package state query failed",
}

local function sanitize(value, limit)
	local ok, text = pcall(tostring, value or "unknown")
	if not ok then
		text = "unknown"
	end
	text = text:gsub("[%z\1-\31\127]", "?")
	limit = limit or 200
	if #text > limit then
		text = text:sub(1, math.max(0, limit - 3)) .. "..."
	end
	return text
end

local function valid_identifier(value)
	return type(value) == "string"
		and value ~= ""
		and #value <= 255
		and value ~= "."
		and value ~= ".."
		and not value:find("[%z\1-\31\127/\\]")
		and not value:match("^[/\\]")
		and not value:match("^[A-Za-z]:")
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
									outcome = "planned",
								}
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
	return {
		registry = get_registry(opts),
		package_module = opts.package_module or require("mason-core.package"),
		notify = opts.notify or vim.notify,
		lsp_enable = opts.lsp_enable or vim.lsp.enable,
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

local function notify(runtime, message)
	pcall(runtime.notify, sanitize(message, 400), vim.log.levels.ERROR, { title = "muster" })
end

local function failure_effect(runtime, item, detail)
	return function()
		notify(
			runtime,
			("muster: Mason install %s failed: %s; inspect :MasonLog"):format(
				sanitize(item.package, 120),
				sanitize(detail, 200)
			)
		)
	end
end

local function unknown_effect(runtime, item)
	return function()
		notify(
			runtime,
			("muster: Mason install %s outcome unknown; inspect :MasonLog"):format(sanitize(item.package, 120))
		)
	end
end

local function success_effect(runtime, item)
	return function()
		for _, name in ipairs(item.lsp_names) do
			pcall(runtime.lsp_enable, name)
		end
	end
end

local function fail_item(runtime, item, detail)
	item.outcome = "failed"
	item.error = sanitize(detail, 200)
	bridge(runtime, failure_effect(runtime, item, detail))
end

local function revalidate(plan, item, registry, opts)
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
	if installed then
		error("package became installed while binary is missing")
	elseif installing then
		error("package installation is already in progress")
	elseif not installable then
		error("package is no longer installable")
	end
	return package
end

local function reserve_install_handle(canonical, handle)
	local kind = type(handle)
	if kind ~= "table" and kind ~= "userdata" then
		error("Mason install returned an invalid handle")
	end
	local ok_method, is_closed = pcall(function()
		return handle.is_closed
	end)
	if not ok_method or type(is_closed) ~= "function" then
		error("Mason install returned an invalid handle")
	end
	canonical.install_handle = handle
	if canonical.install_handle ~= handle then
		error("Mason canonical package rejected install reservation")
	end
end

local function detached_package(item, live_package, package_module)
	if type(package_module) ~= "table" or type(package_module.new) ~= "function" then
		error("Mason detached package constructor unavailable")
	end
	-- The constructor receives a second copy so neither it nor later live-registry
	-- mutation can alter the prepared decision snapshot retained by the ledger.
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

---@param plan muster.MasonPlan
---@param opts? table
function M.execute(plan, opts)
	opts = opts or {}
	if type(plan) ~= "table" or not plan.enabled or type(plan.items) ~= "table" or #plan.items == 0 then
		return
	end
	local ok_runtime, runtime = pcall(defaults, opts)
	if not ok_runtime or type(runtime.registry) ~= "table" then
		return
	end
	for _, item in ipairs(plan.items) do
		if item.outcome == "planned" then
			local ok_package, live_or_error, detached = pcall(function()
				local live_package = revalidate(plan, item, runtime.registry, opts)
				return live_package, detached_package(item, live_package, runtime.package_module)
			end)
			if not ok_package then
				fail_item(runtime, item, live_or_error)
			else
				local canonical = live_or_error
				local package = detached
				local callback_seen = false
				local callback_disabled = false
				local invoking = true
				local buffered_effect
				local function callback(ok, value)
					if callback_seen or callback_disabled then
						return
					end
					callback_seen = true
					if ok then
						item.outcome = "completed"
						item.error = nil
						buffered_effect = success_effect(runtime, item)
					else
						item.outcome = "failed"
						item.error = sanitize(value, 200)
						buffered_effect = failure_effect(runtime, item, value)
					end
					if not invoking then
						bridge(runtime, buffered_effect)
					end
				end
				item.outcome = "dispatched"
				local ok_install, handle_or_error =
					pcall(package.install, package, { location = plan.location }, callback)
				if ok_install then
					ok_install, handle_or_error = pcall(reserve_install_handle, canonical, handle_or_error)
				end
				invoking = false
				if not ok_install then
					callback_disabled = true
					item.outcome = "unknown"
					item.error = sanitize(handle_or_error, 200)
					buffered_effect = nil
					bridge(runtime, unknown_effect(runtime, item))
				elseif buffered_effect then
					bridge(runtime, buffered_effect)
				end
			end
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
