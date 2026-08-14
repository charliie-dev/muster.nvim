local M = {}

M.HEALTH_SEVERITY = {
	planned = "info",
	dispatched = "info",
	verifying = "info",
	completed = "info",
	installed_unverified = "error",
	failed = "error",
	unknown = "error",
}

function M.normalize(value)
	if type(value) == "string" and M.HEALTH_SEVERITY[value] then
		return value
	end
	return "unknown", "invalid Mason install outcome"
end

return M
