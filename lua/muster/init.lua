---muster.nvim — you declare which tools your config expects; muster calls the
---roll and reports who is absent.
---
---It never installs, removes, or reconfigures anything unless you explicitly opt
---in to handing missing tools to Mason.

local M = {}

---Configure muster. Configuration only: this runs no initialization logic, and
---`plugin/muster.lua` has already installed the command and the autocmd.
---
---Setup keys are adapter ids:
---```lua
---require("muster").setup({
---  lsp = { "lua_ls" }, conform = { "stylua" }, lint = { "selene" },
---  dap = { "codelldb" }, none_ls = { --[[ source objects ]] },
---})
---```
---@param opts? table
function M.setup(opts)
	require("muster.config").setup(opts)
	-- Trigger the automatic check from here too. `VimEnter` alone is not enough:
	-- `event = "VeryLazy"` and every cmd/ft/keys lazy spec call setup() strictly
	-- after VimEnter, and the autocmd is `once`, so the check would never run.
	if vim.v.vim_did_enter == 1 then
		require("muster.runner").start()
	end
end

---Register a third-party adapter. Declared in `setup()` under its `id`, exactly
---like a built-in one.
---@param adapter muster.Adapter
function M.register(adapter)
	require("muster.registry").register(adapter)
end

---Probe the declared tools and return the result.
---
---This is the reporting path: it is the only entry point that may emit a report
---and the only one that may hand off to Mason. `:Muster` and
---`:checkhealth muster` probe without doing either, so an inspection command can
---never install anything.
---@param bufnr? integer @Defaults to the current buffer.
---@return muster.Result
function M.check(bufnr)
	return require("muster.check").run(bufnr)
end

return M
