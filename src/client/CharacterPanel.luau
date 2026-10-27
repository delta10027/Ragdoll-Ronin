--[[
	CharacterPanel: the inventory (TAB > Character). On the left the grid of carried items
	(InventoryGrid), on the right the fighter's figure wearing what is equipped, with the seven
	equipment slots around it (Config.Inventory.Slots).
	  drag an item onto its slot (or onto the figure)   wear it (it swaps with the slot's item)
	  drag a slot's item onto the grid                  take it off
	  right-click                                       wear it / take it off
	  drag the figure                                   turn it
	Armour shows its hits left as pips, and BROKEN once it has broken (re-equip it to repair).
]]
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage:WaitForChild("RagdollRonin"):WaitForChild("Config"))
local Theme = require(script.Parent.UITheme)
local ItemArt = require(script.Parent.ItemArt)
local ArmorView = require(script.Parent.ArmorView)
local DragDrop = require(script.Parent.DragDrop)
local ItemTooltip = require(script.Parent.ItemTooltip)
local InventoryClient = require(script.Parent.InventoryClient)
local InventoryGrid = require(script.Parent.InventoryGrid)

local CharacterPanel = {}
CharacterPanel.__index = CharacterPanel
local C = Theme.Colors
local IT = Config.Items
local AR = Config.Armor
local INV = Config.Inventory

local SLOT = 72
-- slot positions in the right half (x, y of the cell's top left), around the figure
local LAYOUT = {
	Head = Vector2.new(0, 34),
	Chest = Vector2.new(0, 132),
	Sleeve = Vector2.new(0, 230),
	Legs = Vector2.new(0, 328),
	Neck = Vector2.new(1, 80),
	Back = Vector2.new(1, 223),
	Boots = Vector2.new(1, 366),
}
local FIGURE_CENTER = Vector3.new(0, -0.1, 0)
local FIGURE_DIST = 13.5
local BREEZE = Vector3.new(0, 0, 4) -- the figure's cape blows back gently (it faces -Z)

local function quickEquip(index, key)
	local def = IT[key]
	if def.Kind == "Wear" then
		InventoryClient.Send("Equip", index, key)
	elseif def.Kind == "Book" then
		InventoryClient.Send("Socket", index, key)
	end
end

function CharacterPanel.new(content, ctx)
	local self = setmetatable({ Ctx = ctx, Slots = {}, Gear = {}, Yaw = 200, YawGoal = 200 }, CharacterPanel)

	local left = Theme.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(32, 84), Size = UDim2.new(0, 488, 1, -116), Parent = content })
	self.Grid = InventoryGrid.new(left, {
		Columns = 6,
		OnQuick = quickEquip,
		Hint = function(key)
			return IT[key].Kind == "Book" and "Drag onto the sword (Weapon) · right-click to set it" or "Drag onto a slot · right-click to wear"
		end,
	})

	-- the divider
	local divider = Theme.new("Frame", {
		Position = UDim2.fromOffset(552, 84),
		Size = UDim2.new(0, 1, 1, -116),
		BackgroundColor3 = C.Gold,
		BorderSizePixel = 0,
		Parent = content,
	})
	Theme.new("UIGradient", {
		Rotation = 90,
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.15, 0.55),
			NumberSequenceKeypoint.new(0.85, 0.55),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Parent = divider,
	})

	local right = Theme.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(584, 70), Size = UDim2.fromOffset(384, 500), Parent = content })
	self.Right = right

	-- the figure
	local vf, world, cam = ItemArt.Viewport({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.fromOffset(230, 470),
		Active = true,
		Parent = right,
	})
	self.View, self.World, self.Cam = vf, world, cam
	-- a soft floor shadow under the figure
	local shadow = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 448),
		Size = UDim2.fromOffset(150, 22),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.55,
		ZIndex = 0,
		Parent = right,
	})
	Theme.corner(shadow, 40)
	vf.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 and not DragDrop.Dragging() then
			self.Turning = UserInputService:GetMouseLocation().X
		end
	end)
	UserInputService.InputChanged:Connect(function(io)
		if self.Turning and io.UserInputType == Enum.UserInputType.MouseMovement then
			local x = UserInputService:GetMouseLocation().X
			self.YawGoal -= (x - self.Turning) * 0.6
			self.Turning = x
		end
	end)
	UserInputService.InputEnded:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 then
			self.Turning = nil
		end
	end)
	-- dropping a wearable on the figure puts it on
	local figureStroke = Theme.stroke(vf, C.Gold, 1, 1)
	DragDrop.Target(vf, {
		Priority = 1,
		Accepts = function(p)
			return p.From == "Grid" and IT[p.Key].Kind == "Wear"
		end,
		Drop = function(p)
			InventoryClient.Send("Equip", p.Index, p.Key)
		end,
		Highlight = function(state)
			Theme.tween(figureStroke, 0.15, { Transparency = state == "Over" and 0.3 or 1 })
		end,
	})

	for _, slot in ipairs(INV.Slots) do
		self:_slot(slot)
	end

	self.Stats = Theme.text(right, "", 13, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 474),
		Size = UDim2.new(1, 0, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Muted,
	})
	Theme.text(content, "Drag items onto a slot to wear them  ·  right-click to wear or take off  ·  drag the figure to turn it", 12, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Faint,
	})

	RunService.RenderStepped:Connect(function(dt)
		if not self.Open then
			return
		end
		self.Yaw += (self.YawGoal - self.Yaw) * math.min(1, dt * 10)
		local dir = CFrame.Angles(0, math.rad(self.Yaw), 0) * CFrame.Angles(math.rad(-6), 0, 0) * Vector3.new(0, 0, 1) -- a little from above
		cam.CFrame = CFrame.lookAt(FIGURE_CENTER + dir * FIGURE_DIST, FIGURE_CENTER)
	end)

	InventoryClient.OnChanged(function(data)
		self:Refresh(data)
	end)
	return self
end

function CharacterPanel:_slot(slot)
	local pos = LAYOUT[slot]
	local holder = Theme.new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.new(pos.X, pos.X == 1 and -SLOT or 0, 0, pos.Y),
		Size = UDim2.fromOffset(SLOT, SLOT + 22),
		Parent = self.Right,
	})
	Theme.text(holder, string.upper(slot), 12, {
		Size = UDim2.new(1, 0, 0, 18),
		FontFace = Theme.Fonts.Strong,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Center,
	})
	local b = Theme.button(holder, "", 14, {
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.fromOffset(SLOT, SLOT),
		BackgroundColor3 = C.Cell,
	})
	Theme.corner(b, 8)
	local stroke = Theme.stroke(b, C.CellEdge, 1)
	local hint = Theme.text(b, INV.SlotHints[slot], 11, {
		Size = UDim2.fromScale(1, 1),
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = C.Faint,
	})
	Theme.pad(hint, 6)
	local icon = Theme.new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(4, 4), Size = UDim2.new(1, -8, 1, -8), Parent = b })
	local pips = Theme.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -5),
		Size = UDim2.fromOffset(60, 4),
		BackgroundTransparency = 1,
		Parent = b,
	})
	Theme.new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		Padding = UDim.new(0, 3),
		Parent = pips,
	})
	local broken = Theme.text(b, "BROKEN", 11, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 4),
		Size = UDim2.new(1, 0, 0, 14),
		FontFace = Theme.Fonts.Strong,
		TextColor3 = C.Bad,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		ZIndex = 3,
	})
	local scale = Theme.scaleOf(b)
	local rec = { Holder = holder, Button = b, Stroke = stroke, Hint = hint, Icon = icon, Pips = pips, Broken = broken, Scale = scale }
	self.Slots[slot] = rec

	local function baseStroke()
		local hits = rec.Key and InventoryClient.Hits(rec.Key)
		return hits == 0 and C.Bad or C.CellEdge
	end
	b.MouseEnter:Connect(function()
		if DragDrop.Dragging() then
			return
		end
		Theme.tween(scale, 0.12, { Scale = 1.05 })
		Theme.tween(b, 0.12, { BackgroundColor3 = C.CellHover })
		if rec.Key then
			Theme.tween(stroke, 0.12, { Color = C.Gold })
			local hits = InventoryClient.Hits(rec.Key)
			ItemTooltip.Show(rec.Key, "Drag onto the grid · right-click to take off", hits == 0 and "Broken: take it off and wear it again to repair" or nil)
		end
	end)
	b.MouseLeave:Connect(function()
		if rec.Glow then
			return
		end
		Theme.tween(scale, 0.18, { Scale = 1 })
		Theme.tween(b, 0.18, { BackgroundColor3 = C.Cell })
		Theme.tween(stroke, 0.18, { Color = baseStroke() })
		ItemTooltip.Hide(rec.Key)
	end)
	b.MouseButton2Click:Connect(function()
		if rec.Key then
			ItemTooltip.Hide()
			InventoryClient.Send("Unequip", slot)
		end
	end)
	DragDrop.Source(b, function()
		local key = rec.Key
		if not key then
			return nil
		end
		return {
			Key = key,
			From = "Slot",
			Icon = function()
				return ItemArt.Icon(key)
			end,
			Return = function()
				InventoryClient.Send("Unequip", slot)
			end,
		}
	end)
	DragDrop.Target(b, {
		Priority = 2,
		Accepts = function(p)
			return p.From == "Grid" and IT[p.Key].Slot == slot
		end,
		Drop = function(p)
			InventoryClient.Send("Equip", p.Index, p.Key)
		end,
		Highlight = function(state)
			rec.Glow = state ~= "Off"
			Theme.tween(stroke, 0.15, {
				Color = state == "Off" and baseStroke() or C.Gold,
				Thickness = state == "Over" and 2.5 or state == "Can" and 1.5 or 1,
			})
			Theme.tween(scale, 0.15, { Scale = state == "Over" and 1.1 or state == "Can" and 1.04 or 1 }, Enum.EasingStyle.Back)
			Theme.tween(b, 0.15, { BackgroundColor3 = state == "Off" and C.Cell or C.CellHover })
		end,
	})
end

function CharacterPanel:_setSlot(slot, key)
	local rec = self.Slots[slot]
	local changed = rec.Key ~= key
	rec.Key = key
	if changed then
		for _, d in ipairs(rec.Icon:GetChildren()) do
			d:Destroy()
		end
		if key then
			ItemArt.Icon(key).Parent = rec.Icon
			if self.Open then
				rec.Scale.Scale = 0.75
				Theme.tween(rec.Scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			end
		end
		rec.Hint.Visible = key == nil
	end
	for _, d in ipairs(rec.Pips:GetChildren()) do
		if d:IsA("Frame") then
			d:Destroy()
		end
	end
	local piece = key and AR.Pieces[key]
	local hits = key and InventoryClient.Hits(key)
	if piece and not piece.Cosmetic then
		local left = hits or piece.Hits
		for i = 1, piece.Hits do
			local pip = Theme.new("Frame", {
				Size = UDim2.fromOffset(math.floor(48 / piece.Hits) - 3, 4),
				BackgroundColor3 = i <= left and C.Armour or C.Faint,
				BackgroundTransparency = i <= left and 0.1 or 0.6,
				BorderSizePixel = 0,
				LayoutOrder = i,
				Parent = rec.Pips,
			})
			Theme.corner(pip, 2)
		end
	end
	rec.Broken.Visible = hits == 0
	if not rec.Glow then
		rec.Stroke.Color = hits == 0 and C.Bad or C.CellEdge
	end
end

-- the figure's colours from the fighter, when there is one
local function fighterColors(ctx)
	local colors = {}
	local model = ctx.Fighter
	if model and model.Parent then
		for _, p in ipairs(model:GetChildren()) do
			if p:IsA("BasePart") then
				colors[p.Name] = p.Color
			end
		end
	end
	return colors
end

function CharacterPanel:_dress(data)
	if not self.Figure then
		return
	end
	for slot, rec in pairs(self.Gear) do
		if data.Equipped[slot] ~= rec.Key then
			for _, p in ipairs(rec.Parts) do
				p:Destroy()
			end
			self.Gear[slot] = nil
		end
	end
	for slot, key in pairs(data.Equipped) do
		if not self.Gear[slot] and AR.Pieces[key] then
			self.Gear[slot] = { Key = key, Parts = ArmorView.BuildPiece(self.Figure, key, self.World, { Wind = BREEZE }) }
		end
	end
end

function CharacterPanel:Refresh(data)
	local armour, pieces = 0, 0
	for _, slot in ipairs(INV.Slots) do
		local key = data.Equipped[slot]
		self:_setSlot(slot, key)
		if key then
			pieces += 1
			if not AR.Pieces[key].Cosmetic then
				armour += 1
			end
		end
	end
	self.Stats.Text = string.format("%d worn  ·  %d armour  ·  %d slots", pieces, armour, data.Capacity)
	self:_dress(data)
end

function CharacterPanel:Opened()
	self.Open = true
	-- a fresh figure in the fighter's colours
	if self.Figure then
		self.Figure:Destroy()
	end
	for _, rec in pairs(self.Gear) do
		for _, p in ipairs(rec.Parts) do
			p:Destroy()
		end
	end
	self.Gear = {}
	self.Figure = ItemArt.Figure(fighterColors(self.Ctx))
	self.Figure.Parent = self.World
	self.Yaw, self.YawGoal = 160, 200 -- turns in to face a little to the side
	self:Refresh(InventoryClient.Data)
	self.Grid:Intro()
	for i, slot in ipairs(INV.Slots) do
		local rec = self.Slots[slot]
		rec.Scale.Scale = 0.5
		Theme.tween(rec.Scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0.12 + i * 0.04)
	end
end

function CharacterPanel:Closed()
	self.Open = false
	self.Turning = nil
	self.Grid:Hidden()
end

return CharacterPanel
