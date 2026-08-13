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

describe("startup runner", function()
	local function harness(fn)
		local original_loaded = vim.g.loaded_muster
		local original_runner = package.loaded["muster.runner"]
		local original_defer_fn = vim.defer_fn
		local deferred = {}
		local requests = 0

		local ok, err = xpcall(function()
			vim.defer_fn = function(callback, delay)
				deferred[#deferred + 1] = { callback = callback, delay = delay }
			end
			package.loaded["muster.runner"] = {
				defer_start = function()
					requests = requests + 1
				end,
			}
			vim.g.loaded_muster = false
			pcall(vim.api.nvim_del_user_command, "Muster")
			pcall(vim.api.nvim_del_augroup_by_name, "muster")
			dofile("plugin/muster.lua")
			fn(function()
				return requests
			end, deferred)
		end, debug.traceback)

		vim.defer_fn = original_defer_fn
		package.loaded["muster.runner"] = original_runner
		vim.g.loaded_muster = original_loaded
		pcall(vim.api.nvim_del_user_command, "Muster")
		pcall(vim.api.nvim_del_augroup_by_name, "muster")
		if not ok then
			error(err, 0)
		end
	end

	it("prefers UIEnter and leaves the VimEnter fallback inert", function()
		harness(function(requests, deferred)
			vim.api.nvim_exec_autocmds("VimEnter", { group = "muster", modeline = false })
			assert.equals(0, requests())
			assert.equals(1, #deferred)
			assert.equals(0, deferred[1].delay)
			vim.api.nvim_exec_autocmds("UIEnter", { group = "muster", modeline = false })
			assert.equals(1, requests())
			deferred[1].callback()
			assert.equals(1, requests())
		end)
	end)

	it("uses the VimEnter fallback when no UI attaches", function()
		harness(function(requests, deferred)
			vim.api.nvim_exec_autocmds("VimEnter", { group = "muster", modeline = false })
			assert.equals(0, requests())
			deferred[1].callback()
			assert.equals(1, requests())
		end)
	end)

	it("contains a rejected VimEnter fallback bridge", function()
		harness(function(requests)
			vim.defer_fn = function()
				error("defer rejected")
			end
			assert.is_true(pcall(vim.api.nvim_exec_autocmds, "VimEnter", { group = "muster", modeline = false }))
			assert.equals(1, requests())
		end)
	end)

	it("contains an invoke-then-throw VimEnter fallback without duplicate requests", function()
		harness(function(requests)
			vim.defer_fn = function(callback)
				callback()
				error("defer rejected after invocation")
			end
			assert.is_true(pcall(vim.api.nvim_exec_autocmds, "VimEnter", { group = "muster", modeline = false }))
			assert.equals(1, requests())
		end)
	end)

	it("contains runner module loading failure and lets the fallback retry", function()
		local original_loaded = vim.g.loaded_muster
		local original_runner = package.loaded["muster.runner"]
		local original_preload = package.preload["muster.runner"]
		local original_defer_fn = vim.defer_fn
		local original_notify = vim.notify
		local deferred = {}
		local notifications = {}
		local requests = 0

		local ok, err = xpcall(function()
			vim.defer_fn = function(callback, delay)
				deferred[#deferred + 1] = { callback = callback, delay = delay }
			end
			vim.notify = function(message)
				notifications[#notifications + 1] = tostring(message)
			end
			package.loaded["muster.runner"] = nil
			package.preload["muster.runner"] = function()
				error("runner module exploded")
			end
			vim.g.loaded_muster = false
			pcall(vim.api.nvim_del_user_command, "Muster")
			pcall(vim.api.nvim_del_augroup_by_name, "muster")
			dofile("plugin/muster.lua")

			vim.api.nvim_exec_autocmds("VimEnter", { group = "muster", modeline = false })
			assert.equals(1, #deferred)
			assert.is_true(pcall(vim.api.nvim_exec_autocmds, "UIEnter", { group = "muster", modeline = false }))
			assert.equals(1, #notifications)
			assert.is_truthy(notifications[1]:find("runner module exploded", 1, true))

			package.preload["muster.runner"] = function()
				return {
					defer_start = function()
						requests = requests + 1
					end,
				}
			end
			deferred[1].callback()
			assert.equals(1, requests)
		end, debug.traceback)

		vim.defer_fn = original_defer_fn
		vim.notify = original_notify
		package.loaded["muster.runner"] = original_runner
		package.preload["muster.runner"] = original_preload
		vim.g.loaded_muster = original_loaded
		pcall(vim.api.nvim_del_user_command, "Muster")
		pcall(vim.api.nvim_del_augroup_by_name, "muster")
		if not ok then
			error(err, 0)
		end
	end)
end)
