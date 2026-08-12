local script_path = debug.getinfo(1, "S").source:sub(2)
local scripts_dir = vim.fs.dirname(script_path)
package.path = scripts_dir .. "/?.lua;" .. package.path

local audit = require("debug_call_audit")
local fixture_root = vim.fn.tempname()
vim.fn.mkdir(fixture_root, "p")

local function cleanup()
	vim.fn.delete(fixture_root, "rf")
end

local function write_file(path, content)
	local handle = assert(io.open(path, "wb"))
	assert(handle:write(content))
	assert(handle:close())
end

local function expect_error(label, expected, callback)
	local ok, message = pcall(callback)
	assert(not ok, label .. " unexpectedly passed")
	assert(tostring(message):find(expected, 1, true), label .. " returned the wrong error")
end

local ok, message = xpcall(function()
	local positive = fixture_root .. "/positive.lua"
	write_file(
		positive,
		[==[((print))("parenthesized global");
(((vim).print))("parenthesized member and callee");
(vim)["print"]("parenthesized table");
((vim))[("print")]("parenthesized table and field");
vim[(("print"))]("nested parenthesized field");
((vim)[(("pr\105nt"))])("decimal escape");
vim['pr\x69nt']("hexadecimal escape");
vim[("pr\z  int")]("whitespace escape");
vim[ [=[print]=] ]("long string");
print -- split across a comment and newlines
(
  "global"
)
vim
  -- member access may span comments and newlines
  .
  print
  (
    "member"
  )
]==]
	)

	local findings = audit.scan({ positive })
	local expected = {
		{ line = 1, kind = "print" },
		{ line = 2, kind = "vim.print" },
		{ line = 3, kind = "vim.print" },
		{ line = 4, kind = "vim.print" },
		{ line = 5, kind = "vim.print" },
		{ line = 6, kind = "vim.print" },
		{ line = 7, kind = "vim.print" },
		{ line = 8, kind = "vim.print" },
		{ line = 9, kind = "vim.print" },
		{ line = 10, kind = "print" },
		{ line = 14, kind = "vim.print" },
	}
	assert(#findings == #expected, "expected every supported debug-call shape")
	for index, wanted in ipairs(expected) do
		local finding = findings[index]
		assert(
			finding.path == positive and finding.line == wanted.line and finding.kind == wanted.kind,
			("finding %d had the wrong path, location, or kind"):format(index)
		)
	end

	local ignored = fixture_root .. "/ignored.lua"
	write_file(
		ignored,
		[==[(other)("parenthesized identifier");
(logger.print)("parenthesized member");
(logger):print("parenthesized method")
((logger).print)("other parenthesized object")
((vim).other)("other parenthesized member")
(vim):print("vim method")
local text = "(print)('string') and (vim.print)('string')"
-- (print)("comment")
-- (vim.print)("comment")
(function(value)
  return value
end)("parenthesized function")
myprint("identifier")
function print(value)
  return value
end
function vim.print(value)
  return value
end
logger.print("field")
logger:print("method")
vim["other"]("other key")
vim[("pr\110nt")]("escaped other key")
other[("print")]("parenthesized other object")
local key = "print"
vim[key]("dynamic key")
vim[("pr" .. "int")]("computed key")
vim[make_key()]("call key")
vim[[print]]()
]==]
	)
	assert(#audit.scan({ ignored }) == 0, "non-debug call shapes or syntax were flagged")

	local malformed = fixture_root .. "/malformed.lua"
	write_file(malformed, "local = broken\n")
	expect_error("parser error", "Lua syntax error", function()
		audit.scan({ malformed })
	end)

	expect_error("missing input", "cannot inspect input", function()
		audit.scan({ fixture_root .. "/missing" })
	end)

	local unreadable = fixture_root .. "/unreadable.lua"
	write_file(unreadable, "local clean = true\n")
	assert(vim.uv.fs_chmod(unreadable, 0))
	expect_error("unreadable input", "cannot read input", function()
		audit.scan({ unreadable })
	end)
	assert(vim.uv.fs_chmod(unreadable, 384))

	assert(#audit.scan({ "lua", "plugin" }) == 0, "repository scan found a debug call")
end, debug.traceback)

cleanup()
if not ok then
	error(message, 0)
end

io.write("debug-call audit fixtures passed\n")
