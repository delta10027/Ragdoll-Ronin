--[[
	InventoryClient: this player's inventory as the server keeps it (server Loadout: the Player
	attribute "RR_Inventory"), for the menus.
	  Data            { Items = { key, ... }, Equipped = { [slot] = key }, Book = key?, Capacity }
	  OnChanged(fn)   called with Data whenever it (or the fighter's armour) changes
	  Send(...)       a request on the Loadout remote ("Equip", index, key), ...
	  Hits(key)       hits left on the fighter's piece: a number, 0 when broken, nil when not worn
	  Describe(key)   the item's kind line for tooltips ("Head · Armour, 3 hits")
	Also sends "Incantation : <name>" to the chat when one of yours takes hold (the model's
	"IncantActive" attribute, set by the server when the rub is complete).
]]
local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))

local InventoryClient = {}
local IT = Config.Items
local AR = Config.Armor
local IC = Config.Incantations

InventoryClient.Data = { Items = {}, Equipped = {}, Capacity = Config.Inventory.Capacity }

local listeners = {}
local remote
local fighter

local function changed()
	for _, fn in ipairs(listeners) do
		task.spawn(fn, InventoryClient.Data)
	end
end

function InventoryClient.OnChanged(fn)
	table.insert(listeners, fn)
end

function InventoryClient.Send(...)
	if remote then
		remote:FireServer(...)
	end
end

function InventoryClient.Hits(key)
	local hits = fighter and fighter.Parent and fighter:GetAttribute("Armor_" .. key)
	return typeof(hits) == "number" and hits or nil
end

-- where it goes and what it does
function InventoryClient.Describe(key)
	local def = IT[key]
	if not def then
		return ""
	end
	if def.Kind == "Book" then
		local inc = IC[def.Incantation]
		return inc and string.format("Incantation · %d s, every %d s", inc.Duration, inc.Cooldown) or "Incantation"
	end
	local piece = AR.Pieces[key]
	local what
	if def.Capacity then
		what = string.format("Bag, +%d slots", def.Capacity)
	elseif piece.Cosmetic then
		what = "Cosmetic"
	else
		what = string.format("Armour, %d hits", piece.Hits)
	end
	return def.Slot .. " · " .. what
end

-- the item's accent: armour blue, cosmetic grey, books ember
function InventoryClient.Accent(key, theme)
	local def = IT[key]
	if not def then
		return theme.Colors.Faint
	end
	if def.Kind == "Book" then
		return theme.Colors.Book
	end
	return AR.Pieces[key].Cosmetic and theme.Colors.Cosmetic or theme.Colors.Armour
end

local function decode(player)
	local raw = player:GetAttribute("RR_Inventory")
	if typeof(raw) ~= "string" then
		return
	end
	local ok, data = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(data) ~= "table" then
		return
	end
	InventoryClient.Data = {
		Items = typeof(data.Items) == "table" and data.Items or {},
		Equipped = typeof(data.Equipped) == "table" and data.Equipped or {},
		Book = data.Book,
		Capacity = tonumber(data.Capacity) or Config.Inventory.Capacity,
	}
	changed()
end

function InventoryClient.Init(ctx)
	remote = ctx.Remotes:WaitForChild("Loadout")
	ctx.Player:GetAttributeChangedSignal("RR_Inventory"):Connect(function()
		decode(ctx.Player)
	end)
	decode(ctx.Player)
end

-- a new fighter: follow its armour (hits left, broken), and announce its incantations in chat
function InventoryClient.OnNewFighter(_ctx, model)
	fighter = model
	changed()
	model.AttributeChanged:Connect(function(name)
		if name:sub(1, 6) == "Armor_" then
			changed()
		elseif name == "IncantActive" then
			local active = model:GetAttribute("IncantActive")
			local def = active and IC[active]
			if def then
				task.spawn(function()
					local channels = TextChatService:FindFirstChild("TextChannels")
					local general = channels and channels:FindFirstChild("RBXGeneral")
					if general then
						pcall(general.SendAsync, general, "Incantation : " .. def.Label)
					end
				end)
			end
		end
	end)
end

return InventoryClient
