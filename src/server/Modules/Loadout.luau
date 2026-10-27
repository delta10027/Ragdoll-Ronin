--[[
	Loadout: what each player wears and which incantation they carry, chosen in the client's
	loadout menu (M) through the Loadout remote:
	  ("Armor", piece, wear: boolean)   put an armour piece on (restored to full) or take it off
	  ("Incantation", name or "None")   the incantation J casts
	The choices are kept on the Player (attributes "Armor_<piece>", "IncantChoice") and applied
	to every new fighter of theirs (Apply, at spawn). Putting armour on only works while standing
	and out of combat (not hurt for Config.Armor.EquipCooldown seconds); taking it off always does.
	Cosmetic pieces (the Cloak) go on any time.
	Refusals come back as Feedback "LoadoutRefused" with the reason.
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)
local Registry = require(script.Parent.Registry)
local Armor = require(script.Parent.Armor)
local Feedback = require(script.Parent.Feedback)

local Loadout = {}
local AR = Config.Armor
local last = {}

local function refuse(f, player, why)
	if f then
		Feedback.Send(f, "LoadoutRefused", { Reason = why })
	end
	return false
end

local function onRequest(player, kind, a, b)
	local now = os.clock()
	if last[player] and now - last[player] < 0.15 then
		return
	end
	last[player] = now
	local f = Registry.ByPlayer[player]
	if kind == "Armor" then
		if typeof(a) ~= "string" or not AR.Pieces[a] or typeof(b) ~= "boolean" then
			return
		end
		if not b then
			player:SetAttribute("Armor_" .. a, false)
			if f and not f.Dead then
				Armor.Unequip(f, a)
			end
			return
		end
		if f and not f.Dead and AR.Pieces[a].Cosmetic then
			Armor.Equip(f, a) -- cosmetic: goes on any time
		elseif f and not f.Dead then
			if f.State ~= "Idle" and f.State ~= "Moving" then
				return refuse(f, player, "Stand still to put armour on")
			end
			local since = now - (f.LastHurtTime or -math.huge)
			if since < AR.EquipCooldown then
				return refuse(f, player, string.format("In combat: wait %d s to put armour on", math.ceil(AR.EquipCooldown - since)))
			end
			Armor.Equip(f, a)
		end
		player:SetAttribute("Armor_" .. a, true)
	elseif kind == "Incantation" then
		if a ~= "None" and (typeof(a) ~= "string" or not Config.Incantations[a] or a == "Order") then
			return
		end
		local choice = a ~= "None" and a or nil
		player:SetAttribute("IncantChoice", choice)
		if f and f.Model.Parent then
			f.Model:SetAttribute("IncantChoice", choice)
		end
	end
end

-- a new fighter of this player's: their armour (whole) and incantation
function Loadout.Apply(f)
	local player = f.Player
	if not player then
		return
	end
	for _, piece in ipairs(AR.Order) do
		if player:GetAttribute("Armor_" .. piece) == true then
			Armor.Equip(f, piece)
		end
	end
	f.Model:SetAttribute("IncantChoice", player:GetAttribute("IncantChoice"))
end

function Loadout.Init()
	ReplicatedStorage.RagdollRonin.Remotes.Loadout.OnServerEvent:Connect(onRequest)
	game:GetService("Players").PlayerRemoving:Connect(function(p)
		last[p] = nil
	end)
end

return Loadout
