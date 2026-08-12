local M = {}

local uv = vim.uv

local function fail(message)
	error(message, 0)
end

local function collect_lua_files(path, files, seen)
	local stat, stat_error = uv.fs_lstat(path)
	if not stat then
		fail(("cannot inspect input %s: %s"):format(path, stat_error or "unknown error"))
	end

	if stat.type == "file" then
		if path:sub(-4) == ".lua" and not seen[path] then
			seen[path] = true
			files[#files + 1] = path
		end
		return
	end

	if stat.type ~= "directory" then
		fail(("unsupported input type for %s: %s"):format(path, stat.type))
	end

	local scanner, scan_error = uv.fs_scandir(path)
	if not scanner then
		fail(("cannot enumerate input %s: %s"):format(path, scan_error or "unknown error"))
	end

	while true do
		local name, entry_type = uv.fs_scandir_next(scanner)
		if not name then
			break
		end

		local child = path .. "/" .. name
		if entry_type == "directory" or entry_type == nil then
			collect_lua_files(child, files, seen)
		elseif entry_type == "file" then
			if child:sub(-4) == ".lua" and not seen[child] then
				seen[child] = true
				files[#files + 1] = child
			end
		elseif entry_type == "link" then
			fail("symbolic links are not valid audit inputs: " .. child)
		else
			fail(("unsupported input type for %s: %s"):format(child, entry_type))
		end
	end
end

local function read_file(path)
	local handle, open_error = io.open(path, "rb")
	if not handle then
		fail(("cannot read input %s: %s"):format(path, open_error or "unknown error"))
	end

	local source, read_error = handle:read("*a")
	local close_ok, close_error = handle:close()
	if not source then
		fail(("cannot read input %s: %s"):format(path, read_error or "unknown error"))
	end
	if not close_ok then
		fail(("cannot close input %s: %s"):format(path, close_error or "unknown error"))
	end
	return source
end

local function node_text(node, source)
	return vim.treesitter.get_node_text(node, source)
end

local function unwrap_parentheses(node)
	while node and node:type() == "parenthesized_expression" do
		node = node:named_child(0)
	end
	return node
end

local function decode_static_string(node, source)
	if node:type() ~= "string" then
		return nil
	end

	local chunk = loadstring("return " .. node_text(node, source), "=(debug-call string literal)")
	if not chunk then
		fail("cannot decode static Lua string literal")
	end
	setfenv(chunk, {})

	local ok, value = pcall(chunk)
	if not ok or type(value) ~= "string" then
		fail("cannot decode static Lua string literal")
	end
	return value
end

local function call_kind(node, source)
	if node:type() ~= "function_call" then
		return nil
	end

	local name = unwrap_parentheses(node:field("name")[1])
	if not name then
		return nil
	end

	if name:type() == "identifier" and node_text(name, source) == "print" then
		return "print"
	end

	if name:type() ~= "dot_index_expression" and name:type() ~= "bracket_index_expression" then
		return nil
	end

	local object = unwrap_parentheses(name:field("table")[1])
	local field = unwrap_parentheses(name:field("field")[1])
	if not object or not field or object:type() ~= "identifier" or node_text(object, source) ~= "vim" then
		return nil
	end

	if
		name:type() == "dot_index_expression"
		and field:type() == "identifier"
		and node_text(field, source) == "print"
	then
		return "vim.print"
	end

	if name:type() == "bracket_index_expression" and decode_static_string(field, source) == "print" then
		return "vim.print"
	end

	return nil
end

local function inspect_file(path, findings)
	local source = read_file(path)
	local parser_ok, parser = pcall(vim.treesitter.get_string_parser, source, "lua")
	if not parser_ok then
		fail("cannot create Lua parser for " .. path)
	end

	local parse_ok, trees = pcall(parser.parse, parser)
	if not parse_ok or not trees or not trees[1] then
		fail("cannot parse Lua input " .. path)
	end

	local root = trees[1]:root()
	if root:has_error() then
		fail("Lua syntax error in " .. path)
	end

	local function visit(node)
		local kind = call_kind(node, source)
		if kind then
			local row = node:range()
			findings[#findings + 1] = {
				path = path,
				line = row + 1,
				kind = kind,
			}
		end

		for child in node:iter_children() do
			visit(child)
		end
	end

	visit(root)
end

function M.scan(paths)
	if type(paths) ~= "table" or #paths == 0 then
		fail("at least one audit input is required")
	end

	local files = {}
	local seen = {}
	for _, path in ipairs(paths) do
		if type(path) ~= "string" or path == "" then
			fail("audit inputs must be non-empty paths")
		end
		collect_lua_files(path, files, seen)
	end
	table.sort(files)

	local findings = {}
	for _, path in ipairs(files) do
		inspect_file(path, findings)
	end
	return findings
end

return M
