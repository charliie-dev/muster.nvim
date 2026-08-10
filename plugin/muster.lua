-- Entry point. Kept small and free of `require` calls at load time: this file
-- runs eagerly at startup, so every module load is deferred into a callback.
--
-- `vim.g.loaded_muster` both prevents double initialization and gives users a
-- documented way to disable muster without uninstalling it.

if vim.g.loaded_muster then
	return
end
vim.g.loaded_muster = true

vim.api.nvim_create_user_command("Muster", function()
	require("muster.overlay").open()
end, { desc = "muster: show tool status for this buffer and everything else" })

vim.api.nvim_create_autocmd("VimEnter", {
	group = vim.api.nvim_create_augroup("muster", { clear = true }),
	once = true,
	callback = function()
		require("muster.runner").start()
	end,
})
