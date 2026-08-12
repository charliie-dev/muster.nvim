---Internal automatic startup pipeline.
---This is the only path allowed to refresh Mason or execute its hand-off.

local M = {}

local current = { state = "idle" }

local function sanitize(value, limit)
	local ok, text = pcall(tostring, value or "unknown")
	if not ok then
		text = "unknown"
	end
	text = text:gsub("[%z\1-\31\127]", "?")
	limit = limit or 200
	if #text > limit then
		text = text:sub(1, limit - 3) .. "..."
	end
	return text
end

local function append_note(result, message)
	result.notes = result.notes or {}
	result.notes[#result.notes + 1] = message
end

local function dependency(opts, key, fallback)
	if opts[key] ~= nil then
		return opts[key]
	end
	return fallback()
end

local function notify_failure(opts, err)
	local notify = dependency(opts, "notify", function()
		return vim.notify
	end)
	pcall(
		notify,
		("muster: the startup check failed: %s"):format(sanitize(err)),
		vim.log.levels.ERROR,
		{ title = "muster" }
	)
end

---Schedule work only after the selected scheduling API has returned successfully.
---The accept callback claims settlement before a synchronously invoked bridge can
---run the continuation.
local function bridge(opts, continuation, accept)
	local schedule = dependency(opts, "schedule", function()
		return vim.schedule
	end)
	local defer = dependency(opts, "defer", function()
		return function(callback)
			vim.defer_fn(callback, 0)
		end
	end)

	local function attempt(invoke)
		local accepted = false
		local requested = false
		local function wrapped()
			if accepted then
				continuation()
			else
				requested = true
			end
		end
		local ok = pcall(invoke, wrapped)
		if not ok then
			return false
		end
		accepted = true
		accept()
		if requested then
			continuation()
		end
		return true
	end

	if attempt(schedule) then
		return true
	end
	return attempt(defer)
end

local function production_opts(opts)
	opts = opts or {}
	local config = opts.config or require("muster.config").get() or { install = false }
	return opts, config
end

---@param callback? fun(result: muster.Result, status: table)
---@param opts? table
function M.run(callback, opts)
	local config
	opts, config = production_opts(opts)
	current = { state = "running" }
	local completed = false

	local function complete(result, state, reason)
		if completed or current.state == "bridge_failed" then
			return
		end
		completed = true
		current = reason and { state = state, reason = sanitize(reason) } or { state = state }
		if callback then
			pcall(callback, result, M.status())
		end
	end
	local function reported(result, reason)
		complete(result, "reported", reason)
	end
	local function failed(result, reason)
		complete(result, "failed", reason)
	end

	local report = dependency(opts, "report", function()
		return require("muster.report").emit
	end)
	local function emit(result, plan, reported_reason)
		local ok, err = pcall(report, result)
		if not ok then
			notify_failure(opts, err)
			failed(result, err)
			return
		end
		if plan then
			local ok_execute, execute_err = pcall(function()
				local handoff = dependency(opts, "handoff", function()
					return require("muster.handoff.mason")
				end)
				handoff.execute(plan)
			end)
			if not ok_execute then
				notify_failure(opts, execute_err)
			end
		end
		reported(result, reported_reason)
	end

	if config.install ~= "mason" then
		local check = dependency(opts, "check", function()
			return require("muster").check
		end)
		local delivered = false
		local check_returned = false
		local buffered_result
		local function checked(result)
			if delivered or buffered_result then
				return
			end
			if not check_returned then
				buffered_result = result
				return
			end
			delivered = true
			emit(result)
		end
		local ok, err = pcall(check, nil, checked)
		check_returned = true
		if not ok then
			buffered_result = nil
			notify_failure(opts, err)
			failed(nil, err)
		elseif buffered_result then
			delivered = true
			emit(buffered_result)
		end
		return
	end

	local probe = dependency(opts, "probe", function()
		return require("muster").probe
	end)
	local ok_probe, result = pcall(probe)
	if not ok_probe then
		notify_failure(opts, result)
		failed(nil, result)
		return
	end

	local enrich = dependency(opts, "enrich", function()
		return require("muster.enrich").run
	end)
	local function enrich_report(allow_handoff, reason)
		local delivered = false
		local ok, err = pcall(enrich, result, function(enriched)
			if delivered then
				return
			end
			delivered = true
			result = enriched
			local plan
			if allow_handoff then
				local handoff = dependency(opts, "handoff", function()
					return require("muster.handoff.mason")
				end)
				local ok_prepare, prepared = pcall(handoff.prepare, result)
				if ok_prepare then
					plan = prepared
				else
					append_note(result, "Mason hand-off prepare failed: " .. sanitize(prepared))
				end
			end
			emit(result, plan, reason)
		end)
		if not ok and not delivered then
			append_note(result, "enrichment failed: " .. sanitize(err))
			emit(result, nil, reason)
		end
	end

	local mason = opts.mason
	if mason == nil then
		mason = package.loaded["mason"]
	end
	local registry = opts.registry
	if registry == nil then
		registry = package.loaded["mason-registry"]
	end
	if type(mason) ~= "table" then
		append_note(result, "Mason is not loaded; automatic refresh and installation were skipped")
		enrich_report(false)
		return
	end
	if mason.has_setup ~= true then
		append_note(result, "Mason has not been set up; automatic refresh and installation were skipped")
		enrich_report(false)
		return
	end
	if type(registry) ~= "table" or type(registry.refresh) ~= "function" then
		append_note(result, "Mason registry is not loaded; automatic refresh and installation were skipped")
		enrich_report(false)
		return
	end

	local timer_factory = dependency(opts, "timer_factory", function()
		return vim.uv.new_timer
	end)
	local ok_timer, timer = pcall(timer_factory)
	if not ok_timer or timer == nil then
		local reason = "Mason refresh watchdog setup failed: " .. sanitize(ok_timer and "timer unavailable" or timer)
		append_note(result, reason)
		enrich_report(false, reason)
		return
	end

	local timer_started = false
	local timer_closed = false
	local function close_timer()
		if timer_closed then
			return
		end
		timer_closed = true
		if timer_started then
			pcall(timer.stop, timer)
		end
		pcall(timer.close, timer)
	end

	local settled = false
	local function bridge_failed(reason)
		if settled then
			return
		end
		settled = true
		close_timer()
		current = { state = "bridge_failed", reason = sanitize(reason) }
	end

	local function settle(kind, detail)
		if settled then
			return
		end
		local function accept()
			if settled then
				return
			end
			settled = true
			close_timer()
		end
		local accepted = bridge(opts, function()
			if current.state == "bridge_failed" then
				return
			end
			if kind == "success" then
				enrich_report(true)
			else
				local note
				if kind == "timeout" then
					note = "Mason registry refresh timed out after 30 seconds"
				else
					note = "Mason registry refresh failed: " .. sanitize(detail)
				end
				append_note(result, note)
				enrich_report(false, note)
			end
		end, accept)
		if not accepted then
			bridge_failed("Mason refresh safe-context bridge failed")
		end
	end

	local timer_ready = false
	-- Treat start as owning the handle before entering foreign code: if it starts
	-- work and then raises, protected stop/close must still run exactly once.
	timer_started = true
	local ok_start, start_err = pcall(function()
		timer:start(30000, 0, function()
			if timer_ready then
				settle("timeout")
			end
		end)
	end)
	if not ok_start then
		close_timer()
		local reason = "Mason refresh watchdog setup failed: " .. sanitize(start_err)
		append_note(result, reason)
		enrich_report(false, reason)
		return
	end
	timer_ready = true

	local refresh_returned = false
	local callback_seen = false
	local callback_ok, callback_err
	local function refreshed(ok, err)
		if callback_seen or settled then
			return
		end
		callback_seen = true
		callback_ok, callback_err = ok, err
		if refresh_returned then
			settle(ok and "success" or "failure", err)
		end
	end
	local ok_refresh, refresh_err = pcall(registry.refresh, refreshed)
	refresh_returned = true
	if not ok_refresh then
		settle("failure", refresh_err)
	elseif callback_seen then
		settle(callback_ok and "success" or "failure", callback_err)
	end
end

---@return { state: "idle"|"running"|"reported"|"failed"|"bridge_failed", reason?: string }
function M.status()
	return vim.deepcopy(current)
end

---Test seam.
function M.reset()
	current = { state = "idle" }
end

return M
