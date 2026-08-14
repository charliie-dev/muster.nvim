---@module 'luassert'
local assert = require("luassert")

local function read(path)
	return table.concat(vim.fn.readfile(path), "\n")
end

describe("Mason verification documentation", function()
	it("lists the exact compiler completion allowlist and fail-closed compilers", function()
		local readme = read("README.md"):gsub("%s+", " ")
		assert.is_truthy(readme:find("cargo, composer, gem, golang, luarocks, nuget, and opam", 1, true))
		for _, compiler in ipairs({ "npm", "pypi", "github", "mason", "generic", "openvsx", "unknown" }) do
			assert.is_truthy(
				readme:find(("`%s`"):format(compiler), 1, true),
				("README must name %s as installed_unverified"):format(compiler)
			)
		end
		assert.is_truthy(readme:find("always remain `installed_unverified`", 1, true))
	end)

	it("calls out npm LSP examples and the trusted-process fingerprint boundary", function()
		local readme = read("README.md"):gsub("%s+", " ")
		assert.is_truthy(readme:find("jsonls", 1, true))
		assert.is_truthy(readme:find("yamlls", 1, true))
		assert.is_truthy(readme:find("npm-backed examples", 1, true))
		assert.is_truthy(readme:find("on-disk Mason Lua source drift", 1, true))
		assert.is_truthy(readme:find("running Neovim process and in-memory Lua functions are trusted", 1, true))
	end)
end)
