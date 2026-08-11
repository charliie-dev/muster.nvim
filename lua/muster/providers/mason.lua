---Mason advice from an already-loaded registry.
---
---This provider never requires or refreshes Mason. A cold, absent, or malformed
---registry simply contributes no advice; E2 owns network refresh and installs.

local M = {}

---@param binaries string[]
---@return table<string, muster.Advice>
function M.collect(binaries)
	local registry = package.loaded["mason-registry"]
	if type(registry) ~= "table" or type(registry.get_all_package_specs) ~= "function" then
		return {}
	end
	local ok, specs = pcall(registry.get_all_package_specs)
	if not ok then
		return {}, "Mason registry specs failed: " .. tostring(specs)
	end
	if type(specs) ~= "table" or not vim.islist(specs) then
		return {}, ("Mason registry returned a %s instead of a package-spec list"):format(type(specs))
	end

	local requested = {}
	local packages = {}
	for _, binary in ipairs(binaries) do
		requested[binary] = true
		packages[binary] = {}
	end
	for _, spec in ipairs(specs) do
		if type(spec) == "table" and type(spec.name) == "string" and type(spec.bin) == "table" then
			for binary in pairs(spec.bin) do
				if requested[binary] then
					packages[binary][spec.name] = true
				end
			end
		end
	end

	local advice = {}
	for _, binary in ipairs(binaries) do
		local names = vim.tbl_keys(packages[binary])
		table.sort(names)
		if #names == 1 then
			advice[binary] = {
				provider = "mason",
				action = "install",
				package = names[1],
				command = ":MasonInstall " .. names[1],
			}
		elseif #names > 1 then
			advice[binary] = { provider = "mason", action = "install" }
		end
	end
	return advice
end

return M
