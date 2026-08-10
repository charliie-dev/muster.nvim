---@module 'luassert'
local assert = require("luassert")

describe(":Muster command", function()
	it("passes the invoking buffer on every opening", function()
		local original_buf = vim.api.nvim_get_current_buf()
		local original_loaded = vim.g.loaded_muster
		local original_overlay = package.loaded["muster.overlay"]
		local seen = {}
		package.loaded["muster.overlay"] = {
			open = function(bufnr)
				seen[#seen + 1] = bufnr
			end,
		}
		vim.g.loaded_muster = false
		pcall(vim.api.nvim_del_user_command, "Muster")
		pcall(vim.api.nvim_del_augroup_by_name, "muster")
		dofile("plugin/muster.lua")

		local first = vim.api.nvim_create_buf(false, true)
		local second = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(first)
		vim.cmd("Muster")
		vim.api.nvim_set_current_buf(second)
		vim.cmd("Muster")

		assert.same({ first, second }, seen)

		vim.api.nvim_set_current_buf(original_buf)
		vim.api.nvim_buf_delete(first, { force = true })
		vim.api.nvim_buf_delete(second, { force = true })
		vim.api.nvim_del_user_command("Muster")
		pcall(vim.api.nvim_del_augroup_by_name, "muster")
		vim.g.loaded_muster = original_loaded
		package.loaded["muster.overlay"] = original_overlay
	end)
end)
