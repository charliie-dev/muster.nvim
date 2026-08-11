---Asynchronous, read-only supplier advice enrichment.
---
---The input Result remains untouched until every provider has settled. Completion
---is delivered exactly once with stable provider ordering. The public `check()`
---API owns the asynchronous scheduling boundary.

local M = {}

local PROVIDER_ORDER = { "mason", "nix", "mise" }
local PROVIDER_ACTION = { mason = "install", nix = "declare", mise = "declare" }

---@param value any
---@return boolean
local function optional_string(value)
	return value == nil or (type(value) == "string" and value ~= "")
end

---@param provider string
---@param value any
---@return table<string, muster.Advice>
---@return string|nil
local function validate_advice(provider, value)
	if type(value) ~= "table" then
		return {}, "advice provider returned invalid data"
	end
	local valid = {}
	local invalid = {}
	for binary, record in pairs(value) do
		local reason
		if type(binary) ~= "string" or binary == "" then
			reason = "invalid binary key " .. vim.inspect(binary)
		elseif type(record) ~= "table" then
			reason = ("%s record is a %s"):format(binary, type(record))
		elseif record.provider ~= provider then
			reason = ("%s record names provider %s"):format(binary, vim.inspect(record.provider))
		elseif record.action ~= PROVIDER_ACTION[provider] then
			reason = ("%s record has invalid action %s"):format(binary, vim.inspect(record.action))
		elseif not optional_string(record.package) then
			reason = ("%s record has invalid package"):format(binary)
		elseif not optional_string(record.command) then
			reason = ("%s record has invalid command"):format(binary)
		elseif provider ~= "mason" and record.command ~= nil then
			reason = ("%s record has an unsupported command"):format(binary)
		else
			valid[binary] = {
				provider = provider,
				action = PROVIDER_ACTION[provider],
				package = record.package,
				command = record.command,
			}
		end
		if reason then
			invalid[#invalid + 1] = reason
		end
	end
	table.sort(invalid)
	return valid, #invalid > 0 and ("discarded invalid advice: " .. table.concat(invalid, "; ")) or nil
end

local function defaults()
	return {
		mason = require("muster.providers.mason"),
		nix = require("muster.providers.nix"),
		mise = require("muster.providers.mise"),
	}
end

---@param result muster.Result
---@param callback fun(result: muster.Result)
---@param opts? { providers?: table, nix_concurrency?: integer }
function M.run(result, callback, opts)
	opts = opts or {}
	local providers = opts.providers or defaults()
	local targets = {}
	for _, entry in ipairs(result.entries) do
		local probe = entry.probe or {}
		if entry.declared and probe.status == "missing" and type(probe.binary) == "string" and probe.binary ~= "" then
			local bucket = targets[probe.binary] or {}
			bucket[#bucket + 1] = entry
			targets[probe.binary] = bucket
		end
	end
	local binaries = vim.tbl_keys(targets)
	table.sort(binaries)

	local delivered = false
	local function deliver()
		if delivered then
			return
		end
		delivered = true
		callback(result)
	end
	if #binaries == 0 then
		deliver()
		return
	end

	local advice_by_provider = { mason = {}, nix = {}, mise = {} }
	local errors = {}
	local mason_ok, mason_advice, mason_err = pcall(providers.mason.collect, binaries)
	if mason_ok then
		local validation_err
		advice_by_provider.mason, validation_err = validate_advice("mason", mason_advice)
		local messages = {}
		if validation_err then
			messages[#messages + 1] = validation_err
		end
		if mason_err then
			messages[#messages + 1] = tostring(mason_err)
		end
		if #messages > 0 then
			errors.mason = table.concat(messages, "; ")
		end
	else
		errors.mason = tostring(mason_advice)
	end

	local pending = 2
	local provider_called = { nix = false, mise = false }
	local function provider_done(name, advice, err)
		if provider_called[name] then
			return
		end
		provider_called[name] = true
		local validation_err
		if advice == nil and err ~= nil then
			advice_by_provider[name] = {}
		else
			advice_by_provider[name], validation_err = validate_advice(name, advice)
		end
		local messages = {}
		if validation_err then
			messages[#messages + 1] = validation_err
		end
		if err then
			messages[#messages + 1] = tostring(err)
		end
		if #messages > 0 then
			errors[name] = table.concat(messages, "; ")
		end
		pending = pending - 1
		if pending ~= 0 then
			return
		end

		for _, entry in ipairs(result.entries) do
			entry.advice = {}
		end
		for _, binary in ipairs(binaries) do
			for _, entry in ipairs(targets[binary]) do
				for _, provider in ipairs(PROVIDER_ORDER) do
					local record = advice_by_provider[provider][binary]
					if type(record) == "table" then
						entry.advice[#entry.advice + 1] = vim.deepcopy(record)
					end
				end
			end
		end
		for _, provider in ipairs(PROVIDER_ORDER) do
			if errors[provider] then
				result.notes[#result.notes + 1] = ("%s enrichment failed: %s"):format(provider, errors[provider])
			end
		end
		deliver()
	end

	local function invoke_provider(name, invoke)
		local returned = false
		local callback_seen = false
		local buffered_advice, buffered_err
		local function receive(advice, err)
			if callback_seen then
				return
			end
			callback_seen = true
			if returned then
				provider_done(name, advice, err)
			else
				buffered_advice, buffered_err = advice, err
			end
		end
		local ok, err = pcall(invoke, receive)
		returned = true
		if not ok then
			provider_done(name, {}, tostring(err))
		elseif callback_seen then
			provider_done(name, buffered_advice, buffered_err)
		end
	end

	invoke_provider("nix", function(provider_callback)
		providers.nix.collect(binaries, opts.nix_concurrency or 4, provider_callback)
	end)
	invoke_provider("mise", function(provider_callback)
		providers.mise.collect(binaries, provider_callback)
	end)
end

return M
