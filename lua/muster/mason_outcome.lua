local M = {}

local HEALTH_SEVERITY = {
	planned = "info",
	dispatched = "info",
	verifying = "info",
	completed = "info",
	installed_unverified = "error",
	failed = "error",
	unknown = "error",
}

function M.normalize(value)
	if type(value) == "string" and HEALTH_SEVERITY[value] then
		return value
	end
	return "unknown", "invalid Mason install outcome"
end

function M.severity(value)
	local normalized = M.normalize(value)
	return HEALTH_SEVERITY[normalized]
end

return M
