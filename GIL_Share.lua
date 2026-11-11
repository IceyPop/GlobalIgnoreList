local addonName, addon = ...
local L = addon.L
local V = addon.V
local M = addon.M

-- Sharing format
-- GIL:<TYPE>:<version>:<base64 of body>.<checksum>

local PREFIX			= "GIL:"
local MAX_IMPORT		= 100
local MAX_DESC			= 100
local MAX_FILTER		= 1000
local MAX_STRING		= 1000000
local PREVIEW_LINES		= 8

local floor  = math.floor
local sub    = string.sub
local byte   = string.byte
local format = string.format

----------------------------
-- SHARE ENGINE FUNCTIONS --
----------------------------

local B64CHARS  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64LOOKUP = {}

for i = 1, 64 do
	B64LOOKUP[byte(B64CHARS, i)] = i - 1
end

local function Base64Encode (s)
	local out, n = {}, 0

	for i = 1, #s, 3 do
		local a, b, c = byte(s, i, i + 2)
		local v = a * 65536 + (b or 0) * 256 + (c or 0)

		local c1 = floor(v / 262144) % 64
		local c2 = floor(v / 4096) % 64
		local c3 = floor(v / 64) % 64
		local c4 = v % 64

		n = n + 1
		out[n] = sub(B64CHARS, c1 + 1, c1 + 1) .. sub(B64CHARS, c2 + 1, c2 + 1)
			.. (b and sub(B64CHARS, c3 + 1, c3 + 1) or "=")
			.. (c and sub(B64CHARS, c4 + 1, c4 + 1) or "=")
	end

	return table.concat(out)
end

local function Base64Decode (s)
	s = string.gsub(s, "%s", "")

	local len = #s

	if len == 0 or len % 4 ~= 0 then return nil end

	local out, n = {}, 0

	for i = 1, len, 4 do
		local c1, c2, c3, c4 = byte(s, i, i + 3)
		local v1, v2 = B64LOOKUP[c1], B64LOOKUP[c2]
		local v3, v4 = B64LOOKUP[c3], B64LOOKUP[c4]
		local last   = (i + 3 == len)

		if not v1 or not v2 then return nil end

		if c3 == 61 then			-- "=" : must be the final group and be "=="
			if not last or c4 ~= 61 then return nil end

			local v = v1 * 262144 + v2 * 4096
			n = n + 1
			out[n] = string.char(floor(v / 65536) % 256)
		elseif c4 == 61 then		-- single "="
			if not last or not v3 then return nil end

			local v = v1 * 262144 + v2 * 4096 + v3 * 64
			n = n + 1
			out[n] = string.char(floor(v / 65536) % 256, floor(v / 256) % 256)
		else
			if not v3 or not v4 then return nil end

			local v = v1 * 262144 + v2 * 4096 + v3 * 64 + v4
			n = n + 1
			out[n] = string.char(floor(v / 65536) % 256, floor(v / 256) % 256, v % 256)
		end
	end

	return table.concat(out)
end

local function Checksum (s)
	-- Adler-32 using plain arithmetic as 8 hex digits

	local a, b = 1, 0

	for i = 1, #s do
		a = (a + byte(s, i)) % 65521
		b = (b + a) % 65521
	end

	return format("%04x%04x", b, a)
end

local function CleanText (text, maxLen)
	text = tostring(text or "")
	text = string.gsub(text, "|", "")				-- no color codes, links or textures
	text = string.gsub(text, "[%c]", " ")			-- no control characters or newlines

	if #text > maxLen then
		text = sub(text, 1, maxLen)

		-- do not leave half of a UTF-8 character at the end
		while #text > 0 do
			local b = byte(text, #text)

			if b >= 128 and b < 192 then
				text = sub(text, 1, #text - 1)
			elseif b >= 192 then
				text = sub(text, 1, #text - 1)
				break
			else
				break
			end
		end
	end

	return M.trim(text)
end

local handlers = {}

function M.GIL_RegisterShareType (typeName, handler)
	handlers[string.upper(typeName)] = handler
end

function M.GIL_PackShare (typeName, version, body)
	return PREFIX .. string.upper(typeName) .. ":" .. version .. ":" .. Base64Encode(body) .. "." .. Checksum(body)
end

function M.GIL_UnpackShare (str)
	str = M.trim(tostring(str or ""))

	if str == "" then return nil, "SHARE_5" end
	if #str > MAX_STRING then return nil, "SHARE_6" end

	str = string.gsub(str, "%s", "")

	local typeName, version, data, check = string.match(str, "GIL:(%a+):(%d+):([A-Za-z0-9+/=]+)%.(%x%x%x%x%x%x%x%x)")

	if not typeName then return nil, "SHARE_5" end

	local body = Base64Decode(data)

	if not body or string.lower(check) ~= Checksum(body) then return nil, "SHARE_6" end

	return string.upper(typeName), tonumber(version), body
end

local function ShowNotice (text)
	M.GIL_ShowDialog({
		key     = "shareimportnotice",
		text    = "%s",
		button1 = OKAY,
	}, text)
end

function M.GIL_ImportString (str, expectedType)
	local typeName, version, body = M.GIL_UnpackShare(str)

	if not typeName then
		ShowNotice(L[version or "SHARE_6"])
		return
	end

	local handler = handlers[typeName]

	if not handler then
		ShowNotice(format(L["SHARE_14"], typeName))
		return
	end

	if expectedType and string.upper(expectedType) ~= typeName then
		ShowNotice(format(L["SHARE_15"], L[handler.label or "SHARE_16"], L[handlers[string.upper(expectedType)].label or "SHARE_16"]))
		return
	end

	if version < 1 or version > handler.version then
		ShowNotice(L["SHARE_17"])
		return
	end

	local data, err = handler.decode(body, version)

	if not data then
		ShowNotice(L[err or "SHARE_6"])
		return
	end

	local text, count = handler.preview(data)

	if count == 0 then
		ShowNotice(text)
		return
	end

	M.GIL_ShowDialog({
		key      = "shareimportconfirm",
		text     = "%s",
		button1  = L["SHARE_12"],
		button2  = L["BOX_5"],
		onAccept = function()
			local added = handler.apply(data)

			M.ShowMsg(format(L[handler.doneKey or "SHARE_13"], added))
		end,
	}, text)
end

function M.GIL_ShowImportDialog (expectedType, title)
	M.GIL_ShowDialog({
		key        = "shareimport",
		text       = "|cffffff00%s|cffffffff\n\n" .. L["SHARE_4"],
		editBox    = true,
		editText   = "",
		maxLetters = 0,
		button1    = L["SHARE_12"],
		button2    = L["BOX_5"],
		onAccept   = function(text)
			M.GIL_ImportString(text, expectedType)
		end,
	}, title or L["BUT_13"])
end

function M.GIL_ShowExportDialog (title, str)
	local f = M.GIL_ShowDialog({
		key        = "shareexport",
		text       = "|cffffff00%s|cffffffff\n\n" .. L["SHARE_2"],
		editBox    = true,
		editText   = str,
		maxLetters = 0,
		button1    = L["BOX_5"],
	}, title)

	if f and f.edit then
		f.edit:SetFocus()
		f.edit:HighlightText()
	end
end

---------------------------------
-- TYPE: FILTER (CHAT FILTERS) --
---------------------------------

-- Chat filter body (version 1) length prefixed: <count>; Per filter: <active 0|1>,<descLen>,<filterLen>:<desc><filter>

local FILTER_VERSION = 1

-- list = array { desc=, filter=, active= }
local function EncodeFilters (list)
	local parts = { #list .. ";" }

	for i = 1, #list do
		local desc   = CleanText(list[i].desc,   MAX_DESC)
		local filter = CleanText(list[i].filter, MAX_FILTER)

		parts[#parts + 1] = format("%d,%d,%d:%s%s", list[i].active and 1 or 0, #desc, #filter, desc, filter)
	end

	return table.concat(parts)
end

local function DecodeFilters (body, version)
	local count, pos = string.match(body, "^(%d+);()")

	count = tonumber(count)

	if not count or count < 1 then return nil, "SHARE_6" end
	if count > MAX_IMPORT then return nil, "SHARE_7" end

	local list = {}

	for i = 1, count do
		local a, ld, lf, np = string.match(body, "^([01]),(%d+),(%d+):()", pos)

		if not a then return nil, "SHARE_6" end

		ld, lf = tonumber(ld), tonumber(lf)

		if ld > MAX_DESC * 4 or lf > MAX_FILTER * 4 then return nil, "SHARE_6" end
		if np + ld + lf - 1 > #body then return nil, "SHARE_6" end

		local desc   = CleanText(sub(body, np, np + ld - 1), MAX_DESC)
		local filter = CleanText(sub(body, np + ld, np + ld + lf - 1), MAX_FILTER)

		pos = np + ld + lf

		if filter ~= "" then
			if desc == "" then desc = L["SHARE_9"] end

			list[#list + 1] = { desc = desc, filter = filter, active = (a == "1") }
		end
	end

	if #list == 0 then return nil, "SHARE_6" end

	return list
end

local function CollectFilters (onlyIndex)
	local db   = GlobalIgnoreDB
	local list = {}

	if onlyIndex then
		if db.filterList[onlyIndex] then
			list[1] = {
				desc   = db.filterDesc[onlyIndex],
				filter = db.filterList[onlyIndex],
				active = db.filterActive[onlyIndex] == true,
			}
		end
	else
		-- Ignore default filters
		for i = 1, #db.filterList do
			local id = db.filterID[i]

			if id == nil or id == "" then
				list[#list + 1] = {
					desc   = db.filterDesc[i],
					filter = db.filterList[i],
					active = db.filterActive[i] == true,
				}
			end
		end
	end

	return list
end

local function FilterExists (filter)
	for i = 1, #GlobalIgnoreDB.filterList do
		if GlobalIgnoreDB.filterList[i] == filter then return true end
	end

	return false
end

local function GetNewFilters (list)
	local fresh = {}

	for i = 1, #list do
		if not FilterExists(list[i].filter) then
			fresh[#fresh + 1] = list[i]
		end
	end

	return fresh
end

-- MAIN

M.GIL_RegisterShareType("FILTER", {
	version = FILTER_VERSION,
	label   = "SHARE_18",

	decode = DecodeFilters,

	preview = function (list)
		local fresh = GetNewFilters(list)

		if #fresh == 0 then
			return L["SHARE_10"], 0
		end

		local names = {}

		for i = 1, math.min(#fresh, PREVIEW_LINES) do
			names[#names + 1] = "|cff69CCF0" .. fresh[i].desc .. "|cffffffff"
		end

		if #fresh > PREVIEW_LINES then
			names[#names + 1] = format(L["SHARE_11"], #fresh - PREVIEW_LINES)
		end

		return format(L["SHARE_3"], #fresh, #list - #fresh) .. "\n\n" .. table.concat(names, "\n"), #fresh
	end,

	apply = function (list)
		local db    = GlobalIgnoreDB
		local fresh = GetNewFilters(list)

		for i = 1, #fresh do
			local idx = #db.filterList + 1

			db.filterList[idx]			= fresh[i].filter
			db.filterDesc[idx]			= fresh[i].desc
			db.filterCount[idx]			= 0
			db.filterActive[idx]		= false			-- imported filters always start disabled
			db.filterID[idx]			= ""
			db.filterBlocked[idx]		= {}
			db.filterBlockedLast[idx]	= 0
		end

		if M.GIL_RefreshFilterList then M.GIL_RefreshFilterList() end

		return #fresh
	end,
})

function M.GIL_ExportFilters (onlyIndex)
	local list = CollectFilters(onlyIndex)

	if #list == 0 then
		M.ShowMsg(L["SHARE_8"])
		return
	end

	M.GIL_ShowExportDialog(format(L["SHARE_1"], #list), M.GIL_PackShare("FILTER", FILTER_VERSION, EncodeFilters(list)))
end

function M.GIL_ShowFilterShareMenu (selectedIndex)
	local db = GlobalIgnoreDB

	M.GIL_ContextMenu(UIParent,
		function (owner, root)
			root:CreateTitle(L["SHARE_19"])
			root:CreateDivider()

			if selectedIndex and selectedIndex > 0 and db.filterList[selectedIndex] then
				root:CreateButton(L["SHARE_20"],
					function ()
						M.GIL_ExportFilters(selectedIndex)
					end
				)
			end

			root:CreateButton(L["SHARE_21"],
				function ()
					M.GIL_ExportFilters(nil)
				end
			)

			root:CreateDivider()
			root:CreateButton(L["SHARE_22"],
				function ()
					M.GIL_ShowFilterImportDialog()
				end
			)

			root:CreateDivider()
			root:CreateButton(L["RCM_5"], function () end)
		end
	)
end

function M.GIL_ShowFilterImportDialog()
	M.GIL_ShowImportDialog("FILTER", L["BUT_13"])
end

--------------------------------
-- TYPE: IGNORE (IGNORE LIST) --
--------------------------------

-- Body: <count>; and for each ignore entry: <p|n|s>,<expDays>,<nameLen>,<factionLen>,<dateLen>,<noteLen>:<name><faction><date><note>

local IGNORE_VERSION      = 1
local MAX_IGNORE_ENTRIES  = 3000
local MAX_NOTE            = 256
local TYPE_TO_CODE        = { player = "p", npc = "n", server = "s" }
local CODE_TO_TYPE        = { p = "player", n = "npc", s = "server" }

local function EncodeIgnore (list)
	local parts = { #list .. ";" }

	for i = 1, #list do
		local e       = list[i]
		local name    = CleanText(e.name,    80)
		local faction = CleanText(e.faction, 20)
		local dt      = CleanText(e.date,    12)
		local note    = CleanText(e.note,    MAX_NOTE)
		local exp     = floor(tonumber(e.exp) or 0)

		parts[#parts + 1] = format("%s,%d,%d,%d,%d,%d:%s%s%s%s", TYPE_TO_CODE[e.type], exp, #name, #faction, #dt, #note, name, faction, dt, note)
	end

	return table.concat(parts)
end

local function DecodeIgnore (body, version)
	local count, pos = string.match(body, "^(%d+);()")

	count = tonumber(count)

	if not count or count < 1 then return nil, "SHARE_6" end
	if count > MAX_IGNORE_ENTRIES then return nil, "SHARE_7" end

	local list = {}

	for i = 1, count do
		local code, exp, ln, lf, ld, lt, np = string.match(body, "^([pns]),(%d+),(%d+),(%d+),(%d+),(%d+):()", pos)

		if not code then return nil, "SHARE_6" end

		exp, ln, lf, ld, lt = tonumber(exp), tonumber(ln), tonumber(lf), tonumber(ld), tonumber(lt)

		if ln > 320 or lf > 80 or ld > 48 or lt > MAX_NOTE * 4 then return nil, "SHARE_6" end
		if np + ln + lf + ld + lt - 1 > #body then return nil, "SHARE_6" end

		local p = np

		local name    = CleanText(sub(body, p, p + ln - 1), 80);		p = p + ln
		local faction = CleanText(sub(body, p, p + lf - 1), 20);		p = p + lf
		local dt      = CleanText(sub(body, p, p + ld - 1), 12);		p = p + ld
		local note    = CleanText(sub(body, p, p + lt - 1), MAX_NOTE);	p = p + lt

		pos = p

		local entryType = CODE_TO_TYPE[code]

		if name ~= "" then
			if entryType == "player" and not string.find(name, "-", 1, true) then
				name = M.addServer(name)
			end

			if M.dateToJulianDate(dt) == 0 then dt = nil end
			if faction == "" then faction = "Unknown" end

			list[#list + 1] = {
				type    = entryType,
				name    = name,
				faction = faction,
				date    = dt,
				note    = note,
				exp     = math.min(exp, 9999),
			}
		end
	end

	if #list == 0 then return nil, "SHARE_6" end

	return list
end

local function CollectIgnores (index)
	local db   = GlobalIgnoreDB
	local list = {}

	local function add (i)
		local name = db.ignoreList[i]
		local t    = db.typeList[i] or "player"

		if name and name ~= "" and TYPE_TO_CODE[t] then
			list[#list + 1] = {
				type    = t,
				name    = name,
				faction = db.factionList[i],
				date    = db.dateList[i],
				note    = db.notes[i],
				exp     = db.expList[i],
			}
		end
	end

	if index then
		add(index)
	else
		for i = 1, #db.ignoreList do add(i) end
	end

	return list
end

local function NewIgnores (list)
	local db    = GlobalIgnoreDB
	local seen  = {}
	local fresh = {}

	for i = 1, #db.ignoreList do
		seen[(db.typeList[i] or "player") .. "\0" .. db.ignoreList[i]] = true
	end

	for i = 1, #list do
		local key = list[i].type .. "\0" .. list[i].name

		if not seen[key] then
			seen[key] = true
			fresh[#fresh + 1] = list[i]
		end
	end

	return fresh
end

M.GIL_RegisterShareType("IGNORE", {
	version = IGNORE_VERSION,
	label   = "SHARE_29",
	doneKey = "SHARE_32",

	decode = DecodeIgnore,

	preview = function (list)
		local fresh = NewIgnores(list)

		if #fresh == 0 then
			return L["SHARE_34"], 0
		end

		local counts = { player = 0, npc = 0, server = 0 }
		local names  = {}

		for i = 1, #fresh do
			counts[fresh[i].type] = counts[fresh[i].type] + 1

			if i <= PREVIEW_LINES then
				local shown = fresh[i].name

				if fresh[i].type == "player" then
					shown = M.removeServer(shown, true) or shown
				end

				names[#names + 1] = "|cff69CCF0" .. shown .. "|cffffffff"
			end
		end

		if #fresh > PREVIEW_LINES then
			names[#names + 1] = format(L["SHARE_11"], #fresh - PREVIEW_LINES)
		end

		return format(L["SHARE_28"], #fresh, #list - #fresh, counts.player, counts.npc, counts.server) .. "\n\n" .. table.concat(names, "\n"), #fresh
	end,

	apply = function (list)
		local fresh = NewIgnores(list)

		for i = 1, #fresh do
			local e = fresh[i]

			M.GIL_ImportEntry(e.name, e.faction, e.date, e.note, e.exp, e.type)
		end

		V.needSorted = true

		if M.GILUpdateUI then M.GILUpdateUI(true) end
		if #fresh > 0 and M.SyncIgnoreList then M.SyncIgnoreList(true) end

		return #fresh
	end,
})

function M.GIL_ExportIgnores (index)
	local list = CollectIgnores(index)

	if #list == 0 then
		M.ShowMsg(L["SHARE_30"])
		return
	end

	M.GIL_ShowExportDialog(format(L["SHARE_27"], #list), M.GIL_PackShare("IGNORE", IGNORE_VERSION, EncodeIgnore(list)))
end

function M.GIL_ShowIgnoreImportDialog()
	M.GIL_ShowImportDialog("IGNORE", L["SHARE_33"])
end

function M.GIL_ShowIgnoreShareMenu (selectedIndex)
	local db = GlobalIgnoreDB

	M.GIL_ContextMenu(UIParent,
		function (owner, root)
			root:CreateTitle(L["SHARE_23"])
			root:CreateDivider()

			if selectedIndex and selectedIndex > 0 and db.ignoreList[selectedIndex] then
				root:CreateButton(L["SHARE_24"],
					function ()
						M.GIL_ExportIgnores(selectedIndex)
					end
				)
			end

			root:CreateButton(L["SHARE_25"],
				function ()
					M.GIL_ExportIgnores(nil)
				end
			)

			root:CreateDivider()
			root:CreateButton(L["SHARE_26"],
				function ()
					M.GIL_ShowIgnoreImportDialog()
				end
			)

			root:CreateDivider()
			root:CreateButton(L["RCM_5"], function () end)
		end
	)
end
