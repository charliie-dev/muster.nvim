local M = {}

local FORMAT_RANGES = {
	{ 0x00AD, 0x00AD },
	{ 0x0600, 0x0605 },
	{ 0x061C, 0x061C },
	{ 0x06DD, 0x06DD },
	{ 0x070F, 0x070F },
	{ 0x0890, 0x0891 },
	{ 0x08E2, 0x08E2 },
	{ 0x180E, 0x180E },
	{ 0x200B, 0x200F },
	{ 0x202A, 0x202E },
	{ 0x2060, 0x2064 },
	{ 0x2066, 0x206F },
	{ 0xFEFF, 0xFEFF },
	{ 0xFFF9, 0xFFFB },
	{ 0x110BD, 0x110BD },
	{ 0x110CD, 0x110CD },
	{ 0x13430, 0x1343F },
	{ 0x1BCA0, 0x1BCA3 },
	{ 0x1D173, 0x1D17A },
	{ 0xE0001, 0xE0001 },
	{ 0xE0020, 0xE007F },
}

local function is_format_control(codepoint)
	for _, range in ipairs(FORMAT_RANGES) do
		if codepoint >= range[1] and codepoint <= range[2] then
			return true
		end
	end
	return false
end

local function decode(text, index)
	local first = text:byte(index)
	if not first or first < 0x80 then
		return first, 1
	end
	local length
	local codepoint
	if first >= 0xC2 and first <= 0xDF then
		length = 2
		codepoint = first - 0xC0
	elseif first >= 0xE0 and first <= 0xEF then
		length = 3
		codepoint = first - 0xE0
	elseif first >= 0xF0 and first <= 0xF4 then
		length = 4
		codepoint = first - 0xF0
	else
		return nil, 1
	end
	for offset = 1, length - 1 do
		local byte = text:byte(index + offset)
		if not byte or byte < 0x80 or byte > 0xBF then
			return nil, 1
		end
		codepoint = codepoint * 0x40 + byte - 0x80
	end
	return codepoint, length
end

local function strip_format_controls(text)
	local parts = {}
	local index = 1
	while index <= #text do
		local codepoint, length = decode(text, index)
		if not codepoint or not is_format_control(codepoint) then
			parts[#parts + 1] = text:sub(index, index + length - 1)
		end
		index = index + length
	end
	return table.concat(parts)
end

function M.sanitize(value, limit)
	local ok, text = pcall(tostring, value or "unknown")
	if not ok then
		text = "unknown"
	end
	text = strip_format_controls(text):gsub("[%z\1-\31\127]", "?")
	limit = limit or 200
	if #text > limit then
		text = text:sub(1, math.max(0, limit - 3)) .. "..."
	end
	return text
end

return M
