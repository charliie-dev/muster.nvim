---@module 'luassert'
local assert = require("luassert")

local config = require("muster.config")

describe("config", function()
	before_each(function()
		config.reset()
	end)

	local function expected_ui_defaults()
		return {
			width = 0.8,
			height = 0.8,
			border = "rounded",
			backdrop = 60,
			icons = {
				found = "●",
				missing = "○",
				unknown = "?",
				broken = "×",
				unverifiable = "!",
				pending = "…",
				discovered = "*",
				expanded = "▾",
				collapsed = "▸",
			},
			labels = {
				title = "muster.nvim",
				tabs = { active = "Active", all = "All", issues = "Issues" },
				adapters = {
					lsp = "LSP",
					conform = "Formatter",
					nvim_lint = "Linter",
					dap = "DAP",
					none_ls = "none-ls",
				},
				columns = { status = "STATUS", tool = "TOOL", adapter = "TYPE", version = "VERSION" },
				details = {
					source = "source",
					executable = "executable",
					path = "path",
					realpath = "realpath",
					reason = "reason",
					advice = "advice",
				},
				empty = "No tools found.",
				no_matches = "No matching tools.",
				no_issues = "No issues found.",
				search_prompt = "Muster search: ",
				help = "Help",
			},
			keymaps = {
				close = { "q", "<Esc>" },
				active = "1",
				all = "2",
				issues = "3",
				next_tab = "<Tab>",
				previous_tab = "<S-Tab>",
				details = "<CR>",
				search = "/",
				help = "?",
				refresh = "r",
				copy_path = "y",
			},
		}
	end

	it("provides the exact complete dashboard UI defaults before and after setup", function()
		assert.same(expected_ui_defaults(), config.ui())
		config.setup({})
		assert.same(expected_ui_defaults(), config.ui())
	end)

	it("accepts an override for every public UI field including mixed tuple borders", function()
		local ui = {
			width = 72,
			height = 0.75,
			border = {
				"─",
				{ "│", "BorderSide" },
				"─",
				{ "│", "BorderSide" },
				{ "╭", "BorderCorner" },
				"╮",
				{ "╯", "BorderCorner" },
				"╰",
			},
			backdrop = 0,
			icons = {
				found = "F",
				missing = "M",
				unknown = "U",
				broken = "B",
				unverifiable = "V",
				pending = "P",
				discovered = "D",
				expanded = "E",
				collapsed = "C",
			},
			labels = {
				title = "Tools",
				tabs = { active = "Current", all = "Everything", issues = "Problems" },
				adapters = {
					lsp = "Language",
					conform = "Format",
					nvim_lint = "Lint",
					dap = "Debug",
					none_ls = "Sources",
					custom = "Custom",
				},
				columns = { status = "S", tool = "T", adapter = "A", version = "V" },
				details = {
					source = "from",
					executable = "exec",
					path = "path-name",
					realpath = "real-path",
					reason = "why",
					advice = "next",
				},
				empty = "Empty",
				no_matches = "No match",
				no_issues = "Clean",
				search_prompt = "Filter: ",
				help = "Keys",
			},
			keymaps = {
				close = { "x", "z" },
				active = "<F1>",
				all = "<F2>",
				issues = "<F3>",
				next_tab = "<F4>",
				previous_tab = "<F5>",
				details = "<F6>",
				search = "<F7>",
				help = false,
				refresh = { "<F8>", "R" },
				copy_path = "<F9>",
			},
		}
		config.setup({ ui = ui })
		assert.is_nil(config.error())
		assert.same(ui, config.ui())
	end)

	it("preserves defaults through each empty structural map override", function()
		local fixtures = {
			{},
			{ icons = {} },
			{ labels = {} },
			{ labels = { tabs = {} } },
			{ labels = { adapters = {} } },
			{ labels = { columns = {} } },
			{ labels = { details = {} } },
			{ keymaps = {} },
		}
		for index, ui in ipairs(fixtures) do
			config.setup({ ui = ui })
			assert.is_nil(config.error(), ("empty structural fixture %d must pass"):format(index))
			assert.same(expected_ui_defaults(), config.ui())
		end
	end)

	it("deep-merges partial UI maps while replacing list-valued keymaps", function()
		config.setup({
			ui = {
				width = 72,
				icons = { found = "+" },
				labels = { tabs = { active = "Current" }, adapters = { custom = "Custom" } },
				keymaps = { close = { "x" }, help = false },
			},
		})
		local ui = config.ui()
		assert.equals(72, ui.width)
		assert.equals(0.8, ui.height)
		assert.equals("+", ui.icons.found)
		assert.equals("Current", ui.labels.tabs.active)
		assert.equals("All", ui.labels.tabs.all)
		assert.equals("Custom", ui.labels.adapters.custom)
		assert.same({ "x" }, ui.keymaps.close)
		assert.is_false(ui.keymaps.help)
	end)

	it("isolates defaults, setup input, config.ui(), and config.get().ui snapshots", function()
		local before_setup = config.ui()
		before_setup.icons.found = "mutated default"
		before_setup.keymaps.close[1] = "mutated default"
		assert.same(expected_ui_defaults(), config.ui())

		local opts = { ui = { icons = { found = "+" }, keymaps = { close = { "x" } } } }
		config.setup(opts)
		opts.ui.icons.found = "mutated input"
		opts.ui.keymaps.close[1] = "mutated input"

		local from_ui = config.ui()
		from_ui.icons.found = "mutated ui snapshot"
		from_ui.keymaps.close[1] = "mutated ui snapshot"
		local from_get = config.get()
		from_get.ui.icons.found = "mutated get snapshot"
		from_get.ui.keymaps.close[1] = "mutated get snapshot"

		assert.equals("+", config.ui().icons.found)
		assert.same({ "x" }, config.ui().keymaps.close)
		assert.equals("+", config.get().ui.icons.found)
		assert.same({ "x" }, config.get().ui.keymaps.close)
	end)

	it("rejects non-table root UI values without retaining any candidate field", function()
		local invalid = { boolean = false, number = 7, string = "ui" }
		for name, ui in pairs(invalid) do
			config.setup({
				mason_install_fallback = true,
				notify_on_startup = false,
				lsp = { "lua_ls" },
				ui = ui,
			})
			assert.is_string(config.error(), name .. " root must fail")
			assert.is_false(config.get().mason_install_fallback)
			assert.is_true(config.get().notify_on_startup)
			assert.is_nil(config.list("lsp"))
			assert.same(expected_ui_defaults(), config.ui())
		end
	end)

	it("rejects malformed dashboard UI options and key collisions", function()
		local cyclic = {}
		cyclic.icons = cyclic
		local cyclic_border_part = { "│" }
		cyclic_border_part[2] = cyclic_border_part
		local sparse_border = { [1] = "─", [8] = "╰" }
		local cyclic_keymap = {}
		cyclic_keymap[1] = cyclic_keymap
		local overlong_character = "a" .. vim.fn.nr2char(0x0301):rep(8)
		assert.equals(17, #overlong_character)
		assert.equals(1, vim.fn.strdisplaywidth(overlong_character))
		local base_border = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }
		local invalid = {
			{ width = 0 },
			{ width = 0 / 0 },
			{ height = math.huge },
			{ border = "zigzag" },
			{ border = { "+" } },
			{ border = sparse_border },
			{ border = setmetatable(vim.deepcopy(base_border), {}) },
			{ border = { setmetatable({ "─", "Border" }, {}), unpack(base_border, 2) } },
			{ border = { overlong_character, unpack(base_border, 2) } },
			{ border = { "界", unpack(base_border, 2) } },
			{ border = { { "─", string.rep("H", 129) }, unpack(base_border, 2) } },
			{ border = { { "─", "Bad\nHighlight" }, unpack(base_border, 2) } },
			{ border = { { "─", vim.fn.nr2char(0x202E) }, unpack(base_border, 2) } },
			{ border = { { "─", "Border", "extra" }, unpack(base_border, 2) } },
			{ border = { cyclic_border_part, unpack(base_border, 2) } },
			{ backdrop = -1 },
			{ backdrop = 101 },
			{ backdrop = 1.5 },
			{ icons = { found = 1 } },
			{ icons = { found = string.rep("x", 33) } },
			{ icons = { found = "\n" } },
			{ labels = { tabs = { active = 1 } } },
			{ labels = { tabs = { active = string.rep("x", 129) } } },
			{ labels = { tabs = { active = vim.fn.nr2char(0x202E) } } },
			{ labels = { adapters = { custom = string.rep("x", 129) } } },
			{ labels = { adapters = { [""] = "Empty" } } },
			{ labels = { adapters = { [1] = "Numeric" } } },
			{ keymaps = { close = "" } },
			{ keymaps = { close = {} } },
			{ keymaps = { close = { "q", "" } } },
			{ keymaps = { close = setmetatable({ "q" }, {}) } },
			{ keymaps = { close = cyclic_keymap } },
			{ keymaps = { close = { [1] = "q", [3] = "x" } } },
			{ keymaps = { close = { "q", "q" } } },
			{ keymaps = { close = "q", help = "q" } },
			{ keymaps = { close = "<Tab>", next_tab = "<C-I>" } },
			{ keymaps = { close = "<Esc>", help = "<C-[>" } },
			{ keymaps = { close = string.rep("x", 51) } },
			{ keymaps = { close = string.rep("x", 65) } },
			{ keymaps = { close = "x\ny" } },
			setmetatable({ width = 0.8 }, {}),
			cyclic,
			{ "positional UI is invalid" },
			{ unexpected = true },
		}
		for index, ui in ipairs(invalid) do
			config.setup({
				mason_install_fallback = true,
				notify_on_startup = false,
				lsp = { "lua_ls" },
				ui = ui,
			})
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
			assert.is_false(config.get().mason_install_fallback)
			assert.is_true(config.get().notify_on_startup)
			assert.is_nil(config.list("lsp"))
			assert.same(expected_ui_defaults(), config.ui())
		end
	end)

	local function prohibited_ui_texts()
		local hostile = {}
		for codepoint = 0x00, 0x1F do
			hostile[#hostile + 1] = codepoint == 0 and "\0" or vim.fn.nr2char(codepoint)
		end
		hostile[#hostile + 1] = vim.fn.nr2char(0x7F)
		for codepoint = 0x80, 0x9F do
			hostile[#hostile + 1] = vim.fn.nr2char(codepoint)
		end
		for _, codepoint in ipairs({
			0x061C,
			0x200E,
			0x200F,
			0x202A,
			0x202B,
			0x202C,
			0x202D,
			0x202E,
			0x2066,
			0x2067,
			0x2068,
			0x2069,
		}) do
			hostile[#hostile + 1] = vim.fn.nr2char(codepoint)
		end
		return hostile
	end

	it("rejects unknown keys and non-plain nested UI containers", function()
		local cyclic_labels = {}
		cyclic_labels.tabs = cyclic_labels
		local invalid = {
			{ icons = { found = "x", extra = "x" } },
			{ icons = setmetatable({ found = "x" }, {}) },
			{ labels = { title = "x", extra = "x" } },
			{ labels = setmetatable({ title = "x" }, {}) },
			{ labels = cyclic_labels },
			{ labels = { tabs = { active = "x", extra = "x" } } },
			{ labels = { tabs = setmetatable({ active = "x" }, {}) } },
			{ labels = { adapters = setmetatable({ custom = "Custom" }, {}) } },
			{ labels = { adapters = { custom = {} } } },
			{ labels = { columns = { status = "x", extra = "x" } } },
			{ labels = { columns = setmetatable({ status = "x" }, {}) } },
			{ labels = { details = { source = "x", extra = "x" } } },
			{ labels = { details = setmetatable({ source = "x" }, {}) } },
			{ keymaps = { close = "x", extra = "x" } },
			{ keymaps = setmetatable({ close = "x" }, {}) },
		}
		for index, ui in ipairs(invalid) do
			config.setup({ ui = ui })
			assert.is_string(config.error(), ("nested fixture %d must fail"):format(index))
		end
	end)

	it("rejects every prohibited code point in every UI text-value category", function()
		for text_index, text in ipairs(prohibited_ui_texts()) do
			local categories = {
				{ icons = { found = text } },
				{ labels = { title = text } },
				{ labels = { adapters = { custom = text } } },
				{ keymaps = { close = text } },
			}
			for category_index, ui in ipairs(categories) do
				config.setup({ ui = ui })
				assert.is_string(
					config.error(),
					("text fixture %d category %d must fail"):format(text_index, category_index)
				)
			end
		end
	end)

	it("keeps adapter label keys aligned with the existing registry ID rule", function()
		local c1 = vim.fn.nr2char(0x80)
		local bidi = vim.fn.nr2char(0x202E)
		local boundary = string.rep("k", 128)
		local overlong = string.rep("k", 129)
		config.setup({
			ui = { labels = { adapters = { [c1] = "C1", [bidi] = "Bidi", [boundary] = "Boundary" } } },
		})
		assert.is_nil(config.error())
		assert.equals("C1", config.ui().labels.adapters[c1])
		assert.equals("Bidi", config.ui().labels.adapters[bidi])
		assert.equals("Boundary", config.ui().labels.adapters[boundary])

		config.setup({ ui = { labels = { adapters = { [overlong] = "Rejected" } } } })
		assert.is_string(config.error())

		local rejected = { "\0", vim.fn.nr2char(0x7F) }
		for codepoint = 0x01, 0x1F do
			rejected[#rejected + 1] = vim.fn.nr2char(codepoint)
		end
		for index, key in ipairs(rejected) do
			config.setup({ ui = { labels = { adapters = { [key] = "Rejected" } } } })
			assert.is_string(config.error(), ("adapter key fixture %d must fail"):format(index))
		end
	end)

	it("never reflects permitted C1 or bidi adapter keys in label-value errors", function()
		local keys = {}
		for codepoint = 0x80, 0x9F do
			keys[#keys + 1] = vim.fn.nr2char(codepoint)
		end
		for _, codepoint in ipairs({
			0x061C,
			0x200E,
			0x200F,
			0x202A,
			0x202B,
			0x202C,
			0x202D,
			0x202E,
			0x2066,
			0x2067,
			0x2068,
			0x2069,
		}) do
			keys[#keys + 1] = vim.fn.nr2char(codepoint)
		end

		local saved_notify = vim.notify
		local ok, err = xpcall(function()
			for index, key in ipairs(keys) do
				local notifications = {}
				vim.notify = function(message)
					notifications[#notifications + 1] = tostring(message)
				end
				config.reset()
				config.setup({ ui = { labels = { adapters = { [key] = "rejected\nlabel" } } } })
				local config_error = assert(config.error(), ("adapter key fixture %d must fail"):format(index))
				assert.equals(1, #notifications)
				assert.is_nil(config_error:find(key, 1, true), ("config error leaked key fixture %d"):format(index))
				assert.is_nil(notifications[1]:find(key, 1, true), ("notification leaked key fixture %d"):format(index))
			end
		end, debug.traceback)
		vim.notify = saved_notify
		assert.is_true(ok, err)
	end)

	it("rejects every control and bidi code point in border text", function()
		local base = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }
		for index, text in ipairs(prohibited_ui_texts()) do
			local plain = vim.deepcopy(base)
			plain[1] = text
			config.setup({ ui = { border = plain } })
			assert.is_string(config.error(), ("plain border fixture %d must fail"):format(index))

			local tuple = vim.deepcopy(base)
			tuple[1] = { "─", text }
			config.setup({ ui = { border = tuple } })
			assert.is_string(config.error(), ("tuple highlight fixture %d must fail"):format(index))
		end
	end)

	it("rejects the entire setup candidate when UI validation fails", function()
		config.setup({
			mason_install_fallback = true,
			notify_on_startup = false,
			lsp = { "lua_ls" },
			conform = { "stylua" },
			ui = { width = 0 },
		})
		assert.is_string(config.error())
		assert.is_false(config.get().mason_install_fallback)
		assert.is_true(config.get().notify_on_startup)
		assert.is_nil(config.list("lsp"))
		assert.is_nil(config.list("conform"))
		assert.same(expected_ui_defaults(), config.ui())
	end)

	it("accepts exact custom-border text limits", function()
		local character = "a" .. vim.fn.nr2char(0x0301):rep(6) .. vim.fn.nr2char(0x20DD)
		local highlight = "H" .. string.rep("x", 127)
		assert.equals(16, #character)
		assert.equals(1, vim.fn.strdisplaywidth(character))
		assert.equals(128, #highlight)

		local plain = { character, "│", "─", "│", "╭", "╮", "╯", "╰" }
		config.setup({ ui = { border = plain } })
		assert.is_nil(config.error())
		assert.same(plain, config.ui().border)

		local tuple = { { character, highlight }, "│", "─", "│", "╭", "╮", "╯", "╰" }
		config.setup({ ui = { border = tuple } })
		assert.is_nil(config.error())
		assert.same(tuple, config.ui().border)
	end)

	it("accepts exact icon, label, adapter-label, and keymap text limits", function()
		local icon = string.rep("i", 32)
		local label = string.rep("l", 128)
		local adapter_label = string.rep("a", 128)
		local keymap = ("<F1>"):rep(16)
		assert.equals(64, #keymap)
		assert.equals(48, #vim.keycode(keymap))
		config.setup({
			ui = {
				icons = { found = icon },
				labels = { title = label, adapters = { custom = adapter_label } },
				keymaps = { close = keymap },
			},
		})
		assert.is_nil(config.error())
		local ui = config.ui()
		assert.equals(icon, ui.icons.found)
		assert.equals(label, ui.labels.title)
		assert.equals(adapter_label, ui.labels.adapters.custom)
		assert.equals(keymap, ui.keymaps.close)

		local bufnr = vim.api.nvim_create_buf(false, true)
		local ok, err = xpcall(function()
			vim.keymap.set("n", keymap, function() end, { buffer = bufnr })
			vim.keymap.del("n", keymap, { buffer = bufnr })
		end, debug.traceback)
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		assert.is_true(ok, err)
	end)

	it("accepts all documented scalar, border, text, and keymap shapes", function()
		local borders = { "none", "single", "double", "rounded", "solid", "shadow" }
		for _, border in ipairs(borders) do
			config.setup({ ui = { border = border } })
			assert.is_nil(config.error(), border .. " border must pass")
			assert.equals(border, config.ui().border)
		end

		local border = { "─", "│", "─", "│", "╭", "╮", "╯", "╰" }
		config.setup({
			ui = {
				width = 120,
				height = 42,
				border = border,
				backdrop = 100,
				icons = { found = "" },
				labels = { title = "", adapters = { ["adapter + printable"] = "" } },
				keymaps = { close = { "x", "z" }, help = false },
			},
		})
		assert.is_nil(config.error())
		assert.same(border, config.ui().border)
		assert.equals(120, config.ui().width)
		assert.equals(42, config.ui().height)
		assert.equals(100, config.ui().backdrop)
		assert.equals("", config.ui().icons.found)
		assert.equals("", config.ui().labels.title)
		assert.equals("", config.ui().labels.adapters["adapter + printable"])
		assert.same({ "x", "z" }, config.ui().keymaps.close)
		assert.is_false(config.ui().keymaps.help)

		config.setup({ ui = { width = 0.1, height = 0.1, backdrop = 0 } })
		assert.is_nil(config.error())
		assert.equals(0.1, config.ui().width)
		assert.equals(0.1, config.ui().height)
		assert.equals(0, config.ui().backdrop)
	end)

	it("installs accepted keymap lhs values in a scratch buffer", function()
		config.setup({
			ui = {
				keymaps = {
					close = { "q", "<Esc>" },
					active = "<F1>",
					all = false,
					issues = "<F3>",
					next_tab = "<Tab>",
					previous_tab = "<S-Tab>",
					details = "<CR>",
					search = "/",
					help = "?",
					refresh = { "r", "R" },
					copy_path = "y",
				},
			},
		})
		assert.is_nil(config.error())

		local bufnr = vim.api.nvim_create_buf(false, true)
		local ok, err = pcall(function()
			for _, mapping in pairs(config.ui().keymaps) do
				if mapping ~= false then
					local lhs_values = type(mapping) == "table" and mapping or { mapping }
					for _, lhs in ipairs(lhs_values) do
						vim.keymap.set("n", lhs, function() end, { buffer = bufnr })
					end
				end
			end
		end)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		assert.is_true(ok, err)
	end)

	it("is nil until setup() runs, so the automatic check can stay silent", function()
		assert.is_nil(config.get())
		config.setup({})
		assert.is_table(config.get())
	end)

	it("accepts nil as defaults but rejects false", function()
		config.setup(nil)
		assert.is_nil(config.error())
		assert.is_false(config.get().mason_install_fallback)

		config.setup(false)
		assert.is_string(config.error())
		assert.is_false(config.get().mason_install_fallback)
	end)

	it("defaults Mason installation fallback to false and the startup notification to on", function()
		config.setup({})
		assert.is_false(config.get().mason_install_fallback)
		assert.is_true(config.get().notify_on_startup)
	end)

	it("accepts only booleans for mason_install_fallback", function()
		for _, value in ipairs({ true, false }) do
			config.setup({ mason_install_fallback = value })
			assert.equals(value, config.get().mason_install_fallback)
			assert.is_nil(config.error())
		end
		config.setup({ mason_install_fallback = "mason" })
		assert.is_string(config.error(), "a rejection must be recorded")
	end)

	it("always rejects the install tombstone with migration guidance", function()
		for _, value in ipairs({ false, true, "mason", {} }) do
			config.setup({ install = value })
			assert.is_truthy(config.error():find("`install` was removed", 1, true))
			assert.is_truthy(config.error():find("mason_install_fallback", 1, true))
		end
	end)

	it("keeps a usable config after a rejection, so health can tell the two apart", function()
		-- A nil config means "setup was never called", which would send a user
		-- who did call it to fix the one thing that is not wrong.
		config.setup({ conform = "stylua" })
		assert.is_table(config.get(), "the config must not be left nil")
		assert.is_string(config.error())
		assert.is_nil(config.list("conform"), "the rejected list must not be used")
	end)

	it("clears a previous rejection on a later valid setup", function()
		config.setup({ conform = "stylua" })
		assert.is_string(config.error())
		config.setup({ conform = { "stylua" } })
		assert.is_nil(config.error())
		assert.same({ "stylua" }, config.list("conform"))
	end)

	it("returns a declared list by adapter id, and nil when the key is absent", function()
		config.setup({ conform = { "stylua" } })
		assert.same({ "stylua" }, config.list("conform"))
		assert.is_nil(config.list("lint"))
	end)

	it("never mistakes option or tombstone keys for tool lists", function()
		config.setup({ mason_install_fallback = true })
		assert.is_nil(config.list("mason_install_fallback"))
		assert.is_nil(config.list("install"))
	end)

	it("accepts valid LSP strings and explicit command maps", function()
		config.setup({
			lsp = {
				"lua_ls",
				{ name = "jsonls", command = "vscode-json-language-server" },
				{ name = "server.name-1", command = "server_name+1.0" },
			},
		})
		assert.is_nil(config.error())
	end)

	it("rejects invalid LSP declaration shapes and grammar", function()
		local metatable_entry = setmetatable({ name = "jsonls", command = "jsonls" }, {})
		local fixtures = {
			7,
			{},
			{ name = "jsonls" },
			{ command = "jsonls" },
			{ name = "jsonls", command = "jsonls", extra = true },
			{ name = "jsonls", command = "jsonls", [1] = "extra" },
			{ name = 7, command = "jsonls" },
			{ name = "jsonls", command = 7 },
			metatable_entry,
			"*",
			"bad name",
			"/absolute",
			string.rep("n", 129),
			{ name = "jsonls", command = "bad command" },
			{ name = "jsonls", command = "bin/server" },
			{ name = "jsonls", command = "bin\\server" },
			{ name = "jsonls", command = "bad\ncommand" },
			{ name = "jsonls", command = string.rep("c", 256) },
		}
		for index, entry in ipairs(fixtures) do
			config.setup({ lsp = { entry } })
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
		end
	end)

	it("rejects ambiguous duplicate LSP declarations independent of order", function()
		local fixtures = {
			{ "jsonls", { name = "jsonls", command = "jsonls" } },
			{ { name = "jsonls", command = "jsonls" }, "jsonls" },
			{
				{ name = "jsonls", command = "jsonls-a" },
				{ name = "jsonls", command = "jsonls-b" },
			},
			{
				{ name = "jsonls", command = "jsonls-b" },
				{ name = "jsonls", command = "jsonls-a" },
			},
		}
		for index, entries in ipairs(fixtures) do
			config.setup({ lsp = entries })
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
		end
	end)

	it("leaves identical duplicate LSP declarations to the existing duplicate warning", function()
		config.setup({
			lsp = {
				"lua_ls",
				"lua_ls",
				{ name = "jsonls", command = "jsonls" },
				{ name = "jsonls", command = "jsonls" },
			},
		})
		assert.is_nil(config.error())
	end)

	it("copies setup input before validation and storage", function()
		local opts = {
			mason_install_fallback = true,
			conform = { "stylua" },
			lsp = { { name = "jsonls", command = "vscode-json-language-server" } },
		}
		config.setup(opts)
		opts.mason_install_fallback = false
		opts.conform[1] = "prettier"
		opts.lsp[1].name = "mutated"
		opts.lsp[1].command = "mutated"

		local snapshot = config.get()
		assert.is_true(snapshot.mason_install_fallback)
		assert.same({ "stylua" }, snapshot.conform)
		assert.same({ { name = "jsonls", command = "vscode-json-language-server" } }, snapshot.lsp)
	end)

	it("preserves opaque adapter entry identity while isolating list containers", function()
		local timer = assert(vim.uv.new_timer())
		local opaque = setmetatable({ value = 1 }, { __index = { marker = true } })
		local thread = coroutine.create(function() end)
		local opts = { third_party = { timer, opaque, thread } }
		local ok, err = pcall(function()
			config.setup(opts)
			assert.is_nil(config.error())
			opts.third_party[1] = "caller mutation"

			local first = config.list("third_party")
			assert.equals(timer, first[1])
			assert.equals(opaque, first[2])
			assert.equals(thread, first[3])
			first[1] = "list mutation"

			local from_get = config.get().third_party
			assert.equals(timer, from_get[1])
			assert.equals(opaque, from_get[2])
			assert.equals(thread, from_get[3])
			from_get[2] = "get mutation"
			assert.equals(opaque, config.list("third_party")[2])

			opaque.value = 2
			assert.equals(2, config.list("third_party")[2].value)
		end)
		pcall(timer.close, timer)
		assert.is_true(ok, err)
	end)

	it("returns independent get and list snapshots", function()
		config.setup({
			mason_install_fallback = true,
			conform = { "stylua" },
			lsp = { { name = "jsonls", command = "vscode-json-language-server" } },
		})
		local first = config.get()
		first.mason_install_fallback = false
		first.conform[1] = "prettier"
		first.lsp[1].command = "mutated"
		local conform = config.list("conform")
		conform[1] = "mutated"
		local lsp = config.list("lsp")
		lsp[1].name = "mutated"

		local second = config.get()
		assert.is_true(second.mason_install_fallback)
		assert.same({ "stylua" }, second.conform)
		assert.same({ { name = "jsonls", command = "vscode-json-language-server" } }, second.lsp)
		assert.same({ "stylua" }, config.list("conform"))
		assert.same({ { name = "jsonls", command = "vscode-json-language-server" } }, config.list("lsp"))
	end)

	it("accepts and snapshots structured nvim-lint declarations", function()
		local opts = {
			nvim_lint = { "selene", { name = "oxlint", command = "oxlint" } },
		}
		config.setup(opts)
		assert.is_nil(config.error())
		opts.nvim_lint[2].command = "mutated"
		local first = config.get()
		first.nvim_lint[2].name = "mutated"
		local listed = config.list("nvim_lint")
		listed[2].command = "mutated"
		assert.same({ "selene", { name = "oxlint", command = "oxlint" } }, config.get().nvim_lint)
		assert.same({ "selene", { name = "oxlint", command = "oxlint" } }, config.list("nvim_lint"))
	end)

	it("rejects invalid nvim-lint declarations and conflicting duplicates", function()
		local metatable_entry = setmetatable({ name = "oxlint", command = "oxlint" }, {})
		local invalid = {
			7,
			{},
			{ name = "oxlint" },
			{ command = "oxlint" },
			{ name = "oxlint", command = "oxlint", extra = true },
			{ name = "bad name", command = "oxlint" },
			{ name = "oxlint", command = "bin/oxlint" },
			metatable_entry,
		}
		for index, entry in ipairs(invalid) do
			config.setup({ nvim_lint = { entry } })
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
		end
		for _, entries in ipairs({
			{ "oxlint", { name = "oxlint", command = "oxlint" } },
			{ { name = "oxlint", command = "oxlint" }, "oxlint" },
			{ { name = "oxlint", command = "a" }, { name = "oxlint", command = "b" } },
			{ { name = "oxlint", command = "b" }, { name = "oxlint", command = "a" } },
		}) do
			config.setup({ nvim_lint = entries })
			assert.is_string(config.error())
		end
	end)

	it("keeps identical nvim-lint duplicates for the normal duplicate warning", function()
		config.setup({
			nvim_lint = {
				"selene",
				"selene",
				{ name = "oxlint", command = "oxlint" },
				{ name = "oxlint", command = "oxlint" },
			},
		})
		assert.is_nil(config.error())
	end)

	it("rejects malformed Conform formatter lists", function()
		local fixtures = {
			{ "" },
			{ "bad\nname" },
			{ string.rep("x", 129) },
			{ { name = "stylua" } },
			setmetatable({ "stylua" }, {}),
		}
		for index, conform in ipairs(fixtures) do
			config.setup({ conform = conform })
			assert.is_string(config.error(), ("fixture %d must be rejected"):format(index))
		end
	end)

	it("always rejects the old lint setup tombstone", function()
		for _, value in ipairs({ {}, { "selene" }, false, "selene" }) do
			config.setup({ lint = value })
			assert.is_truthy(config.error():find("nvim_lint", 1, true))
			assert.is_nil(config.list("lint"))
		end
	end)

	it("keeps reserved option authority private", function()
		assert.is_nil(config.OPTIONS)
		assert.is_true(config.is_option("install"))
		assert.is_true(config.is_option("lint"))
		assert.is_true(config.is_option("mason_install_fallback"))
		assert.is_true(config.is_option("ui"))
		assert.is_false(config.is_option("nvim_lint"))
	end)
end)
