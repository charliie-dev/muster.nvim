---The `:Muster` overlay.
---
---Not implemented yet — this is the next slice. The module exists so `:Muster`
---says so plainly instead of failing with a module-not-found traceback, and it
---points at the surface that already works.
---
---When it lands it must, per DESIGN.md: re-probe against the buffer it was
---invoked from (never render the cached VimEnter result), emit no report, and
---never enter the Mason hand-off — an inspection command must not install
---anything.

local M = {}

function M.open()
	vim.notify(
		"muster: the :Muster overlay is not implemented yet.\nUse :checkhealth muster in the meantime.",
		vim.log.levels.INFO,
		{ title = "muster" }
	)
end

return M
