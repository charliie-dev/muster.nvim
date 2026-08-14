local M = {}

-- This binds the loaded Mason modules to one on-disk source tree. The running
-- Neovim process and its in-memory Lua functions remain trusted.
M.EXPECTED_FINGERPRINT = "ffc7c0fe56fdddeb9e5ef2ede6a35561ca0c262af17da29f13a3aedfe064c5bd"

local MAX_DEPTH = 32
local MAX_ENTRIES = 2048
local MAX_FILES = 512
local MAX_FILE_BYTES = 1024 * 1024
local MAX_TOTAL_BYTES = 8 * 1024 * 1024
local MAX_RELATIVE_BYTES = 512

local function normalized(path)
	if type(path) ~= "string" or path == "" or path:find("[%z\1-\31\127]") then
		error("invalid Mason source path")
	end
	local value = vim.fs.normalize(path):gsub("/+$", "")
	if value == "" then
		error("invalid Mason source path")
	end
	return value
end

local function canonical(path)
	local value = vim.uv.fs_realpath(path)
	if type(value) ~= "string" or value == "" then
		error("Mason source path is unreadable")
	end
	return normalized(value)
end

local function strictly_under(path, root)
	return path ~= root and path:sub(1, #root + 1) == root .. "/"
end

local function checked_name(name)
	if type(name) ~= "string" or name == "" or name == "." or name == ".." or name:find("[%z\1-\31\127/\\]") then
		error("invalid Mason source entry")
	end
	return name
end

local function read_file(path, expected_size)
	local descriptor, open_err = vim.uv.fs_open(path, "r", 438)
	if not descriptor then
		error("Mason source file open failed: " .. tostring(open_err))
	end
	local ok, value = pcall(function()
		local before = assert(vim.uv.fs_fstat(descriptor))
		if before.type ~= "file" or before.size ~= expected_size then
			error("Mason source file changed during fingerprint")
		end
		local data = assert(vim.uv.fs_read(descriptor, expected_size, 0))
		local after = assert(vim.uv.fs_fstat(descriptor))
		if #data ~= expected_size or after.type ~= "file" or after.size ~= expected_size then
			error("Mason source file changed during fingerprint")
		end
		return data
	end)
	vim.uv.fs_close(descriptor)
	if not ok then
		error(value, 0)
	end
	return value
end

local function collect(lua_root)
	local files = {}
	local entries = 0

	local function scan(directory, relative, depth)
		if depth > MAX_DEPTH then
			error("Mason source tree exceeds depth bound")
		end
		local handle, scan_err = vim.uv.fs_scandir(directory)
		if not handle then
			error("Mason source directory scan failed: " .. tostring(scan_err))
		end
		local children = {}
		while true do
			local name, kind = vim.uv.fs_scandir_next(handle)
			if not name then
				break
			end
			entries = entries + 1
			if entries > MAX_ENTRIES then
				error("Mason source tree exceeds entry bound")
			end
			children[#children + 1] = { name = checked_name(name), kind = kind }
		end
		table.sort(children, function(left, right)
			return left.name < right.name
		end)
		for _, child in ipairs(children) do
			local child_relative = relative == "" and child.name or (relative .. "/" .. child.name)
			if #child_relative > MAX_RELATIVE_BYTES then
				error("Mason source relative path exceeds bound")
			end
			local child_path = directory .. "/" .. child.name
			if child.kind == "directory" then
				scan(child_path, child_relative, depth + 1)
			elseif child.kind == "file" then
				if child.name:sub(-4) == ".lua" then
					files[#files + 1] = { path = child_path, relative = child_relative }
					if #files > MAX_FILES then
						error("Mason source tree exceeds file bound")
					end
				end
			elseif child.kind == "link" then
				error("Mason source tree contains a symbolic link")
			elseif child.kind ~= "file" then
				error("Mason source tree contains an unsupported entry")
			end
		end
	end

	scan(lua_root, "", 1)
	table.sort(files, function(left, right)
		return left.relative < right.relative
	end)
	if #files == 0 then
		error("Mason source tree contains no Lua files")
	end
	return files
end

function M.fingerprint_root(root)
	local canonical_root = canonical(root)
	local lua_path = canonical_root .. "/lua"
	local lua_lstat = vim.uv.fs_lstat(lua_path)
	if not lua_lstat or lua_lstat.type ~= "directory" then
		error("Mason Lua source root is unavailable")
	end
	local lua_root = canonical(lua_path)
	if not strictly_under(lua_root, canonical_root) then
		error("Mason Lua source root escapes package root")
	end

	local records = { "muster-mason-lua-v1" }
	local total = 0
	for _, file in ipairs(collect(lua_root)) do
		local lstat = vim.uv.fs_lstat(file.path)
		if not lstat or lstat.type ~= "file" or lstat.size > MAX_FILE_BYTES then
			error("Mason source file violates bounds")
		end
		total = total + lstat.size
		if total > MAX_TOTAL_BYTES then
			error("Mason source tree exceeds byte bound")
		end
		local realpath = canonical(file.path)
		if not strictly_under(realpath, lua_root) then
			error("Mason source file escapes Lua root")
		end
		local bytes = read_file(realpath, lstat.size)
		records[#records + 1] = table.concat({ #file.relative, file.relative, lstat.size, vim.fn.sha256(bytes) }, ":")
	end
	return vim.fn.sha256(table.concat(records, "\n"))
end

local RUNTIME_SOURCES = {
	{ "compiler", "parse", "lua/mason-core/installer/compiler/init.lua" },
	{ "package_module", "new", "lua/mason-core/package/init.lua" },
	{ "purl", "compile", "lua/mason-core/purl.lua" },
	{ "receipt", "from_json", "lua/mason-core/receipt.lua" },
}

function M.fingerprint_runtime(runtime)
	local root
	for _, declaration in ipairs(RUNTIME_SOURCES) do
		local owner = runtime[declaration[1]]
		local fn = owner and owner[declaration[2]]
		if type(fn) ~= "function" then
			error("Mason runtime source function unavailable")
		end
		local info = debug.getinfo(fn, "S")
		local source = info and info.source
		if type(source) ~= "string" or source:sub(1, 1) ~= "@" then
			error("Mason runtime source identity unavailable")
		end
		local file = canonical(source:sub(2))
		local suffix = "/" .. declaration[3]
		if file:sub(-#suffix) ~= suffix then
			error("Mason runtime source path mismatch")
		end
		local candidate = file:sub(1, #file - #suffix)
		if candidate == "" or (root and candidate ~= root) then
			error("Mason runtime modules do not share one source root")
		end
		root = candidate
	end
	return M.fingerprint_root(root)
end

return M
