--[[
	Loadout: each player's inventory (Config.Inventory, Config.Items) and the server's weather,
	changed by the client's menus (TAB: inventory and sword; M: creative menu) through the
	Loadout remote:
	  ("Equip", index, key)      wear the item in grid cell `index` (it swaps with the slot's item)
	  ("Unequip", slot)          take the slot's item off, back into the grid
	  ("Socket", index, key)     set the book in cell `index` on the sword (swaps with its book)
	  ("Unsocket")               take the sword's book back into the grid
	  ("Move", from, to)         move a grid item to another cell
	  ("Discard", index, key)    throw an item away
	  ("Give", key)              creative: add a new item (Config.Inventory.Creative)
	  ("Clear")                  creative: empty the grid
	  ("Wind", speed, yaw)       the server's wind (Config.Wind; anyone may change it)
	  ("Rain", intensity 0..1)   the server's rain (Config.Rain; anyone may change it)
	`key` is the item the client saw in that cell: a request made on a stale view is ignored.
	A player's inventory is kept for the session and mirrored to them as the Player attribute
	"RR_Inventory" (JSON: Items, Equipped, Book, Capacity). What is equipped is put on every new
	fighter of theirs (Apply, at spawn); the book sets the incantation J casts ("IncantChoice").
	Armour only goes on while standing and out of combat (not hurt for Config.Armor.EquipCooldown
	seconds); cosmetic pieces go on any time and taking anything off always works.
	Refusals come back as Feedback "LoadoutRefused" with the reason.
]]
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.RagdollRonin.Config)
local Registry = require(script.Parent.Registry)
local Armor = require(script.Parent.Armor)
local Feedback = require(script.Parent.Feedback)

local Loadout = {}
local AR = Config.Armor
local INV = Config.Inventory
local IT = Config.Items
local last = {}
local inventories = {} -- player -> { Items = { key, ... }, Equipped = { [slot] = key }, Book = key? }

local function capacityWith(bag)
	return INV.Capacity + (bag and IT[bag].Capacity or 0)
end

local function inventoryOf(player)
	local s = inventories[player]
	if not s then
		s = { Items = table.clone(INV.Starter), Equipped = {} }
		inventories[player] = s
	end
	return s
end

local function publish(player, s)
	player:SetAttribute("RR_Inventory", HttpService:JSONEncode({
		Items = s.Items,
		Equipped = s.Equipped,
		Book = s.Book,
		Capacity = capacityWith(s.Equipped.Back),
	}))
end

local function refuse(player, why)
	Feedback.Send({ Player = player }, "LoadoutRefused", { Reason = why })
end

local function alive(f)
	return f and not f.Dead and f.Model.Parent ~= nil
end

local function setIncantation(player, s)
	local choice = s.Book and IT[s.Book].Incantation or nil
	local f = Registry.ByPlayer[player]
	if f and f.Model.Parent then
		f.Model:SetAttribute("IncantChoice", choice)
	end
end

-- why this fighter can't put armour on right now, or nil
local function armourBlocked(f, now)
	if f.State ~= "Idle" and f.State ~= "Moving" then
		return "Stand still to put armour on"
	end
	local since = now - (f.LastHurtTime or -math.huge)
	if since < AR.EquipCooldown then
		return string.format("In combat: wait %d s to put armour on", math.ceil(AR.EquipCooldown - since))
	end
	return nil
end

local function validIndex(s, i)
	return typeof(i) == "number" and i == math.floor(i) and i >= 1 and i <= #s.Items
end

local function item(key)
	return typeof(key) == "string" and key ~= "Order" and IT[key] or nil
end

local function onInventory(player, s, kind, a, b)
	local f = Registry.ByPlayer[player]
	if kind == "Equip" then
		local def = item(b)
		if not (def and def.Kind == "Wear" and validIndex(s, a) and s.Items[a] == b) then
			return false
		end
		local slot = def.Slot
		local old = s.Equipped[slot]
		if slot == "Back" and #s.Items - (old and 0 or 1) > capacityWith(b) then
			return refuse(player, "Not enough room in the " .. def.Label .. " for what you carry")
		end
		if alive(f) and not AR.Pieces[b].Cosmetic then
			local why = armourBlocked(f, os.clock())
			if why then
				return refuse(player, why)
			end
		end
		if old then
			s.Items[a] = old
		else
			table.remove(s.Items, a)
		end
		s.Equipped[slot] = b
		if alive(f) then
			if old then
				Armor.Unequip(f, old)
			end
			Armor.Equip(f, b)
		end
	elseif kind == "Unequip" then
		local key = typeof(a) == "string" and s.Equipped[a]
		if not key then
			return false
		end
		local room = a == "Back" and INV.Capacity or capacityWith(s.Equipped.Back)
		if #s.Items + 1 > room then
			return refuse(player, a == "Back" and "Empty the bag before taking it off" or "Your inventory is full")
		end
		table.insert(s.Items, key)
		s.Equipped[a] = nil
		if alive(f) then
			Armor.Unequip(f, key)
		end
	elseif kind == "Socket" then
		local def = item(b)
		if not (def and def.Kind == "Book" and validIndex(s, a) and s.Items[a] == b) then
			return false
		end
		if s.Book then
			s.Items[a] = s.Book
		else
			table.remove(s.Items, a)
		end
		s.Book = b
		setIncantation(player, s)
	elseif kind == "Unsocket" then
		if not s.Book then
			return false
		end
		if #s.Items + 1 > capacityWith(s.Equipped.Back) then
			return refuse(player, "Your inventory is full")
		end
		table.insert(s.Items, s.Book)
		s.Book = nil
		setIncantation(player, s)
	elseif kind == "Move" then
		if not (validIndex(s, a) and validIndex(s, b)) or a == b then
			return false
		end
		table.insert(s.Items, b, table.remove(s.Items, a))
	elseif kind == "Discard" then
		if not (validIndex(s, a) and s.Items[a] == b) then
			return false
		end
		table.remove(s.Items, a)
	elseif kind == "Give" then
		if not INV.Creative or not item(a) then
			return false
		end
		if #s.Items >= capacityWith(s.Equipped.Back) then
			return refuse(player, "Your inventory is full")
		end
		table.insert(s.Items, a)
	elseif kind == "Clear" then
		if not INV.Creative then
			return false
		end
		table.clear(s.Items)
	else
		return false
	end
	return true
end

local function onRequest(player, kind, a, b)
	local now = os.clock()
	if last[player] and now - last[player] < 0.05 then
		return
	end
	last[player] = now
	if kind == "Wind" then
		if typeof(a) ~= "number" or typeof(b) ~= "number" or a ~= a or b ~= b then
			return
		end
		workspace:SetAttribute("WindSpeed", math.clamp(math.round(a), 0, Config.Wind.MaxSpeed))
		workspace:SetAttribute("WindYaw", math.round(b) % 360)
	elseif kind == "Rain" then
		if typeof(a) ~= "number" or a ~= a then
			return
		end
		workspace:SetAttribute("RainIntensity", math.clamp(math.round(a * 100) / 100, 0, 1))
	else
		local s = inventoryOf(player)
		-- publish even when nothing changed, so a client that acted on a stale view catches up
		onInventory(player, s, kind, a, b)
		publish(player, s)
	end
end

-- a new fighter of this player's: what they have equipped (whole) and the sword's incantation
function Loadout.Apply(f)
	local player = f.Player
	if not player then
		return
	end
	local s = inventoryOf(player)
	for _, key in pairs(s.Equipped) do
		Armor.Equip(f, key)
	end
	f.Model:SetAttribute("IncantChoice", s.Book and IT[s.Book].Incantation or nil)
end

function Loadout.Init()
	workspace:SetAttribute("WindSpeed", Config.Wind.Speed)
	workspace:SetAttribute("WindYaw", Config.Wind.Yaw)
	workspace:SetAttribute("RainIntensity", Config.Rain.Intensity)
	ReplicatedStorage.RagdollRonin.Remotes.Loadout.OnServerEvent:Connect(onRequest)
	local function added(p)
		local s = inventoryOf(p)
		if s.Book == nil then
			-- start with the starter book on the sword, so J works straight away
			for i, key in ipairs(s.Items) do
				if IT[key].Kind == "Book" then
					s.Book = table.remove(s.Items, i)
					break
				end
			end
		end
		setIncantation(p, s)
		publish(p, s)
	end
	Players.PlayerAdded:Connect(added)
	for _, p in ipairs(Players:GetPlayers()) do
		added(p)
	end
	Players.PlayerRemoving:Connect(function(p)
		last[p] = nil
		inventories[p] = nil
	end)
end

return Loadout
