local ok, findings = pcall(function()
	local script_path = debug.getinfo(1, "S").source:sub(2)
	local scripts_dir = vim.fs.dirname(script_path)
	package.path = scripts_dir .. "/?.lua;" .. package.path

	local audit = require("debug_call_audit")
	if type(audit) ~= "table" or type(audit.scan) ~= "function" then
		error("invalid debug-call audit module", 0)
	end

	local paths = {}
	for index = 1, #arg do
		paths[#paths + 1] = arg[index]
	end

	local scan_findings = audit.scan(paths)
	if type(scan_findings) ~= "table" or getmetatable(scan_findings) ~= nil then
		error("invalid debug-call audit result", 0)
	end

	local finding_count = 0
	for index in pairs(scan_findings) do
		if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then
			error("invalid debug-call audit result", 0)
		end
		finding_count = finding_count + 1
	end

	local validated_findings = {}
	for index = 1, finding_count do
		local finding = rawget(scan_findings, index)
		if type(finding) ~= "table" or getmetatable(finding) ~= nil then
			error("invalid debug-call audit finding", 0)
		end

		local path = finding.path
		local line = finding.line
		local kind = finding.kind
		if type(path) ~= "string" or path == "" then
			error("invalid debug-call audit finding", 0)
		end
		if type(line) ~= "number" or line <= 0 or line % 1 ~= 0 then
			error("invalid debug-call audit finding", 0)
		end
		if kind ~= "print" and kind ~= "vim.print" then
			error("invalid debug-call audit finding", 0)
		end

		validated_findings[index] = {
			path = path,
			line = line,
			kind = kind,
		}
	end

	return validated_findings
end)

if not ok then
	vim.api.nvim_err_writeln("debug-call audit failed")
	os.exit(2)
end

local function sanitize_path(path)
	return (path:gsub("%c", function(character)
		return ("\\x%02x"):format(character:byte())
	end))
end

if #findings > 0 then
	for _, finding in ipairs(findings) do
		vim.api.nvim_err_writeln(
			("debug-call finding: %s:%d: %s()"):format(sanitize_path(finding.path), finding.line, finding.kind)
		)
	end
	vim.api.nvim_err_writeln("debug-call audit failed: leftover debug calls found")
	os.exit(1)
end
