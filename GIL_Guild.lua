-------------------
-- GUILD IGNORE  --
-------------------
--
-- DB:
-- GlobalIgnoreDB.guildIgnore = {
--     guilds  = { [guildKey] = { name="Guild Name", server="Server", date="09 Nov 2026" } },
--     players = { ["Player-Server"] = guildKey },
--     exempt  = { ["Player-Server"] = true }, (Excluded players never added to a scan)
-- }
-- Primary Key = lower(guild name) .. "-" .. server

local addonName, addon = ...
local L = addon.L
local V = addon.V
local M = addon.M

local sub    = string.sub
local lower  = string.lower
local format = string.format

local NAME_MAX       = 60
local MAX_GUILDS     = 1000
local MAX_PLAYERS    = 60000
local MAX_EXPORT     = 900000		-- characters in one export string
local PREVIEW_LINES  = 8

-----------
-- DATA  --
-----------

local counts      = {}
local guildTotal  = 0
local countsSrc   = nil
local countsDirty = true

local function DB ()
	local db = GlobalIgnoreDB

	if not db then return nil end

	local c = db.guildIgnore

	if type(c) ~= "table" then
		c = {}
		db.guildIgnore = c
	end

	c.guilds  = c.guilds  or {}
	c.players = c.players or {}
	c.exempt  = c.exempt  or {}

	return c
end

local function RebuildCounts ()
	local c = DB()

	counts, guildTotal = {}, 0

	if not c then return end

	for _ in pairs(c.guilds) do guildTotal = guildTotal + 1 end
	for _, gkey in pairs(c.players) do counts[gkey] = (counts[gkey] or 0) + 1 end

	countsSrc   = c.players
	countsDirty = false
end

local function EnsureCounts ()
	local c = DB()

	if countsDirty or (c and countsSrc ~= c.players) then
		RebuildCounts()
	end
end

local function Refresh ()
	if M.GIL_GuildRefresh then M.GIL_GuildRefresh() end
end

local function CleanName (text)
	text = tostring(text or "")
	text = string.gsub(text, "|", "")
	text = string.gsub(text, "%c", " ")
	text = M.trim(text)

	if #text > NAME_MAX then
		text = sub(text, 1, NAME_MAX)

		while #text > 0 do						-- no half UTF-8 characters
			local b = string.byte(text, #text)

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

local function ServerKey (server)
	if not server or server == "" then return V.serverName end

	return M.Proper(server, false) or V.serverName
end

local function GuildKey (name, server)
	return lower(name) .. "-" .. ServerKey(server)
end

local function PlayerKey (name)
	name = M.trim(tostring(name or ""))

	if name == "" then return nil end

	return M.Proper(M.addServer(name))
end

local function AddGuildRaw (c, name, server, dateStr)
	local gkey = GuildKey(name, server)

	if c.guilds[gkey] then return gkey, false end

	c.guilds[gkey] = { name = name, server = ServerKey(server), date = dateStr or date("%d %b %Y") }
	countsDirty = true

	return gkey, true
end

-- true when the player is on the Guild Ignore list (or the guild key)
function M.hasGuildIgnored (name)
	local c = GlobalIgnoreDB and GlobalIgnoreDB.guildIgnore

	if not name or not c or not c.players then return false end

	return c.players[name] or false
end

local function RemovePlayer (pkey, exempt)
	EnsureCounts()

	local c = DB()
	local gkey = c and c.players[pkey]

	if not gkey then return end

	c.players[pkey] = nil

	if exempt then c.exempt[pkey] = true end

	counts[gkey] = (counts[gkey] or 1) - 1
end

local function RemoveGuild (gkey)
	local c = DB()

	if not c or not c.guilds[gkey] then return end

	for pkey, g in pairs(c.players) do
		if g == gkey then c.players[pkey] = nil end
	end

	c.guilds[gkey] = nil
	countsDirty = true
end

-- excludes pkey from all discovery and scans (removing them from the list when they are on it)
local function ExcludePlayer (pkey)
	EnsureCounts()

	local c = DB()

	if c.players[pkey] then
		RemovePlayer(pkey, true)
	else
		c.exempt[pkey] = true
	end
end

local function UnexcludePlayer (pkey)
	local c = DB()

	if c then c.exempt[pkey] = nil end
end

-- guild name and server for display: "Name" or "Name (Server)"
local function GuildLabel (g)
	if V.wowIsForever == true or g.server == V.serverName then return g.name end

	return g.name .. " (" .. (M.prettyServer(g.server) or g.server) .. ")"
end

---------------
-- DISCOVERY --
---------------

local function GuildOf (unit)
	local gname, _, _, grealm = GetGuildInfo(unit)

	if not gname or gname == "" then return nil end

	if issecretvalue and (issecretvalue(gname) or (grealm ~= nil and issecretvalue(grealm))) then return nil end

	if grealm == "" then grealm = nil end

	return gname, grealm
end

local function FindGuild (c, gname, servers)
	for i = 1, 3 do
		if servers[i] then
			local key = GuildKey(gname, servers[i])

			if c.guilds[key] then return key end
		end
	end

	return nil
end

local function Learn (c, pkey, gkey)
	-- adds player (pkey) to guild (gkey).  False when skipped (removed by hand, already listed, normal ignore list)

	local cur = c.players[pkey]

	if cur == gkey or c.exempt[pkey] then return false end
	if M.hasGlobalIgnored(pkey) > 0 then return false end

	if cur then counts[cur] = (counts[cur] or 1) - 1 end

	c.players[pkey] = gkey
	counts[gkey] = (counts[gkey] or 0) + 1

	return true
end

local function CheckUnit (unit)
	if not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end

	local gname, grealm = GuildOf(unit)

	if not gname then return end

	local full = M.GetUnitFullName(unit)

	if not full then return end

	local pkey = PlayerKey(full)

	if not pkey then return end

	local c = DB()
	local gkey = FindGuild(c, gname, { grealm, M.getServer(pkey), V.serverName })
	local cur  = c.players[pkey]

	if gkey then
		if not Learn(c, pkey, gkey) then return end

		if GlobalIgnoreDB.guildIgnoreMsg ~= false then
			M.ShowMsg(format(L["GUILD_11"], M.removeServer(pkey, true) or pkey, c.guilds[gkey].name))
		end

		Refresh()
	elseif cur then
		-- Found them in a different guild that is listed, so now we have to move them
		local old = c.guilds[cur] and c.guilds[cur].name or "?"

		RemovePlayer(pkey, false)

		if GlobalIgnoreDB.guildIgnoreMsg ~= false then
			M.ShowMsg(format(L["GUILD_33"], M.removeServer(pkey, true) or pkey, old))
		end

		Refresh()
	end
end

local function Enabled ()
	if not GlobalIgnoreDB or GlobalIgnoreDB.guildIgnoreEnabled == false then return false end

	EnsureCounts()

	return guildTotal > 0
end

-- Delay for event timing guild data in group roster updates
-- I may remove the entire group discovery I dont know how much value it has in hindsight vs its complexity

local RECHECK_DELAY = 0.5

local function QuickCheck (unit)
	if not Enabled() then return end

	pcall(CheckUnit, unit)

	C_Timer.After(RECHECK_DELAY, function ()
		if Enabled() then pcall(CheckUnit, unit) end
	end)
end

local function CheckGroup ()
	if not IsInGroup() then return end

	local prefix = IsInRaid() and "raid" or "party"

	for i = 1, GetNumGroupMembers() do
		pcall(CheckUnit, prefix .. i)
	end
end

local groupPending = false

local function GroupCheck ()
	if not Enabled() then return end

	CheckGroup()

	if groupPending then return end

	groupPending = true

	C_Timer.After(RECHECK_DELAY, function ()
		groupPending = false

		if Enabled() then CheckGroup() end
	end)
end

local FinishScan
local eventFrame = CreateFrame("Frame")

eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
eventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
pcall(eventFrame.RegisterEvent, eventFrame, "NAME_PLATE_UNIT_ADDED")

eventFrame:SetScript("OnEvent", function (self, event, unit)
	if event == "WHO_LIST_UPDATE" then
		pcall(FinishScan, false)
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		QuickCheck(unit)
	elseif event == "PLAYER_TARGET_CHANGED" then
		QuickCheck("target")
	elseif event == "PLAYER_FOCUS_CHANGED" then
		QuickCheck("focus")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		QuickCheck("mouseover")
	elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
		GroupCheck()
	end
end)

-----------------------
-- SCAN FOR MEMBERS  --
-----------------------

local WHO_MAX      = 50
local WHO_TIMEOUT  = 10
local WHO_COOLDOWN = 5
local BAND_SIZE    = 10
local BAND_LAST    = (V.wowIsForever == true) and 60 or 100

local scanPending = nil
local scanLastAt  = 0
local scanBand    = {}		-- guildKey -> next level band start (nil = full guild query)

local function HideWhoFrame (wasShown)
	if not wasShown and FriendsFrame and FriendsFrame:IsShown() then
		pcall(HideUIPanel, FriendsFrame)
	end
end

FinishScan = function (timedOut)
	local p = scanPending

	if not p then return end

	scanPending = nil

	pcall(C_FriendList.SetWhoToUi, p.oldToUi == true)
	pcall(p.frame.UnregisterEvent, p.frame, "WHO_LIST_UPDATE")

	if timedOut then
		M.ShowMsg(L["GUILD_42"])
		return
	end

	local c = DB()
	local g = c and c.guilds[p.gkey]

	if not g then return end

	EnsureCounts()

	local num   = C_FriendList.GetNumWhoResults() or 0
	local found = 0
	local added = 0
	local want  = lower(g.name)

	for i = 1, num do
		local info = C_FriendList.GetWhoInfo(i)
		local gn   = info and info.fullGuildName
		local fn   = info and info.fullName

		if gn and fn and not (issecretvalue and (issecretvalue(gn) or issecretvalue(fn))) and lower(gn) == want then
			local pkey = PlayerKey(fn)

			if pkey and FindGuild(c, gn, { M.getServer(pkey), V.serverName }) == p.gkey then
				found = found + 1

				if Learn(c, pkey, p.gkey) then added = added + 1 end
			end
		end
	end

	HideWhoFrame(p.wasShown)

	local range = ""

	if p.band then range = format(L["GUILD_45"], p.band, p.band + BAND_SIZE - 1) end

	M.ShowMsg(format(L["GUILD_39"], g.name, range, found, added))

	if num >= WHO_MAX then
		-- the answer was cut off: next click looks at the next level range
		if p.band then
			scanBand[p.gkey] = (p.band + BAND_SIZE <= BAND_LAST) and (p.band + BAND_SIZE) or nil
		else
			scanBand[p.gkey] = 1
		end

		M.ShowMsg(L["GUILD_40"])
	elseif p.band then
		scanBand[p.gkey] = (p.band + BAND_SIZE <= BAND_LAST) and (p.band + BAND_SIZE) or nil
	else
		scanBand[p.gkey] = nil
	end

	Refresh()
end

-- must run from a click (hardware event)
function M.GIL_GuildScan (gkey)
	local c = DB()
	local g = c and gkey and c.guilds[gkey]

	if not g then
		M.ShowMsg(L["GUILD_44"])
		return
	end

	if not (C_FriendList and C_FriendList.SendWho and C_FriendList.GetWhoInfo and C_FriendList.GetNumWhoResults) then
		M.ShowMsg(L["GUILD_43"])
		return
	end

	if scanPending or (GetTime() - scanLastAt) < WHO_COOLDOWN then
		M.ShowMsg(L["GUILD_41"])
		return
	end

	local band  = scanBand[gkey]
	local query = 'g-"' .. string.gsub(g.name, '"', "") .. '"'

	if band then query = query .. " " .. band .. "-" .. (band + BAND_SIZE - 1) end

	scanPending = {
		gkey     = gkey,
		band     = band,
		frame    = eventFrame,
		wasShown = FriendsFrame and FriendsFrame:IsShown() or false,
		oldToUi  = false,
	}

	local pending = scanPending

	scanLastAt = GetTime()

	pcall(C_FriendList.SetWhoToUi, true)			-- results come as an event, not chat lines
	pcall(eventFrame.RegisterEvent, eventFrame, "WHO_LIST_UPDATE")

	local ok = pcall(C_FriendList.SendWho, query)

	if not ok then
		FinishScan(true)
		return
	end

	M.ShowMsg(format(L["GUILD_38"], g.name))

	C_Timer.After(WHO_TIMEOUT, function ()
		if scanPending == pending then FinishScan(true) end
	end)
end

-----------------------
-- ADD GUILD / MENUS --
-----------------------

-- text = "Guild Name" or "Guild Name @ Server"
-- I think guild names can have a dash so we're looking for an AT here which is kind of nonstandard feeling.

local function ParseGuildText (text)
	local name, server = string.match(tostring(text or ""), "^(.-)%s*@%s*(.-)$")

	if not name then name = text end

	name = CleanName(name)

	if name == "" then return nil end

	if server then
		server = M.trim(server)
		if server == "" then server = nil end
	end

	return name, server
end

local function AddGuild (name, server)
	local c = DB()

	if not c then return nil end

	EnsureCounts()

	if guildTotal >= MAX_GUILDS then return nil end

	local gkey, added = AddGuildRaw(c, name, server)

	if added then
		guildTotal = guildTotal + 1
		M.ShowMsg(format(L["GUILD_10"], name))
		Refresh()
	else
		M.ShowMsg(format(L["GUILD_9"], name))
	end

	return gkey, added
end

function M.GIL_GuildAddGuildDialog (prefill)
	M.GIL_ShowDialog({
		key        = "guildadd",
		text       = "|cffffff00%s|cffffffff\n\n" .. L["GUILD_8"],
		editBox    = true,
		editText   = prefill or "",
		maxLetters = NAME_MAX + 40,
		button1    = L["NOTE_3"],
		button2    = L["BOX_5"],
		onAccept   = function (text)
			local name, server = ParseGuildText(text)

			if name then AddGuild(name, server) end
		end,
	}, L["GUILD_6"])
end

function M.GIL_GuildOpen ()
	M.GIL_GUI()

	local tab = _G["GILTab4"]

	if tab and tab.Click then tab:Click() end
end

-- "/gi guild" opens the tab, "/gi guild Guild Name [@ Server]" adds a guild
function M.GIL_GuildFromCmd (raw)
	local rest = M.trim(tostring(raw or ""))

	rest = M.trim(string.match(rest, "^%S+%s*(.*)$") or "")		-- drop the word "guild"

	if rest == "" then
		M.GIL_GuildOpen()
		return
	end

	if sub(rest, 1, 1) == '"' and sub(rest, -1) == '"' and #rest > 1 then
		rest = sub(rest, 2, -2)
	end

	local name, server = ParseGuildText(rest)

	if name then AddGuild(name, server) end
end

function M.GIL_GuildAddUnitGuild (unit)
	local ok, gname, grealm = pcall(GuildOf, unit)

	if not ok or not gname then
		M.ShowMsg(L["GUILD_36"])
		return false
	end

	local server = grealm

	if not server then
		local full = M.GetUnitFullName(unit)

		server = full and M.getServer(PlayerKey(full)) or V.serverName
	end

	local gkey = AddGuild(CleanName(gname), server)

	if gkey then pcall(CheckUnit, unit) end

	return gkey ~= nil
end

function M.GIL_GuildMenuUnit (root, unit)
	local full = M.GetUnitFullName(unit)
	local pkey = full and PlayerKey(full)

	if not pkey then return end

	if M.hasGuildIgnored(pkey) then
		root:CreateButton(L["GUILD_17"],
			function ()
				RemovePlayer(pkey, true)
				Refresh()
			end)
	else
		local ok, gname = pcall(GuildOf, unit)

		if ok and gname then
			root:CreateButton(L["GUILD_18"],
				function ()
					M.GIL_GuildAddUnitGuild(unit)
				end)
		end
	end
end

-----------------
-- SHARE STUFF --
-----------------

-- <guildCount>;<nameLen>,<serverLen>,<playerCount>:<name><server>   followed by <playerCount> * <len>:<player>

local GUILD_VERSION = 1

local function Collect (onlyKey, withPlayers)
	local c = DB()
	local list, byKey = {}, {}

	for gkey, g in pairs(c.guilds) do
		if not onlyKey or gkey == onlyKey then
			local item = { name = g.name, server = g.server, players = {} }

			list[#list + 1] = item
			byKey[gkey] = item
		end
	end

	table.sort(list, function (a, b) return lower(a.name) < lower(b.name) end)

	if withPlayers then
		for pkey, gkey in pairs(c.players) do
			if byKey[gkey] then
				local t = byKey[gkey].players

				t[#t + 1] = pkey
			end
		end

		for i = 1, #list do table.sort(list[i].players) end
	end

	return list
end

local function Encode (list)
	local parts = { #list .. ";" }

	for i = 1, #list do
		local g = list[i]

		parts[#parts + 1] = format("%d,%d,%d:%s%s", #g.name, #g.server, #g.players, g.name, g.server)

		for j = 1, #g.players do
			parts[#parts + 1] = format("%d:%s", #g.players[j], g.players[j])
		end
	end

	return table.concat(parts)
end

local function Decode (body, version)
	local count, pos = string.match(body, "^(%d+);()")

	count = tonumber(count)

	if not count or count < 1 then return nil, "SHARE_6" end
	if count > MAX_GUILDS then return nil, "SHARE_7" end

	local list, total = {}, 0

	for i = 1, count do
		local ln, ls, np, p = string.match(body, "^(%d+),(%d+),(%d+):()", pos)

		if not ln then return nil, "SHARE_6" end

		ln, ls, np = tonumber(ln), tonumber(ls), tonumber(np)

		if ln > NAME_MAX * 4 or ls > 80 or np > MAX_PLAYERS then return nil, "SHARE_6" end

		total = total + np

		if total > MAX_PLAYERS then return nil, "SHARE_7" end
		if p + ln + ls - 1 > #body then return nil, "SHARE_6" end

		local name   = CleanName(sub(body, p, p + ln - 1))
		local server = M.trim((string.gsub(sub(body, p + ln, p + ln + ls - 1), "[%c|]", "")))

		pos = p + ln + ls

		local players = {}

		for j = 1, np do
			local lp, q = string.match(body, "^(%d+):()", pos)

			if not lp then return nil, "SHARE_6" end

			lp = tonumber(lp)

			if lp > 320 or q + lp - 1 > #body then return nil, "SHARE_6" end

			local pkey = string.gsub(sub(body, q, q + lp - 1), "[%c|]", "")

			pos = q + lp
			pkey = PlayerKey(pkey)

			if pkey then players[#players + 1] = pkey end
		end

		if name ~= "" then
			list[#list + 1] = { name = name, server = ServerKey(server), players = players }
		end
	end

	if #list == 0 then return nil, "SHARE_6" end

	return list
end

local function NewItems (list)
	local c = DB()
	local newGuilds, newPlayers = {}, {}
	local seenGuild, seenPlayer = {}, {}

	for i = 1, #list do
		local g    = list[i]
		local gkey = GuildKey(g.name, g.server)

		if not c.guilds[gkey] and not seenGuild[gkey] then
			seenGuild[gkey] = true
			newGuilds[#newGuilds + 1] = g
		end

		for j = 1, #g.players do
			local pkey = g.players[j]

			if not c.players[pkey] and not c.exempt[pkey] and not seenPlayer[pkey] and M.hasGlobalIgnored(pkey) == 0 then
				seenPlayer[pkey] = true
				newPlayers[#newPlayers + 1] = { pkey = pkey, gkey = gkey }
			end
		end
	end

	return newGuilds, newPlayers
end

M.GIL_RegisterShareType("GUILD", {
	version = GUILD_VERSION,
	label   = "GUILD_29",
	doneKey = "GUILD_30",

	decode = Decode,

	preview = function (list)
		local newGuilds, newPlayers = NewItems(list)

		if #newGuilds == 0 and #newPlayers == 0 then
			return L["GUILD_31"], 0
		end

		local names = {}

		for i = 1, math.min(#newGuilds, PREVIEW_LINES) do
			names[#names + 1] = "|cff69CCF0" .. newGuilds[i].name .. "|cffffffff"
		end

		if #newGuilds > PREVIEW_LINES then
			names[#names + 1] = format(L["SHARE_11"], #newGuilds - PREVIEW_LINES)
		end

		return format(L["GUILD_28"], #newGuilds, #newPlayers, #list - #newGuilds) .. "\n\n" .. table.concat(names, "\n"), #newGuilds + #newPlayers
	end,

	apply = function (list)
		local c = DB()
		local newGuilds, newPlayers = NewItems(list)

		EnsureCounts()

		for i = 1, #newGuilds do
			if guildTotal < MAX_GUILDS then
				AddGuildRaw(c, newGuilds[i].name, newGuilds[i].server)
				guildTotal = guildTotal + 1
			end
		end

		local added = #newGuilds

		for i = 1, #newPlayers do
			local gkey = newPlayers[i].gkey

			if c.guilds[gkey] then
				c.players[newPlayers[i].pkey] = gkey
				added = added + 1
			end
		end

		countsDirty = true
		Refresh()

		return added
	end,
})

-- gkey = one guild, nil = all guilds, withPlayers = include the discovered players
function M.GIL_ExportGuilds (gkey, withPlayers)
	local list = Collect(gkey, withPlayers)

	if #list == 0 then
		M.ShowMsg(L["GUILD_32"])
		return
	end

	local str = M.GIL_PackShare("GUILD", GUILD_VERSION, Encode(list))

	if #str > MAX_EXPORT then
		M.ShowMsg(L["GUILD_34"])
		return
	end

	M.GIL_ShowExportDialog(format(L["GUILD_27"], #list), str)
end

----------------
-- GUILD TAB  --
----------------

function M.GIL_BuildGuildTab (MainFrame)

	local K = M.UIKit

	if not K or M.GIL_GuildShow then return end

	local SERVER_HIDDEN = K.SERVER_HIDDEN
	local COL_1 = SERVER_HIDDEN and 400 or 270
	local COL_2 = SERVER_HIDDEN and 1 or 130
	local COL_3 = 80
	local COL_4 = 688 - COL_1 - COL_2 - COL_3

	local selected = 0		-- index into view
	local backState = 0		-- where back goes from the excluded list
	local state    = 0		-- 0 = guild list, 1 = players of one guild, 2 = excluded players (all guilds)
	local viewGuild = nil	-- guildKey while state = 1
	local view     = {}		-- state 0=guildKeys, state 1=player keys
	local rows     = {}
	local headers  = {}

	local ListFrame = CreateFrame("Frame", "GILFrameGuild", MainFrame, "InsetFrameTemplate")

	ListFrame:Hide()
	ListFrame:SetWidth(K.WINDOW_WIDTH - 19)
	ListFrame:SetHeight(K.WINDOW_HEIGHT - K.WINDOW_OFFSET)
	ListFrame:SetPoint("TOPLEFT", MainFrame, "TOPLEFT", 8, -84)

	local prevHeader

	local function Header (idx, width)
		local h = CreateFrame("Button", "GILFrameGuildHeader" .. idx, ListFrame, "ColumnDisplayButtonTemplate")

		h:SetWidth(width)
		h:SetID(idx)
		h:SetScript("OnClick", function () end)

		if h.Text then h.Text:SetFontObject("GameFontHighlight") end

		if prevHeader then
			h:SetPoint("LEFT", prevHeader, "RIGHT", 0, 0)
		else
			h:SetPoint("TOPLEFT", ListFrame, "TOPLEFT", 1, 22)
		end

		prevHeader = h
		headers[idx] = h

		return h
	end

	Header(1, COL_1)
	Header(2, COL_2)
	Header(3, COL_3)
	Header(4, COL_4)

	local ScrollFrame = CreateFrame("ScrollFrame", "GILGuildScrollFrame", ListFrame, "FauxScrollFrameTemplate")

	ScrollFrame:SetWidth(K.WINDOW_WIDTH - 46)
	ScrollFrame:SetHeight(K.BUTTON_TOTAL * K.BUTTON_HEIGHT)
	ScrollFrame:SetPoint("TOPLEFT", 0, -4)

	ListFrame.infotext = ListFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	ListFrame.infotext:SetWidth(400)
	ListFrame.infotext:SetJustifyH("CENTER")
	ListFrame.infotext:SetPoint("TOP", 0, 46)

	ListFrame.hint = ListFrame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ListFrame.hint:SetWidth(150)
	ListFrame.hint:SetJustifyH("RIGHT")
	ListFrame.hint:SetPoint("TOPRIGHT", -2, 54)
	ListFrame.hint:SetText(L["HINT_1"])

	local function BuildView ()
		local c = DB()

		view = {}

		if not c then return end

		EnsureCounts()

		if state == 0 then
			for gkey in pairs(c.guilds) do view[#view + 1] = gkey end

			table.sort(view, function (a, b)
				return lower(c.guilds[a].name) < lower(c.guilds[b].name)
			end)
		elseif state == 2 then
			for pkey in pairs(c.exempt) do view[#view + 1] = pkey end

			table.sort(view, function (a, b) return lower(a) < lower(b) end)
		else
			if not c.guilds[viewGuild] then
				state, viewGuild = 0, nil
				return BuildView()
			end

			for pkey, gkey in pairs(c.players) do
				if gkey == viewGuild then view[#view + 1] = pkey end
			end

			table.sort(view, function (a, b) return lower(a) < lower(b) end)
		end

		if selected > #view then selected = #view end
	end

	local addButton, removeButton, excludedButton, shareButton, scanButton

	local function SetColumns (w1, w2, w3, w4)
		headers[1]:SetWidth(w1)
		headers[2]:SetWidth(w2)

		for i = 1, #rows do
			rows[i].c1:SetWidth(w1)
			rows[i].c2:SetWidth(w2)
		end
	end

	local function UpdateLayout ()
		if state == 0 then
			SetColumns(COL_1, COL_2)

			headers[1]:SetText(L["GUILD_3"])
			headers[2]:SetText(L["COL_2"])
			headers[3]:SetText(L["GUILD_4"])
			headers[4]:SetText(L["GUILD_5"])

			if SERVER_HIDDEN then headers[2]:Hide() else headers[2]:Show() end

			headers[3]:Show()
			headers[4]:Show()

			addButton:SetText(L["GUILD_6"])
			removeButton:SetText(L["GUILD_7"])
			excludedButton:SetText(L["GUILD_47"])

			shareButton:Show()
			scanButton:Show()
			excludedButton:ClearAllPoints()
			excludedButton:SetPoint("LEFT", scanButton, "RIGHT", 4, 0)
		else
			if SERVER_HIDDEN then SetColumns(687, 1) else SetColumns(344, 344) end

			headers[1]:SetText(L["COL_1"])
			headers[2]:SetText(L["COL_2"])

			if SERVER_HIDDEN then headers[2]:Hide() else headers[2]:Show() end

			headers[3]:Hide()
			headers[4]:Hide()

			if state == 1 then
				addButton:SetText(L["GUILD_14"])
				removeButton:SetText(L["GUILD_15"])
				excludedButton:SetText(L["GUILD_47"])

				shareButton:Show()
				scanButton:Show()
				excludedButton:ClearAllPoints()
				excludedButton:SetPoint("LEFT", scanButton, "RIGHT", 4, 0)
			else
				addButton:SetText(L["GUILD_51"])
				removeButton:SetText(L["BOX_10"])
				excludedButton:SetText(L["GUILD_14"])

				shareButton:Hide()
				scanButton:Hide()
				excludedButton:ClearAllPoints()
				excludedButton:SetPoint("BOTTOMLEFT", -1, -24)
			end
		end
	end

	local function DrawUpdate ()
		BuildView()
		UpdateLayout()

		local c = DB()

		FauxScrollFrame_Update(ScrollFrame, #view, K.BUTTON_TOTAL, K.BUTTON_HEIGHT)

		if state == 0 then
			ListFrame.infotext:SetText(format(L["GUILD_2"], #view))
		elseif state == 1 then
			ListFrame.infotext:SetText(format(L["GUILD_21"], #view, c.guilds[viewGuild].name))
		else
			ListFrame.infotext:SetText(format(L["GUILD_48"], #view))
		end

		local offset = FauxScrollFrame_GetOffset(ScrollFrame)

		for count = 1, K.BUTTON_TOTAL do
			local idx = count + offset
			local key = view[idx]
			local row = rows[count]

			if key then
				if state == 0 then
					local g = c.guilds[key]

					row.c1:SetText(g.name)
					row.c2:SetText(M.prettyServer(g.server) or g.server)
					row.c3:SetText(tostring(counts[key] or 0))
					row.c4:SetText(g.date or "")
				else
					row.c1:SetText(M.removeServer(key, true) or key)
					row.c2:SetText(M.prettyServer(M.getServer(key)) or M.getServer(key))
					row.c3:SetText("")
					row.c4:SetText("")
				end

				row:SetID(idx)

				if selected == idx then
					row:LockHighlight()
				else
					row:UnlockHighlight()
				end

				row:Show()
			else
				row:Hide()
			end
		end
	end

	ScrollFrame:SetScript("OnVerticalScroll", function (self, offset)
		FauxScrollFrame_OnVerticalScroll(self, offset, K.BUTTON_HEIGHT, DrawUpdate)
	end)

	local function OpenGuild (gkey)
		state, viewGuild, selected = 1, gkey, 0
		DrawUpdate()
	end

	local function CloseGuild ()
		state, viewGuild, selected = 0, nil, 0
		DrawUpdate()
	end

	local function OpenExcluded ()
		backState = state
		state, selected = 2, 0
		DrawUpdate()
	end

	local function CloseExcluded ()
		state, selected = backState, 0
		DrawUpdate()
	end

	local function ConfirmRemoveGuild (gkey)
		local c = DB()
		local g = c and c.guilds[gkey]

		if not g then return end

		M.GIL_ShowDialog({
			key      = "guildremoveguild",
			text     = "|cffffff00%s|cffffffff\n\n" .. format(L["GUILD_12"], counts[gkey] or 0),
			button1  = L["BOX_10"],
			button2  = L["BOX_5"],
			onAccept = function ()
				RemoveGuild(gkey)

				if viewGuild == gkey then state, viewGuild = 0, nil end

				DrawUpdate()
			end,
		}, g.name)
	end

	local function DoRemove (pkey, exclude)
		RemovePlayer(pkey, exclude)
		DrawUpdate()
	end

	-- the two ways to remove a discovered player
	local function AddRemoveItems (root, pkey)
		root:CreateButton(L["GUILD_49"], function () DoRemove(pkey, true) end)
		root:CreateButton(L["GUILD_50"], function () DoRemove(pkey, false) end)
	end

	local function RemoveMenu (pkey)
		if not pkey or not M.hasGuildIgnored(pkey) then return end

		M.GIL_ContextMenu(UIParent,
			function (owner, root)
				root:CreateTitle(M.removeServer(pkey, true) or pkey)
				root:CreateDivider()
				AddRemoveItems(root, pkey)
				root:CreateDivider()
				root:CreateButton(L["RCM_5"], function () end)
			end
		)
	end

	local function AddExcludedDialog ()
		M.GIL_ShowDialog({
			key        = "guildexclude",
			text       = "|cffffff00%s|cffffffff\n\n" .. L["GUILD_52"],
			editBox    = true,
			editText   = "",
			maxLetters = NAME_MAX + 40,
			button1    = L["NOTE_3"],
			button2    = L["BOX_5"],
			onAccept   = function (text)
				local pkey = PlayerKey(CleanName(text))

				if not pkey then return end

				if DB().exempt[pkey] then
					M.ShowMsg(format(L["GUILD_54"], M.removeServer(pkey, true) or pkey))
				else
					ExcludePlayer(pkey)
				end

				DrawUpdate()
			end,
		}, L["GUILD_47"])
	end

	local function RowClick (self, button, down)
		if down == true then return end

		local id  = self:GetID()
		local key = view[id]

		if not key then return end

		if state == 0 and selected == id and button == "LeftButton" then
			OpenGuild(key)
			return
		elseif selected ~= id then
			selected = id
			DrawUpdate()
		end

		if button == "RightButton" then
			M.GIL_ContextMenu(UIParent,
				function (owner, root)
					if state == 0 then
						local g = DB().guilds[key]

						root:CreateTitle(g.name)
						root:CreateDivider()
						root:CreateButton(L["GUILD_16"], function () OpenGuild(key) end)
						root:CreateButton(L["GUILD_37"], function () M.GIL_GuildScan(key) end)
						root:CreateButton(L["GUILD_23"], function () M.GIL_ExportGuilds(key, true) end)
						root:CreateDivider()
						root:CreateButton(L["GUILD_7"], function () ConfirmRemoveGuild(key) end)
					elseif state == 1 then
						root:CreateTitle(M.removeServer(key, true) or key)
						root:CreateDivider()
						AddRemoveItems(root, key)
					else
						root:CreateTitle(M.removeServer(key, true) or key)
						root:CreateDivider()
						root:CreateButton(L["GUILD_53"], function () UnexcludePlayer(key); DrawUpdate() end)
					end

					root:CreateDivider()
					root:CreateButton(L["RCM_5"], function () end)
				end
			)
		end
	end

	for count = 1, K.BUTTON_TOTAL do
		local row = K.CreateListButton(ListFrame)

		rows[count] = row

		if count == 1 then
			row:SetPoint("TOPLEFT", ScrollFrame, -1, 0)
		else
			row:SetPoint("TOP", rows[count - 1], "BOTTOM")
		end

		row:SetSize(K.BUTTON_WIDTH, K.BUTTON_HEIGHT)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row:SetScript("OnClick", RowClick)

		row.c1 = row.name
		row.c1:SetWidth(COL_1)

		row.c2 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.c2:SetPoint("LEFT", row.c1, "RIGHT", 0, 0)
		row.c2:SetWidth(COL_2)
		row.c2:SetJustifyH("LEFT")

		if SERVER_HIDDEN then row.c2:Hide() end

		row.c3 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.c3:SetPoint("LEFT", row.c2, "RIGHT", 0, 0)
		row.c3:SetWidth(COL_3)
		row.c3:SetJustifyH("LEFT")

		row.c4 = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.c4:SetPoint("LEFT", row.c3, "RIGHT", 0, 0)
		row.c4:SetWidth(COL_4)
		row.c4:SetJustifyH("LEFT")
		row.c4:SetWordWrap(false)
	end

	ListFrame:SetScript("OnShow", DrawUpdate)

	-- BOTTOM BUTTONS

	addButton = CreateFrame("Button", "GILFrameGuildAdd", ListFrame, "UIPanelButtonTemplate")
	addButton:SetSize(110, 22)
	addButton:SetPoint("BOTTOMRIGHT", -1, -24)
	addButton:SetScript("OnClick", function ()
		if state == 0 then
			M.GIL_GuildAddGuildDialog()
		elseif state == 1 then
			CloseGuild()
		else
			AddExcludedDialog()
		end
	end)

	removeButton = CreateFrame("Button", "GILFrameGuildRemove", ListFrame, "UIPanelButtonTemplate")
	removeButton:SetSize(110, 22)
	removeButton:SetPoint("RIGHT", addButton, "LEFT", 0, 0)
	removeButton:SetScript("OnClick", function ()
		local key = view[selected]

		if not key then return end

		if state == 0 then
			ConfirmRemoveGuild(key)
		elseif state == 1 then
			RemoveMenu(key)
		else
			UnexcludePlayer(key)
			DrawUpdate()
		end
	end)

	shareButton = CreateFrame("Button", "GILFrameGuildShare", ListFrame, "UIPanelButtonTemplate")
	shareButton:SetSize(110, 22)
	shareButton:SetText(L["BUT_12"])
	shareButton:SetPoint("BOTTOMLEFT", -1, -24)

	scanButton = CreateFrame("Button", "GILFrameGuildScan", ListFrame, "UIPanelButtonTemplate")
	scanButton:SetSize(140, 22)
	scanButton:SetText(L["GUILD_37"])
	scanButton:SetPoint("LEFT", shareButton, "RIGHT", 4, 0)
	scanButton:SetScript("OnClick", function ()
		M.GIL_GuildScan((state == 1 and viewGuild) or (state == 0 and view[selected]) or nil)
	end)

	excludedButton = CreateFrame("Button", "GILFrameGuildExcluded", ListFrame, "UIPanelButtonTemplate")
	excludedButton:SetSize(110, 22)
	excludedButton:SetText(L["GUILD_47"])
	excludedButton:SetPoint("LEFT", scanButton, "RIGHT", 4, 0)
	excludedButton:SetScript("OnClick", function ()
		if state == 2 then
			CloseExcluded()
		else
			OpenExcluded()
		end
	end)
	shareButton:SetScript("OnClick", function ()
		M.GIL_ContextMenu(UIParent,
			function (owner, root)
				root:CreateTitle(L["GUILD_22"])
				root:CreateDivider()

				local gkey = (state == 1 and viewGuild) or (state == 0 and view[selected]) or nil

				if gkey then
					root:CreateButton(L["GUILD_23"], function () M.GIL_ExportGuilds(gkey, true) end)
				end

				root:CreateButton(L["GUILD_24"], function () M.GIL_ExportGuilds(nil, false) end)
				root:CreateButton(L["GUILD_25"], function () M.GIL_ExportGuilds(nil, true) end)
				root:CreateDivider()
				root:CreateButton(L["GUILD_26"], function () M.GIL_ShowImportDialog("GUILD", L["GUILD_26"]) end)
				root:CreateDivider()
				root:CreateButton(L["RCM_5"], function () end)
			end
		)
	end)

	----------------------
	-- TAB INTERFACE    --
	----------------------

	function M.GIL_GuildShow ()
		ListFrame:Show()
		DrawUpdate()
	end

	function M.GIL_GuildHide ()
		ListFrame:Hide()
	end

	function M.GIL_GuildRefresh ()
		if ListFrame:IsShown() then DrawUpdate() end
	end
end
