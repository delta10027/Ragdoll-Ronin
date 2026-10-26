--[[
	Armor: the fighter's armour pieces (Config.Armor) and what a blade does to them.

	f.Armor[piece] = hits left (absent = not worn). Mirrored on the model as "Armor_<piece>" so
	every client can draw it (client ArmorView) and the owner's loadout menu can show it. A
	damaging hit on a covered segment is stopped (CombatResolver) and costs the piece a hit; at 0
	it breaks off ("Armor_<piece>" = 0) and the segment is exposed until the piece is re-equipped
	(out of combat) or the fighter respawns.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)

local Armor = {}
local AR = Config.Armor

local PIECE_OF = {} -- segment -> piece
for name, def in pairs(AR.Pieces) do
	for _, seg in ipairs(def.Segments) do
		PIECE_OF[seg] = name
	end
end

local function publish(f, piece)
	if f.Model and f.Model.Parent then
		f.Model:SetAttribute("Armor_" .. piece, f.Armor and f.Armor[piece])
	end
end

function Armor.Equip(f, piece)
	local def = AR.Pieces[piece]
	if not def then
		return false
	end
	f.Armor = f.Armor or {}
	f.Armor[piece] = def.Hits
	publish(f, piece)
	return true
end

function Armor.Unequip(f, piece)
	if f.Armor then
		f.Armor[piece] = nil
	end
	publish(f, piece)
end

-- the intact piece covering this segment, or nil
function Armor.Covering(f, segName)
	local piece = PIECE_OF[segName]
	if piece and f.Armor and (f.Armor[piece] or 0) > 0 then
		return piece
	end
	return nil
end

-- a damaging hit lands on the piece; returns true when it broke
function Armor.Strike(f, piece)
	local left = math.max(0, (f.Armor[piece] or 0) - 1)
	f.Armor[piece] = left
	publish(f, piece)
	return left == 0
end

return Armor
