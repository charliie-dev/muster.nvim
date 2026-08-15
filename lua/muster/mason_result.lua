local M = {}

local sanitize = require("muster.text").sanitize

local OUTCOMES = { "planned", "dispatched", "verifying", "completed", "failed", "unknown" }
local AVAILABILITIES = { "not_checked", "found", "missing", "unverifiable", "unknown", "broken" }
local ATTESTATIONS = { "not_checked", "full", "partial", "failed" }
local MAX_STATUS_ITEMS = 256

local function set(values)
	local result = {}
	for _, value in ipairs(values) do
		result[value] = true
	end
	return result
end

local OUTCOME = set(OUTCOMES)
local AVAILABILITY = set(AVAILABILITIES)
local ATTESTATION = set(ATTESTATIONS)
local AUTOMATIC_STATE = set({ "idle", "running", "reported", "failed", "bridge_failed" })
local INVALID = {
	outcome = "unknown",
	availability = "not_checked",
	attestation = "not_checked",
	error = "invalid Mason install result",
}
local MALFORMED_DTO = {
	package = "unknown",
	outcome = "unknown",
	availability = "not_checked",
	attestation = "not_checked",
	error = "malformed Mason status item",
}
local MALFORMED_STATUS = { state = "failed", reason = "malformed automatic status" }

local function plain_table(value)
	return type(value) == "table" and getmetatable(value) == nil
end

local function present(value)
	return type(value) == "string" and value ~= ""
end

local function legal(value)
	if not plain_table(value) then
		return false
	end
	local outcome = rawget(value, "outcome")
	local availability = rawget(value, "availability")
	local attestation = rawget(value, "attestation")
	if not OUTCOME[outcome] or not AVAILABILITY[availability] or not ATTESTATION[attestation] then
		return false
	end
	local error = rawget(value, "error")
	local availability_reason = rawget(value, "availability_reason")
	local attestation_reason = rawget(value, "attestation_reason")
	local has_error = present(error)
	local has_availability_reason = present(availability_reason)
	local has_attestation_reason = present(attestation_reason)
	if
		(error ~= nil and not has_error)
		or (availability_reason ~= nil and not has_availability_reason)
		or (attestation_reason ~= nil and not has_attestation_reason)
	then
		return false
	end

	if outcome == "planned" or outcome == "dispatched" or outcome == "verifying" then
		return availability == "not_checked"
			and attestation == "not_checked"
			and not has_error
			and not has_availability_reason
			and not has_attestation_reason
	end
	if outcome == "failed" or outcome == "unknown" then
		return availability == "not_checked"
			and attestation == "not_checked"
			and has_error
			and not has_availability_reason
			and not has_attestation_reason
	end
	if has_error or attestation == "not_checked" then
		return false
	end
	if availability == "found" and attestation == "full" then
		return not has_availability_reason and not has_attestation_reason
	end
	if availability == "found" and attestation == "partial" then
		return not has_availability_reason and has_attestation_reason
	end
	if availability == "found" and attestation == "failed" then
		return not has_availability_reason and has_attestation_reason
	end
	return attestation == "failed" and has_availability_reason and has_attestation_reason
end

local function copy(value)
	local result = {
		outcome = rawget(value, "outcome"),
		availability = rawget(value, "availability"),
		attestation = rawget(value, "attestation"),
	}
	if rawget(value, "error") ~= nil then
		result.error = sanitize(rawget(value, "error"), 200)
	end
	if rawget(value, "availability_reason") ~= nil then
		result.availability_reason = sanitize(rawget(value, "availability_reason"), 200)
	end
	if rawget(value, "attestation_reason") ~= nil then
		result.attestation_reason = sanitize(rawget(value, "attestation_reason"), 200)
	end
	return result
end

local function valid_package(value)
	return type(value) == "string" and value ~= "" and #value <= 128 and sanitize(value, 128) == value
end

local function malformed_dto()
	return vim.deepcopy(MALFORMED_DTO)
end

function M.outcomes()
	return vim.deepcopy(OUTCOMES)
end

function M.availabilities()
	return vim.deepcopy(AVAILABILITIES)
end

function M.attestations()
	return vim.deepcopy(ATTESTATIONS)
end

function M.normalize(value)
	if legal(value) then
		local normalized = copy(value)
		if legal(normalized) then
			return normalized
		end
	end
	return vim.deepcopy(INVALID)
end

---@param value any
---@return muster.AutomaticMasonItemStatus
function M.normalize_dto(value)
	if not plain_table(value) or not valid_package(rawget(value, "package")) then
		return malformed_dto()
	end
	local result = M.normalize(value)
	result.package = rawget(value, "package")
	return result
end

---Status item containers are dense plain lists capped at 256 entries.
---@param value any
---@return muster.AutomaticMasonItemStatus[]
function M.normalize_items(value)
	if not plain_table(value) then
		return { malformed_dto() }
	end
	local count = 0
	for key in next, value do
		count = count + 1
		if count > MAX_STATUS_ITEMS or type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > MAX_STATUS_ITEMS then
			return { malformed_dto() }
		end
	end
	for index = 1, count do
		if rawget(value, index) == nil then
			return { malformed_dto() }
		end
	end
	local items = {}
	for index = 1, count do
		items[index] = M.normalize_dto(rawget(value, index))
	end
	return items
end

local function normalized_reason(value)
	if not present(value) then
		return nil
	end
	local reason = sanitize(value, 200)
	if reason == "" then
		return nil
	end
	return reason
end

---@param value any
---@return muster.AutomaticStatus
function M.normalize_status(value)
	if not plain_table(value) then
		return vim.deepcopy(MALFORMED_STATUS)
	end
	local state = rawget(value, "state")
	local raw_reason = rawget(value, "reason")
	local reason = normalized_reason(raw_reason)
	if
		not AUTOMATIC_STATE[state]
		or ((state == "idle" or state == "running") and raw_reason ~= nil)
		or (state == "reported" and raw_reason ~= nil and reason == nil)
		or ((state == "failed" or state == "bridge_failed") and reason == nil)
	then
		return vim.deepcopy(MALFORMED_STATUS)
	end
	local status = { state = state }
	if reason then
		status.reason = reason
	end
	local mason = rawget(value, "mason")
	if mason ~= nil then
		if not plain_table(mason) or rawget(mason, "items") == nil then
			status.mason = { items = { malformed_dto() } }
		else
			status.mason = { items = M.normalize_items(rawget(mason, "items")) }
		end
	end
	return status
end

---@param value any
---@return "info"|"warn"|"error"
function M.status_severity(value)
	local status = M.normalize_status(value)
	if status.state == "failed" or status.state == "bridge_failed" then
		return "error"
	end
	if status.state == "reported" and status.reason ~= nil then
		return "warn"
	end
	return "info"
end

local RESULT_FIELDS = {
	"outcome",
	"availability",
	"attestation",
	"error",
	"availability_reason",
	"attestation_reason",
}

local function unset(item)
	if not plain_table(item) then
		return false
	end
	for _, field in ipairs(RESULT_FIELDS) do
		if rawget(item, field) ~= nil then
			return false
		end
	end
	return true
end

local function transition(item, predecessors, value)
	local normalized = copy(value)
	if not legal(value) or not legal(normalized) then
		error("invalid Mason result transition value", 3)
	end
	local allowed = predecessors.unset == true and unset(item)
	if not allowed and legal(item) then
		allowed = predecessors[rawget(item, "outcome")] == true
	end
	if not allowed then
		error("invalid Mason result transition", 3)
	end
	item.outcome = normalized.outcome
	item.availability = normalized.availability
	item.attestation = normalized.attestation
	item.error = normalized.error
	item.availability_reason = normalized.availability_reason
	item.attestation_reason = normalized.attestation_reason
	item._availability_probes = nil
	return normalized
end

local function nonterminal(item, outcome, predecessors)
	return transition(item, predecessors, {
		outcome = outcome,
		availability = "not_checked",
		attestation = "not_checked",
	})
end

function M.planned(item)
	return nonterminal(item, "planned", { unset = true })
end

function M.dispatched(item)
	return nonterminal(item, "dispatched", { planned = true })
end

function M.verifying(item)
	return nonterminal(item, "verifying", { dispatched = true })
end

function M.failed(item, reason)
	return transition(item, { planned = true, dispatched = true }, {
		outcome = "failed",
		availability = "not_checked",
		attestation = "not_checked",
		error = sanitize(reason, 200),
	})
end

function M.unknown(item, reason)
	return transition(item, { dispatched = true }, {
		outcome = "unknown",
		availability = "not_checked",
		attestation = "not_checked",
		error = sanitize(reason, 200),
	})
end

---@param item muster.MasonInstallItem
---@param availability_result muster.MasonAvailabilityEvidence
---@param attestation_result muster.MasonAttestationEvidence
function M.completed(item, availability_result, attestation_result)
	availability_result = type(availability_result) == "table" and availability_result or {}
	attestation_result = type(attestation_result) == "table" and attestation_result or {}
	return transition(item, { verifying = true }, {
		outcome = "completed",
		availability = availability_result.status,
		attestation = attestation_result.status,
		availability_reason = availability_result.reason,
		attestation_reason = attestation_result.reason,
	})
end

function M.is_terminal(value)
	local result = M.normalize(value)
	return result.outcome == "completed" or result.outcome == "failed" or result.outcome == "unknown"
end

function M.is_verified_success(value)
	local result = M.normalize(value)
	return result.outcome == "completed" and result.availability == "found" and result.attestation == "full"
end

function M.severity(value)
	local result = M.normalize(value)
	if result.outcome == "planned" or result.outcome == "dispatched" or result.outcome == "verifying" then
		return "info"
	end
	if M.is_verified_success(result) then
		return "info"
	end
	if result.outcome == "completed" and result.availability == "found" and result.attestation == "partial" then
		return "warn"
	end
	return "error"
end

return M
