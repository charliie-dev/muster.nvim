---@module 'luassert'
local assert = require("luassert")

local mason_result = require("muster.mason_result")

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

local function has_bit(value, bit_value)
	return math.floor(value / bit_value) % 2 == 1
end

local function expected_legal(value)
	local error = value.error ~= nil
	local availability_reason = value.availability_reason ~= nil
	local attestation_reason = value.attestation_reason ~= nil
	if value.outcome == "planned" or value.outcome == "dispatched" or value.outcome == "verifying" then
		return value.availability == "not_checked"
			and value.attestation == "not_checked"
			and not error
			and not availability_reason
			and not attestation_reason
	end
	if value.outcome == "failed" or value.outcome == "unknown" then
		return value.availability == "not_checked"
			and value.attestation == "not_checked"
			and error
			and not availability_reason
			and not attestation_reason
	end
	if error or value.outcome ~= "completed" then
		return false
	end
	if value.availability == "found" and value.attestation == "full" then
		return not availability_reason and not attestation_reason
	end
	if value.availability == "found" and (value.attestation == "partial" or value.attestation == "failed") then
		return not availability_reason and attestation_reason
	end
	return value.attestation == "failed" and availability_reason and attestation_reason
end

describe("muster.mason_result", function()
	it("exhaustively accepts only the complete legal tuple and reason-presence matrix", function()
		local legal = 0
		local illegal = 0
		for _, outcome in ipairs(mason_result.outcomes()) do
			for _, availability in ipairs(mason_result.availabilities()) do
				for _, attestation in ipairs(mason_result.attestations()) do
					for mask = 0, 7 do
						local value = {
							outcome = outcome,
							availability = availability,
							attestation = attestation,
							error = has_bit(mask, 1) and "operation" or nil,
							availability_reason = has_bit(mask, 2) and "availability" or nil,
							attestation_reason = has_bit(mask, 4) and "attestation" or nil,
						}
						local normalized = mason_result.normalize(value)
						if expected_legal(value) then
							legal = legal + 1
							assert.same(value, normalized)
						else
							illegal = illegal + 1
							assert.same(INVALID, normalized)
						end
					end
				end
			end
		end
		assert.equals(13, legal)
		assert.equals(1139, illegal)
	end)

	it("fails closed for malformed enums, reasons, and stale attacker-controlled fields", function()
		for _, value in ipairs({
			nil,
			false,
			{},
			{ outcome = "installed" .. "_unverified", availability = "found", attestation = "partial" },
			{ outcome = "completed", availability = "found", attestation = "future" },
			{ outcome = "failed", availability = "not_checked", attestation = "not_checked", error = "" },
			{
				outcome = "completed",
				availability = "found",
				attestation = "full",
				attestation_reason = {},
			},
			{
				outcome = "completed",
				availability = "found",
				attestation = "partial",
				attestation_reason = "\226\128\174",
			},
		}) do
			assert.same(INVALID, mason_result.normalize(value))
		end
		assert.same(
			INVALID,
			mason_result.normalize({
				outcome = "corrupt",
				availability = "broken",
				attestation = "failed",
				error = "secret",
				availability_reason = "secret",
				attestation_reason = "secret",
			})
		)
	end)

	it("returns private enum copies and sanitizes bounded legal reasons", function()
		local outcomes = mason_result.outcomes()
		outcomes[1] = "corrupt"
		assert.equals("planned", mason_result.outcomes()[1])
		local normalized = mason_result.normalize({
			outcome = "completed",
			availability = "broken",
			attestation = "failed",
			availability_reason = string.rep("a", 250) .. "\n",
			attestation_reason = "bridge \226\128\174rejected",
		})
		assert.equals(200, #normalized.availability_reason)
		assert.is_falsy(normalized.availability_reason:find("\n", 1, true))
		assert.equals("bridge rejected", normalized.attestation_reason)
	end)

	it("enforces every writer predecessor and keeps invalid transitions mutation-free", function()
		local predecessors = {
			{ name = "unset" },
			{ name = "partially-unset", availability = "not_checked" },
			{ name = "malformed", outcome = "planned", availability = "found", attestation = "not_checked" },
			{ name = "planned", outcome = "planned", availability = "not_checked", attestation = "not_checked" },
			{ name = "dispatched", outcome = "dispatched", availability = "not_checked", attestation = "not_checked" },
			{ name = "verifying", outcome = "verifying", availability = "not_checked", attestation = "not_checked" },
			{
				name = "failed",
				outcome = "failed",
				availability = "not_checked",
				attestation = "not_checked",
				error = "failed",
			},
			{
				name = "unknown",
				outcome = "unknown",
				availability = "not_checked",
				attestation = "not_checked",
				error = "unknown",
			},
			{ name = "completed-full", outcome = "completed", availability = "found", attestation = "full" },
			{
				name = "completed-partial",
				outcome = "completed",
				availability = "found",
				attestation = "partial",
				attestation_reason = "gap",
			},
			{
				name = "completed-found-failed",
				outcome = "completed",
				availability = "found",
				attestation = "failed",
				attestation_reason = "failed",
			},
		}
		for _, availability in ipairs({ "missing", "unknown", "broken", "unverifiable", "not_checked" }) do
			predecessors[#predecessors + 1] = {
				name = "completed-" .. availability,
				outcome = "completed",
				availability = availability,
				attestation = "failed",
				availability_reason = "unavailable",
				attestation_reason = "failed",
			}
		end
		local writers = {
			planned = {
				allowed = { unset = true },
				call = function(item)
					mason_result.planned(item)
				end,
			},
			dispatched = {
				allowed = { planned = true },
				call = function(item)
					mason_result.dispatched(item)
				end,
			},
			verifying = {
				allowed = { dispatched = true },
				call = function(item)
					mason_result.verifying(item)
				end,
			},
			failed = {
				allowed = { planned = true, dispatched = true },
				call = function(item)
					mason_result.failed(item, "failure")
				end,
			},
			unknown = {
				allowed = { dispatched = true },
				call = function(item)
					mason_result.unknown(item, "ambiguous")
				end,
			},
			completed = {
				allowed = { verifying = true },
				call = function(item)
					mason_result.completed(item, { status = "found" }, { status = "full" })
				end,
			},
		}
		for writer_name, writer in pairs(writers) do
			for _, predecessor in ipairs(predecessors) do
				local item = vim.deepcopy(predecessor)
				item.name = nil
				item.package = "tool"
				item._availability_probes = { secret = true }
				local before = vim.deepcopy(item)
				local ok = pcall(writer.call, item)
				assert.equals(writer.allowed[predecessor.name] == true, ok, writer_name .. " from " .. predecessor.name)
				if ok then
					assert.is_nil(item._availability_probes)
				else
					assert.same(before, item, writer_name .. " mutated " .. predecessor.name)
				end
			end
		end
	end)

	it("clears stale dimensions atomically along legal paths", function()
		local failed = { package = "failed", _availability_probes = { secret = true } }
		mason_result.planned(failed)
		mason_result.failed(failed, "failed\nreason")
		assert.same({
			package = "failed",
			outcome = "failed",
			availability = "not_checked",
			attestation = "not_checked",
			error = "failed?reason",
		}, failed)

		local unknown = { package = "unknown" }
		mason_result.planned(unknown)
		mason_result.dispatched(unknown)
		mason_result.unknown(unknown, "ambiguous")
		assert.same({
			package = "unknown",
			outcome = "unknown",
			availability = "not_checked",
			attestation = "not_checked",
			error = "ambiguous",
		}, unknown)

		local completed = { package = "completed" }
		mason_result.planned(completed)
		mason_result.dispatched(completed)
		mason_result.verifying(completed)
		mason_result.completed(completed, { status = "found" }, { status = "partial", reason = "closed gap" })
		assert.same({
			package = "completed",
			outcome = "completed",
			availability = "found",
			attestation = "partial",
			attestation_reason = "closed gap",
		}, completed)
	end)

	it("raises on an illegal completed candidate without mutating verifying state", function()
		local item = { package = "tool", _availability_probes = { tool = { status = "found" } } }
		mason_result.planned(item)
		mason_result.dispatched(item)
		mason_result.verifying(item)
		local before = vim.deepcopy(item)
		assert.has_error(function()
			mason_result.completed(item, { status = "missing" }, { status = "partial", reason = "gap" })
		end)
		assert.same(before, item)
	end)

	it("normalizes package-aware DTOs once while preserving exact valid identity", function()
		local package = string.rep("a", 120) .. ".tool-1"
		local dto = mason_result.normalize_dto({
			package = package,
			outcome = "completed",
			availability = "found",
			attestation = "full",
		})
		assert.same({
			package = package,
			outcome = "completed",
			availability = "found",
			attestation = "full",
		}, dto)
		for _, invalid_package in ipairs({
			false,
			"",
			string.rep("a", 129),
			"bad\npackage",
			"bad\226\128\174package",
			setmetatable({}, {}),
		}) do
			assert.same(
				MALFORMED_DTO,
				mason_result.normalize_dto({
					package = invalid_package,
					outcome = "completed",
					availability = "found",
					attestation = "full",
				})
			)
		end
		assert.same(
			MALFORMED_DTO,
			mason_result.normalize_dto({
				outcome = "completed",
				availability = "found",
				attestation = "full",
			})
		)
	end)

	it("rejects metatable, huge, sparse, and noninteger status containers in bounded rows", function()
		local valid = {
			package = "tool",
			outcome = "completed",
			availability = "found",
			attestation = "full",
		}
		local dense = {}
		for index = 1, 256 do
			dense[index] = valid
		end
		assert.equals(256, #mason_result.normalize_items(dense))
		dense[257] = valid
		assert.same({ MALFORMED_DTO }, mason_result.normalize_items(dense))
		for _, container in ipairs({
			false,
			setmetatable({}, {
				__pairs = function()
					error("must not iterate")
				end,
			}),
			{ [1000000000] = valid },
			{ [2] = valid },
			{ [1.5] = valid },
			{ bad = valid },
		}) do
			assert.same({ MALFORMED_DTO }, mason_result.normalize_items(container))
		end
		local throwing_item = setmetatable({}, {
			__index = function()
				error("must not index")
			end,
		})
		assert.same({ MALFORMED_DTO }, mason_result.normalize_items({ throwing_item }))
	end)

	it("normalizes and grades the complete top-level automatic status contract", function()
		local reported = mason_result.normalize_status({ state = "reported", reason = "degraded\nreason" })
		assert.same({ state = "reported", reason = "degraded?reason" }, reported)
		assert.equals("warn", mason_result.status_severity(reported))
		assert.equals("info", mason_result.status_severity({ state = "reported" }))
		for _, malformed in ipairs({
			false,
			{},
			{ state = "future" },
			{ state = "idle", reason = "stale" },
			{ state = "failed" },
			{ state = "bridge_failed" },
			setmetatable({ state = "reported" }, {}),
		}) do
			assert.same(
				{ state = "failed", reason = "malformed automatic status" },
				mason_result.normalize_status(malformed)
			)
			assert.equals("error", mason_result.status_severity(malformed))
		end
		assert.same(
			{ state = "failed", reason = "failed safely" },
			mason_result.normalize_status({
				state = "failed",
				reason = "failed safely",
			})
		)
		assert.same(
			{ state = "bridge_failed", reason = "bridge safely" },
			mason_result.normalize_status({
				state = "bridge_failed",
				reason = "bridge safely",
			})
		)
	end)

	it("enforces the static no-bare-completed and atomic-writer contracts", function()
		for _, path in ipairs(vim.fn.glob("lua/muster/**/*.lua", false, true)) do
			local source = table.concat(vim.fn.readfile(path), "\n")
			if path ~= "lua/muster/mason_result.lua" then
				assert.is_nil(source:match("%.outcome%s*=%s*[^=]"), path .. " assigns an outcome directly")
				assert.is_nil(source:match("%.availability%s*=%s*[^=]"), path .. " assigns availability directly")
				assert.is_nil(source:match("%.attestation%s*=%s*[^=]"), path .. " assigns attestation directly")
				assert.is_nil(source:match("outcome%s*==%s*[\"']completed[\"']"), path .. " uses completed alone")
			end
			assert.is_nil(source:find("installed" .. "_unverified", 1, true), path .. " retains the removed state")
		end
	end)

	it("derives terminal state, verified success, and severity from the full tuple", function()
		local cases = {
			{
				{ outcome = "planned", availability = "not_checked", attestation = "not_checked" },
				false,
				false,
				"info",
			},
			{
				{ outcome = "dispatched", availability = "not_checked", attestation = "not_checked" },
				false,
				false,
				"info",
			},
			{
				{ outcome = "verifying", availability = "not_checked", attestation = "not_checked" },
				false,
				false,
				"info",
			},
			{
				{ outcome = "failed", availability = "not_checked", attestation = "not_checked", error = "x" },
				true,
				false,
				"error",
			},
			{
				{ outcome = "unknown", availability = "not_checked", attestation = "not_checked", error = "x" },
				true,
				false,
				"error",
			},
			{ { outcome = "completed", availability = "found", attestation = "full" }, true, true, "info" },
			{
				{ outcome = "completed", availability = "found", attestation = "partial", attestation_reason = "gap" },
				true,
				false,
				"warn",
			},
			{
				{ outcome = "completed", availability = "found", attestation = "failed", attestation_reason = "bad" },
				true,
				false,
				"error",
			},
		}
		for _, case in ipairs(cases) do
			assert.equals(case[2], mason_result.is_terminal(case[1]))
			assert.equals(case[3], mason_result.is_verified_success(case[1]))
			assert.equals(case[4], mason_result.severity(case[1]))
		end
		assert.equals("error", mason_result.severity({ outcome = "completed" }))
	end)
end)
