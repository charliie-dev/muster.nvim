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

---Synchronously probe the declared tools without enrichment or side effects.
---
---Used by read-only inspection surfaces. It never spawns enrichment processes,
---emits a report, refreshes a registry, or hands anything to Mason.
---@param bufnr? integer @Defaults to the current buffer.
---@return muster.Result
function M.probe(bufnr)
	return require("muster.check").run(bufnr)
end

---Probe and asynchronously enrich the declared tools.
---
---The callback receives the Result only after every read-only provider has
---settled. Nothing partially enriched is returned or mutated behind the caller's
---back, and this explicit API never emits or provisions.
---@param bufnr? integer @Defaults to the current buffer.
---@param callback fun(result: muster.Result)
function M.check(bufnr, callback)
	vim.validate("callback", callback, "function")
	local result = M.probe(bufnr)
	local started = false
	local delivered = false
	local cancelled = false
	local schedule_returned = false
	local buffered_result

	local function complete(enriched)
		if cancelled or delivered or buffered_result then
			return
		end
		if not schedule_returned then
			buffered_result = enriched
			return
		end
		delivered = true
		callback(enriched)
	end
	local function start()
		if started then
			return
		end
		started = true
		require("muster.enrich").run(result, complete)
	end

	local start_requested = false
	local function scheduled_start()
		if not schedule_returned then
			start_requested = true
			return
		end
		start()
	end
	local scheduled, schedule_err = pcall(vim.schedule, scheduled_start)
	schedule_returned = true
	if not scheduled then
		cancelled = true
		buffered_result = nil
		error(schedule_err, 0)
	end
	if start_requested then
		start()
	end
	if buffered_result and not delivered then
		delivered = true
		callback(buffered_result)
	end
end

return M
