---Classify where a resolved executable came from, by path prefix.
---
---Evaluated top-down, first match wins. Which path column each row reads
---matters: row 1 must test the PRE-realpath path, because every mise shim is a
---symlink to the mise binary itself, so a shimmed tool's realpath escapes the
---shim root entirely and would classify as whatever provides mise.
---
---No prefix is obtained by spawning a process.

local M = {}

---Join without caring whether `dir` already ends in a separator.
---@param dir string
---@return string
local function as_prefix(dir)
	return (dir:gsub("/*$", "")) .. "/"
end

---Prefix test that respects path boundaries: "/usr/localhost/x" must not match
---the "/usr/local" prefix.
---@param path string
---@param prefix string|nil
---@return boolean
local function under(path, prefix)
	if not prefix or prefix == "" then
		return false
	end
	return path:sub(1, #prefix) == prefix
end

---Mason's install root, without spawning and without requiring mason to be
---loaded. `vim.env.MASON` is set by `mason.setup()`; the API call is the
---fallback for a loaded-but-not-set-up Mason.
---@return string|nil
function M.mason_root()
	if vim.env.MASON and vim.env.MASON ~= "" then
		return vim.env.MASON
	end
	local ok, location = pcall(require, "mason-core.installer.InstallLocation")
	if ok and type(location) == "table" and type(location.global) == "function" then
		local ok_dir, dir = pcall(function()
			return location.global():get_dir()
		end)
		if ok_dir and type(dir) == "string" and dir ~= "" then
			return dir
		end
	end
	return nil
end

---@return string|nil
function M.mise_data_dir()
	if vim.env.MISE_DATA_DIR and vim.env.MISE_DATA_DIR ~= "" then
		return vim.env.MISE_DATA_DIR
	end
	local xdg = vim.env.XDG_DATA_HOME
	if xdg and xdg ~= "" then
		return xdg .. "/mise"
	end
	local home = vim.env.HOME or vim.env.USERPROFILE
	return home and (home .. "/.local/share/mise") or nil
end

---Homebrew's prefix. `brew --prefix` is never run; an unset $HOMEBREW_PREFIX
---falls back to the two standard locations, which is a hint rather than proof —
---a hand-installed binary under /usr/local will be labelled `brew`. Every row of
---the report shows the path beside the source for exactly this reason.
---@return string[]
function M.brew_prefixes()
	if vim.env.HOMEBREW_PREFIX and vim.env.HOMEBREW_PREFIX ~= "" then
		return { vim.env.HOMEBREW_PREFIX }
	end
	return { "/opt/homebrew", "/usr/local" }
end

---@param path string|nil     @As resolved on $PATH (symlinks NOT followed).
---@param realpath string|nil @Symlinks followed; nil when fs_realpath failed.
---@return muster.Source
function M.classify(path, realpath)
	if not realpath then
		-- Found, but nothing can be said about where it came from. Never the
		-- fallback for an unrecognised prefix; that case is `system`.
		return "unknown"
	end

	local mise = M.mise_data_dir()

	-- Row 1: shim root, against the PRE-realpath path. Must come first.
	if mise and under(path or "", as_prefix(mise) .. "shims/") then
		return "mise"
	end

	local mason = M.mason_root()
	if mason and under(realpath, as_prefix(mason)) then
		return "mason"
	end
	if mise and under(realpath, as_prefix(mise) .. "installs/") then
		return "mise"
	end
	if under(realpath, "/nix/store/") then
		return "nix"
	end
	for _, prefix in ipairs(M.brew_prefixes()) do
		if under(realpath, as_prefix(prefix)) then
			return "brew"
		end
	end
	return "system"
end

---Resolve a binary name to the full location record a `found` probe needs.
---@param name string
---@return { path: string, realpath: string|nil, source: muster.Source }|nil
function M.locate(name)
	local path = require("muster.env").executable(name)
	if not path then
		return nil
	end
	local realpath = vim.uv.fs_realpath(path)
	return { path = path, realpath = realpath, source = M.classify(path, realpath) }
end

return M
