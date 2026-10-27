--[[
	LoadoutMenu: M (or the Loadout button) opens the loadout menu.
	  Armour       put each piece on or take it off (server Loadout / Armor). Shows the hits a worn
	               piece has left, or that it is broken. Armour only goes on out of combat.
	  Incantation  the one J casts (None, Fire)
	While the menu is open the mouse is free and the fighter takes no input (ctx.MenuOpen).
	Also sends "Incantation : <name>" to the chat when one of yours takes hold (the model's
	"IncantActive" attribute, set by the server when the rub is complete).
]]
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))

local LoadoutMenu = {}
local AR = Config.Armor
local IC = Config.Incantations
local BG = Color3.fromRGB(22, 20, 24)
local ROW = Color3.fromRGB(44, 40, 46)
local ON = Color3.fromRGB(150, 40, 36)
local TEXT = Color3.fromRGB(235, 230, 225)

local ui = {}
local remote

local function label(parent, text, size, bold)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.new(1, 0, 0, size + 8)
	l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
	l.TextSize = size
	l.TextColor3 = TEXT
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	l.Parent = parent
	return l
end

local function button(parent, text)
	local b = Instance.new("TextButton")
	b.Size = UDim2.new(1, 0, 0, 34)
	b.BackgroundColor3 = ROW
	b.BorderSizePixel = 0
	b.AutoButtonColor = true
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 14
	b.TextColor3 = TEXT
	b.TextXAlignment = Enum.TextXAlignment.Left
	b.Text = text
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.Parent = b
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	b.Parent = parent
	return b
end

local function refresh(ctx)
	if not ui.Panel then
		return
	end
	local player = ctx.Player
	local model = ctx.Fighter
	for piece, b in pairs(ui.Armor) do
		local def = AR.Pieces[piece]
		local wanted = player:GetAttribute("Armor_" .. piece) == true
		local hits = model and model:GetAttribute("Armor_" .. piece)
		local status
		if typeof(hits) == "number" and hits > 0 then
			status = def.Cosmetic and "worn" or string.format("worn  %d/%d", hits, def.Hits)
		elseif hits == 0 then
			status = "BROKEN (click to repair)"
		elseif wanted then
			status = "on next spawn"
		else
			status = "off"
		end
		b.Text = def.Label .. "   -   " .. status
		b.BackgroundColor3 = (typeof(hits) == "number" and hits > 0) and ON or ROW
	end
	local choice = player:GetAttribute("IncantChoice") or "None"
	for name, b in pairs(ui.Incant) do
		b.BackgroundColor3 = name == choice and ON or ROW
	end
end

function LoadoutMenu.Toggle(ctx)
	ui.Panel.Visible = not ui.Panel.Visible
	ctx.MenuOpen = ui.Panel.Visible
	ui.Status.Text = ""
	refresh(ctx)
end

-- server refusal (Feedback "LoadoutRefused")
function LoadoutMenu.Refused(ctx, reason)
	ui.Status.Text = tostring(reason)
end

function LoadoutMenu.Init(ctx)
	remote = ctx.Remotes:WaitForChild("Loadout")
	ctx.MenuOpen = false
	ctx.LoadoutRefused = function(reason)
		LoadoutMenu.Refused(ctx, reason)
	end

	local open = Instance.new("TextButton")
	open.Name = "LoadoutButton"
	open.AnchorPoint = Vector2.new(0, 0)
	open.Position = UDim2.fromOffset(12, 56)
	open.Size = UDim2.fromOffset(130, 30)
	open.BackgroundColor3 = BG
	open.BackgroundTransparency = 0.2
	open.BorderSizePixel = 0
	open.Font = Enum.Font.GothamBold
	open.TextSize = 14
	open.TextColor3 = TEXT
	open.Text = "Loadout (M)"
	local oc = Instance.new("UICorner")
	oc.CornerRadius = UDim.new(0, 6)
	oc.Parent = open
	open.Parent = ctx.Gui
	open.Activated:Connect(function()
		LoadoutMenu.Toggle(ctx)
	end)

	local panel = Instance.new("Frame")
	panel.Name = "LoadoutMenu"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(380, 0)
	panel.AutomaticSize = Enum.AutomaticSize.Y
	panel.BackgroundColor3 = BG
	panel.BackgroundTransparency = 0.05
	panel.BorderSizePixel = 0
	panel.Visible = false
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 10)
	pc.Parent = panel
	local pad = Instance.new("UIPadding")
	for _, k in ipairs({ "PaddingTop", "PaddingBottom", "PaddingLeft", "PaddingRight" }) do
		pad[k] = UDim.new(0, 14)
	end
	pad.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 6)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = panel
	panel.Parent = ctx.Gui
	ui.Panel = panel

	local order = 0
	local function add(inst)
		order += 1
		inst.LayoutOrder = order
		return inst
	end
	add(label(panel, "Loadout", 20, true))
	add(label(panel, "Armour - breaks after a number of hits, the body under it is then exposed", 12, false)).TextWrapped = true
	ui.Armor = {}
	for _, piece in ipairs(AR.Order) do
		local b = add(button(panel, AR.Pieces[piece].Label))
		ui.Armor[piece] = b
		b.Activated:Connect(function()
			local hits = ctx.Fighter and ctx.Fighter:GetAttribute("Armor_" .. piece)
			local worn = typeof(hits) == "number" and hits > 0
			-- worn: take it off; off or broken: put it on (restored)
			remote:FireServer("Armor", piece, not worn)
			task.delay(0.25, refresh, ctx)
		end)
	end
	add(label(panel, "Incantation - J with the sword drawn", 16, true))
	ui.Incant = {}
	local names = { "None" }
	for _, n in ipairs(IC.Order) do
		table.insert(names, n)
	end
	for _, name in ipairs(names) do
		local def = IC[name]
		local text = def and string.format("%s   -   %d s, every %d s", def.Label, def.Duration, def.Cooldown) or "None"
		local b = add(button(panel, text))
		ui.Incant[name] = b
		b.Activated:Connect(function()
			remote:FireServer("Incantation", name)
			task.delay(0.25, refresh, ctx)
		end)
	end
	ui.Status = add(label(panel, "", 13, false))
	ui.Status.TextColor3 = Color3.fromRGB(255, 120, 100)
	ui.Status.TextWrapped = true
	add(label(panel, "M to close", 12, false)).TextTransparency = 0.4

	-- keep the menu current (hits left, broken pieces)
	local player = Players.LocalPlayer
	player.AttributeChanged:Connect(function()
		refresh(ctx)
	end)
end

-- a new fighter: follow its armour, and announce its incantations in chat
function LoadoutMenu.OnNewFighter(ctx, model)
	refresh(ctx)
	model.AttributeChanged:Connect(function(name)
		if name:sub(1, 6) == "Armor_" then
			refresh(ctx)
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

return LoadoutMenu
