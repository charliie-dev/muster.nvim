---Host-plugin presence, without loading anything.
---
---`pcall(require, "conform")` would answer the question by force-loading the
---plugin, which defeats the user's lazy loading during what is supposed to be a
---read-only inspection — the same hazard the design forbids for Mason. So
---presence is read from `package.loaded`, and a not-loaded plugin is
---distinguished from an absent one through the runtimepath, which also does not
---load it.

local M = {}

---@param module string   @Module name, e.g. "conform".
---@param rtp_file string @Runtime path to probe, e.g. "lua/conform/init.lua".
---@return boolean loaded
---@return string|nil reason @Why not, when not loaded.
function M.status(module, rtp_file)
	if package.loaded[module] ~= nil then
		return true, nil
	end
	if #vim.api.nvim_get_runtime_file(rtp_file, false) > 0 then
		return false, "host plugin is on the runtimepath but not loaded yet"
	end
	-- NOT "not installed". A plugin manager keeps lazy-loaded plugins off the
	-- runtimepath until they load, so absence here proves nothing — and muster
	-- must not claim a plugin is missing when it may simply be waiting. Telling
	-- the user what muster actually knows is the whole point.
	return false,
		"host plugin is not loaded (muster does not force-load it; "
			.. "if it is lazy-loaded, run the check after it loads)"
end

---Is a plugin installed at all, loaded or not? Used for hazard detection where
---loading would be the wrong cure.
---@param rtp_file string
---@return boolean
function M.installed(rtp_file)
	return #vim.api.nvim_get_runtime_file(rtp_file, false) > 0
end

return M
