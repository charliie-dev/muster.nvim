-- Entry point. Kept small and free of `require` calls at load time: this file
-- runs eagerly at startup, so every module load is deferred into a callback.
--
-- `vim.g.loaded_muster` prevents double initialization and lets users suppress
-- this file -- the :Muster command and the automatic check -- without
-- uninstalling. It cannot disable an explicit `require("muster").setup()`: this
-- file sets the flag itself once it runs, so the flag cannot distinguish "the
-- user disabled us" from "we loaded normally", and calling setup() by hand is an
-- explicit opt-in either way.

if vim.g.loaded_muster then
	return
end
vim.g.loaded_muster = true

vim.api.nvim_create_user_command("Muster", function()
	local bufnr = vim.api.nvim_get_current_buf()
	require("muster.overlay").open(bufnr)
end, { desc = "muster: show tool status for this buffer and everything else" })

local group = vim.api.nvim_create_augroup("muster", { clear = true })
local requested = false
local function request_start()
	if requested then
		return
	end
	local ok, err = pcall(function()
		require("muster.runner").defer_start()
	end)
	if ok then
		requested = true
	else
		package.loaded["muster.runner"] = nil
		pcall(vim.notify, "muster: failed to request the startup check: " .. tostring(err), vim.log.levels.ERROR, {
			title = "muster",
		})
	end
end

vim.api.nvim_create_autocmd("UIEnter", {
	group = group,
	once = true,
	callback = request_start,
})

vim.api.nvim_create_autocmd("VimEnter", {
	group = group,
	once = true,
	callback = function()
		local ok = pcall(vim.defer_fn, function()
			if not requested then
				request_start()
			end
		end, 0)
		if not ok then
			request_start()
		end
	end,
})
