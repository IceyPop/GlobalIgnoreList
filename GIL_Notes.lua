------------------
-- PLAYER NOTES --
------------------

-- I'm experimenting with moving all GUI and functions related to one thing here, rather than having a separate GUI source
-- so I will either incorporate this into GUI or split out all the other code into their own files (chat filter, ignore, etc)

-- Saved data: GlobalIgnoreDB.playerNotes = { { name="Name-Server", note="", kos=false, faction="Unknown", date="08 Nov 2026" }, ... }
-- Options:    GlobalIgnoreDB.kosEnabled (default on), GlobalIgnoreDB.kosSoundKey (default "raid", "none" = chat only)

local addonName, addon = ...
local L = addon.L
local V = addon.V
local M = addon.M

local floor  = math.floor
local sub    = string.sub
local byte   = string.byte
local format = string.format

local NOTE_MAX       = 1000
local NAME_MAX       = 80
local ALERT_COOLDOWN = 60		-- seconds before the same player can alert again
local MAX_IMPORT     = 2000
local PREVIEW_LINES  = 8

-----------
-- DATA  --
-----------

local index    = {}
local indexSrc = nil
local kosCount = 0
local dirty    = true

local function NotesDB ()
	local db = GlobalIgnoreDB

	if not db then return {} end

	if type(db.playerNotes) ~= "table" then
		db.playerNotes = {}
	end

	return db.playerNotes
end

local function RebuildIndex ()
	local list = NotesDB()

	index    = {}
	kosCount = 0

	for i = 1, #list do
		index[list[i].name] = i

		if list[i].kos then kosCount = kosCount + 1 end
	end

	indexSrc = list
	dirty    = false
end

local function EnsureIndex ()
	if dirty or indexSrc ~= NotesDB() then
		RebuildIndex()
	end
end

local function KeyFor (name)
	name = M.trim(tostring(name or ""))

	if name == "" then return nil end

	return M.Proper(M.addServer(name))
end

local function CleanNote (text)
	text = tostring(text or "")
	text = string.gsub(text, "|", "")					-- no color codes or links
	text = string.gsub(text, "\r", "")
	text = string.gsub(text, "[%c]", function (c) if c == "\n" then return c end return " " end)
	text = M.trim(text)

	if #text > NOTE_MAX then
		text = sub(text, 1, NOTE_MAX)

		-- never leave half of a UTF-8 character at the end
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

	return text
end

local function OneLine (text)
	return (string.gsub(text or "", "%s+", " "))
end

local FACTION_COLORS = { Alliance = "|cff3399ff", Horde = "|cffe60000", Neutral = "|cffffd100" }

local function FactionName (faction)

	if faction == "Alliance" then return _G.FACTION_ALLIANCE or "Alliance" end
	if faction == "Horde"    then return _G.FACTION_HORDE or "Horde" end
	if faction == "Neutral"  then return _G.FACTION_NEUTRAL or "Neutral" end

	return L["NOTE_38"]
end

local function FactionText (faction)
	return (FACTION_COLORS[faction] or "|cff888888") .. FactionName(faction)
end

local function SortNotes ()
	local list = NotesDB()

	table.sort(list, function (a, b)
		return string.lower(a.name) < string.lower(b.name)
	end)

	dirty = true
end

local function FindNote (key)
	EnsureIndex()

	return key and index[key] or nil
end

local function ResolveFaction (unit)
	if not UnitExists(unit) or not UnitIsPlayer(unit) then return false end

	EnsureIndex()

	local full = M.GetUnitFullName(unit)

	if not full then return false end

	local idx   = index[M.Proper(M.addServer(full))]
	local entry = idx and NotesDB()[idx]

	if entry and (entry.faction == nil or entry.faction == "Unknown") then
		local faction = UnitFactionGroup(unit)

		if faction and faction ~= "" and not (issecretvalue and issecretvalue(faction)) then
			entry.faction = faction

			return true
		end
	end

	return false
end

local function UpdateNoteFaction (unit)
	if #NotesDB() == 0 then return end

	local ok, changed = pcall(ResolveFaction, unit)

	if ok and changed and M.GIL_NotesRefresh then
		M.GIL_NotesRefresh()
	end
end

-- returns index, alreadyExisted
local function AddNote (name, note, kos)
	local key = KeyFor(name)

	if not key then return nil end

	local found = FindNote(key)

	if found then return found, true end

	local list = NotesDB()

	list[#list + 1] = {
		name = key,
		note = CleanNote(note),
		kos  = (kos == true),
		faction = "Unknown",
		date = date("%d %b %Y"),
	}

	SortNotes()

	UpdateNoteFaction("target")
	UpdateNoteFaction("mouseover")
	UpdateNoteFaction("focus")

	return FindNote(key), false
end

local function RemoveNote (idx)
	local list = NotesDB()

	if list[idx] then
		table.remove(list, idx)
		dirty = true
	end
end

function M.GIL_NoteFind (name)
	return FindNote(KeyFor(name))
end

--------------------
-- KILL ON SIGHT  --
--------------------

local lastAlert = {}

local SOUND_DIR = "Interface\\AddOns\\" .. addonName .. "\\Sounds\\"
local RAID_ID   = (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959

M.GIL_KoSSounds = {
	{ key = "none",   label = L["NOTE_40"] },
	{ key = "raid",   label = "Raid Warning", id = RAID_ID },
	{ key = "beep",   label = L["NOTE_41"],   files = { SOUND_DIR .. "Beep.ogg" } },
	{ key = "custom", label = L["NOTE_42"],   files = { SOUND_DIR .. "Custom.ogg", SOUND_DIR .. "Custom.mp3" } },
}

function M.GIL_KoSSoundKey ()
	local db = GlobalIgnoreDB

	if db.kosSoundKey then return db.kosSoundKey end

	return "raid"
end

function M.GIL_KoSSoundLabel ()
	local key = M.GIL_KoSSoundKey()

	for i = 1, #M.GIL_KoSSounds do
		if M.GIL_KoSSounds[i].key == key then return M.GIL_KoSSounds[i].label end
	end

	return M.GIL_KoSSounds[2].label
end

function M.GIL_PlayKoSSound (key, preview)
	key = key or M.GIL_KoSSoundKey()

	if key == "none" then return end

	for i = 1, #M.GIL_KoSSounds do
		local s = M.GIL_KoSSounds[i]

		if s.key == key and s.files then
			for f = 1, #s.files do
				local ok, willPlay = pcall(PlaySoundFile, s.files[f], "Master")

				if ok and willPlay then return end
			end

			if preview then M.ShowMsg(L["NOTE_43"]) end

			break
		end
	end

	pcall(PlaySound, RAID_ID, "Master")	
end

local function Alert (entry, test)
	local now = GetTime()

	if not test then
		if lastAlert[entry.name] and now - lastAlert[entry.name] < ALERT_COOLDOWN then return end

		lastAlert[entry.name] = now
	end

	M.GIL_PlayKoSSound()

	local shown  = M.removeServer(entry.name, true) or entry.name
	local server = M.getServer(entry.name)

	if server ~= V.serverName then
		shown = shown .. "-" .. (M.prettyServer(server) or server)
	end

	local zone = GetZoneText() or ""

	M.ShowMsg(format(L["NOTE_20"], shown, zone))

	local note = OneLine(entry.note)

	if note ~= "" then
		if #note > 120 then note = sub(note, 1, 120) .. "..." end

		M.ShowMsg(format(L["NOTE_21"], note))
	end
end

local kosPlate = {}

local function KosEntry (key)
	if not key then return end

	EnsureIndex()

	local idx   = key and index[key]
	local entry = idx and NotesDB()[idx]

	if entry and entry.kos then return entry end
end

local function CheckUnit (unit)
	if not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end

	local full = M.GetUnitFullName(unit)

	if not full then return end

	local key   = M.Proper(M.addServer(full))
	local entry = KosEntry(key)

	if not entry then return end

	if sub(unit, 1, 9) == "nameplate" then kosPlate[unit] = key end

	if UnitAffectingCombat(unit) then
		Alert(entry, false)
	end
end

local function PlateActive (unit)
	-- A unit we already know is listed did something (flags, damage, spell cast)
	local entry = KosEntry(kosPlate[unit])

	if entry and UnitAffectingCombat(unit) then
		Alert(entry, false)
	end
end

local function QuickCheck (unit)
	if not GlobalIgnoreDB or GlobalIgnoreDB.kosEnabled == false then return end

	EnsureIndex()

	if kosCount == 0 then return end

	pcall(CheckUnit, unit)
end

-- MAIN --

local alertFrame = CreateFrame("Frame")

alertFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
alertFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
alertFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
alertFrame:RegisterEvent("UNIT_FLAGS")
alertFrame:RegisterEvent("UNIT_COMBAT")
alertFrame:RegisterEvent("UNIT_SPELLCAST_START")
pcall(alertFrame.RegisterEvent, alertFrame, "NAME_PLATE_UNIT_ADDED")
pcall(alertFrame.RegisterEvent, alertFrame, "NAME_PLATE_UNIT_REMOVED")

alertFrame:SetScript("OnEvent", function (self, event, unit)
	if event == "UNIT_FLAGS" or event == "UNIT_COMBAT" or event == "UNIT_SPELLCAST_START" then
		if kosPlate[unit] then
			pcall(PlateActive, unit)
		elseif event == "UNIT_FLAGS" and (unit == "target" or unit == "focus") then
			QuickCheck(unit)
		end
	elseif event == "NAME_PLATE_UNIT_REMOVED" then
		kosPlate[unit] = nil
	elseif event == "NAME_PLATE_UNIT_ADDED" then
		UpdateNoteFaction(unit)
		QuickCheck(unit)
	elseif event == "PLAYER_TARGET_CHANGED" then
		UpdateNoteFaction("target")
		QuickCheck("target")
	elseif event == "PLAYER_FOCUS_CHANGED" then
		QuickCheck("focus")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		UpdateNoteFaction("mouseover")
		QuickCheck("mouseover")
	end
end)

-----------------
-- SHARE NOTES --
-----------------

-- Body: <count>; then one per note: <kos 0|1>,<faction a|h|n|u>,<nameLen>,<noteLen>:<name><note>

local NOTE_VERSION = 1

local FACTION_TO_CODE = { Alliance = "a", Horde = "h", Neutral = "n", Unknown = "u" }
local CODE_TO_FACTION = { a = "Alliance", h = "Horde", n = "Neutral", u = "Unknown" }

local function EncodeNotes (list)
	local parts = { #list .. ";" }

	for i = 1, #list do
		local name = sub(list[i].name, 1, NAME_MAX)
		local note = CleanNote(list[i].note)

		parts[#parts + 1] = format("%d,%s,%d,%d:%s%s", list[i].kos and 1 or 0, FACTION_TO_CODE[list[i].faction] or "u", #name, #note, name, note)
	end

	return table.concat(parts)
end

local function DecodeNotes (body)
	local count, pos = string.match(body, "^(%d+);()")

	count = tonumber(count)

	if not count or count < 1 then return nil, "SHARE_6" end
	if count > MAX_IMPORT then return nil, "SHARE_7" end

	local list = {}

	for i = 1, count do
		local k, f, ln, lt, np = string.match(body, "^([01]),([ahnu]),(%d+),(%d+):()", pos)

		if not k then return nil, "SHARE_6" end

		ln, lt = tonumber(ln), tonumber(lt)

		if ln > NAME_MAX * 4 or lt > NOTE_MAX * 4 then return nil, "SHARE_6" end
		if np + ln + lt - 1 > #body then return nil, "SHARE_6" end

		local name = string.gsub(sub(body, np, np + ln - 1), "[%c|]", "")
		local note = CleanNote(sub(body, np + ln, np + ln + lt - 1))

		pos = np + ln + lt

		local key = KeyFor(name)

		if key then
			list[#list + 1] = { name = key, note = note, kos = (k == "1"), faction = CODE_TO_FACTION[f] or "Unknown" }
		end
	end

	if #list == 0 then return nil, "SHARE_6" end

	return list
end

local function CollectNotes ()
	local db   = NotesDB()
	local list = {}

	for i = 1, #db do list[#list + 1] = db[i] end

	return list
end

local function NewNotes (list)
	EnsureIndex()

	local seen  = {}
	local fresh = {}

	for i = 1, #list do
		local key = list[i].name

		if not index[key] and not seen[key] then
			seen[key] = true
			fresh[#fresh + 1] = list[i]
		end
	end

	return fresh
end

M.GIL_RegisterShareType("NOTE", {
	version = NOTE_VERSION,
	label   = "NOTE_29",
	doneKey = "NOTE_31",

	decode = DecodeNotes,

	preview = function (list)
		local fresh = NewNotes(list)

		if #fresh == 0 then
			return L["NOTE_33"], 0
		end

		local kos   = 0
		local names = {}

		for i = 1, #fresh do
			if fresh[i].kos then kos = kos + 1 end

			if i <= PREVIEW_LINES then
				names[#names + 1] = "|cff69CCF0" .. (M.removeServer(fresh[i].name, true) or fresh[i].name) .. "|cffffffff"
			end
		end

		if #fresh > PREVIEW_LINES then
			names[#names + 1] = format(L["SHARE_11"], #fresh - PREVIEW_LINES)
		end

		return format(L["NOTE_28"], #fresh, #list - #fresh, kos) .. "\n\n" .. table.concat(names, "\n"), #fresh
	end,

	apply = function (list)
		local fresh = NewNotes(list)
		local db    = NotesDB()

		for i = 1, #fresh do
			db[#db + 1] = { name = fresh[i].name, note = fresh[i].note, kos = fresh[i].kos, faction = fresh[i].faction or "Unknown", date = date("%d %b %Y") }
		end

		SortNotes()

		if M.GIL_NotesRefresh then M.GIL_NotesRefresh() end

		return #fresh
	end,
})

function M.GIL_ExportNotes ()
	local list = CollectNotes()

	if #list == 0 then
		M.ShowMsg(L["NOTE_30"])
		return
	end

	M.GIL_ShowExportDialog(format(L["NOTE_27"], #list), M.GIL_PackShare("NOTE", NOTE_VERSION, EncodeNotes(list)))
end

---------------
-- ADD STUFF --
---------------

-- Shows the window on the Player Notes tab and optionally opens the editor for idx.
function M.GIL_NotesOpen (idx)
	M.GIL_GUI()

	local tab = _G["GILTab3"]

	if tab and tab.Click then tab:Click() end

	if idx and M.GIL_NotesEdit then
		M.GIL_NotesEdit(idx)
	end
end

function M.GIL_NoteAddUnit (unit, kos)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return false end

	local full = M.GetUnitFullName(unit)

	if not full then return false end

	local idx, existed = AddNote(full, "", kos)

	if not idx then return false end

	UpdateNoteFaction(unit)

	local entry = NotesDB()[idx]

	if existed then
		if kos then entry.kos = true end
		dirty = true
	end

	M.GIL_NotesOpen(idx)

	return true
end

function M.GIL_NotesAddDialog (prefill, unit)
	if not prefill or prefill == "" then
		prefill = ""

		if UnitExists("target") and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
			prefill = M.GetUnitFullName("target") or ""
		end
	end

	M.GIL_ShowDialog({
		key        = "notesadd",
		text       = "|cffffff00%s|cffffffff\n\n" .. L["NOTE_2"],
		editBox    = true,
		editText   = prefill,
		maxLetters = NAME_MAX,
		button1    = L["NOTE_3"],
		button2    = L["BOX_5"],
		onAccept   = function (text)
			local idx, existed = AddNote(text, "", false)

			if not idx then return end

			if unit then UpdateNoteFaction(unit) end

			if existed then
				M.ShowMsg(format(L["NOTE_34"], M.removeServer(NotesDB()[idx].name, true) or text))
			end

			M.GIL_NotesOpen(idx)
		end,
	}, L["NOTE_1"])
end

-- This all needs to be redone this is sloppy mess to adapt for Forever, same copied to guild ignore too.
-- Command line revamp needed in general tbh

function M.GIL_NoteFromCmd (raw, kos)
	local rest = M.trim(tostring(raw or ""))

	rest = M.trim(string.match(rest, "^%S+%s*(.*)$") or "")		-- drop the "note" / "kos" word

	if rest == "" then
		if not M.GIL_NoteAddUnit("target", kos) then
			M.GIL_NotesAddDialog()
		end

		return
	end

	local name, note

	if sub(rest, 1, 1) == '"' then
		name, note = string.match(rest, '^"([^"]+)"%s*(.*)$')

		if not name then
			name = string.match(rest, '^"(.*)$')
			note = ""
		end
	else
		if V.wowIsForever == true and UnitExists("target") and UnitIsPlayer("target") then
			local first, last = UnitName("target")

			if first and last and last ~= "" and not (issecretvalue and (issecretvalue(first) or issecretvalue(last))) then
				local twoWords = first .. " " .. last

				if string.lower(sub(rest, 1, #twoWords)) == string.lower(twoWords) then
					local after = sub(rest, #twoWords + 1, #twoWords + 1)

					if after == "" or after == " " then
						name = twoWords
						note = sub(rest, #twoWords + 1)
					end
				end
			end
		end

		if not name then
			name, note = string.match(rest, "^(%S+)%s*(.*)$")
		end
	end

	name = M.trim(name or "")

	if name == "" then
		M.GIL_NotesAddDialog()
		return
	end

	local idx, existed = AddNote(name, note, kos)

	if not idx then return end

	local entry = NotesDB()[idx]

	if existed then
		if M.trim(note or "") ~= "" then entry.note = CleanNote(note) end
		if kos then entry.kos = true end
	end

	dirty = true

	M.ShowMsg(format(L["NOTE_35"], M.removeServer(entry.name, true) or entry.name) .. (entry.kos and (" (" .. L["NOTE_22"] .. ")") or ""))

	if M.GIL_NotesRefresh then M.GIL_NotesRefresh() end
end

----------------
-- NOTES TAB  --
----------------

function M.GIL_BuildNotesTab (MainFrame)

	local K = M.UIKit

	if not K or M.GIL_NotesShow then return end

	local SERVER_HIDDEN = K.SERVER_HIDDEN
	local COL_NAME      = SERVER_HIDDEN and 184 or 130
	local COL_SERVER    = SERVER_HIDDEN and 1 or 140
	local COL_FACTION   = 66
	local COL_KOS       = 38
	local COL_NOTE      = 688 - COL_NAME - COL_SERVER - COL_FACTION - COL_KOS

	local selected  = 0
	local editIndex = 0
	local state     = 0		-- 0 = list, 1 = editor
	local rows      = {}

	-----------
	-- LIST  --
	-----------

	local ListFrame = CreateFrame("Frame", "GILFrameNotes", MainFrame, "InsetFrameTemplate")

	ListFrame:Hide()
	ListFrame:SetWidth(K.WINDOW_WIDTH - 19)
	ListFrame:SetHeight(K.WINDOW_HEIGHT - K.WINDOW_OFFSET)
	ListFrame:SetPoint("TOPLEFT", MainFrame, "TOPLEFT", 8, -84)

	local prevHeader

	local function Header (idx, text, width)
		local h = CreateFrame("Button", "GILFrameNotesHeader" .. idx, ListFrame, "ColumnDisplayButtonTemplate")

		h:SetWidth(width)
		h:SetText(text)
		h:SetID(idx)
		h:SetScript("OnClick", function () end)

		if h.Text then h.Text:SetFontObject("GameFontHighlight") end

		if prevHeader then
			h:SetPoint("LEFT", prevHeader, "RIGHT", 0, 0)
		else
			h:SetPoint("TOPLEFT", ListFrame, "TOPLEFT", 1, 22)
		end

		prevHeader = h

		return h
	end

	Header(1, L["COL_1"], COL_NAME)

	local serverHeader = Header(2, L["COL_2"], COL_SERVER)

	if SERVER_HIDDEN then serverHeader:Hide() end

	Header(3, L["NOTE_36"], COL_FACTION)
	Header(4, L["NOTE_22"], COL_KOS)
	Header(5, L["COL_6"], COL_NOTE)

	local ScrollFrame = CreateFrame("ScrollFrame", "GILNotesScrollFrame", ListFrame, "FauxScrollFrameTemplate")

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

	local function DrawUpdate ()
		local list = NotesDB()

		FauxScrollFrame_Update(ScrollFrame, #list, K.BUTTON_TOTAL, K.BUTTON_HEIGHT)

		if selected > #list then selected = #list end

		ListFrame.infotext:SetText(format(L["NOTE_6"], #list))

		local offset = FauxScrollFrame_GetOffset(ScrollFrame)

		for count = 1, K.BUTTON_TOTAL do
			local idx   = count + offset
			local entry = list[idx]
			local row   = rows[count]

			if entry then
				local server = M.getServer(entry.name)

				row.name:SetText(M.removeServer(entry.name, true) or entry.name)
				row.server:SetText(M.prettyServer(server) or server)
				row.faction:SetText(FactionText(entry.faction))
				row.kos:SetText(entry.kos and ("|cffff2020" .. L["NOTE_22"]) or "")
				row.note:SetText(OneLine(entry.note))
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

	local function ShowState ()
		if state == 1 then
			ListFrame:Hide()
			M.GIL_NotesEditFrame:Show()
		else
			M.GIL_NotesEditFrame:Hide()
			ListFrame:Show()
		end
	end

	local EditNote		-- forward declaration

	local function ToggleKOS (idx)
		local entry = NotesDB()[idx]

		if entry then
			entry.kos = not entry.kos
			dirty = true
			DrawUpdate()
		end
	end

	local function ConfirmRemove (idx)
		local entry = NotesDB()[idx]

		if not entry then return end

		M.GIL_ShowDialog({
			key      = "notesremove",
			text     = "|cffffff00%s|cffffffff\n\n" .. L["NOTE_19"],
			button1  = L["BOX_10"],
			button2  = L["BOX_5"],
			onAccept = function ()
				local e = NotesDB()[idx]

				if e and e.name == entry.name then
					RemoveNote(idx)
					DrawUpdate()
				end
			end,
		}, M.removeServer(entry.name, true) or entry.name)
	end

	local function RowClick (self, button, down)
		if down == true then return end

		local id = self:GetID()

		if selected == id and button == "LeftButton" then
			EditNote(id)
			return
		elseif selected ~= id then
			selected = id
			DrawUpdate()
		end

		if button == "RightButton" then
			local entry = NotesDB()[id]

			if not entry then return end

			M.GIL_ContextMenu(UIParent,
				function (owner, root)
					root:CreateTitle(M.removeServer(entry.name, true) or entry.name)
					root:CreateDivider()
					root:CreateButton(L["NOTE_14"], function () EditNote(id) end)
					root:CreateButton(L["NOTE_15"], function () ToggleKOS(id) end)

					if entry.kos then
						root:CreateButton(L["NOTE_18"], function () Alert(entry, true) end)
					end

					root:CreateDivider()
					root:CreateButton(L["NOTE_16"], function () ConfirmRemove(id) end)
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

		row.name:SetWidth(COL_NAME)

		row.server = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.server:SetPoint("LEFT", row.name, "RIGHT", 0, 0)
		row.server:SetWidth(COL_SERVER)
		row.server:SetJustifyH("LEFT")

		if SERVER_HIDDEN then row.server:Hide() end

		row.faction = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.faction:SetPoint("LEFT", row.server, "RIGHT", 0, 0)
		row.faction:SetWidth(COL_FACTION)
		row.faction:SetJustifyH("LEFT")

		row.kos = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.kos:SetPoint("LEFT", row.faction, "RIGHT", 0, 0)
		row.kos:SetWidth(COL_KOS)
		row.kos:SetJustifyH("LEFT")

		row.note = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		row.note:SetPoint("LEFT", row.kos, "RIGHT", 0, 0)
		row.note:SetWidth(COL_NOTE)
		row.note:SetJustifyH("LEFT")
		row.note:SetWordWrap(false)
	end

	ListFrame:SetScript("OnShow", DrawUpdate)

	-----------------------
	-- ADD / SHARE MENU  --
	-----------------------

	local function ShareMenu ()
		M.GIL_ContextMenu(UIParent,
			function (owner, root)
				root:CreateTitle(L["NOTE_23"])
				root:CreateDivider()

				root:CreateButton(L["NOTE_25"], function () M.GIL_ExportNotes() end)
				root:CreateDivider()
				root:CreateButton(L["NOTE_26"], function () M.GIL_ShowImportDialog("NOTE", L["NOTE_32"]) end)
				root:CreateDivider()
				root:CreateButton(L["RCM_5"], function () end)
			end
		)
	end

	-- BOTTOM BUTTONS (left: share, right: remove and add)

	local addButton = CreateFrame("Button", "GILFrameNotesAdd", ListFrame, "UIPanelButtonTemplate")
	addButton:SetSize(110, 22)
	addButton:SetText(L["NOTE_1"])
	addButton:SetPoint("BOTTOMRIGHT", -1, -24)
	addButton:SetScript("OnClick", function () M.GIL_NotesAddDialog() end)

	local removeButton = CreateFrame("Button", "GILFrameNotesRemove", ListFrame, "UIPanelButtonTemplate")
	removeButton:SetSize(110, 22)
	removeButton:SetText(L["NOTE_4"])
	removeButton:SetPoint("RIGHT", addButton, "LEFT", 0, 0)
	removeButton:SetScript("OnClick", function ()
		if selected > 0 then ConfirmRemove(selected) end
	end)

	local shareButton = CreateFrame("Button", "GILFrameNotesShare", ListFrame, "UIPanelButtonTemplate")
	shareButton:SetSize(110, 22)
	shareButton:SetText(L["BUT_12"])
	shareButton:SetPoint("BOTTOMLEFT", -1, -24)
	shareButton:SetScript("OnClick", ShareMenu)

	------------
	-- EDITOR --
	------------

	local Edit = CreateFrame("Frame", "GILFrameNotesEdit", MainFrame, "InsetFrameTemplate")

	M.GIL_NotesEditFrame = Edit

	Edit:Hide()
	Edit:SetWidth(K.WINDOW_WIDTH - 19)
	Edit:SetHeight(K.WINDOW_HEIGHT - K.WINDOW_OFFSET + 20)
	Edit:SetPoint("TOPLEFT", MainFrame, "TOPLEFT", 8, -64)

	local title = Edit:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", Edit, "TOPLEFT", 24, -18)
	title:SetWidth(400)
	title:SetJustifyH("LEFT")
	title:SetText(L["NOTE_7"])

	local nameLabel = Edit:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	nameLabel:SetPoint("TOPLEFT", Edit, "TOPLEFT", 24, -56)
	nameLabel:SetText(L["NOTE_8"])

	local nameValue = Edit:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	nameValue:SetPoint("LEFT", nameLabel, "RIGHT", 8, 0)
	nameValue:SetWidth(330)
	nameValue:SetJustifyH("LEFT")

	local kosCheck = CreateFrame("CheckButton", "GILFrameNotesEditKOS", Edit, "UICheckButtonTemplate")
	kosCheck:SetPoint("TOPLEFT", Edit, "TOPLEFT", 18, -80)
	_G[kosCheck:GetName() .. "Text"]:SetText(L["NOTE_9"])
	_G[kosCheck:GetName() .. "Text"]:SetFontObject("GameFontHighlight")

	-- small Help button to the right of the checkbox text (same look as the chat filter editor)
	local kosHelp = CreateFrame("Button", "GILFrameNotesEditKOSHelp", Edit, "UIPanelButtonTemplate")
	kosHelp:SetSize(38, 18)
	kosHelp:SetNormalFontObject("GameFontNormalSmall")
	kosHelp:SetText("Help")
	kosHelp:SetPoint("LEFT", _G[kosCheck:GetName() .. "Text"], "RIGHT", 8, 0)
	kosHelp:SetScript("OnEnter", function (self)
		GameTooltip:SetOwner(self)
		GameTooltip:ClearLines()
		GameTooltip:AddLine(L["NOTE_45"], 1, 1, 1, true)
		GameTooltip:Show()
	end)
	kosHelp:SetScript("OnLeave", function () GameTooltip:Hide() end)

	local noteLabel = Edit:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	noteLabel:SetPoint("TOPLEFT", Edit, "TOPLEFT", 24, -122)
	noteLabel:SetText(L["NOTE_10"])

	local noteBox = CreateFrame("ScrollFrame", "GILFrameNotesEditNote", Edit, "InputScrollFrameTemplate")
	noteBox:SetPoint("TOPLEFT", noteLabel, "BOTTOMLEFT", 6, -8)
	noteBox:SetSize(618, 130)
	noteBox.EditBox:SetAutoFocus(false)
	noteBox.EditBox:SetMaxLetters(NOTE_MAX)
	noteBox.EditBox:SetWidth(570)
	noteBox.EditBox:SetFontObject("ChatFontNormal")
	noteBox.EditBox:SetScript("OnEscapePressed", function (self) self:ClearFocus() end)

	local FACTION_ORDER = { "Unknown", "Alliance", "Horde", "Neutral" }
	local editFaction   = "Unknown"

	local factionButton = CreateFrame("Button", "GILFrameNotesEditFaction", Edit, "UIPanelButtonTemplate")
	factionButton:SetSize(170, 22)
	factionButton:SetPoint("TOPRIGHT", Edit, "TOPRIGHT", -24, -52)

	local function UpdateFactionButton ()
		factionButton:SetText(format(L["NOTE_37"], FactionName(editFaction)))
	end

	factionButton:SetScript("OnClick", function ()
		for i = 1, #FACTION_ORDER do
			if FACTION_ORDER[i] == editFaction then
				editFaction = FACTION_ORDER[(i % #FACTION_ORDER) + 1]
				break
			end
		end

		UpdateFactionButton()
	end)

	local cancelButton = CreateFrame("Button", "GILFrameNotesEditCancel", Edit, "UIPanelButtonTemplate")
	cancelButton:SetSize(110, 22)
	cancelButton:SetText(L["BOX_5"])
	cancelButton:SetPoint("BOTTOMRIGHT", -1, -24)
	cancelButton:SetScript("OnClick", function ()
		editIndex = 0
		state     = 0
		ShowState()
	end)

	local saveButton = CreateFrame("Button", "GILFrameNotesEditSave", Edit, "UIPanelButtonTemplate")
	saveButton:SetSize(110, 22)
	saveButton:SetText(L["NOTE_11"])
	saveButton:SetPoint("RIGHT", cancelButton, "LEFT", 0, 0)
	saveButton:SetScript("OnClick", function ()
		local entry = NotesDB()[editIndex]

		if entry then
			entry.note = CleanNote(noteBox.EditBox:GetText())
			entry.kos  = (kosCheck:GetChecked() == true)
			entry.faction = editFaction
			dirty = true
		end

		editIndex = 0
		state     = 0
		ShowState()
		DrawUpdate()
	end)

	EditNote = function (idx)
		local entry = NotesDB()[idx]

		if not entry then return end

		editIndex = idx
		state     = 1

		local server = M.getServer(entry.name)

		local shownName = M.removeServer(entry.name, true) or entry.name

		if not SERVER_HIDDEN then
			shownName = shownName .. "  |cffaaaaaa(" .. (M.prettyServer(server) or server) .. ")"
		end

		nameValue:SetText(shownName)
		kosCheck:SetChecked(entry.kos == true)
		editFaction = entry.faction or "Unknown"
		UpdateFactionButton()
		noteBox.EditBox:SetText(entry.note or "")
		noteBox.EditBox:SetCursorPosition(0)

		ShowState()
	end

	----------------------
	-- TAB INTERFACE    --
	----------------------

	function M.GIL_NotesEdit (idx)
		selected = idx
		DrawUpdate()
		EditNote(idx)
	end

	function M.GIL_NotesShow ()
		ShowState()
	end

	function M.GIL_NotesHide ()
		ListFrame:Hide()
		Edit:Hide()
	end

	function M.GIL_NotesRefresh ()
		DrawUpdate()
	end
end
