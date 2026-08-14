---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")
local registry = require("muster.registry")

local function fake(id, opts)
	opts = opts or {}
	return {
		id = id,
		available = function()
			return opts.available ~= false, opts.available == false and "host not loaded" or nil
		end,
		identity = opts.identity or tostring,
		probe = opts.probe or function(entry, bufnr)
			return {
				status = "found",
				binary = tostring(entry),
				path = ("/buf/%d/%s"):format(bufnr, tostring(entry)),
				realpath = ("/buf/%d/%s"):format(bufnr, tostring(entry)),
				source = "system",
			}
		end,
		live = opts.live,
	}
end

local function with_adapters(adapters, opts, fn)
	registry.reset()
	for _, adapter in ipairs(adapters) do
		registry.register(adapter)
	end
	local saved = registry.load_builtins
	registry.load_builtins = function()
		return {}
	end
	config.setup(opts or {})
	package.loaded["muster.overlay"] = nil
	local overlay = require("muster.overlay")
	local ok, err = pcall(fn, overlay)
	registry.load_builtins = saved
	config.reset()
	registry.reset()
	package.loaded["muster.overlay"] = nil
	if not ok then
		error(err, 0)
	end
end

local function names(entries)
	return vim.tbl_map(function(entry)
		return entry.adapter .. "/" .. entry.name
	end, entries)
end

local function protect(body, cleanup)
	local body_ok, body_err = xpcall(body, debug.traceback)
	local cleanup_ok, cleanup_err = xpcall(cleanup, debug.traceback)
	if not body_ok then
		if not cleanup_ok then
			body_err = body_err .. "\ncleanup also failed:\n" .. cleanup_err
		end
		error(body_err, 0)
	end
	if not cleanup_ok then
		error(cleanup_err, 0)
	end
end

local function cleanup_all(...)
	local errors = {}
	for index = 1, select("#", ...) do
		local action = select(index, ...)
		local ok, err = xpcall(action, debug.traceback)
		if not ok then
			errors[#errors + 1] = err
		end
	end
	if #errors > 0 then
		error(table.concat(errors, "\ncleanup also failed:\n"), 0)
	end
end

local function close_overlay(win, report_buf, source_buf)
	cleanup_all(function()
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, function()
		if report_buf and vim.api.nvim_buf_is_valid(report_buf) then
			vim.api.nvim_buf_delete(report_buf, { force = true })
		end
	end, function()
		if source_buf and vim.api.nvim_buf_is_valid(source_buf) then
			vim.api.nvim_buf_delete(source_buf, { force = true })
		end
	end)
end

describe("overlay spec cleanup", function()
	it("runs cleanup even when the protected body fails", function()
		local cleaned = false
		local ok = pcall(function()
			protect(function()
				error("deliberate body failure")
			end, function()
				cleaned = true
			end)
		end)
		assert.is_false(ok)
		assert.is_true(cleaned)
	end)

	it("preserves the body error when cleanup also fails", function()
		local cleaned = false
		local ok, err = pcall(function()
			protect(function()
				error("deliberate body failure")
			end, function()
				cleanup_all(function()
					error("deliberate cleanup failure")
				end, function()
					cleaned = true
				end)
			end)
		end)
		local body_error = err:find("deliberate body failure", 1, true)
		local cleanup_error = err:find("deliberate cleanup failure", 1, true)
		assert.is_false(ok)
		assert.is_true(cleaned)
		assert.is_truthy(body_error)
		assert.is_truthy(cleanup_error)
		assert.is_true(body_error < cleanup_error)
	end)

	it("restores overridden modules and overlay resources after an assertion failure", function()
		with_adapters({ fake("a") }, { a = { "tool" } }, function(overlay)
			local version = require("muster.version")
			local saved_resolve = version.resolve
			local saved_runner = package.loaded["muster.runner"]
			local source_buf, report_buf, win
			version.resolve = function(_, callback)
				callback({ value = "1.0.0", tier = 4 })
			end
			package.loaded["muster.runner"] = { start = function() end }

			local ok, err = pcall(function()
				protect(function()
					source_buf = vim.api.nvim_create_buf(false, true)
					report_buf, win = overlay.open(source_buf)
					error("deliberate overlay assertion failure")
				end, function()
					cleanup_all(function()
						error("deliberate first cleanup failure")
					end, function()
						version.resolve = saved_resolve
					end, function()
						package.loaded["muster.runner"] = saved_runner
					end, function()
						close_overlay(win, report_buf, source_buf)
					end)
				end)
			end)

			local resolver_restored = version.resolve == saved_resolve
			local runner_restored = package.loaded["muster.runner"] == saved_runner
			local window_closed = not win or not vim.api.nvim_win_is_valid(win)
			local report_deleted = not report_buf or not vim.api.nvim_buf_is_valid(report_buf)
			local source_deleted = not source_buf or not vim.api.nvim_buf_is_valid(source_buf)
			-- Defensive cleanup keeps this spec isolated even if an assertion below fails.
			version.resolve = saved_resolve
			package.loaded["muster.runner"] = saved_runner
			pcall(close_overlay, win, report_buf, source_buf)

			assert.is_false(ok)
			assert.is_truthy(err:find("deliberate overlay assertion failure", 1, true))
			assert.is_truthy(err:find("deliberate first cleanup failure", 1, true))
			assert.is_true(resolver_restored)
			assert.is_true(runner_restored)
			assert.is_true(window_closed)
			assert.is_true(report_deleted)
			assert.is_true(source_deleted)
		end)
	end)
end)

describe("overlay.collect", function()
	it("re-probes declared and live entries against the invoking buffer", function()
		local probed = {}
		local bufnr = vim.api.nvim_get_current_buf()
		local adapter = fake("a", {
			live = function(actual)
				assert.equals(bufnr, actual)
				return { "live-only" }
			end,
			probe = function(entry, actual_bufnr)
				probed[entry] = actual_bufnr
				return {
					status = "found",
					binary = entry,
					path = "/bin/" .. entry,
					realpath = "/bin/" .. entry,
					source = "system",
				}
			end,
		})
		with_adapters({ adapter }, { a = { "declared" } }, function(overlay)
			local view = overlay.collect(bufnr)
			assert.equals(bufnr, view.bufnr)
			assert.same({ declared = bufnr, ["live-only"] = bufnr }, probed)
		end)
	end)

	it("merges a declared live identity with declared=true winning", function()
		local adapter = fake("a", {
			live = function()
				return { "shared", "discovered" }
			end,
		})
		with_adapters({ adapter }, { a = { "shared", "elsewhere" } }, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({ "a/discovered", "a/shared" }, names(view.active))
			assert.same({ "a/elsewhere" }, names(view.other))
			assert.is_false(view.active[1].declared)
			assert.same({}, view.active[1].advice)
			assert.is_true(view.active[2].declared)
		end)
	end)

	it("puts every declared entry below when an adapter omits live", function()
		with_adapters({ fake("third_party") }, { third_party = { "x" } }, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({}, view.active)
			assert.same({ "third_party/x" }, names(view.other))
		end)
	end)

	it("surfaces a failed live query instead of rendering it as empty", function()
		local adapter = fake("a", {
			live = function()
				return {}, "foreign API exploded"
			end,
		})
		with_adapters({ adapter }, { a = { "x" } }, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.equals(1, #view.diagnostics)
			assert.is_truthy(view.diagnostics[1]:find("foreign API exploded", 1, true))
		end)
	end)

	it("contains raised live queries and identities without losing healthy entries", function()
		local query_error = fake("query_error", {
			live = function()
				error("query exploded")
			end,
		})
		local identity_error = fake("identity_error", {
			live = function()
				return { "broken" }
			end,
			identity = function()
				error("identity exploded")
			end,
		})
		local healthy = fake("healthy", {
			live = function()
				return { "ok" }
			end,
		})
		with_adapters({ query_error, identity_error, healthy }, {}, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({ "healthy/ok" }, names(view.active))
			assert.equals(2, #view.diagnostics)
			assert.is_truthy(view.diagnostics[1]:find("identity exploded", 1, true))
			assert.is_truthy(view.diagnostics[2]:find("query exploded", 1, true))
		end)
	end)

	it("reports an empty live identity instead of creating a blank row", function()
		local adapter = fake("a", {
			live = function()
				return { "nameless" }
			end,
			identity = function()
				return ""
			end,
		})
		with_adapters({ adapter }, {}, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({}, view.active)
			assert.equals(1, #view.diagnostics)
			assert.is_truthy(view.diagnostics[1]:find("non-empty string", 1, true))
		end)
	end)

	it("reports a map-shaped live result instead of treating it as empty", function()
		local adapter = fake("a", {
			live = function()
				return { tool = true }
			end,
		})
		with_adapters({ adapter }, {}, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.equals(1, #view.diagnostics)
			assert.is_truthy(view.diagnostics[1]:find("expected a list", 1, true))
		end)
	end)

	it("contains an invalid discovered probe and preserves healthy adapters", function()
		local bad = fake("bad", {
			live = function()
				return { "broken" }
			end,
			probe = function()
				return { status = "found" }
			end,
		})
		local good = fake("good", {
			live = function()
				return { "ok" }
			end,
		})
		with_adapters({ bad, good }, {}, function(overlay)
			local view = overlay.collect(vim.api.nvim_get_current_buf())
			assert.same({ "bad/broken", "good/ok" }, names(view.active))
			assert.equals("broken", view.active[1].probe.status)
			assert.equals("found", view.active[2].probe.status)
		end)
	end)
end)

describe("overlay.lines", function()
	it("renders the buffer header, both sections, row columns, and discovered marker", function()
		with_adapters({}, {}, function(overlay)
			local view = {
				bufnr = 12,
				filetype = "lua",
				active = {
					{
						adapter = "lsp",
						name = "lua_ls",
						declared = false,
						advice = {},
						probe = {
							status = "found",
							binary = "lua-language-server",
							path = "/mason/bin/lua-language-server",
							realpath = "/mason/packages/lua-language-server/bin/lua-language-server",
							source = "mason",
						},
					},
				},
				other = {
					{
						adapter = "conform",
						name = "prettier",
						declared = true,
						advice = {},
						probe = { status = "missing", binary = "prettier" },
					},
				},
				diagnostics = { "lint live query failed: boom" },
				notes = {},
			}
			local lines = overlay.lines(view, {
				["lsp\0lua_ls"] = { value = "3.19.0", tier = 1 },
			})
			local text = table.concat(lines, "\n")
			assert.is_truthy(text:find("lua  •  buf 12", 1, true))
			assert.is_truthy(text:find("ACTIVE IN THIS BUFFER", 1, true))
			assert.is_truthy(text:find("EVERYTHING ELSE", 1, true))
			assert.is_truthy(text:find("lua_ls*", 1, true))
			assert.is_truthy(text:find("lsp", 1, true))
			assert.is_truthy(text:find("mason", 1, true))
			assert.is_truthy(text:find("3.19.0", 1, true))
			assert.is_truthy(text:find("/mason/bin/lua-language-server", 1, true))
			assert.is_truthy(text:find("prettier", 1, true))
			assert.is_truthy(text:find("not on $PATH", 1, true))
			assert.is_truthy(text:find("* discovered live", 1, true))
			assert.is_truthy(text:find("lint live query failed: boom", 1, true))
		end)
	end)

	it("marks a found row when its version process cannot start", function()
		with_adapters({}, {}, function(overlay)
			local entry = {
				adapter = "lsp",
				name = "broken_ls",
				declared = true,
				advice = {},
				probe = {
					status = "found",
					binary = "broken-ls",
					path = "/bin/broken-ls",
					realpath = "/bin/broken-ls",
					source = "system",
				},
			}
			local text = table.concat(
				overlay.lines({
					bufnr = 3,
					filetype = "lua",
					active = { entry },
					other = {},
					diagnostics = {},
					notes = {},
				}, {
					["lsp\0broken_ls"] = { tier = 4, reason = "spawn failed" },
				}),
				"\n"
			)
			assert.is_truthy(text:find("[version probe failed]", 1, true))
		end)
	end)
end)

describe("overlay.open", function()
	it("opens a nofile floating report and fills versions asynchronously", function()
		local adapter = fake("a", {
			live = function()
				return { "tool" }
			end,
		})
		with_adapters({ adapter }, { a = { "tool" } }, function(overlay)
			local version = require("muster.version")
			local saved_resolve = version.resolve
			local finish
			local source_buf, report_buf, win
			version.resolve = function(_, callback)
				finish = callback
			end

			protect(function()
				source_buf = vim.api.nvim_create_buf(false, true)
				vim.bo[source_buf].filetype = "lua"
				report_buf, win = overlay.open(source_buf)
				assert.is_true(vim.api.nvim_win_is_valid(win))
				assert.equals("editor", vim.api.nvim_win_get_config(win).relative)
				assert.equals("nofile", vim.bo[report_buf].buftype)
				assert.equals("wipe", vim.bo[report_buf].bufhidden)
				assert.equals("muster://report", vim.api.nvim_buf_get_name(report_buf))
				assert.is_truthy(
					table.concat(vim.api.nvim_buf_get_lines(report_buf, 0, -1, false), "\n"):find("…", 1, true)
				)

				finish({ value = "9.8.7", tier = 4 })
				vim.wait(100, function()
					return table
						.concat(vim.api.nvim_buf_get_lines(report_buf, 0, -1, false), "\n")
						:find("9.8.7", 1, true) ~= nil
				end)
				assert.is_truthy(
					table.concat(vim.api.nvim_buf_get_lines(report_buf, 0, -1, false), "\n"):find("9.8.7", 1, true)
				)
			end, function()
				cleanup_all(function()
					version.resolve = saved_resolve
				end, function()
					close_overlay(win, report_buf, source_buf)
				end)
			end)
		end)
	end)

	it("defines and runs both buffer-local close mappings with pending versions", function()
		local adapter = fake("a", {
			live = function()
				return { "tool" }
			end,
		})
		with_adapters({ adapter }, { a = { "tool" } }, function(overlay)
			local version = require("muster.version")
			local saved_resolve = version.resolve
			local finish
			version.resolve = function(_, callback)
				finish = callback
			end

			protect(function()
				for _, lhs in ipairs({ "q", "<Esc>" }) do
					local source_buf, report_buf, win
					local current_win = vim.api.nvim_get_current_win()
					protect(function()
						source_buf = vim.api.nvim_create_buf(false, true)
						report_buf, win = overlay.open(source_buf)
						local mappings = vim.api.nvim_buf_get_keymap(report_buf, "n")
						assert.equals(2, #mappings)
						local matching = vim.tbl_filter(function(mapping)
							return mapping.lhs == lhs
						end, mappings)
						assert.equals(1, #matching)
						local mapping = matching[1]
						assert.equals(1, mapping.silent)
						assert.equals(1, mapping.nowait)
						assert.equals("Close Muster report", mapping.desc)
						vim.api.nvim_set_current_win(current_win)
						mapping.callback()
						mapping.callback()
						assert.is_false(vim.api.nvim_win_is_valid(win))
						assert.is_false(vim.api.nvim_buf_is_valid(report_buf))
						assert.is_true(vim.api.nvim_buf_is_valid(source_buf))
						assert.equals(current_win, vim.api.nvim_get_current_win())
						finish({ value = "late", tier = 4 })
						vim.wait(20)
					end, function()
						close_overlay(win, report_buf, source_buf)
					end)
				end
			end, function()
				version.resolve = saved_resolve
			end)
		end)
	end)

	it("resolves versions only for found rows and never starts the reporting runner", function()
		local adapter = fake("a", {
			live = function()
				return { "found", "missing" }
			end,
			probe = function(entry)
				if entry == "missing" then
					return { status = "missing", binary = "missing" }
				end
				return {
					status = "found",
					binary = entry,
					path = "/bin/" .. entry,
					realpath = "/bin/" .. entry,
					source = "system",
				}
			end,
		})
		with_adapters({ adapter }, { mason_install_fallback = true, a = { "found", "missing" } }, function(overlay)
			assert.is_nil(config.error())
			local version = require("muster.version")
			local saved_resolve = version.resolve
			local saved_runner = package.loaded["muster.runner"]
			local resolved = {}
			local report_buf, win
			version.resolve = function(entry, callback)
				resolved[#resolved + 1] = entry.name
				callback({ value = "1.0.0", tier = 4 })
			end
			package.loaded["muster.runner"] = {
				start = function()
					error("an inspection command must not emit or provision")
				end,
			}

			protect(function()
				report_buf, win = overlay.open(vim.api.nvim_get_current_buf())
				assert.same({ "found" }, resolved)
			end, function()
				cleanup_all(function()
					version.resolve = saved_resolve
				end, function()
					package.loaded["muster.runner"] = saved_runner
				end, function()
					close_overlay(win, report_buf)
				end)
			end)
		end)
	end)
end)
