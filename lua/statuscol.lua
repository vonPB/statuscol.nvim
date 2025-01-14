local a = vim.api
local f = vim.fn
local g = vim.g
local o = vim.o
local Ol = vim.opt_local
local S = vim.schedule
local contains = vim.tbl_contains
local M = {}
local callargs = {}
local formatstr = ""
local sign_cache = {}
local formatargs = {}
local formatargret = {}
local formatargcount = 0
local signsegments = {}
local signsegmentcount = 0
local builtin, ffi, error, C, lnumfunc
local cfg = {
	-- Builtin line number string options
	thousands = false,
	relculright = false,
	-- Builtin 'statuscolumn' options
	setopt = true,
	ft_ignore = nil,
	clickmod = "c",
	clickhandlers = {},
}

--- Store defined signs without whitespace.
local function update_sign_defined()
	for _, s in ipairs(f.sign_getdefined()) do
		if s.text then
			for i = 1, signsegmentcount do
				local ss = signsegments[i]
				if ss.lnum and not ss.sclnu then goto nextsegment end
				for j = 1, ss.notnamecount do
					if s.name:find(ss.notname[j]) then goto nextsegment end
				end
				for j = 1, ss.namecount do
					if s.name:find(ss.name[j]) then
						s.segment = i
						goto nextsign
					end
				end
				::nextsegment::
			end
		end
		::nextsign::
		sign_cache[s.name] = s
		if s.segment then
			s.wtext = s.text:gsub("%s","")
			if not s.texthl then s.texthl = "NoTexthl" end
			if signsegments[s.segment].colwidth == 1 then s.text = s.wtext end
		end
	end
end

--- Store click args and fn.getmousepos() in table.
--- Set current window and mouse position to clicked line.
local function get_click_args(minwid, clicks, button, mods)
	local args = {
		minwid = minwid,
		clicks = clicks,
		button = button,
		mods = mods,
		mousepos = f.getmousepos()
	}
	a.nvim_set_current_win(args.mousepos.winid)
	a.nvim_win_set_cursor(0, { args.mousepos.line, 0 })
	return args
end

local function call_click_func(name, args)
	local handler = cfg.clickhandlers[name]
	if handler then S(function() handler(args) end) end
end

--- Execute fold column click callback.
local function get_fold_action(minwid, clicks, button, mods)
	local args = get_click_args(minwid, clicks, button, mods)
	local char = f.screenstring(args.mousepos.screenrow, args.mousepos.screencol)
	local fold = callargs[args.mousepos.winid].fold
	local type = char == fold.open and "FoldOpen"
			or char == fold.close and "FoldClose" or "FoldOther"
	call_click_func(type, args)
end

local function get_sign_action_inner(args)
	local sign = f.screenstring(args.mousepos.screenrow, args.mousepos.screencol)
	-- When empty space is clicked in the sign column, try one cell to the left
	if sign == ' ' then
		sign = f.screenstring(args.mousepos.screenrow, args.mousepos.screencol - 1)
	end
	if not sign_cache[sign] then update_sign_defined() end

	for name, s in pairs(sign_cache) do
		if s.wtext == sign then
			call_click_func(name, args)
			break
		end
	end
end

--- Execute sign column click callback.
local function get_sign_action(minwid, clicks, button, mods)
	local args = get_click_args(minwid, clicks, button, mods)
	get_sign_action_inner(args)
end

--- Execute line number click callback.
local function get_lnum_action(minwid, clicks, button, mods)
	local args = get_click_args(minwid, clicks, button, mods)
	local cargs = callargs[args.mousepos.winid]
	if lnumfunc and cargs.sclnu then
		local placed = f.sign_getplaced(cargs.buf, { group = "*", lnum = args.mousepos.line })
		if #placed[1].signs > 0 then
			get_sign_action_inner(args)
			return
		end
	end
	call_click_func("Lnum", args)
end

--- Return 'statuscolumn' option value (%! item).
local function get_statuscol_string()
	local win = g.statusline_winid
	local args = callargs[win]
	if not args then
		args = { win = win, wp = C.find_window_by_handle(win, error), fold = {}, tick = 0 }
		callargs[win] = args
	end

	-- Update callargs once per window per redraw
	local tick = C.display_tick
	if args.tick < tick then
		local fcs = Ol.fcs:get()
		local buf = a.nvim_win_get_buf(win)
		args.buf = buf
		args.tick = tick
		args.nu = a.nvim_win_get_option(win, "nu")
		args.rnu = a.nvim_win_get_option(win, "rnu")
		args.sclnu = lnumfunc and a.nvim_win_get_option(win, "scl"):find("nu")
		args.fold.sep = fcs.foldsep or "│"
		args.fold.open = fcs.foldopen or "-"
		args.fold.close = fcs.foldclose or "+"
		if signsegmentcount - ((lnumfunc and not args.sclnu) and 1 or 0) > 0 then
			-- Retrieve signs for the entire buffer and store in "signsegments"
			-- by line number. Only do this if a "signs" segment was configured.
			local signs = f.sign_getplaced(buf, { group = "*" })[1].signs
			local signcount = #signs
			for i = 1, signsegmentcount do
				local ss = signsegments[i]
				if ss.lnum and args.sclnu ~= ss.sclnu then
					ss.sclnu = args.sclnu
					update_sign_defined()
				end
				ss.width = 0
				ss.signs = {}
			end
			for j = 1, signcount do
				local s = signs[j]
				if not sign_cache[s.name] then update_sign_defined() end
				local sign = sign_cache[s.name]
				if not sign.segment then goto nextsign end
				local ss = signsegments[sign.segment]
				local sss = ss.signs
				local width = (sss[s.lnum] and #sss[s.lnum] or 0) + 1
				if width > ss.maxwidth then goto nextsign end
				if not sss[s.lnum] then sss[s.lnum] = {} end
				if ss.width < width then ss.width = width end
				sss[s.lnum][width] = sign_cache[s.name]
				::nextsign::
			end
			for i = 1, signsegmentcount do
				local ss = signsegments[i]
				if ss.auto then
					ss.empty = ss.fillchar:rep(ss.width * ss.colwidth)
					ss.padwidth = ss.width
				end
			end
		end
	end

	for i = 1, formatargcount do
		local fa = formatargs[i]
		if fa.cond == true or fa.cond(args) then
			formatargret[i] = type(fa.text) == "string" and fa.text or fa.text(args, fa)
		else
			formatargret[i] = ""
		end
	end

	return formatstr:format(unpack(formatargret))
end

function M.setup(user)
	local ok = pcall(a.nvim_win_get_option, 0, "statuscolumn")
	if not ok then
		vim.notify([[statuscol.nvim requires a neovim version that includes the 'statuscolumn' option.
Please update to the latest nightly or build from source.]], vim.log.levels.WARN)
	return
	end

	ffi = require("statuscol.ffidef")
	builtin = require("statuscol.builtin")
	error = ffi.new("Error")
	C = ffi.C

	cfg.clickhandlers = {
		Lnum                   = builtin.lnum_click,
		FoldClose              = builtin.foldclose_click,
		FoldOpen               = builtin.foldopen_click,
		FoldOther              = builtin.foldother_click,
		DapBreakpointRejected  = builtin.toggle_breakpoint,
		DapBreakpoint          = builtin.toggle_breakpoint,
		DapBreakpointCondition = builtin.toggle_breakpoint,
		DiagnosticSignError    = builtin.diagnostic_click,
		DiagnosticSignHint     = builtin.diagnostic_click,
		DiagnosticSignInfo     = builtin.diagnostic_click,
		DiagnosticSignWarn     = builtin.diagnostic_click,
		GitSignsTopdelete      = builtin.gitsigns_click,
		GitSignsUntracked      = builtin.gitsigns_click,
		GitSignsAdd            = builtin.gitsigns_click,
		GitSignsChange         = builtin.gitsigns_click,
		GitSignsChangedelete   = builtin.gitsigns_click,
		GitSignsDelete         = builtin.gitsigns_click,
	}
	if user then cfg = vim.tbl_deep_extend("force", cfg, user) end
	builtin.init(cfg)

	cfg.segments = cfg.segments or {
		-- Default segments (fold -> sign -> line number -> separator)
		{ text = { "%C" }, click = "v:lua.ScFa" },
		{ text = { "%s" }, click = "v:lua.ScSa" },
		{
			text = { builtin.lnumfunc, " " },
			condition = { true, builtin.not_empty },
			click = "v:lua.ScLa",
		}
	}

	-- To improve performance of the 'statuscolumn' evaluation, we parse the
	-- "segments" here and convert it to a format string. Only the variable
	-- elements are evaluated each redraw.
	local setscl
	for i = 1, #cfg.segments do
		local segment = cfg.segments[i]
		if segment.text and contains(segment.text, builtin.lnumfunc) then
			lnumfunc = true
			segment.sign = segment.sign or { name = { ".*" }, lnum = true }
		end
		local ss = segment.sign
		if ss then
			signsegmentcount = signsegmentcount + 1
			signsegments[signsegmentcount] = ss
			ss.namecount = #ss.name
			ss.auto = ss.auto or false
			ss.maxwidth = ss.maxwidth or 1
			ss.colwidth = ss.colwidth or 2
			ss.padwidth = ss.maxwidth
			ss.fillchar = ss.fillchar or " "
			ss.empty = ss.fillchar:rep(ss.maxwidth * ss.colwidth)
			if setscl ~= false then setscl = true end
			if not segment.text then segment.text = { builtin.signfunc } end
		end
		if segment.hl then formatstr = formatstr.."%%#"..segment.hl.."#" end
		if segment.click then formatstr = formatstr.."%%@"..segment.click.."@" end
		for j = 1, #segment.text do
			local condition = segment.condition and segment.condition[j]
			if condition == nil then condition = true end
			if condition then
				local text = segment.text[j]
				if type(text) == "string" then
					if text:find("%%s") then setscl = false end
					text = text:gsub("%%", "%%%%")
				end
				if type(text) == "function" or type(condition) == "function" then
					formatstr = formatstr.."%s"
					formatargcount = formatargcount + 1
					formatargs[formatargcount] = {
						text = text,
						cond = condition,
						sign = ss
					}
				else
					formatstr = formatstr..text
				end
			end
		end
		if segment.click then formatstr = formatstr.."%%T" end
		if segment.hl then formatstr = formatstr.."%%*" end
	end
	if setscl and o.scl ~= "number" then o.scl = "no" end
	-- For each sign segment, store the name patterns from other sign segments.
	-- This list is used in update_sign_defined() to make sure that signs that
	-- have a dedicated segment do not get placed in a wildcard(".*") segment.
	if signsegmentcount > 0 then
		for i = 1, signsegmentcount do
			local ss = signsegments[i]
			ss.notname = {}
			ss.notnamecount = 0
			for j = 1, signsegmentcount do
				if j ~= i then
					local sso = signsegments[j]
					for k = 1, #sso.name do
						if sso.name[k] ~= ".*" then
							ss.notnamecount = ss.notnamecount + 1
							ss.notname[ss.notnamecount] = sso.name[k]
						end
					end
				end
			end
		end
		a.nvim_set_hl(0, "NoTexthl", { fg = "NONE" })
	end

	_G.ScFa = get_fold_action
	_G.ScSa = get_sign_action
	_G.ScLa = get_lnum_action

	local id = a.nvim_create_augroup("StatusCol", {})

	if cfg.setopt then
		_G.StatusCol = get_statuscol_string
		o.statuscolumn = "%!v:lua.StatusCol()"
		a.nvim_create_autocmd("WinClosed", {
			group = id,
			callback = function(args)
				callargs[args.file] = nil
			end
		})
	end

	if cfg.ft_ignore then
		a.nvim_create_autocmd({ "FileType", "BufEnter" }, { group = id, callback = function()
			if contains(cfg.ft_ignore, a.nvim_buf_get_option(0, "ft")) then
				Ol.statuscolumn = ""
			end
		end })
	end

	if cfg.bt_ignore then
		a.nvim_create_autocmd("OptionSet", { pattern = "buftype", group = id, callback = function()
			if contains(cfg.bt_ignore, a.nvim_buf_get_option(0, "bt")) then
				Ol.statuscolumn = ""
			end
		end })
	end
end

return M
