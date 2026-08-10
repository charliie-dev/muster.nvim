-- Entry point. Kept small and free of `require` calls: this file is run eagerly
-- at startup, so every module load is deferred into a callback.
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
		-- Without a setup() call nothing is declared, so the automatic check
		-- does not run at all: no probing, no notification, no warning about
		-- missing configuration. :Muster and :checkhealth still work on demand.
		local config = require("muster.config").get()
		if not config then
			return
		end
		vim.schedule(function()
			require("muster.report").emit(require("muster.check").run())
		end)
	end,
})
