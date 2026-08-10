rockspec_format = "3.0"
package = "muster.nvim"
version = "scm-1"

source = {
	url = "git+https://github.com/charliie-dev/muster.nvim",
}

description = {
	summary = "Call the roll on the tools your Neovim config declares",
	detailed = [[
You declare which tools your Neovim config expects — LSP servers, formatters,
linters, DAP adapters, none-ls sources — and muster reports which are absent,
where the present ones came from, and what could provide the rest.

It never installs, removes, or reconfigures anything unless you explicitly opt
in to handing missing tools to Mason. A tool already on your system is used as
it is, which is the point: on hosts that provision declaratively, Mason is a
partial supplier rather than the only one.
]],
	homepage = "https://github.com/charliie-dev/muster.nvim",
	license = "MIT",
	labels = { "neovim", "lsp", "mason", "tooling" },
}

dependencies = {
	-- Lua 5.1 API only: some Neovim builds ship PUC Lua rather than LuaJIT.
	"lua >= 5.1, < 5.5",
}

test_dependencies = {
	-- Neovim as the Lua interpreter, so specs run against the real vim.* API.
	"nlua",
}

test = {
	type = "busted",
}

build = {
	type = "builtin",
	copy_directories = { "plugin", "doc" },
}
